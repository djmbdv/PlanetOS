// Semantic analysis, array/memory fixpoint, and Vala emitter for c2vala.

using Planc;

namespace C2Vala {

    // Builder emitted for a C compound literal `(T){ .a = x }` (see
    // Translator.ensure_lit_helper).
    public class LitHelper : Object {
        public string name;
        public CType ctype;
        public GenericArray<string> fields = new GenericArray<string> ();
        public GenericArray<string> vtypes = new GenericArray<string> ();
    }

    public class ReportEntry : Object {
        public string name;
        public bool ok;
        public string reason;

        public ReportEntry (string name, bool ok, string reason = "") {
            this.name = name;
            this.ok = ok;
            this.reason = reason;
        }
    }

    public class LocalInfo : Object {
        public string name;
        public CType ctype;
        public bool is_array = false;
        public bool is_param = false;
        public bool has_ptr_arith = false;
        public bool has_addr_taken = false;

        public LocalInfo (string name, CType ctype, bool is_param = false) {
            this.name = name;
            this.ctype = ctype;
            this.is_param = is_param;
        }
    }

    public class FuncSig : Object {
        public string name;
        public CType ret_type;
        public bool ret_is_array = false;
        public bool is_extern = false;
        public bool is_varargs = false;
        public GenericArray<CType> param_types = new GenericArray<CType> ();
        public GenericArray<bool> param_is_array = new GenericArray<bool> ();

        public FuncSig (string name, CType ret_type) {
            this.name = name;
            this.ret_type = ret_type;
        }
    }

    public class GotoPlan : Object {
        public string label;
        public string flag_name;
        public bool is_general = false;
        public int target_idx = -1;
        public StmtIf? hoisted_if = null;
        public StmtBlock? hoisted_block = null;
        public int hoisted_label_idx = 0;
        public CStmt? loop_continue_stmt = null;
        public StmtSwitch? switch_case_sw = null;
        public int switch_case_idx = -1;
        public StmtBlock? nested_target_block = null;
        public int nested_label_idx = 0;
        public int top_stmt_idx = -1;

        public GotoPlan (string label, string flag_name, bool is_general = false, int target_idx = -1) {
            this.label = label;
            this.flag_name = flag_name;
            this.is_general = is_general;
            this.target_idx = target_idx;
        }
    }

    public class Translator : Object {
        private TranslationUnit tu;
        private GenericArray<FuncSig> sigs = new GenericArray<FuncSig> ();
        private GenericArray<string> enum_member_names = new GenericArray<string> ();
        private GenericArray<string> enum_member_types = new GenericArray<string> ();
        private int64[] enum_member_vals = new int64[256];
        private int enum_member_vals_len = 0;
        private NameIndexMap enum_map = new NameIndexMap (512);
        private NameIndexMap struct_map = new NameIndexMap (2048);
        private NameIndexMap sig_map = new NameIndexMap (4096);
        private NameIndexMap global_map = new NameIndexMap (1024);
        private NameIndexMap enum_member_map = new NameIndexMap (8192);
        private NameIndexMap del_sig_map = new NameIndexMap (512);
        private NameIndexMap del_name_map = new NameIndexMap (512);
        private NameIndexMap slice_map = new NameIndexMap (256);
        private GenericArray<string> slice_names = new GenericArray<string> ();
        private GenericArray<string> slice_vtypes = new GenericArray<string> ();
        private NameIndexMap opaque_map = new NameIndexMap (256);
        private GenericArray<string> opaque_names = new GenericArray<string> ();
        private NameIndexMap emitted_globals = new NameIndexMap (1024);
        private int[] del_lock = new int[1];
        private GenericArray<GenericArray<LocalInfo>> fn_locals = new GenericArray<GenericArray<LocalInfo>> ();

        // Struct types whose `T *` is used as an array (indexed, offset or
        // passed where an array is expected). Deciding this per *type* keeps
        // every declaration of that pointer consistent: a `T?` field can no
        // longer collide with a `T[]` parameter of the same struct.
        private NameIndexMap ptr_arr_map = new NameIndexMap (1024);

        private bool ptr_is_array (CType ct) {
            if (ct.kind != CTypeKind.PTR || ct.inner == null)
                return false;
            var inner = (CType) ct.inner;
            if (inner.kind == CTypeKind.STRUCT)
                return ptr_arr_map.get_index (inner.name) >= 0;
            return false;
        }

        private void mark_ptr_array (CType ct) {
            if (ct.kind != CTypeKind.PTR || ct.inner == null)
                return;
            var inner = (CType) ct.inner;
            if (inner.kind == CTypeKind.STRUCT && ptr_arr_map.get_index (inner.name) < 0)
                ptr_arr_map.set_index (inner.name, 1);
        }

        // Generated conversions between the two Vala views of a C pointer:
        // `T[]` (address + length) and `T?` (a single nullable reference).
        private NameIndexMap box_map = new NameIndexMap (128);
        private GenericArray<string> box_names = new GenericArray<string> ();
        private GenericArray<string> box_types = new GenericArray<string> ();

        private string ensure_box_helper (string vt) {
            Host.spin_lock (del_lock);
            int idx = box_map.get_index (vt);
            if (idx >= 0) {
                string existing = box_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            var m = new StrBuilder ("_c2v_box_");
            for (int i = 0; i < vt.length; i++) {
                char ch = vt[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string fn_name = m.str;
            box_map.set_index (vt, box_names.length);
            box_names.add (fn_name);
            box_types.add (vt);
            Host.spin_unlock (del_lock);
            return fn_name;
        }

        private void ensure_opaque_struct (string name) {
            if (name == "") return;
            Host.spin_lock (del_lock);
            if (opaque_map.get_index (name) < 0) {
                opaque_map.set_index (name, opaque_names.length);
                opaque_names.add (name);
            }
            Host.spin_unlock (del_lock);
        }

        private string ensure_slice_helper (CType elem_type) throws RefuseError {
            string vt = vala_type (elem_type, false);
            Host.spin_lock (del_lock);
            int idx = slice_map.get_index (vt);
            if (idx >= 0) {
                string existing = slice_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            var m = new StrBuilder ("_c2v_slice_");
            for (int i = 0; i < vt.length; i++) {
                char ch = vt[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string fn_name = m.str;
            slice_map.set_index (vt, slice_names.length);
            slice_names.add (fn_name);
            slice_vtypes.add (vt);
            Host.spin_unlock (del_lock);
            return fn_name;
        }

        private void push_enum_val (int64 v) {
            if (enum_member_vals_len >= enum_member_vals.length) {
                var bigger = new int64[enum_member_vals.length * 2];
                for (int i = 0; i < enum_member_vals_len; i++)
                    bigger[i] = enum_member_vals[i];
                enum_member_vals = bigger;
            }
            enum_member_vals[enum_member_vals_len++] = v;
        }

        public GenericArray<ReportEntry> report_entries = new GenericArray<ReportEntry> ();
        public int translated_count = 0;
        public int refused_count = 0;

        public Translator (TranslationUnit tu) {
            this.tu = tu;
            for (int i = 0; i < tu.enums.length; i++)
                enum_map.set_index (tu.enums[i].name, i);
            for (int i = 0; i < tu.structs.length; i++)
                struct_map.set_index (tu.structs[i].name, i);
            for (int i = 0; i < tu.globals.length; i++)
                global_map.set_index (tu.globals[i].name, i);
        }

        private Translator.worker (Translator src) {
            this.tu = src.tu;
            this.sigs = src.sigs;
            this.enum_member_names = src.enum_member_names;
            this.enum_member_types = src.enum_member_types;
            this.enum_member_vals = src.enum_member_vals;
            this.enum_member_vals_len = src.enum_member_vals_len;
            this.enum_map = src.enum_map;
            this.struct_map = src.struct_map;
            this.sig_map = src.sig_map;
            this.global_map = src.global_map;
            this.enum_member_map = src.enum_member_map;
            this.cur_locals = new GenericArray<LocalInfo> ();
            this.cur_gotos = new GenericArray<GotoPlan> ();
            this.del_names = src.del_names;
            this.del_sigs = src.del_sigs;
            this.del_ctypes = src.del_ctypes;
            this.del_sig_map = src.del_sig_map;
            this.del_name_map = src.del_name_map;
            this.slice_map = src.slice_map;
            this.slice_names = src.slice_names;
            this.slice_vtypes = src.slice_vtypes;
            this.assign_arr_map = src.assign_arr_map;
            this.assign_arr_names = src.assign_arr_names;
            this.assign_arr_vtypes = src.assign_arr_vtypes;
            this.ptr_arr_map = src.ptr_arr_map;
            this.box_map = src.box_map;
            this.box_names = src.box_names;
            this.box_types = src.box_types;
            this.lit_map = src.lit_map;
            this.lit_helpers = src.lit_helpers;
            this.idx_set_map = src.idx_set_map;
            this.idx_set_names = src.idx_set_names;
            this.idx_set_vtypes = src.idx_set_vtypes;
            this.op_assign_map = src.op_assign_map;
            this.op_assign_names = src.op_assign_names;
            this.op_assign_vtypes = src.op_assign_vtypes;
            this.op_assign_ops = src.op_assign_ops;
            this.opaque_map = src.opaque_map;
            this.opaque_names = src.opaque_names;
            this.del_lock = src.del_lock;
            this.fn_locals = src.fn_locals;
        }

        private static void refuse_loc (string file, int line, string msg) throws RefuseError {
            if (file != "")
                throw new RefuseError.FAILED (@"$file:$line: $msg");
            throw new RefuseError.FAILED (msg);
        }

        private EnumDef? find_enum (string name) {
            int idx = enum_map.get_index (name);
            return (idx >= 0) ? tu.enums[idx] : null;
        }

        private StructDef? find_struct (string name) {
            int idx = struct_map.get_index (name);
            return (idx >= 0) ? tu.structs[idx] : null;
        }

        private FuncSig? find_sig (string name) {
            int idx = sig_map.get_index (name);
            return (idx >= 0) ? sigs[idx] : null;
        }

        private int find_enum_member (string name) {
            return enum_member_map.get_index (name);
        }

        private static int type_rank (string k) {
            if (k == "bool") return 1;
            if (k == "char" || k == "uchar" || k == "int8" || k == "uint8") return 2;
            if (k == "short" || k == "ushort" || k == "int16" || k == "uint16") return 3;
            if (k == "int" || k == "uint" || k == "int32" || k == "uint32") return 4;
            if (k == "long" || k == "ulong" || k == "size_t" || k == "ssize_t" || k == "int64" || k == "uint64") return 5;
            if (k == "float") return 6;
            if (k == "double") return 7;
            return 4;
        }

        private const string VALA_KEYWORDS = "|abstract|as|async|base|bool|break|case|catch|char|class|const|construct|continue|default|delegate|delete|do|double|dynamic|else|ensures|enum|errordomain|extern|false|finally|float|for|foreach|get|global|if|in|inline|int|int8|int16|int32|int64|interface|internal|is|lock|long|namespace|new|null|object|out|override|owned|params|private|protected|public|ref|requires|return|sealed|set|short|signal|sizeof|static|string|struct|switch|this|throw|throws|true|try|typeof|uchar|uint|uint8|uint16|uint32|uint64|ulong|unichar|unowned|ushort|using|value|var|virtual|void|weak|while|yield|";

        private static bool is_vala_keyword (string s) {
            if (s.length == 0 || s.contains ("|"))
                return false;
            return VALA_KEYWORDS.contains ("|" + s + "|");
        }

        private static string esc_ident (string s) {
            if (s == "" || s.has_prefix ("@"))
                return s;
            return is_vala_keyword (s) ? ("@" + s) : s;
        }

        private static string norm_int_lit (ExprInt ei) {
            string r = ei.raw;
            if (r.has_suffix ("ULL") || r.has_suffix ("ull") || r.has_suffix ("Ull") || r.has_suffix ("uLL")
                || r.has_suffix ("LLU") || r.has_suffix ("llu") || r.has_suffix ("LLu") || r.has_suffix ("llU"))
                return "((uint64) " + r.substring (0, r.length - 3) + ")";
            if (r.has_suffix ("LL") || r.has_suffix ("ll") || r.has_suffix ("UL") || r.has_suffix ("ul")
                || r.has_suffix ("LU") || r.has_suffix ("lu") || r.has_suffix ("Ul") || r.has_suffix ("uL")) {
                string core = r.substring (0, r.length - 2);
                return ei.is_unsigned ? ("((uint64) " + core + ")") : ("((int64) " + core + ")");
            }
            if (r.has_suffix ("L") || r.has_suffix ("l"))
                return "((int64) " + r.substring (0, r.length - 1) + ")";
            return r;
        }

        private GenericArray<string> del_names = new GenericArray<string> ();
        private GenericArray<string> del_sigs = new GenericArray<string> ();
        private GenericArray<CType> del_ctypes = new GenericArray<CType> ();

        private string delegate_sig_key (CType fp) throws RefuseError {
            var sb = new StrBuilder ();
            sb.append (fp.fp_ret != null ? vala_type ((CType) fp.fp_ret, false) : "void");
            sb.append ("(");
            if (fp.fp_params != null) {
                for (int i = 0; i < fp.fp_params.length; i++) {
                    if (i > 0) sb.append (",");
                    sb.append (vala_type (fp.fp_params[i].ctype, false));
                }
            }
            sb.append (")");
            return sb.str;
        }

        private string ensure_delegate (CType fp, string hint) throws RefuseError {
            string key = delegate_sig_key (fp);
            Host.spin_lock (del_lock);
            int d_idx = del_sig_map.get_index (key);
            if (d_idx >= 0) {
                string res = del_names[d_idx];
                Host.spin_unlock (del_lock);
                return res;
            }
            string base_name = (hint != "") ? hint : @"_c2v_del_$(del_names.length)";
            string name = base_name;
            bool clash = (find_struct (name) != null || find_enum (name) != null
                || find_sig (name) != null || del_name_map.get_index (name) >= 0
                || global_map.get_index (name) >= 0);
            if (clash)
                name = @"_c2v_del_$(del_names.length)";
            del_sig_map.set_index (key, del_names.length);
            del_name_map.set_index (name, del_names.length);
            del_names.add (name);
            del_sigs.add (key);
            del_ctypes.add (fp);
            Host.spin_unlock (del_lock);
            return name;
        }

        private static bool is_unsigned_kind (string k) {
            return k == "uchar" || k == "ushort" || k == "uint" || k == "ulong" || k == "size_t"
                || k == "uint8" || k == "uint16" || k == "uint32" || k == "uint64";
        }

        private static string common_scalar (string a, string b) {
            if (a == "double" || b == "double") return "double";
            if (a == "float" || b == "float") return "float";
            int ra = type_rank (a);
            int rb = type_rank (b);
            if (ra < 4) { a = "int"; ra = 4; }
            if (rb < 4) { b = "int"; rb = 4; }
            if (ra > rb) return a;
            if (rb > ra) return b;
            return (is_unsigned_kind (a) || is_unsigned_kind (b)) ? (ra == 5 ? "uint64" : "uint32") : a;
        }

        // ---- Enum constant folding ----

        private int64 eval_const_expr (CExpr e) throws RefuseError {
            if (e is ExprInt)
                return ((ExprInt) e).val;
            if (e is ExprChar)
                return ((ExprChar) e).val;
            if (e is ExprIdent) {
                string nm = ((ExprIdent) e).name;
                int idx = find_enum_member (nm);
                if (idx >= 0)
                    return enum_member_vals[idx];
                refuse_loc (e.file, e.line, "non-constant enum initializer");
            }
            if (e is ExprUnary) {
                var u = (ExprUnary) e;
                int64 v = eval_const_expr (u.operand);
                if (u.op == "-") return -v;
                if (u.op == "+") return v;
                if (u.op == "~") return ~v;
                if (u.op == "!") return v == 0 ? 1 : 0;
                refuse_loc (e.file, e.line, @"unsupported constant unary '$(u.op)'");
            }
            if (e is ExprBinary) {
                var b = (ExprBinary) e;
                int64 l = eval_const_expr (b.left);
                int64 r = eval_const_expr (b.right);
                if (b.op == "+") return l + r;
                if (b.op == "-") return l - r;
                if (b.op == "*") return l * r;
                if (b.op == "/") return r != 0 ? l / r : 0;
                if (b.op == "%") return r != 0 ? l % r : 0;
                if (b.op == "<<") return l << r;
                if (b.op == ">>") return l >> r;
                if (b.op == "&") return l & r;
                if (b.op == "|") return l | r;
                if (b.op == "^") return l ^ r;
                if (b.op == "==") return (l == r) ? 1 : 0;
                if (b.op == "!=") return (l != r) ? 1 : 0;
                if (b.op == "<") return (l < r) ? 1 : 0;
                if (b.op == "<=") return (l <= r) ? 1 : 0;
                if (b.op == ">") return (l > r) ? 1 : 0;
                if (b.op == ">=") return (l >= r) ? 1 : 0;
                if (b.op == "&&") return (l != 0 && r != 0) ? 1 : 0;
                if (b.op == "||") return (l != 0 || r != 0) ? 1 : 0;
                refuse_loc (e.file, e.line, @"unsupported constant operator '$(b.op)'");
            }
            if (e is ExprTernary) {
                var te = (ExprTernary) e;
                return (eval_const_expr (te.cond) != 0)
                    ? eval_const_expr (te.if_true)
                    : eval_const_expr (te.if_false);
            }
            refuse_loc (e.file, e.line, "non-constant enum initializer");
            throw new RefuseError.FAILED ("unreachable");
        }

        private void resolve_enums () throws RefuseError {
            for (int ei = 0; ei < tu.enums.length; ei++) {
                var ed = tu.enums[ei];
                int64 next_val = 0;
                for (int mi = 0; mi < ed.members.length; mi++) {
                    var m = ed.members[mi];
                    if (m.init_expr != null) {
                        next_val = eval_const_expr ((CExpr) m.init_expr);
                    }
                    m.val = next_val;
                    m.has_val = true;
                    enum_member_map.set_index (m.name, enum_member_names.length);
                    enum_member_names.add (m.name);
                    enum_member_types.add (ed.name);
                    push_enum_val (next_val);
                    next_val++;
                }
            }
        }

        // ---- Whole-program array fixpoint ----

        private void build_sigs_and_fixpoint () throws RefuseError {
            for (int fi = 0; fi < tu.funcs.length; fi++) {
                var fn = tu.funcs[fi];
                var sig = new FuncSig (fn.name, fn.ret_type);
                var locals = new GenericArray<LocalInfo> ();
                for (int pi = 0; pi < fn.params.length; pi++) {
                    sig.param_types.add (fn.params[pi].ctype);
                    sig.param_is_array.add (fn.params[pi].ctype.is_char_ptr () || fn.params[pi].ctype.is_void_ptr ());
                    locals.add (new LocalInfo (fn.params[pi].name, fn.params[pi].ctype, true));
                }
                if (fn.body != null)
                    collect_locals_for_fixpoint ((CStmt) fn.body, locals);
                fn_locals.add (locals);
                sig.is_varargs = fn.is_varargs;
                sig_map.set_index (sig.name, sigs.length);
                sigs.add (sig);
            }
            // Prototypes of functions defined elsewhere (other .c files).
            for (int pi2 = 0; pi2 < tu.protos.length; pi2++) {
                var pf = tu.protos[pi2];
                if (sig_map.get_index (pf.name) >= 0)
                    continue;
                var psig = new FuncSig (pf.name, pf.ret_type);
                for (int pi = 0; pi < pf.params.length; pi++) {
                    psig.param_types.add (pf.params[pi].ctype);
                    psig.param_is_array.add (pf.params[pi].ctype.is_char_ptr () || pf.params[pi].ctype.is_void_ptr ());
                }
                psig.is_extern = true;
                psig.is_varargs = pf.is_varargs;
                sig_map.set_index (psig.name, sigs.length);
                sigs.add (psig);
            }

            // Fixpoint: propagate array-ness across calls and returns
            bool changed = true;
            while (changed) {
                changed = false;
                for (int fi = 0; fi < tu.funcs.length; fi++) {
                    var fn = tu.funcs[fi];
                    var sig = sigs[fi];
                    if (fn.body == null) continue;
                    var locals = fn_locals[fi];
                    for (int pi = 0; pi < fn.params.length; pi++) {
                        if (sig.param_is_array[pi])
                            locals[pi].is_array = true;
                    }
                    bool old_ret = sig.ret_is_array;
                    bool fn_changed = true;
                    while (fn_changed) {
                        fn_changed = scan_stmt_for_arrays ((CStmt) fn.body, locals, sig);
                    }
                    if (sig.ret_is_array != old_ret)
                        changed = true;
                    for (int pi = 0; pi < fn.params.length; pi++) {
                        if (locals[pi].is_array && !sig.param_is_array[pi]) {
                            sig.param_is_array[pi] = true;
                            mark_ptr_array (fn.params[pi].ctype);
                            changed = true;
                        }
                    }
                    if (sig.ret_is_array)
                        mark_ptr_array (fn.ret_type);
                }
            }
        }

        private LocalInfo? find_local (GenericArray<LocalInfo> locals, string name) {
            for (int i = locals.length - 1; i >= 0; i--) {
                if (locals[i].name == name)
                    return locals[i];
            }
            return null;
        }

        private void collect_locals_for_fixpoint (CStmt s, GenericArray<LocalInfo> locals) {
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    collect_locals_for_fixpoint (b.stmts[i], locals);
            } else if (s is StmtDecl) {
                var d = (StmtDecl) s;
                var li = new LocalInfo (d.name, d.ctype, false);
                if (d.ctype.kind == CTypeKind.ARRAY)
                    li.is_array = true;
                locals.add (li);
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                collect_locals_for_fixpoint (ifs.then_branch, locals);
                if (ifs.else_branch != null)
                    collect_locals_for_fixpoint ((CStmt) ifs.else_branch, locals);
            } else if (s is StmtWhile) {
                collect_locals_for_fixpoint (((StmtWhile) s).body, locals);
            } else if (s is StmtFor) {
                var fs = (StmtFor) s;
                if (fs.init_decl != null)
                    collect_locals_for_fixpoint ((CStmt) fs.init_decl, locals);
                collect_locals_for_fixpoint (fs.body, locals);
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                for (int i = 0; i < sw.cases.length; i++) {
                    for (int j = 0; j < sw.cases[i].stmts.length; j++)
                        collect_locals_for_fixpoint (sw.cases[i].stmts[j], locals);
                }
            } else if (s is StmtLabel) {
                collect_locals_for_fixpoint (((StmtLabel) s).stmt, locals);
            }
        }

        private static bool is_alloc_call (CExpr? e) {
            if (e == null || !(e is ExprCall))
                return false;
            var c = (ExprCall) e;
            if (c.callee is ExprIdent) {
                string nm = ((ExprIdent) c.callee).name;
                return nm == "malloc" || nm == "calloc" || nm == "realloc";
            }
            return false;
        }

        private bool mark_expr_array (CExpr e, GenericArray<LocalInfo> locals) {
            if (e is ExprIdent) {
                var li = find_local (locals, ((ExprIdent) e).name);
                if (li != null && li.ctype.kind == CTypeKind.PTR && !li.is_array) {
                    li.is_array = true;
                    mark_ptr_array (li.ctype);
                    return true;
                }
            }
            return false;
        }

        private bool scan_stmt_for_arrays (CStmt s, GenericArray<LocalInfo> locals, FuncSig cur_sig) throws RefuseError {
            bool changed = false;
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (scan_stmt_for_arrays (b.stmts[i], locals, cur_sig)) changed = true;
            } else if (s is StmtDecl) {
                var d = (StmtDecl) s;
                if (d.init != null) {
                    if (is_alloc_call (d.init)) {
                        var li = find_local (locals, d.name);
                        if (li != null && !li.is_array) { li.is_array = true; changed = true; }
                    } else if (d.init is ExprCall && ((ExprCall) d.init).callee is ExprIdent) {
                        var csig = find_sig (((ExprIdent) ((ExprCall) d.init).callee).name);
                        if (csig != null && csig.ret_is_array) {
                            var li = find_local (locals, d.name);
                            if (li != null && !li.is_array) { li.is_array = true; changed = true; }
                        }
                    }
                    if (scan_expr_for_arrays ((CExpr) d.init, locals)) changed = true;
                }
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                if (scan_expr_for_arrays (ifs.cond, locals)) changed = true;
                if (scan_stmt_for_arrays (ifs.then_branch, locals, cur_sig)) changed = true;
                if (ifs.else_branch != null && scan_stmt_for_arrays ((CStmt) ifs.else_branch, locals, cur_sig)) changed = true;
            } else if (s is StmtWhile) {
                var ws = (StmtWhile) s;
                if (scan_expr_for_arrays (ws.cond, locals)) changed = true;
                if (scan_stmt_for_arrays (ws.body, locals, cur_sig)) changed = true;
            } else if (s is StmtFor) {
                var fs = (StmtFor) s;
                if (fs.init_decl != null && scan_stmt_for_arrays ((CStmt) fs.init_decl, locals, cur_sig)) changed = true;
                if (fs.init_expr != null && scan_expr_for_arrays ((CExpr) fs.init_expr, locals)) changed = true;
                if (fs.cond != null && scan_expr_for_arrays ((CExpr) fs.cond, locals)) changed = true;
                if (fs.next != null && scan_expr_for_arrays ((CExpr) fs.next, locals)) changed = true;
                if (scan_stmt_for_arrays (fs.body, locals, cur_sig)) changed = true;
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                if (scan_expr_for_arrays (sw.cond, locals)) changed = true;
                for (int i = 0; i < sw.cases.length; i++) {
                    for (int j = 0; j < sw.cases[i].stmts.length; j++)
                        if (scan_stmt_for_arrays (sw.cases[i].stmts[j], locals, cur_sig)) changed = true;
                }
            } else if (s is StmtReturn) {
                var rs = (StmtReturn) s;
                if (rs.expr != null) {
                    if (rs.expr is ExprIdent) {
                        var li = find_local (locals, ((ExprIdent) rs.expr).name);
                        if (li != null && li.is_array && !cur_sig.ret_is_array) {
                            cur_sig.ret_is_array = true;
                            changed = true;
                        }
                    } else if (is_alloc_call (rs.expr) && !cur_sig.ret_is_array) {
                        cur_sig.ret_is_array = true;
                        changed = true;
                    }
                    if (scan_expr_for_arrays ((CExpr) rs.expr, locals)) changed = true;
                }
            } else if (s is StmtLabel) {
                if (scan_stmt_for_arrays (((StmtLabel) s).stmt, locals, cur_sig)) changed = true;
            } else if (s is StmtExpr) {
                var es = (StmtExpr) s;
                if (es.expr != null && scan_expr_for_arrays ((CExpr) es.expr, locals)) changed = true;
            }
            return changed;
        }

        private bool scan_expr_for_arrays (CExpr e, GenericArray<LocalInfo> locals) throws RefuseError {
            bool changed = false;
            if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                // Only mark non-char* pointers as array when indexed (char* is string unless malloc'd)
                if (ix.array is ExprIdent) {
                    var li = find_local (locals, ((ExprIdent) ix.array).name);
                    if (li != null && li.ctype.kind == CTypeKind.PTR && !li.ctype.is_char_ptr () && !li.is_array) {
                        li.is_array = true;
                        changed = true;
                    }
                }
                // The struct behind a pointer that is indexed is used as an
                // array, wherever that pointer was declared (field, global or
                // result of a call).
                var iat = infer_type (ix.array);
                if (iat != null && iat.kind == CTypeKind.PTR)
                    mark_ptr_array (iat);
                if (scan_expr_for_arrays (ix.array, locals)) changed = true;
                if (scan_expr_for_arrays (ix.index, locals)) changed = true;
            } else if (e is ExprUnary) {
                var u = (ExprUnary) e;
                if (u.op == "&" && u.operand is ExprIndex) {
                    var ix = (ExprIndex) u.operand;
                    if (mark_expr_array (ix.array, locals)) changed = true;
                } else if (u.op == "&" && u.operand is ExprIdent) {
                    var li = find_local (locals, ((ExprIdent) u.operand).name);
                    if (li != null && !li.is_array && !li.has_ptr_arith && !li.has_addr_taken
                        && (li.ctype.kind == CTypeKind.SCALAR || li.ctype.kind == CTypeKind.ENUM
                            || li.ctype.is_char_ptr () || li.ctype.is_struct_ptr ())) {
                        li.has_addr_taken = true;
                        changed = true;
                    }
                } else if (u.op == "*") {
                    CExpr dop = u.operand;
                    while (dop is ExprCast) dop = ((ExprCast) dop).expr;
                    if (dop is ExprUnary && ((ExprUnary) dop).op == "&")
                        return scan_expr_for_arrays (((ExprUnary) dop).operand, locals);
                    if (mark_expr_array (u.operand, locals)) changed = true;
                } else if ((u.op == "++" || u.op == "--") && u.operand is ExprIdent) {
                    var li = find_local (locals, ((ExprIdent) u.operand).name);
                    if (li != null && li.ctype.kind == CTypeKind.PTR) {
                        if (!li.is_array) { li.is_array = true; changed = true; }
                        if (!li.has_ptr_arith) { li.has_ptr_arith = true; changed = true; }
                    }
                }
                if (scan_expr_for_arrays (u.operand, locals)) changed = true;
            } else if (e is ExprAssign) {
                var a = (ExprAssign) e;
                // `s[i] = c` needs a mutable buffer, never a Vala string.
                if (a.lvalue is ExprIndex) {
                    var wix = (ExprIndex) a.lvalue;
                    if (wix.array is ExprIdent) {
                        var wli = find_local (locals, ((ExprIdent) wix.array).name);
                        if (wli != null && wli.ctype.kind == CTypeKind.PTR && !wli.is_array) {
                            wli.is_array = true;
                            changed = true;
                        }
                    }
                    var wat = infer_type (wix.array);
                    if (wat != null && wat.kind == CTypeKind.PTR)
                        mark_ptr_array (wat);
                }
                if (a.lvalue is ExprIdent) {
                    var li = find_local (locals, ((ExprIdent) a.lvalue).name);
                    if (li != null) {
                        if (li.ctype.kind == CTypeKind.PTR && (a.op == "+=" || a.op == "-=")) {
                            if (!li.is_array) { li.is_array = true; changed = true; }
                            if (!li.has_ptr_arith) { li.has_ptr_arith = true; changed = true; }
                        }
                        if (!li.is_array) {
                            if (is_alloc_call (a.rvalue)) {
                                li.is_array = true;
                                changed = true;
                            } else if (a.rvalue is ExprCall && ((ExprCall) a.rvalue).callee is ExprIdent) {
                                var csig = find_sig (((ExprIdent) ((ExprCall) a.rvalue).callee).name);
                                if (csig != null && csig.ret_is_array) {
                                    li.is_array = true;
                                    changed = true;
                                }
                            }
                        }
                    }
                }
                if (scan_expr_for_arrays (a.lvalue, locals)) changed = true;
                if (scan_expr_for_arrays (a.rvalue, locals)) changed = true;
            } else if (e is ExprCall) {
                var c = (ExprCall) e;
                if (c.callee is ExprIdent) {
                    string cfn = ((ExprIdent) c.callee).name;
                    if (cfn == "__atomic_load_n" || cfn == "__atomic_store_n"
                        || cfn == "__atomic_exchange_n" || cfn == "__atomic_fetch_add"
                        || cfn == "__atomic_fetch_sub") {
                        for (int i = 0; i < c.args.length; i++) {
                            var a = c.args[i];
                            if (i == 0 && a is ExprUnary && ((ExprUnary) a).op == "&") {
                                if (scan_expr_for_arrays (((ExprUnary) a).operand, locals)) changed = true;
                            } else if (i == 0 || i == 1) {
                                if (scan_expr_for_arrays (a, locals)) changed = true;
                            }
                        }
                        return changed;
                    }
                    if (cfn == "memcpy" || cfn == "memmove" || cfn == "memcmp") {
                        if (c.args.length >= 1 && mark_expr_array (c.args[0], locals)) changed = true;
                        if (c.args.length >= 2 && mark_expr_array (c.args[1], locals)) changed = true;
                    } else if (cfn == "memset") {
                        if (c.args.length >= 1 && mark_expr_array (c.args[0], locals)) changed = true;
                    }
                    var csig = find_sig (cfn);
                    if (csig != null) {
                        for (int i = 0; i < c.args.length && i < csig.param_is_array.length; i++) {
                            if (csig.param_is_array[i]) {
                                if (mark_expr_array (c.args[i], locals)) changed = true;
                            } else if (c.args[i] is ExprIdent) {
                                var li = find_local (locals, ((ExprIdent) c.args[i]).name);
                                if (li != null && li.is_array && !csig.param_is_array[i]) {
                                    csig.param_is_array[i] = true;
                                    changed = true;
                                }
                            }
                        }
                    }
                }
                for (int i = 0; i < c.args.length; i++)
                    if (scan_expr_for_arrays (c.args[i], locals)) changed = true;
            } else if (e is ExprBinary) {
                var b = (ExprBinary) e;
                if ((b.op == "+" || b.op == "-") && b.left is ExprIdent) {
                    var li = find_local (locals, ((ExprIdent) b.left).name);
                    if (li != null && li.ctype.kind == CTypeKind.PTR) {
                        if (!li.is_array) { li.is_array = true; changed = true; }
                        if (!li.has_ptr_arith) { li.has_ptr_arith = true; changed = true; }
                        mark_ptr_array (li.ctype);
                    }
                }
                if (b.op == "+" || b.op == "-") {
                    var lat = infer_type (b.left);
                    if (lat != null && lat.kind == CTypeKind.PTR)
                        mark_ptr_array (lat);
                    var rat2 = infer_type (b.right);
                    if (rat2 != null && rat2.kind == CTypeKind.PTR)
                        mark_ptr_array (rat2);
                }
                if (scan_expr_for_arrays (b.left, locals)) changed = true;
                if (scan_expr_for_arrays (b.right, locals)) changed = true;
            } else if (e is ExprTernary) {
                var t = (ExprTernary) e;
                if (scan_expr_for_arrays (t.cond, locals)) changed = true;
                if (scan_expr_for_arrays (t.if_true, locals)) changed = true;
                if (scan_expr_for_arrays (t.if_false, locals)) changed = true;
            } else if (e is ExprCast) {
                if (scan_expr_for_arrays (((ExprCast) e).expr, locals)) changed = true;
            } else if (e is ExprMember) {
                if (scan_expr_for_arrays (((ExprMember) e).obj, locals)) changed = true;
            }
            return changed;
        }

        // ---- Vala type formatting ----

        // True for both `union` and the typedef'd anonymous unions c2vala keeps
        // as structs flagged `is_union`.
        private bool is_union_type (CType ct) {
            if (ct.kind == CTypeKind.UNION)
                return true;
            if (ct.kind == CTypeKind.STRUCT) {
                var sd = find_struct (ct.name);
                return sd != null && sd.is_union;
            }
            return false;
        }

        // planc rejects `union[]` (and `union?[]`); a translated type that
        // needs one has to become a marker + stub instead of broken Vala.
        private void assert_supported_type (string vt) throws RefuseError {
            string inner = vt;
            if (inner.has_suffix ("[]"))
                inner = inner.substring (0, inner.length - 2);
            if (inner.has_suffix ("?"))
                inner = inner.substring (0, inner.length - 1);
            if (!vt.has_suffix ("[]"))
                return;
            var sd = find_struct (inner);
            if (sd != null && sd.is_union)
                throw new RefuseError.FAILED (@"planc does not support arrays of unions ('$vt')");
            if (del_name_map.get_index (inner) >= 0)
                throw new RefuseError.FAILED (@"planc does not support arrays of delegates ('$vt')");
        }

        private string vala_type (CType ct, bool as_array = false) throws RefuseError {
            if (ct.kind == CTypeKind.FUNC_PTR)
                return esc_ident (ensure_delegate (ct, ct.name)) + "?";
            if (ct.kind == CTypeKind.SCALAR)
                return ct.name;
            if (ct.kind == CTypeKind.ENUM)
                return esc_ident (ct.name);
            if (ct.kind == CTypeKind.STRUCT || ct.kind == CTypeKind.UNION) {
                if (ct.name == "FILE" || ct.name == "_c2v_FILE")
                    return "FileStream";
                if (find_struct (ct.name) == null)
                    ensure_opaque_struct (ct.name);
                return esc_ident (ct.name);
            }
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null) {
                if (((CType) ct.inner).is_scalar ("char"))
                    return "uint8[]";
                if (is_union_type ((CType) ct.inner))
                    throw new RefuseError.FAILED ("planc does not support arrays of unions");
                return vala_type ((CType) ct.inner, false) + "[]";
            }
            if (ct.kind == CTypeKind.PTR && ct.inner != null) {
                var inner = (CType) ct.inner;
                if (inner.is_scalar ("void"))
                    return "uint8[]";
                if (as_array) {
                    if (inner.is_scalar ("char"))
                        return "uint8[]";
                    if (is_union_type (inner))
                        throw new RefuseError.FAILED ("planc does not support arrays of unions");
                    string ia = vala_type (inner, false);
                    if (cur_fn != null && ia.has_suffix ("[]"))
                        throw new RefuseError.FAILED ("pointer to array/pointer (stacked arrays) is not supported");
                    return ia + "[]";
                }
                if (inner.is_scalar ("char"))
                    return "string";
                if (inner.kind == CTypeKind.STRUCT) {
                    if (inner.name == "FILE" || inner.name == "_c2v_FILE")
                        return "FileStream?";
                    if (find_struct (inner.name) == null)
                        ensure_opaque_struct (inner.name);
                    return esc_ident (inner.name) + "?";
                }
                string ib = vala_type (inner, false);
                if (cur_fn != null && ib.has_suffix ("[]"))
                    throw new RefuseError.FAILED ("pointer to array/pointer (stacked arrays) is not supported");
                return ib + "[]";
            }
            throw new RefuseError.FAILED ("unsupported type");
        }

        // ---- Main translation entry point ----

        private static Translator[] mt_workers;
        private static string[] mt_fn_code;
        private static ReportEntry[] mt_fn_rep;
        private static string[] mt_fn_err;
        private static bool mt_report_mode = false;
        private static int mt_nworkers = 1;

        private static void mt_run_worker (int wid) {
            var w = mt_workers[wid];
            int n = w.tu.funcs.length;
            for (int fi = wid; fi < n; fi += mt_nworkers) {
                var fn = w.tu.funcs[fi];
                var sig = w.sigs[fi];
                if (mt_report_mode) {
                    try {
                        var fsb = new StrBuilder ();
                        w.emit_func (fsb, fn, sig, fi);
                        mt_fn_code[fi] = fsb.str + "\n";
                        mt_fn_rep[fi] = new ReportEntry (fn.name, true);
                    } catch (RefuseError e) {
                        var rsb = new StrBuilder ();
                        w.emit_refused_func (rsb, fn, sig, e.message);
                        mt_fn_code[fi] = rsb.str;
                        mt_fn_rep[fi] = new ReportEntry (fn.name, false, e.message);
                    }
                } else {
                    try {
                        var fsb = new StrBuilder ();
                        w.emit_func (fsb, fn, sig, fi);
                        mt_fn_code[fi] = fsb.str + "\n";
                        mt_fn_rep[fi] = new ReportEntry (fn.name, true);
                    } catch (RefuseError e) {
                        var rsb = new StrBuilder ();
                        w.emit_refused_func (rsb, fn, sig, e.message);
                        mt_fn_code[fi] = rsb.str;
                        mt_fn_rep[fi] = new ReportEntry (fn.name, false, e.message);
                    }
                }
            }
        }

        public string translate (bool report_mode, string ns_name = "") throws RefuseError {
            resolve_enums ();
            build_sigs_and_fixpoint ();

            int nfuncs = tu.funcs.length;
            int ncpus = Host.cpu_count ();
            bool use_mt = (nfuncs >= 16 && ncpus > 1);
            if (use_mt) {
                int nw = (ncpus < nfuncs) ? ncpus : nfuncs;
                if (nw > 16) nw = 16;
                mt_nworkers = nw;
                mt_report_mode = report_mode;
                mt_workers = new Translator[nw];
                mt_fn_code = new string[nfuncs];
                mt_fn_rep = new ReportEntry[nfuncs];
                mt_fn_err = new string[nw];
                for (int wi = 0; wi < nw; wi++) {
                    mt_workers[wi] = new Translator.worker (this);
                    mt_fn_err[wi] = "";
                }
                int64[] handles = new int64[nw];
                for (int wi = 1; wi < nw; wi++)
                    handles[wi] = Host.thread_spawn (mt_run_worker, wi);
                mt_run_worker (0);
                for (int wi = 1; wi < nw; wi++)
                    Host.thread_join (handles[wi]);
                for (int wi = 0; wi < nw; wi++) {
                    if (mt_fn_err[wi] != "")
                        throw new RefuseError.FAILED (mt_fn_err[wi]);
                }
            }

            var types_sb = new StrBuilder ();
            var body_sb = new StrBuilder ();
            if (tu.refused_global_reason != null) {
                body_sb.append (@"// c2vala: UNTRANSLATED global ($(tu.refused_global_file ?? ""):$(tu.refused_global_line)) -- $(tu.refused_global_reason)\n");
                body_sb.append ("// TODO: declare and initialize it by hand.\n\n");
            }

            int ei = 0;
            int si = 0;
            int fi = 0;
            int gi = 0;
            for (int ti = 0; ti < tu.top_order.length; ti++) {
                string kind = tu.top_kinds[ti];
                if (kind == "enum") {
                    var ed = tu.enums[ei++];
                    try {
                        emit_enum (types_sb, ed);
                    } catch (RefuseError e) {
                        types_sb.append (@"// c2vala: UNTRANSLATED enum $(ed.name) -- $(e.message)\n// TODO: port this type by hand.\n");
                    }
                    types_sb.append ("\n");
                } else if (kind == "struct") {
                    var sd = tu.structs[si++];
                    try {
                        emit_struct (types_sb, sd);
                    } catch (RefuseError e) {
                        types_sb.append (@"// c2vala: UNTRANSLATED $(sd.is_union ? "union" : "struct") $(sd.name) -- $(e.message)\n// TODO: port this type by hand.\n");
                    }
                    types_sb.append ("\n");
                } else if (kind == "global") {
                    emit_global (body_sb, tu.globals[gi++]);
                    body_sb.append ("\n");
                } else if (kind == "func") {
                    int cur_fi = fi++;
                    if (use_mt) {
                        body_sb.append (mt_fn_code[cur_fi]);
                        var rep = mt_fn_rep[cur_fi];
                        if (rep != null) {
                            report_entries.add ((ReportEntry) rep);
                            if (rep.ok) translated_count++;
                            else refused_count++;
                        }
                        continue;
                    }
                    var fn = tu.funcs[cur_fi];
                    var sig = sigs[cur_fi];
                    if (report_mode) {
                        try {
                            var fsb = new StrBuilder ();
                            emit_func (fsb, fn, sig, cur_fi);
                            body_sb.append (fsb.str);
                            body_sb.append ("\n");
                            report_entries.add (new ReportEntry (fn.name, true));
                            translated_count++;
                        } catch (RefuseError e) {
                            body_sb.append (@"// c2vala refused $(fn.name): $(e.message)\n\n");
                            report_entries.add (new ReportEntry (fn.name, false, e.message));
                            refused_count++;
                        }
                    } else {
                        var fsb = new StrBuilder ();
                        try {
                            emit_func (fsb, fn, sig, cur_fi);
                            body_sb.append (fsb.str);
                            body_sb.append ("\n");
                            report_entries.add (new ReportEntry (fn.name, true));
                            translated_count++;
                        } catch (RefuseError e) {
                            emit_refused_func (body_sb, fn, sig, e.message);
                            report_entries.add (new ReportEntry (fn.name, false, e.message));
                            refused_count++;
                        }
                    }
                }
            }

            if (tu.globals.length > 0)
                emit_global_initializers (body_sb);

            var sb = new StrBuilder ();
            sb.append ("// Generated by c2vala.\n\n");
            if (ns_name != "")
                sb.append (@"namespace $ns_name {\n\n");
            for (int oi = 0; oi < opaque_names.length; oi++) {
                sb.append (@"[Compact]\npublic sealed class $(esc_ident (opaque_names[oi])) {}\n");
            }
            if (opaque_names.length > 0)
                sb.append ("\n");
            sb.append (types_sb.str);
            for (int di = 0; di < del_names.length; di++) {
                var fp = del_ctypes[di];
                string rtype = fp.fp_ret != null ? vala_type ((CType) fp.fp_ret, false) : "void";
                sb.append (@"public delegate $rtype $(esc_ident (del_names[di])) (");
                if (fp.fp_params != null) {
                    for (int pi = 0; pi < fp.fp_params.length; pi++) {
                        if (pi > 0) sb.append (", ");
                        var prm = fp.fp_params[pi];
                        sb.append (@"$(vala_type (prm.ctype, prm.ctype.is_char_ptr () || prm.ctype.is_void_ptr ())) $(esc_ident (prm.name))");
                    }
                }
                sb.append (");\n");
            }
            if (del_names.length > 0)
                sb.append ("\n");
            for (int si2 = 0; si2 < slice_names.length; si2++) {
                string sfn = slice_names[si2];
                string svt = slice_vtypes[si2];
                sb.append (@"private static $svt[] $sfn ($svt[] arr, int off) {\n");
                sb.append ("    if (off <= 0) return arr;\n");
                sb.append ("    if (off >= arr.length) return new " + svt + "[0];\n");
                sb.append ("    int n = arr.length - off;\n");
                sb.append (@"    $svt[] res = new $svt[n];\n");
                sb.append ("    for (int i = 0; i < n; i++) res[i] = arr[off + i];\n");
                sb.append ("    return res;\n");
                sb.append ("}\n\n");
            }
            for (int oi2 = 0; oi2 < op_assign_names.length; oi2++) {
                string ovt = op_assign_vtypes[oi2];
                sb.append (@"private static $ovt $(op_assign_names[oi2]) ($ovt v, ref $ovt t) {\n");
                sb.append (@"    t $(op_assign_ops[oi2])= v;\n");
                sb.append ("    return t;\n");
                sb.append ("}\n\n");
            }
            for (int bi = 0; bi < box_names.length; bi++) {
                string bvt = box_types[bi];
                sb.append (@"private static $bvt[] $(box_names[bi])_arr ($bvt? v) {\n");
                sb.append ("    if (v == null) return new " + bvt + "[0];\n");
                sb.append (@"    $bvt[] r = new $bvt[1];\n");
                sb.append ("    r[0] = v;\n");
                sb.append ("    return r;\n");
                sb.append ("}\n\n");
                sb.append (@"private static $bvt? $(box_names[bi])_obj ($bvt[] a) {\n");
                sb.append ("    if (a.length == 0) return null;\n");
                sb.append ("    return a[0];\n");
                sb.append ("}\n\n");
            }
            emit_lit_helpers (sb);
            for (int xi = 0; xi < idx_set_names.length; xi++) {
                string xvt = idx_set_vtypes[xi];
                sb.append (@"private static $xvt $(idx_set_names[xi]) ($xvt[] arr, int idx, $xvt v) {\n");
                sb.append ("    arr[idx] = v;\n");
                sb.append ("    return v;\n");
                sb.append ("}\n\n");
            }
            for (int ai = 0; ai < assign_arr_names.length; ai++) {
                string avt = assign_arr_vtypes[ai];
                sb.append (@"private static $avt $(assign_arr_names[ai]) ($avt v, ref $avt t) {\n");
                sb.append ("    t = v;\n");
                sb.append ("    return v;\n");
                sb.append ("}\n\n");
            }
            sb.append (body_sb.str);
            if (ns_name != "")
                sb.append ("}\n");
            return sb.str;
        }

        private static void emit_ignored_attrs (StrBuilder sb, GenericArray<string> attrs, int level = 0) {
            for (int i = 0; i < attrs.length; i++) {
                indent (sb, level);
                sb.append (@"// c2vala ignored: $(attrs[i])\n");
            }
        }

        private GenericArray<GlobalVarDef> runtime_globals = new GenericArray<GlobalVarDef> ();

        private static bool is_static_literal_init (CExpr? init) {
            return init is ExprInt || init is ExprFloat || init is ExprChar || init is ExprStr
                || (init is ExprUnary && ((ExprUnary) init).op == "-"
                    && (((ExprUnary) init).operand is ExprInt || ((ExprUnary) init).operand is ExprFloat));
        }

        private void emit_global (StrBuilder sb, GlobalVarDef g) throws RefuseError {
            if (g.name == "stdin" || g.name == "stdout" || g.name == "stderr")
                return;
            if (emitted_globals.get_index (g.name) >= 0)
                return;
            emitted_globals.set_index (g.name, 1);
            emit_ignored_attrs (sb, g.ignored_attrs);
            bool is_arr = (g.ctype.kind == CTypeKind.ARRAY);
            string vt = vala_type (g.ctype, is_arr);
            string gname = esc_ident (g.name);
            try {
                assert_supported_type (vt);
            } catch (RefuseError e) {
                sb.append (@"// c2vala: UNTRANSLATED global $(g.name) ($(g.file):$(g.line)) -- $(e.message)\n");
                sb.append (@"// TODO: declare and initialize it by hand.\n");
                return;
            }
            bool is_scalar_or_enum = (g.ctype.kind == CTypeKind.SCALAR || g.ctype.kind == CTypeKind.ENUM);

            if (g.init == null) {
                sb.append (@"public $vt $gname;\n");
                return;
            }
            if (is_scalar_or_enum && is_static_literal_init (g.init)) {
                string iv = emit_expr ((CExpr) g.init);
                if (g.ctype.is_const && (g.init is ExprInt || g.init is ExprStr || g.init is ExprChar))
                    sb.append (@"public const $vt $gname = $iv;\n");
                else
                    sb.append (@"public $vt $gname = $iv;\n");
                return;
            }
            if (g.ctype.is_const && vt == "string" && g.init is ExprStr) {
                sb.append (@"public const string $gname = $(emit_expr ((CExpr) g.init));\n");
                return;
            }

            // Arrays, pointers and structs cannot be initialized at namespace
            // scope (planc rejects global initializers outright), so they are
            // declared here and filled in by c2vala_init_globals ().
            sb.append (@"public $vt $gname;\n");
            if (!(g.init is ExprInt && ((ExprInt) g.init).val == 0))
                runtime_globals.add (g);
        }

        // Emits the body of c2vala_init_globals (), which carries every global
        // initializer that is not a static scalar literal. `main` calls it
        // first; when the translation unit is a library (.dlib) the consumer
        // has to call it once before using any translated symbol.
        private void emit_global_initializers (StrBuilder sb) throws RefuseError {
            cur_fn = null;
            cur_sig = null;
            cur_gotos = new GenericArray<GotoPlan> ();
            cur_locals = new GenericArray<LocalInfo> ();
            for (int gi = 0; gi < tu.globals.length; gi++) {
                var g = tu.globals[gi];
                var li = new LocalInfo (g.name, g.ctype, true);
                li.is_array = (g.ctype.kind == CTypeKind.ARRAY);
                cur_locals.add (li);
            }
            sb.append ("public void c2vala_init_globals () {\n");
            sb.append ("    c_init_stdio ();\n");
            for (int gi = 0; gi < runtime_globals.length; gi++) {
                var g = runtime_globals[gi];
                try {
                    emit_global_init (sb, g);
                } catch (RefuseError e) {
                    sb.append (@"    // c2vala: cannot initialize '$(g.name)': $(e.message)\n");
                }
            }
            sb.append ("}\n\n");
            cur_locals = new GenericArray<LocalInfo> ();
        }

        // Decodes a C string literal (raw text including the quotes) to bytes.
        // Returns null for escapes this decoder does not know.
        private static uint8[]? decode_c_string (string raw) {
            if (raw.length < 2)
                return null;
            var bytes = new GenericArray<uint8> ();
            int i = 1;
            int end = raw.length - 1;
            while (i < end) {
                uint8 ch = raw[i];
                if (ch != '\\') {
                    bytes.add (ch);
                    i++;
                    continue;
                }
                i++;
                if (i >= end)
                    return null;
                uint8 e = raw[i];
                if (e >= '0' && e <= '7') {
                    int v = 0;
                    int n = 0;
                    while (i < end && n < 3 && raw[i] >= '0' && raw[i] <= '7') {
                        v = v * 8 + (raw[i] - '0');
                        i++;
                        n++;
                    }
                    bytes.add ((uint8) v);
                } else if (e == 'x') {
                    i++;
                    int v = 0;
                    int n = 0;
                    while (i < end && n < 2) {
                        uint8 h = raw[i];
                        int d;
                        if (h >= '0' && h <= '9') d = h - '0';
                        else if (h >= 'a' && h <= 'f') d = 10 + h - 'a';
                        else if (h >= 'A' && h <= 'F') d = 10 + h - 'A';
                        else break;
                        v = v * 16 + d;
                        i++;
                        n++;
                    }
                    if (n == 0)
                        return null;
                    bytes.add ((uint8) v);
                } else {
                    i++;
                    switch (e) {
                        case 'n': bytes.add ('\n'); break;
                        case 't': bytes.add ('\t'); break;
                        case 'r': bytes.add ('\r'); break;
                        case 'a': bytes.add ((uint8) 7); break;
                        case 'b': bytes.add ((uint8) 8); break;
                        case 'f': bytes.add ((uint8) 12); break;
                        case 'v': bytes.add ((uint8) 11); break;
                        case '\\': bytes.add ('\\'); break;
                        case '\'': bytes.add ('\''); break;
                        case '"': bytes.add ('"'); break;
                        case '?': bytes.add ('?'); break;
                        default: return null;
                    }
                }
            }
            var res = new uint8[bytes.length];
            for (int k = 0; k < bytes.length; k++)
                res[k] = bytes[k];
            return res;
        }

        // True when `e` is emitted as a Vala array view (uint8[]/T[]) rather
        // than as a `string`. Call sites that need a `string` wrap the value in
        // c_bytes_to_str (see the return/assignment coercions).
        private bool emits_array_view (CExpr e) throws RefuseError {
            if (e is ExprCast)
                return emits_array_view (((ExprCast) e).expr);
            if (e is ExprUnary && ((ExprUnary) e).op == "&" && ((ExprUnary) e).operand is ExprIndex) {
                var ix = (ExprIndex) ((ExprUnary) e).operand;
                var at = infer_type (ix.array);
                if (at == null || at.inner == null)
                    return false;
                if (at.inner.is_scalar ("char") || at.inner.is_scalar ("void"))
                    return ptr_view (ix.array, at) == 2;
                return at.inner.kind == CTypeKind.SCALAR || at.inner.kind == CTypeKind.ENUM;
            }
            var t = infer_type (e);
            return t != null && (t.kind == CTypeKind.ARRAY
                || (t.kind == CTypeKind.PTR && ptr_view (e, t) == 2));
        }

        private NameIndexMap assign_arr_map = new NameIndexMap (64);
        private GenericArray<string> assign_arr_names = new GenericArray<string> ();
        private GenericArray<string> assign_arr_vtypes = new GenericArray<string> ();

        // Runtime helper for `x = y` used as a value when `x` holds a string or
        // an array (scalars use the fixed c_assign_* helpers).
        private string ensure_assign_helper (string vt) {
            Host.spin_lock (del_lock);
            int idx = assign_arr_map.get_index (vt);
            if (idx >= 0) {
                string existing = assign_arr_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            var m = new StrBuilder ("_c2v_assign_");
            for (int i = 0; i < vt.length; i++) {
                char ch = vt[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string fn_name = m.str;
            assign_arr_map.set_index (vt, assign_arr_names.length);
            assign_arr_names.add (fn_name);
            assign_arr_vtypes.add (vt);
            Host.spin_unlock (del_lock);
            return fn_name;
        }

        private NameIndexMap op_assign_map = new NameIndexMap (128);
        private GenericArray<string> op_assign_names = new GenericArray<string> ();
        private GenericArray<string> op_assign_vtypes = new GenericArray<string> ();
        private GenericArray<string> op_assign_ops = new GenericArray<string> ();

        // Runtime helper for a compound assignment used as a value, e.g.
        // `(v >>= 7) != 0`: the helper applies `t <op>= v` and returns `t`.
        private string ensure_op_assign_helper (string op, string vt) {
            string key = op + "|" + vt;
            Host.spin_lock (del_lock);
            int idx = op_assign_map.get_index (key);
            if (idx >= 0) {
                string existing = op_assign_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            var m = new StrBuilder ("_c2v_op_");
            string bop = op.has_suffix ("=") ? op.substring (0, op.length - 1) : op;
            string op_tag = "";
            if (bop == "+") op_tag = "add";
            else if (bop == "-") op_tag = "sub";
            else if (bop == "*") op_tag = "mul";
            else if (bop == "/") op_tag = "div";
            else if (bop == "%") op_tag = "mod";
            else if (bop == "&") op_tag = "and";
            else if (bop == "|") op_tag = "or";
            else if (bop == "^") op_tag = "xor";
            else if (bop == "<<") op_tag = "shl";
            else op_tag = "shr";
            m.append (op_tag);
            m.append_c ('_');
            for (int i = 0; i < vt.length; i++) {
                char ch = vt[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string fn_name = m.str;
            op_assign_map.set_index (key, op_assign_names.length);
            op_assign_names.add (fn_name);
            op_assign_vtypes.add (vt);
            op_assign_ops.add (bop);
            Host.spin_unlock (del_lock);
            return fn_name;
        }

        private NameIndexMap idx_set_map = new NameIndexMap (128);
        private GenericArray<string> idx_set_names = new GenericArray<string> ();
        private GenericArray<string> idx_set_vtypes = new GenericArray<string> ();

        // `a[i] = v` used as a value becomes `_c2v_set_T (a, i, v)`.
        private string ensure_index_set_helper (string vt) {
            Host.spin_lock (del_lock);
            int idx = idx_set_map.get_index (vt);
            if (idx >= 0) {
                string existing = idx_set_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            var m = new StrBuilder ("_c2v_set_");
            for (int i = 0; i < vt.length; i++) {
                char ch = vt[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string fn_name = m.str;
            idx_set_map.set_index (vt, idx_set_names.length);
            idx_set_names.add (fn_name);
            idx_set_vtypes.add (vt);
            Host.spin_unlock (del_lock);
            return fn_name;
        }

        // Vala type of an indexable element, or null when it cannot be
        // expressed as a `T[]` element (stacked arrays).
        private string? index_elem_vtype (CType et) throws RefuseError {
            if (et.kind == CTypeKind.SCALAR)
                return et.is_scalar ("char") ? "uint8" : et.name;
            if (et.kind == CTypeKind.ENUM)
                return et.name;
            if (et.kind == CTypeKind.STRUCT || et.kind == CTypeKind.UNION || et.kind == CTypeKind.PTR
                || et.kind == CTypeKind.FUNC_PTR) {
                string vt = vala_type (et, false);
                if (vt.has_suffix ("[]"))
                    return null;
                return vt;
            }
            return null;
        }

        // Normalizes an indexable assignment target (`a[i]`, `*p`, `*(p + n)`,
        // `*(&a[i])`) to the array expression, the element index and the Vala
        // element type.
        private bool extract_index_lvalue (CExpr lv, ref string? base_s, ref string? idx_s,
                                           ref string? elem_vt) throws RefuseError {
            CExpr t = lv;
            if (t is ExprUnary && ((ExprUnary) t).op == "*") {
                CExpr inner_e = ((ExprUnary) t).operand;
                while (inner_e is ExprCast) inner_e = ((ExprCast) inner_e).expr;
                if (inner_e is ExprUnary && ((ExprUnary) inner_e).op == "&")
                    t = ((ExprUnary) inner_e).operand;
                else if (inner_e is ExprBinary && (((ExprBinary) inner_e).op == "+"
                         || ((ExprBinary) inner_e).op == "-") && ((ExprBinary) inner_e).left is ExprIdent) {
                    var pb = (ExprBinary) inner_e;
                    string pn = ((ExprIdent) pb.left).name;
                    var pli = find_local (cur_locals, pn);
                    string off = (pli != null && pli.has_ptr_arith) ? @"_off_$pn" : "0";
                    string sign = (pb.op == "+") ? "+" : "-";
                    var it = infer_type (pb.left);
                    if (it == null || it.inner == null)
                        return false;
                    var ict = (CType) it.inner;
                    base_s = emit_expr (pb.left);
                    idx_s = @"$off $sign (int) ($(emit_expr (pb.right)))";
                    elem_vt = index_elem_vtype (ict);
                    return elem_vt != null;
                } else if (inner_e is ExprIdent) {
                    string pn2 = ((ExprIdent) inner_e).name;
                    var it2 = infer_type (inner_e);
                    if (it2 == null || it2.inner == null)
                        return false;
                    var ict2 = (CType) it2.inner;
                    var pli2 = find_local (cur_locals, pn2);
                    base_s = emit_expr (inner_e);
                    idx_s = (pli2 != null && pli2.has_ptr_arith) ? @"_off_$pn2" : "0";
                    elem_vt = index_elem_vtype (ict2);
                    return elem_vt != null;
                } else {
                    return false;
                }
            }
            if (!(t is ExprIndex))
                return false;
            var ix = (ExprIndex) t;
            var et = infer_type (ix);
            var at = infer_type (ix.array);
            if (et == null || at == null || (at.kind != CTypeKind.ARRAY && at.kind != CTypeKind.PTR))
                return false;
            elem_vt = index_elem_vtype (et);
            if (elem_vt == null)
                return false;
            base_s = emit_expr (ix.array);
            idx_s = @"(int) ($(emit_expr (ix.index)))";
            if (ix.array is ExprIdent) {
                string an = ((ExprIdent) ix.array).name;
                var ali = find_local (cur_locals, an);
                if (ali != null && ali.has_ptr_arith)
                    idx_s = @"_off_$an + $idx_s";
            }
            return true;
        }

        private void emit_global_init (StrBuilder sb, GlobalVarDef g) throws RefuseError {
            string gname = esc_ident (g.name);
            CExpr init = (CExpr) g.init;

            if (g.ctype.kind == CTypeKind.STRUCT || g.ctype.kind == CTypeKind.UNION) {
                unowned var gsd = find_struct (g.ctype.name);
                bool g_union = (gsd != null) && gsd.is_union && !union_needs_class (gsd);
                if (init is ExprInitList) {
                    sb.append (g_union
                        ? @"    $gname = $(esc_ident (g.ctype.name)) ();\n"
                        : @"    $gname = new $(esc_ident (g.ctype.name)) ();\n");
                    if (gsd != null)
                        emit_struct_init_assigns (sb, gname, (StructDef) gsd, (ExprInitList) init, 1);
                } else {
                    sb.append (@"    $gname = $(emit_expr (init));\n");
                }
                return;
            }

            if (g.ctype.kind == CTypeKind.ARRAY && g.ctype.inner != null) {
                var elem_ct = (CType) g.ctype.inner;
                // Use the element type of the declared array view, so `char[]`
                // becomes `uint8[]` exactly like the global's own type.
                string arr_t = vala_type (g.ctype, false);
                string elem_t = arr_t.has_suffix ("[]")
                    ? arr_t.substring (0, arr_t.length - 2)
                    : vala_type (elem_ct, false);
                if (init is ExprInitList) {
                    var il = (ExprInitList) init;
                    string len_s = (g.ctype.array_len != null)
                        ? emit_expr ((CExpr) g.ctype.array_len)
                        : @"$(il.items.length)";
                    sb.append (@"    $gname = new $elem_t[$len_s];\n");
                    if (elem_ct.kind == CTypeKind.STRUCT)
                        sb.append (@"    for (int _c2v_i = 0; _c2v_i < $gname.length; _c2v_i++) { $gname[_c2v_i] = new $elem_t (); }\n");
                    string? etgt = (elem_ct.kind == CTypeKind.SCALAR || elem_ct.kind == CTypeKind.ENUM) ? elem_t : null;
                    int seq_idx = 0;
                    for (int ii = 0; ii < il.items.length; ii++) {
                        CExpr? idx_e = (ii < il.index_exprs.length) ? il.index_exprs[ii] : null;
                        string idx_s;
                        if (idx_e != null) {
                            idx_s = emit_expr ((CExpr) idx_e);
                            if (idx_e is ExprInt)
                                seq_idx = (int) ((ExprInt) idx_e).val + 1;
                        } else {
                            idx_s = @"$seq_idx";
                            seq_idx++;
                        }
                        if (elem_ct.kind == CTypeKind.STRUCT && il.items[ii] is ExprInitList) {
                            var sd = find_struct (elem_ct.name);
                            if (sd != null)
                                emit_struct_init_assigns (sb, @"$gname[$idx_s]", (StructDef) sd, (ExprInitList) il.items[ii], 1);
                        } else {
                            sb.append (@"    $gname[$idx_s] = $(coerce_value (il.items[ii], etgt));\n");
                        }
                    }
                } else if (init is ExprStr) {
                    string sv = emit_expr (init);
                    var bytes = decode_c_string (((ExprStr) init).raw);
                    bool has_nul = false;
                    if (bytes != null) {
                        for (int bi = 0; bi < bytes.length; bi++) {
                            if (bytes[bi] == 0) {
                                has_nul = true;
                                break;
                            }
                        }
                    }
                    string len_s;
                    if (g.ctype.array_len != null)
                        len_s = emit_expr ((CExpr) g.ctype.array_len);
                    else if (has_nul && bytes != null)
                        len_s = @"$(bytes.length + 1)"; // .length stops at the NUL here
                    else
                        len_s = @"($sv.length + 1)";
                    sb.append (@"    $gname = new $elem_t[$len_s];\n");
                    if (has_nul && bytes != null) {
                        // A Vala/planc string stops at an embedded NUL, so the
                        // bytes are written one by one from the decoded literal.
                        for (int bi = 0; bi < bytes.length; bi++)
                            sb.append (@"    $gname[$bi] = $((int) bytes[bi]);\n");
                    } else {
                        sb.append (@"    c_strcpy_buf ($gname, $sv);\n");
                    }
                } else {
                    sb.append (@"    $gname = $(emit_global_ptr_value (init));\n");
                }
                return;
            }

            if (g.ctype.kind == CTypeKind.PTR && !is_null_ptr_expr (init))
                sb.append (@"    $gname = $(emit_global_ptr_value (init));\n");
            else
                sb.append (@"    $gname = $(emit_expr (init));\n");
        }

        // Pointer-valued global initializer as a Vala array view: `&global` and
        // `&arr[n]` become a slice of the base array instead of an element.
        private string emit_global_ptr_value (CExpr init) throws RefuseError {
            if (init is ExprCast)
                return emit_global_ptr_value (((ExprCast) init).expr);
            if (init is ExprUnary && ((ExprUnary) init).op == "&") {
                var u = (ExprUnary) init;
                if (u.operand is ExprIndex) {
                    var ix = (ExprIndex) u.operand;
                    var at = infer_type (ix.array);
                    if (at != null && at.inner != null && at.inner.kind != CTypeKind.ARRAY) {
                        string base_s = emit_expr (ix.array);
                        string off = @"(int) ($(emit_expr (ix.index)))";
                        if (at.inner.is_scalar ("char") || at.inner.is_scalar ("void"))
                            return @"c_bytes_add ($base_s, $off)";
                        string sh = ensure_slice_helper ((CType) at.inner);
                        return @"$sh ($base_s, $off)";
                    }
                }
                return emit_expr (u.operand);
            }
            return emit_expr (init);
        }

        private void emit_enum (StrBuilder sb, EnumDef ed) {
            sb.append (@"public enum $(esc_ident (ed.name)) {\n");
            for (int i = 0; i < ed.members.length; i++) {
                var m = ed.members[i];
                string comma = (i + 1 < ed.members.length) ? "," : "";
                sb.append (@"    $(esc_ident (m.name)) = $(m.val)$comma\n");
            }
            sb.append ("}\n");
        }

        // A planc union may only hold value types; a C union with pointers or
        // arrays is emitted as a class instead (storage overlap is lost) and
        // flagged so it can be fixed by hand.
        private bool is_ref_ctype (CType ct) {
            if (ct.kind == CTypeKind.PTR || ct.kind == CTypeKind.ARRAY
                || ct.kind == CTypeKind.STRUCT || ct.kind == CTypeKind.UNION
                || ct.kind == CTypeKind.FUNC_PTR)
                return true;
            return false;
        }

        // planc unions cannot hold reference-counted fields, so those C unions
        // are emitted as classes instead.
        private bool union_needs_class (StructDef sd) {
            if (!sd.is_union)
                return false;
            for (int i = 0; i < sd.fields.length; i++) {
                if (sd.fields[i].name != "" && is_ref_ctype (sd.fields[i].ctype))
                    return true;
            }
            return false;
        }

        private void emit_struct (StrBuilder sb, StructDef sd) throws RefuseError {
            if (sd.name == "_c2v_FILE" || sd.name == "FILE")
                return;
            emit_ignored_attrs (sb, sd.ignored_attrs);
            string sname = esc_ident (sd.name);
            bool union_as_class = union_needs_class (sd);
            if (union_as_class) {
                sb.append (@"// c2vala: union $(sd.name) holds reference-counted members, so it is\n");
                sb.append ("// emitted as a class: the overlapping storage of the C union is lost.\n");
                sb.append ("// TODO: review every use of this type by hand.\n");
            }
            if (sd.is_union && !union_as_class)
                sb.append (@"public union $sname {\n");
            else
                sb.append (@"public sealed class $sname : Object {\n");

            bool has_bf = false;
            for (int i = 0; i < sd.fields.length; i++) {
                if (sd.fields[i].bit_width >= 0) {
                    has_bf = true;
                    break;
                }
            }

            if (!has_bf || sd.is_union) {
                for (int i = 0; i < sd.fields.length; i++) {
                    var f = sd.fields[i];
                    if (f.name == "")
                        continue;
                    string vt = vala_type (f.ctype, false);
                    sb.append (@"    public $vt $(esc_ident (f.name));\n");
                }
                sb.append ("}\n");
                return;
            }

            int bf_word = -1;
            int bf_off = 64;
            var bf_sb = new StrBuilder ();
            for (int i = 0; i < sd.fields.length; i++) {
                var f = sd.fields[i];
                if (f.bit_width < 0) {
                    if (f.name != "") {
                        string vt = vala_type (f.ctype, false);
                        sb.append (@"    public $vt $(esc_ident (f.name));\n");
                    }
                    continue;
                }
                if (f.bit_width == 0) {
                    bf_off = 64; // force next backing word
                    continue;
                }
                int w = f.bit_width;
                if (w > 64) w = 64;
                if (bf_off + w > 64) {
                    bf_word++;
                    bf_off = 0;
                    sb.append (@"    private uint64 _bf$bf_word;\n");
                }
                if (f.name != "") {
                    string vt = vala_type (f.ctype, false);
                    string fn = esc_ident (f.name);
                    uint64 mask = (w >= 64) ? uint64.MAX : (((uint64) 1 << w) - 1);
                    string mask_s = @"((uint64) $(mask.to_string ()))";
                    bool is_signed = !is_unsigned_kind (vt) && vt != "bool";
                    bf_sb.append (@"    public $vt $fn {\n");
                    bf_sb.append ("        get {\n");
                    bf_sb.append (@"            uint64 raw = (_bf$bf_word >> $bf_off) & $mask_s;\n");
                    if (vt == "bool") {
                        bf_sb.append ("            return raw != 0;\n");
                    } else if (is_signed && w < 64) {
                        uint64 sign_bit = (uint64) 1 << (w - 1);
                        bf_sb.append (@"            if ((raw & ((uint64) $(sign_bit.to_string ()))) != 0)\n");
                        bf_sb.append (@"                raw |= ~$mask_s;\n");
                        bf_sb.append (@"            return ($vt) ((int64) raw);\n");
                    } else {
                        bf_sb.append (@"            return ($vt) raw;\n");
                    }
                    bf_sb.append ("        }\n");
                    bf_sb.append ("        set {\n");
                    string vcast = (vt == "bool") ? "(value ? ((uint64) 1) : ((uint64) 0))" : "((uint64) value)";
                    bf_sb.append (@"            _bf$bf_word = (_bf$bf_word & ~($mask_s << $bf_off)) | (($vcast & $mask_s) << $bf_off);\n");
                    bf_sb.append ("        }\n");
                    bf_sb.append ("    }\n");
                }
                bf_off += w;
            }
            sb.append (bf_sb.str);
            sb.append ("}\n");
        }

        // ---- Function emission ----

        private GenericArray<LocalInfo> cur_locals = new GenericArray<LocalInfo> ();
        private GenericArray<GotoPlan> cur_gotos = new GenericArray<GotoPlan> ();
        private FuncDef? cur_fn = null;
        private FuncSig? cur_sig = null;

        // Best-effort Vala type for a stub member; unsupported C types fall
        // back to something that still has the same arity.
        private string stub_type (CType ct, bool as_array) {
            try {
                string vt = vala_type (ct, as_array);
                assert_supported_type (vt);
                return vt;
            } catch (RefuseError e) {
                if (ct.kind == CTypeKind.PTR || ct.kind == CTypeKind.ARRAY)
                    return "uint8[]";
                return "int";
            }
        }

        private string default_value_for (CType ct, string vt) {
            if (ct.kind == CTypeKind.ARRAY)
                return @"new $(vt.has_suffix ("[]") ? vt.substring (0, vt.length - 2) : "uint8")[0]";
            if (ct.kind == CTypeKind.PTR) {
                if (vt == "string") return "\"\"";
                if (vt.has_suffix ("[]"))
                    return @"new $(vt.substring (0, vt.length - 2))[0]";
                return "null";
            }
            if (ct.kind == CTypeKind.FUNC_PTR)
                return "null";
            if (ct.kind == CTypeKind.STRUCT)
                return @"new $vt ()";
            if (ct.kind == CTypeKind.UNION)
                return @"$vt ()";
            if (ct.kind == CTypeKind.ENUM)
                return @"(($vt) 0)";
            if (vt == "bool") return "false";
            if (vt == "double" || vt == "float") return "0.0";
            if (vt == "string") return "\"\"";
            if (vt.has_suffix ("[]"))
                return @"new $(vt.substring (0, vt.length - 2))[0]";
            if (vt.has_suffix ("?"))
                return "null";
            return "0";
        }

        // A function c2vala cannot translate is left in place as a marker plus
        // a stub with the same shape, so the rest of the output still compiles
        // and the function can be ported by hand in the generated Vala.
        private void emit_refused_func (StrBuilder sb, FuncDef fn, FuncSig sig, string reason) {
            if (fn.file != "")
                sb.append (@"// c2vala: UNTRANSLATED $(fn.name) ($(fn.file):$(fn.line)) -- $reason\n");
            else
                sb.append (@"// c2vala: UNTRANSLATED $(fn.name) -- $reason\n");
            sb.append ("// TODO: port this function by hand.\n");
            string ret_t = stub_type (fn.ret_type, sig.ret_is_array);
            sb.append (@"$ret_t $(esc_ident (fn.name)) (");
            for (int i = 0; i < fn.params.length; i++) {
                if (i > 0)
                    sb.append (", ");
                sb.append (@"$(stub_type (fn.params[i].ctype, sig.param_is_array[i])) $(esc_ident (fn.params[i].name))");
            }
            if (fn.is_varargs) {
                if (fn.params.length > 0)
                    sb.append (", ");
                sb.append ("...");
            }
            sb.append (") {\n");
            if (!fn.ret_type.is_scalar ("void")) {
                sb.append (@"    return $(default_value_for (fn.ret_type, ret_t));\n");
            }
            sb.append ("}\n\n");
        }

        private void emit_func (StrBuilder sb, FuncDef fn, FuncSig sig, int func_idx) throws RefuseError {
            emit_ignored_attrs (sb, fn.ignored_attrs);

            cur_fn = fn;
            cur_sig = sig;
            cur_locals = new GenericArray<LocalInfo> ();
            for (int gi = 0; gi < tu.globals.length; gi++) {
                var g = tu.globals[gi];
                var gli = new LocalInfo (g.name, g.ctype, false);
                gli.is_array = (g.ctype.kind == CTypeKind.ARRAY);
                cur_locals.add (gli);
            }
            cur_gotos = new GenericArray<GotoPlan> ();

            if (fn.name == "main") {
                sb.append ("int main (string[] args) {\n");
                if (tu.globals.length > 0)
                    sb.append ("    c2vala_init_globals ();\n");
            } else {
                var prescan_p = fn_locals[func_idx];
                string ret_t = vala_type (fn.ret_type, sig.ret_is_array);
                assert_supported_type (ret_t);
                sb.append (@"$ret_t $(esc_ident (fn.name)) (");
                for (int i = 0; i < fn.params.length; i++) {
                    var p = fn.params[i];
                    string pt = vala_type (p.ctype, sig.param_is_array[i]);
                    assert_supported_type (pt);
                    if (i > 0)
                        sb.append (", ");
                    var ppl = find_local (prescan_p, p.name);
                    string pname = (ppl != null && ppl.has_addr_taken && !sig.param_is_array[i])
                        ? esc_ident (@"_p_$(p.name)") : esc_ident (p.name);
                    sb.append (@"$pt $pname");
                    var li = new LocalInfo (p.name, p.ctype, true);
                    li.is_array = sig.param_is_array[i];
                    cur_locals.add (li);
                }
                if (fn.is_varargs) {
                    if (fn.params.length > 0)
                        sb.append (", ");
                    sb.append ("...");
                }
                sb.append (") {\n");
            }

            if (fn.body != null) {
                var blk = (StmtBlock) fn.body;
                var prescan_locals = fn_locals[func_idx];
                for (int pi = 0; pi < cur_locals.length; pi++) {
                    var pl = find_local (prescan_locals, cur_locals[pi].name);
                    if (pl != null) {
                        cur_locals[pi].has_ptr_arith = pl.has_ptr_arith;
                        if (pl.has_ptr_arith && cur_locals[pi].is_param)
                            sb.append (@"    int _off_$(cur_locals[pi].name) = 0;\n");
                        if (pl.has_addr_taken && cur_locals[pi].is_param && !cur_locals[pi].is_array) {
                            cur_locals[pi].has_addr_taken = true;
                            string bpt = vala_type (cur_locals[pi].ctype, false);
                            string en = esc_ident (cur_locals[pi].name);
                            sb.append (@"    $bpt[] $en = { $(esc_ident (@"_p_$(cur_locals[pi].name)")) };\n");
                        }
                    }
                }
                cur_prescan = prescan_locals;

                plan_gotos (blk);
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    sb.append (@"    bool $(cur_gotos[gi].flag_name) = false;\n");
                }
                bool has_gen = false;
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    if (cur_gotos[gi].is_general) {
                        has_gen = true;
                        break;
                    }
                }
                if (!has_gen) {
                    emit_stmt_list (sb, blk.stmts, 1);
                } else {
                    emit_body_with_general_gotos (sb, blk);
                }
            }
            sb.append ("}\n");
        }

        private GenericArray<LocalInfo>? cur_prescan = null;
        private CStmt? cur_loop_stmt = null;

        private string? all_goto_cond (CStmt? current_loop = null) {
            if (cur_gotos.length == 0)
                return null;
            var sb = new StrBuilder ();
            int cnt = 0;
            for (int i = 0; i < cur_gotos.length; i++) {
                if (current_loop != null && cur_gotos[i].loop_continue_stmt == current_loop)
                    continue;
                if (cur_gotos[i].switch_case_sw != null)
                    continue;
                if (cnt > 0) sb.append (" || ");
                sb.append (cur_gotos[i].flag_name);
                cnt++;
            }
            return cnt > 0 ? sb.str : null;
        }

        private void emit_body_with_general_gotos (StrBuilder sb, StmtBlock blk) throws RefuseError {
            // Collect sorted general goto target indices
            var lbl_indices = new GenericArray<int> ();
            var lbl_flags = new GenericArray<string> ();
            for (int i = 0; i < blk.stmts.length; i++) {
                if (blk.stmts[i] is StmtLabel) {
                    var ls = (StmtLabel) blk.stmts[i];
                    var gp = find_goto_plan (ls.label);
                    if (gp != null && gp.is_general) {
                        lbl_indices.add (i);
                        lbl_flags.add (gp.flag_name);
                    }
                } else {
                    for (int gi = 0; gi < cur_gotos.length; gi++) {
                        if (cur_gotos[gi].nested_target_block != null && cur_gotos[gi].top_stmt_idx == i) {
                            lbl_indices.add (i);
                            lbl_flags.add (cur_gotos[gi].flag_name);
                            break;
                        }
                    }
                }
            }

            // Hoist top-level StmtDecl variables so they remain in scope across label blocks
            for (int i = 0; i < blk.stmts.length; i++) {
                if (blk.stmts[i] is StmtDecl) {
                    var d = (StmtDecl) blk.stmts[i];
                    var d_no_init = new StmtDecl () { name = d.name, ctype = d.ctype, file = d.file, line = d.line };
                    emit_decl (sb, d_no_init, 1);
                }
            }

            int seg_start = 0;
            for (int k = 0; k <= lbl_indices.length; k++) {
                int seg_end = (k < lbl_indices.length) ? lbl_indices[k] : blk.stmts.length;
                if (k > 0) {
                    // Skip this label's block only if a later general goto is active
                    bool has_later = (k < lbl_flags.length);
                    if (has_later) {
                        sb.append ("    if (");
                        for (int li = k; li < lbl_flags.length; li++) {
                            if (li > k) sb.append (" && ");
                            sb.append (@"!$(lbl_flags[li])");
                        }
                        sb.append (") {\n");
                    }
                    bool is_nested = false;
                    for (int gi = 0; gi < cur_gotos.length; gi++) {
                        if (cur_gotos[gi].nested_target_block != null && cur_gotos[gi].top_stmt_idx == seg_start) {
                            is_nested = true;
                            break;
                        }
                    }
                    if (!is_nested)
                        sb.append (@"    $(lbl_flags[k - 1]) = false;\n");
                }
                bool wrap_do = true;
                if (k == lbl_indices.length) {
                    var seg_gotos = new GenericArray<StmtGoto> ();
                    for (int si = seg_start; si < seg_end; si++)
                        collect_gotos (blk.stmts[si], seg_gotos);
                    if (seg_gotos.length == 0)
                        wrap_do = false;
                }
                if (wrap_do)
                    sb.append ("    do {\n");
                int body_lvl = wrap_do ? 2 : 1;
                for (int si = seg_start; si < seg_end; si++) {
                    var st = blk.stmts[si];
                    if (st is StmtDecl) {
                        var d = (StmtDecl) st;
                        if (d.init != null) {
                            var a = new ExprAssign () {
                                op = "=",
                                lvalue = new ExprIdent () { name = d.name, file = d.file, line = d.line },
                                rvalue = (CExpr) d.init,
                                file = d.file,
                                line = d.line
                            };
                            var es = new StmtExpr () { expr = a, file = d.file, line = d.line };
                            emit_stmt (sb, es, body_lvl);
                        }
                    } else if (st is StmtLabel && k > 0 && si == seg_start) {
                        var ls = (StmtLabel) st;
                        emit_stmt (sb, ls.stmt, body_lvl);
                    } else {
                        emit_stmt (sb, st, body_lvl);
                    }
                    if (wrap_do && (st is StmtFor || st is StmtWhile || st is StmtIf || st is StmtBlock || st is StmtSwitch)) {
                        string? gc = all_goto_cond ();
                        if (gc != null) {
                            indent (sb, body_lvl);
                            sb.append (@"if ($gc) break;\n");
                        }
                    }
                }
                if (wrap_do)
                    sb.append ("    } while (false);\n");
                if (k > 0 && k < lbl_flags.length)
                    sb.append ("    }\n");
                seg_start = seg_end;
            }
            for (int gi = 0; gi < cur_gotos.length; gi++) {
                var gp = cur_gotos[gi];
                if (gp.hoisted_block != null) {
                    var hb = (StmtBlock) gp.hoisted_block;
                    sb.append (@"    if ($(gp.flag_name)) {\n");
                    sb.append (@"        $(gp.flag_name) = false;\n");
                    for (int hi = gp.hoisted_label_idx; hi < hb.stmts.length; hi++) {
                        var hs = hb.stmts[hi];
                        if (hi == gp.hoisted_label_idx && hs is StmtLabel)
                            emit_stmt (sb, ((StmtLabel) hs).stmt, 2);
                        else
                            emit_stmt (sb, hs, 2);
                    }
                    sb.append ("    }\n");
                }
            }
        }

        private bool is_empty_stmt (CStmt s) {
            if (s is StmtExpr && ((StmtExpr) s).expr == null)
                return true;
            if (s is StmtBlock && ((StmtBlock) s).stmts.length == 0)
                return true;
            return false;
        }

        private CStmt? find_loop_tail_label (CStmt s, string label) {
            if (s is StmtWhile) {
                var ws = (StmtWhile) s;
                if (ws.body is StmtBlock) {
                    var wb = (StmtBlock) ws.body;
                    if (wb.stmts.length > 0 && wb.stmts[wb.stmts.length - 1] is StmtLabel) {
                        var ls = (StmtLabel) wb.stmts[wb.stmts.length - 1];
                        if (ls.label == label && is_empty_stmt (ls.stmt))
                            return s;
                    }
                }
                return find_loop_tail_label (ws.body, label);
            }
            if (s is StmtFor) {
                var fs = (StmtFor) s;
                if (fs.body is StmtBlock) {
                    var fb = (StmtBlock) fs.body;
                    if (fb.stmts.length > 0 && fb.stmts[fb.stmts.length - 1] is StmtLabel) {
                        var ls = (StmtLabel) fb.stmts[fb.stmts.length - 1];
                        if (ls.label == label && is_empty_stmt (ls.stmt))
                            return s;
                    }
                }
                return find_loop_tail_label (fs.body, label);
            }
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++) {
                    var r = find_loop_tail_label (b.stmts[i], label);
                    if (r != null) return r;
                }
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                var r = find_loop_tail_label (ifs.then_branch, label);
                if (r != null) return r;
                if (ifs.else_branch != null)
                    return find_loop_tail_label ((CStmt) ifs.else_branch, label);
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                for (int i = 0; i < sw.cases.length; i++) {
                    for (int j = 0; j < sw.cases[i].stmts.length; j++) {
                        var r = find_loop_tail_label (sw.cases[i].stmts[j], label);
                        if (r != null) return r;
                    }
                }
            }
            return null;
        }

        private bool find_switch_case_label (CStmt s, string label, out StmtSwitch? out_sw, out int out_ci) {
            out_sw = null;
            out_ci = -1;
            if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                for (int i = 0; i < sw.cases.length; i++) {
                    var sc = sw.cases[i];
                    if (sc.stmts.length > 0 && sc.stmts[0] is StmtLabel
                        && ((StmtLabel) sc.stmts[0]).label == label) {
                        out_sw = sw;
                        out_ci = i;
                        return true;
                    }
                    for (int j = 0; j < sc.stmts.length; j++) {
                        if (find_switch_case_label (sc.stmts[j], label, out out_sw, out out_ci))
                            return true;
                    }
                }
            } else if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++) {
                    if (find_switch_case_label (b.stmts[i], label, out out_sw, out out_ci))
                        return true;
                }
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                if (find_switch_case_label (ifs.then_branch, label, out out_sw, out out_ci))
                    return true;
                if (ifs.else_branch != null && find_switch_case_label ((CStmt) ifs.else_branch, label, out out_sw, out out_ci))
                    return true;
            } else if (s is StmtWhile) {
                return find_switch_case_label (((StmtWhile) s).body, label, out out_sw, out out_ci);
            } else if (s is StmtFor) {
                return find_switch_case_label (((StmtFor) s).body, label, out out_sw, out out_ci);
            }
            return false;
        }

        private bool find_nested_if_label (CStmt s, string label, out StmtBlock? out_blk, out int out_idx) {
            out_blk = null;
            out_idx = 0;
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int li = 0; li < b.stmts.length; li++) {
                    if (b.stmts[li] is StmtLabel && ((StmtLabel) b.stmts[li]).label == label) {
                        out_blk = b;
                        out_idx = li;
                        return true;
                    }
                    if (find_nested_if_label (b.stmts[li], label, out out_blk, out out_idx))
                        return true;
                }
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                if (find_nested_if_label (ifs.then_branch, label, out out_blk, out out_idx))
                    return true;
                if (ifs.else_branch != null && find_nested_if_label ((CStmt) ifs.else_branch, label, out out_blk, out out_idx))
                    return true;
            }
            return false;
        }

        private bool stmt_contains_block (CStmt? s, StmtBlock target) {
            if (s == null) return false;
            if (s == target) return true;
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (stmt_contains_block (b.stmts[i], target)) return true;
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                if (stmt_contains_block (ifs.then_branch, target)) return true;
                if (stmt_contains_block (ifs.else_branch, target)) return true;
            }
            return false;
        }

        private bool find_hoisted_tail_label (CStmt s, string label, out StmtIf? out_if, out StmtBlock? out_blk, out int out_idx, bool is_root = false) {
            out_if = null;
            out_blk = null;
            out_idx = 0;
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                if (!is_root && b.stmts.length > 0 && b.stmts[b.stmts.length - 1] is StmtReturn) {
                    for (int li = 0; li < b.stmts.length; li++) {
                        if (b.stmts[li] is StmtLabel && ((StmtLabel) b.stmts[li]).label == label) {
                            out_blk = b;
                            out_idx = li;
                            return true;
                        }
                    }
                }
                for (int i = 0; i < b.stmts.length; i++) {
                    if (find_hoisted_tail_label (b.stmts[i], label, out out_if, out out_blk, out out_idx, false))
                        return true;
                }
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                if (find_hoisted_tail_label (ifs.then_branch, label, out out_if, out out_blk, out out_idx, false))
                    return true;
                if (ifs.else_branch != null && find_hoisted_tail_label ((CStmt) ifs.else_branch, label, out out_if, out out_blk, out out_idx, false))
                    return true;
            }
            return false;
        }

        private void plan_gotos (StmtBlock blk) throws RefuseError {
            var gotos = new GenericArray<StmtGoto> ();
            collect_gotos (blk, gotos);
            if (gotos.length == 0)
                return;

            for (int gi = 0; gi < gotos.length; gi++) {
                var g = gotos[gi];
                if (g.label == "")
                    refuse_loc (g.file, g.line, "computed gotos are not supported");
                if (find_goto_plan (g.label) != null)
                    continue;
                bool found = false;
                for (int i = 0; i + 1 < blk.stmts.length; i++) {
                    var cur_s = blk.stmts[i];
                    var nxt_s = blk.stmts[i + 1];
                    if ((cur_s is StmtFor || cur_s is StmtWhile) && nxt_s is StmtLabel) {
                        var ls = (StmtLabel) nxt_s;
                        if (ls.label == g.label) {
                            found = true;
                            cur_gotos.add (new GotoPlan (g.label, "c2v_goto_" + g.label, false, i + 1));
                            break;
                        }
                    }
                }
                if (!found) {
                    for (int i = 0; i < blk.stmts.length; i++) {
                        if (blk.stmts[i] is StmtLabel && ((StmtLabel) blk.stmts[i]).label == g.label) {
                            found = true;
                            cur_gotos.add (new GotoPlan (g.label, "c2v_goto_" + g.label, true, i));
                            break;
                        }
                    }
                }
                if (!found) {
                    var lloop = find_loop_tail_label (blk, g.label);
                    if (lloop != null) {
                        found = true;
                        var gp = new GotoPlan (g.label, "c2v_goto_" + g.label, false, -1);
                        gp.loop_continue_stmt = lloop;
                        cur_gotos.add (gp);
                    }
                }
                if (!found) {
                    StmtSwitch? tsw = null;
                    int tci = -1;
                    if (find_switch_case_label (blk, g.label, out tsw, out tci)) {
                        found = true;
                        var gp = new GotoPlan (g.label, "c2v_goto_" + g.label, false, -1);
                        gp.switch_case_sw = tsw;
                        gp.switch_case_idx = tci;
                        cur_gotos.add (gp);
                    }
                }
                if (!found) {
                    StmtIf? hif = null;
                    StmtBlock? hblk = null;
                    int hidx = 0;
                    if (find_hoisted_tail_label (blk, g.label, out hif, out hblk, out hidx, true)) {
                        found = true;
                        var gp = new GotoPlan (g.label, "c2v_goto_" + g.label, true, -1);
                        gp.hoisted_if = hif;
                        gp.hoisted_block = hblk;
                        gp.hoisted_label_idx = hidx;
                        cur_gotos.add (gp);
                    }
                }
                if (!found) {
                    for (int ti = 0; ti < blk.stmts.length; ti++) {
                        if (blk.stmts[ti] is StmtIf) {
                            StmtBlock? nblk = null;
                            int nidx = 0;
                            if (find_nested_if_label (blk.stmts[ti], g.label, out nblk, out nidx)) {
                                found = true;
                                var gp = new GotoPlan (g.label, "c2v_goto_" + g.label, true, ti);
                                gp.nested_target_block = nblk;
                                gp.nested_label_idx = nidx;
                                gp.top_stmt_idx = ti;
                                cur_gotos.add (gp);
                                break;
                            }
                        }
                    }
                }
                if (!found)
                    refuse_loc (g.file, g.line, @"goto: label '$(g.label)' not found at function top level");
            }
        }

        private void collect_gotos (CStmt s, GenericArray<StmtGoto> out_g) {
            if (s is StmtGoto) {
                out_g.add ((StmtGoto) s);
            } else if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    collect_gotos (b.stmts[i], out_g);
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                collect_gotos (ifs.then_branch, out_g);
                if (ifs.else_branch != null)
                    collect_gotos ((CStmt) ifs.else_branch, out_g);
            } else if (s is StmtWhile) {
                collect_gotos (((StmtWhile) s).body, out_g);
            } else if (s is StmtFor) {
                collect_gotos (((StmtFor) s).body, out_g);
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                for (int i = 0; i < sw.cases.length; i++)
                    for (int j = 0; j < sw.cases[i].stmts.length; j++)
                        collect_gotos (sw.cases[i].stmts[j], out_g);
            } else if (s is StmtLabel) {
                collect_gotos (((StmtLabel) s).stmt, out_g);
            }
        }

        private GotoPlan? find_goto_plan (string label) {
            for (int i = 0; i < cur_gotos.length; i++) {
                if (cur_gotos[i].label == label)
                    return cur_gotos[i];
            }
            return null;
        }

        private static void indent (StrBuilder sb, int level) {
            for (int i = 0; i < level; i++)
                sb.append ("    ");
        }

        private void emit_stmt_list (StrBuilder sb, GenericArray<CStmt> stmts, int level) throws RefuseError {
            for (int i = 0; i < stmts.length; i++) {
                var s = stmts[i];
                bool is_loop = (s is StmtFor || s is StmtWhile);
                emit_stmt (sb, s, level);
                if (is_loop && i + 1 < stmts.length && stmts[i + 1] is StmtLabel) {
                    var ls = (StmtLabel) stmts[i + 1];
                    var gp = find_goto_plan (ls.label);
                    if (gp != null) {
                        // The loop itself needs to check the flag at end of body — handled inside emit_loop!
                    }
                }
            }
        }

        // Emits a comma expression as separate statements (Vala has none).
        private void emit_comma_stmts (StrBuilder sb, CExpr e, int level) throws RefuseError {
            if (e is ExprBinary && ((ExprBinary) e).op == ",") {
                var b = (ExprBinary) e;
                emit_comma_stmts (sb, b.left, level);
                emit_comma_stmts (sb, b.right, level);
                return;
            }
            emit_stmt (sb, new StmtExpr () { expr = e, file = e.file, line = e.line }, level);
        }

        // True when the statement contains a `continue` that belongs to the
        // enclosing loop (nested loops own theirs).
        private static bool stmt_has_continue (CStmt s) {
            if (s is StmtContinue)
                return true;
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (stmt_has_continue (b.stmts[i])) return true;
            } else if (s is StmtIf) {
                var f = (StmtIf) s;
                if (stmt_has_continue ((CStmt) f.then_branch)) return true;
                if (f.else_branch != null && stmt_has_continue ((CStmt) f.else_branch)) return true;
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                for (int i = 0; i < sw.cases.length; i++)
                    for (int j = 0; j < sw.cases[i].stmts.length; j++)
                        if (stmt_has_continue (sw.cases[i].stmts[j])) return true;
            } else if (s is StmtLabel) {
                return stmt_has_continue (((StmtLabel) s).stmt);
            }
            return false;
        }

        private string emit_comma_list (CExpr e) throws RefuseError {
            if (e is ExprBinary && ((ExprBinary) e).op == ",") {
                var b = (ExprBinary) e;
                return @"$(emit_comma_list (b.left)), $(emit_comma_list (b.right))";
            }
            return emit_expr (e, true);
        }

        private void emit_stmt (StrBuilder sb, CStmt s, int level, string? loop_goto_flag = null) throws RefuseError {
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    if (cur_gotos[gi].hoisted_block == b) {
                        indent (sb, level);
                        sb.append ("{\n");
                        for (int pi = 0; pi < cur_gotos[gi].hoisted_label_idx; pi++)
                            emit_stmt (sb, b.stmts[pi], level + 1);
                        indent (sb, level + 1);
                        sb.append (@"$(cur_gotos[gi].flag_name) = true;\n");
                        indent (sb, level + 1);
                        sb.append ("break;\n");
                        indent (sb, level);
                        sb.append ("}\n");
                        return;
                    }
                    if (cur_gotos[gi].nested_target_block == b) {
                        indent (sb, level);
                        sb.append ("{\n");
                        int nidx = cur_gotos[gi].nested_label_idx;
                        if (nidx > 0) {
                            indent (sb, level + 1);
                            sb.append (@"if (!$(cur_gotos[gi].flag_name)) {\n");
                            for (int pi = 0; pi < nidx; pi++)
                                emit_stmt (sb, b.stmts[pi], level + 2);
                            indent (sb, level + 1);
                            sb.append ("}\n");
                        }
                        indent (sb, level + 1);
                        sb.append (@"$(cur_gotos[gi].flag_name) = false;\n");
                        for (int pi = nidx; pi < b.stmts.length; pi++)
                            emit_stmt (sb, b.stmts[pi], level + 1);
                        indent (sb, level);
                        sb.append ("}\n");
                        return;
                    }
                }
                indent (sb, level);
                sb.append ("{\n");
                emit_stmt_list (sb, b.stmts, level + 1);
                if (loop_goto_flag != null) {
                    indent (sb, level + 1);
                    sb.append (@"if ($loop_goto_flag) { break; }\n");
                }
                indent (sb, level);
                sb.append ("}\n");
                return;
            }
            if (s is StmtDecl) {
                emit_decl (sb, (StmtDecl) s, level);
                return;
            }
            if (s is StmtIf) {
                var ifs = (StmtIf) s;
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    if (cur_gotos[gi].hoisted_if == ifs) {
                        indent (sb, level);
                        if (cur_gotos[gi].hoisted_label_idx == 0) {
                            sb.append (@"if ($(emit_top_cond (ifs.cond))) { $(cur_gotos[gi].flag_name) = true; }\n");
                        } else {
                            sb.append (@"if ($(emit_top_cond (ifs.cond))) {\n");
                            var hb = (StmtBlock) cur_gotos[gi].hoisted_block;
                            for (int pi = 0; pi < cur_gotos[gi].hoisted_label_idx; pi++)
                                emit_stmt (sb, hb.stmts[pi], level + 1);
                            indent (sb, level + 1);
                            sb.append (@"$(cur_gotos[gi].flag_name) = true;\n");
                            indent (sb, level);
                            sb.append ("}\n");
                        }
                        return;
                    }
                }
                string cond_s = emit_top_cond (ifs.cond);
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    var ntb = cur_gotos[gi].nested_target_block;
                    if (ntb != null) {
                        if (stmt_contains_block (ifs.then_branch, (StmtBlock) ntb))
                            cond_s = @"(($cond_s) || $(cur_gotos[gi].flag_name))";
                        else if (ifs.else_branch != null && stmt_contains_block (ifs.else_branch, (StmtBlock) ntb))
                            cond_s = @"(($cond_s) && !$(cur_gotos[gi].flag_name))";
                    }
                }
                indent (sb, level);
                sb.append ("if (");
                sb.append (cond_s);
                sb.append (") ");
                emit_branch (sb, ifs.then_branch, level);
                if (ifs.else_branch != null) {
                    indent (sb, level);
                    sb.append ("else ");
                    if (ifs.else_branch is StmtIf) {
                        // else if
                        sb.append ("\n");
                        emit_stmt (sb, (CStmt) ifs.else_branch, level);
                    } else {
                        emit_branch (sb, (CStmt) ifs.else_branch, level);
                    }
                }
                return;
            }
            if (s is StmtWhile) {
                var ws = (StmtWhile) s;
                var prev_loop = cur_loop_stmt;
                cur_loop_stmt = s;
                string? gf = all_goto_cond (s);
                if (ws.is_do) {
                    indent (sb, level);
                    sb.append ("do {\n");
                    if (ws.body is StmtBlock) {
                        var blk = (StmtBlock) ws.body;
                        emit_stmt_list (sb, blk.stmts, level + 1);
                    } else {
                        emit_stmt (sb, ws.body, level + 1);
                    }
                    if (gf != null) {
                        indent (sb, level + 1);
                        sb.append (@"if ($gf) break;\n");
                    }
                    indent (sb, level);
                    sb.append ("} while (");
                    sb.append (emit_top_cond (ws.cond));
                    sb.append (");\n");
                } else {
                    indent (sb, level);
                    sb.append ("while (");
                    sb.append (emit_top_cond (ws.cond));
                    sb.append (") ");
                    emit_loop_body (sb, ws.body, level, gf);
                }
                cur_loop_stmt = prev_loop;
                if (prev_loop != null) {
                    for (int gi = 0; gi < cur_gotos.length; gi++) {
                        if (cur_gotos[gi].loop_continue_stmt == prev_loop) {
                            indent (sb, level);
                            sb.append (@"if ($(cur_gotos[gi].flag_name)) { $(cur_gotos[gi].flag_name) = false; continue; }\n");
                        }
                    }
                }
                return;
            }
            if (s is StmtFor) {
                var fs = (StmtFor) s;
                var prev_loop = cur_loop_stmt;
                cur_loop_stmt = s;
                // Vala has no comma operator: `for (a, b; ...)` starts with the
                // initializers hoisted into a block in front of the loop.
                bool hoist = (fs.init_decl == null && fs.init_expr is ExprBinary
                    && ((ExprBinary) fs.init_expr).op == ",");
                int loop_level = level;
                if (hoist) {
                    indent (sb, level);
                    sb.append ("{\n");
                    loop_level = level + 1;
                    emit_comma_stmts (sb, (CExpr) fs.init_expr, loop_level);
                }
                indent (sb, loop_level);
                sb.append ("for (");
                if (fs.init_decl != null) {
                    var d = (StmtDecl) fs.init_decl;
                    string vt = vala_type (d.ctype, false);
                    var li = new LocalInfo (d.name, d.ctype, false);
                    cur_locals.add (li);
                    sb.append (@"$vt $(esc_ident (d.name))");
                    if (d.init != null)
                        sb.append (@" = $(emit_expr ((CExpr) d.init))");
                } else if (fs.init_expr != null && !hoist) {
                    sb.append (emit_comma_list ((CExpr) fs.init_expr));
                }
                sb.append ("; ");
                if (fs.cond != null)
                    sb.append (emit_top_cond ((CExpr) fs.cond));
                sb.append ("; ");
                bool next_multi = (fs.next is ExprBinary && ((ExprBinary) fs.next).op == ",");
                if (next_multi && stmt_has_continue (fs.body))
                    refuse_loc (s.file, s.line,
                        "a for loop with several increment expressions and a continue is not supported");
                if (fs.next != null && !next_multi)
                    sb.append (emit_comma_list ((CExpr) fs.next));
                string? loop_gf = all_goto_cond (s);
                if (next_multi) {
                    // Vala's for-increment is a single expression: run the
                    // increments at the end of the body instead.
                    sb.append (") {\n");
                    emit_stmt (sb, fs.body, loop_level + 1, loop_gf);
                    emit_comma_stmts (sb, (CExpr) fs.next, loop_level + 1);
                    indent (sb, loop_level);
                    sb.append ("}\n");
                } else {
                    sb.append (") ");
                    emit_loop_body (sb, fs.body, loop_level, loop_gf);
                }
                cur_loop_stmt = prev_loop;
                if (prev_loop != null) {
                    for (int gi = 0; gi < cur_gotos.length; gi++) {
                        if (cur_gotos[gi].loop_continue_stmt == prev_loop) {
                            indent (sb, loop_level);
                            sb.append (@"if ($(cur_gotos[gi].flag_name)) { $(cur_gotos[gi].flag_name) = false; continue; }\n");
                        }
                    }
                }
                if (hoist) {
                    indent (sb, level);
                    sb.append ("}\n");
                }
                return;
            }
            if (s is StmtSwitch) {
                emit_switch (sb, (StmtSwitch) s, level);
                return;
            }
            if (s is StmtBreak) {
                indent (sb, level);
                sb.append ("break;\n");
                return;
            }
            if (s is StmtContinue) {
                indent (sb, level);
                if (cur_sw_cont_flag != null) {
                    sb.append (@"{ $cur_sw_cont_flag = true; break; }\n");
                } else {
                    sb.append ("continue;\n");
                }
                return;
            }
            if (s is StmtReturn) {
                var rs = (StmtReturn) s;
                indent (sb, level);
                if (rs.expr == null) {
                    sb.append ("return;\n");
                } else if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.PTR
                           && is_null_ptr_expr ((CExpr) rs.expr)) {
                    sb.append (@"return $(ptr_null_value (cur_fn.ret_type));\n");
                } else {
                    string ex = emit_expr ((CExpr) rs.expr);
                    var rt = infer_type ((CExpr) rs.expr);
                    if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.SCALAR
                        && rt != null && rt.kind == CTypeKind.ENUM) {
                        ex = @"(($(cur_fn.ret_type.name)) $ex)";
                    } else if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.SCALAR
                               && !cur_fn.ret_type.is_scalar ("void")) {
                        ex = coerce_value ((CExpr) rs.expr, cur_fn.ret_type.name);
                    } else if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.PTR
                               && cur_fn.ret_type.inner != null
                               && !((CType) cur_fn.ret_type.inner).is_scalar ("void")) {
                        int ret_view = vala_type (cur_fn.ret_type, false).has_suffix ("[]") ? 2 : 1;
                        var rexpr = (CExpr) rs.expr;
                        if (!is_null_ptr_expr (rexpr)) {
                            ex = coerce_ptr (rexpr, cur_fn.ret_type, null, ret_view);
                        } else {
                            ex = ptr_null_value (cur_fn.ret_type);
                        }
                    }
                    sb.append (@"return $ex;\n");
                }
                return;
            }
            if (s is StmtGoto) {
                var gs = (StmtGoto) s;
                var gp = find_goto_plan (gs.label);
                if (gp == null)
                    refuse_loc (gs.file, gs.line, "goto: unsupported target");
                if (gp.loop_continue_stmt != null && cur_loop_stmt == gp.loop_continue_stmt) {
                    indent (sb, level);
                    if (cur_sw_cont_flag != null)
                        sb.append (@"{ $cur_sw_cont_flag = true; break; }\n");
                    else
                        sb.append ("continue;\n");
                    return;
                }
                indent (sb, level);
                sb.append (@"$(gp.flag_name) = true;\n");
                indent (sb, level);
                sb.append ("break;\n");
                return;
            }
            if (s is StmtLabel) {
                var ls = (StmtLabel) s;
                emit_stmt (sb, ls.stmt, level);
                return;
            }
            if (s is StmtExpr) {
                var es = (StmtExpr) s;
                if (es.expr == null)
                    return;
                if (es.expr is ExprBinary && ((ExprBinary) es.expr).op == ",") {
                    var cb = (ExprBinary) es.expr;
                    emit_stmt (sb, new StmtExpr () { expr = cb.left, file = es.file, line = es.line }, level);
                    emit_stmt (sb, new StmtExpr () { expr = cb.right, file = es.file, line = es.line }, level);
                    return;
                }
                if (es.expr is ExprCast && ((ExprCast) es.expr).target_type.kind == CTypeKind.SCALAR
                    && ((ExprCast) es.expr).target_type.name == "void") {
                    var vc = (ExprCast) es.expr;
                    if (vc.expr is ExprIdent || vc.expr is ExprMember) {
                        indent (sb, level);
                        sb.append (@"// (void) $(emit_expr (vc.expr))\n");
                        return;
                    }
                    emit_stmt (sb, new StmtExpr () { expr = vc.expr, file = es.file, line = es.line }, level);
                    return;
                }
                // Handle chained assignment `a = b = c;`
                if (es.expr is ExprAssign && ((ExprAssign) es.expr).rvalue is ExprAssign) {
                    emit_chained_assign (sb, (ExprAssign) es.expr, level);
                    return;
                }
                // Handle free(p) and memset(struct_ptr, 0, ...)
                if (es.expr is ExprCall) {
                    var call = (ExprCall) es.expr;
                    if (call.callee is ExprIdent && ((ExprIdent) call.callee).name == "va_start" && call.args.length >= 1) {
                        indent (sb, level);
                        sb.append (@"$(emit_expr (call.args[0])) = va_list ();\n");
                        return;
                    }
                    if (call.callee is ExprIdent && ((ExprIdent) call.callee).name == "va_end") {
                        indent (sb, level);
                        sb.append ("// va_end\n");
                        return;
                    }
                    if (call.callee is ExprIdent && ((ExprIdent) call.callee).name == "fclose" && call.args.length == 1
                        && (call.args[0] is ExprIdent || call.args[0] is ExprMember)) {
                        indent (sb, level);
                        sb.append (@"$(emit_expr (call.args[0])) = null;\n");
                        return;
                    }
                    if (call.callee is ExprIdent && ((ExprIdent) call.callee).name == "free") {
                        string arg_s = call.args.length > 0 ? emit_expr (call.args[0]) : "";
                        indent (sb, level);
                        sb.append (@"// free ($arg_s): the GC owns the array\n");
                        return;
                    }
                    if (call.callee is ExprIdent && ((ExprIdent) call.callee).name == "memset"
                        && call.args.length == 3 && call.args[1] is ExprInt && ((ExprInt) call.args[1]).val == 0) {
                        var mt = infer_type (call.args[0]);
                        if (mt != null && (mt.kind == CTypeKind.STRUCT || mt.is_struct_ptr ())) {
                            string sname = (mt.kind == CTypeKind.STRUCT) ? mt.name : ((CType) mt.inner).name;
                            var sd = find_struct (sname);
                            if (sd != null) {
                                string lhs_s = emit_expr (call.args[0]);
                                emit_struct_zero (sb, lhs_s, (StructDef) sd, level);
                                return;
                            }
                        }
                    }
                }
                if (es.expr is ExprAssign && ((ExprAssign) es.expr).op == "=") {
                    // `fp = (fp != 0)` assigns a boolean in C but means "keep
                    // the pointer or null"; Vala has no such conversion.
                    var fa = (ExprAssign) es.expr;
                    var flt = infer_type (fa.lvalue);
                    if (flt != null && flt.kind == CTypeKind.FUNC_PTR && fa.rvalue is ExprBinary) {
                        var fb = (ExprBinary) fa.rvalue;
                        if ((fb.op == "!=" || fb.op == "==") && fb.right is ExprInt
                            && ((ExprInt) fb.right).val == 0) {
                            indent (sb, level);
                            string fval = (fb.op == "!=") ? emit_expr (fb.left) : "null";
                            sb.append (@"$(emit_expr (fa.lvalue)) = $fval;\n");
                            return;
                        }
                    }
                }
                if (es.expr is ExprAssign && ((ExprAssign) es.expr).op == "="
                    && ((ExprAssign) es.expr).lvalue is ExprIdent) {
                    var pa = (ExprAssign) es.expr;
                    var pli = find_local (cur_locals, ((ExprIdent) pa.lvalue).name);
                    if (pli != null && pli.has_ptr_arith) {
                        emit_ptr_assign_stmt (sb, pa, pli, level);
                        return;
                    }
                }
                indent (sb, level);
                sb.append (emit_expr ((CExpr) es.expr, true));
                sb.append (";\n");
                return;
            }
            refuse_loc (s.file, s.line, "unsupported statement");
        }

        private void emit_branch (StrBuilder sb, CStmt b, int level) throws RefuseError {
            if (b is StmtBlock) {
                sb.append ("\n");
                emit_stmt (sb, b, level);
            } else {
                sb.append ("{\n");
                emit_stmt (sb, b, level + 1);
                indent (sb, level);
                sb.append ("}\n");
            }
        }

        private void emit_loop_body (StrBuilder sb, CStmt body, int level, string? gf) throws RefuseError {
            if (body is StmtBlock) {
                sb.append ("\n");
                emit_stmt (sb, body, level, gf);
            } else {
                sb.append ("{\n");
                emit_stmt (sb, body, level + 1);
                if (gf != null) {
                    indent (sb, level + 1);
                    sb.append (@"if ($gf) { break; }\n");
                }
                indent (sb, level);
                sb.append ("}\n");
            }
        }

        // Statement form of `p = ...` when `p` tracks a pointer offset: Vala
        // cannot express the offset bookkeeping as a ternary in statement
        // position, so the assignment and the offset update are two statements.
        private void emit_ptr_assign_stmt (StrBuilder sb, ExprAssign a, LocalInfo pli, int level) throws RefuseError {
            string lname = esc_ident (pli.name);
            CExpr rv = a.rvalue;
            if (is_alloc_call (rv)) {
                indent (sb, level);
                sb.append (@"$lname = $(emit_alloc ((ExprCall) rv, pli.ctype));\n");
                indent (sb, level);
                sb.append (@"_off_$(pli.name) = 0;\n");
                return;
            }
            if (rv is ExprBinary) {
                var rb = (ExprBinary) rv;
                if ((rb.op == "+" || rb.op == "-") && rb.left is ExprIdent) {
                    string src = ((ExprIdent) rb.left).name;
                    var sli = find_local (cur_locals, src);
                    string base_off = (sli != null && sli.has_ptr_arith) ? @"_off_$src" : "0";
                    string sign = (rb.op == "+") ? "+" : "-";
                    indent (sb, level);
                    if (src == pli.name)
                        sb.append (@"$lname = $(emit_expr (rb.left));\n");
                    else
                        sb.append (@"$lname = $(coerce_ptr (rb.left, pli.ctype, a.lvalue));\n");
                    indent (sb, level);
                    sb.append (@"_off_$(pli.name) = $base_off $sign (int) ($(emit_expr (rb.right)));\n");
                    return;
                }
            }
            indent (sb, level);
            sb.append (@"$lname = $(coerce_assign (a.lvalue, rv));\n");
            string src_off = "0";
            if (rv is ExprIdent) {
                string rn = ((ExprIdent) rv).name;
                var sli2 = find_local (cur_locals, rn);
                if (sli2 != null && sli2.has_ptr_arith)
                    src_off = @"_off_$rn";
            }
            indent (sb, level);
            sb.append (@"_off_$(pli.name) = $src_off;\n");
        }

        private void emit_chained_assign (StrBuilder sb, ExprAssign a, int level) throws RefuseError {
            if (a.rvalue is ExprAssign) {
                var inner = (ExprAssign) a.rvalue;
                emit_chained_assign (sb, inner, level);
                indent (sb, level);
                sb.append (@"$(emit_expr (a.lvalue)) $(a.op) $(emit_expr (inner.lvalue));\n");
            } else {
                indent (sb, level);
                sb.append (@"$(emit_expr (a.lvalue)) $(a.op) $(emit_expr (a.rvalue));\n");
            }
        }

        private void emit_struct_zero (StrBuilder sb, string lhs, StructDef sd, int level) throws RefuseError {
            for (int i = 0; i < sd.fields.length; i++) {
                var f = sd.fields[i];
                if (f.name == "") continue;
                string fn = esc_ident (f.name);
                indent (sb, level);
                if (f.ctype.kind == CTypeKind.STRUCT) {
                    string vt = vala_type (f.ctype, false);
                    sb.append (@"$lhs.$fn = new $vt ();\n");
                } else if (f.ctype.kind == CTypeKind.UNION) {
                    string vt = vala_type (f.ctype, false);
                    unowned var usd = find_struct (f.ctype.name);
                    bool u_class = (usd != null) && union_needs_class (usd);
                    sb.append (u_class ? @"$lhs.$fn = new $vt ();\n" : @"$lhs.$fn = $vt ();\n");
                } else if (f.ctype.kind == CTypeKind.ARRAY && f.ctype.inner != null && f.ctype.array_len != null) {
                    string et = vala_type ((CType) f.ctype.inner, false);
                    string ls = emit_expr ((CExpr) f.ctype.array_len);
                    sb.append (@"$lhs.$fn = new $et[$ls];\n");
                } else if (f.ctype.kind == CTypeKind.PTR || f.ctype.kind == CTypeKind.FUNC_PTR) {
                    sb.append (@"$lhs.$fn = $(f.ctype.is_char_ptr () ? "\"\"" : "null");\n");
                } else if (f.ctype.kind == CTypeKind.ENUM) {
                    string vt = vala_type (f.ctype, false);
                    sb.append (@"$lhs.$fn = ($vt) 0;\n");
                } else {
                    sb.append (@"$lhs.$fn = 0;\n");
                }
            }
        }

        private void emit_struct_init_assigns (StrBuilder sb, string lhs, StructDef sd, ExprInitList il, int level) throws RefuseError {
            int cur_idx = 0;
            for (int fi = 0; fi < il.items.length; fi++) {
                string fname = (fi < il.field_names.length) ? il.field_names[fi] : "";
                StructField? fld = null;
                if (fname != "") {
                    for (int k = 0; k < sd.fields.length; k++) {
                        if (sd.fields[k].name == fname) {
                            fld = sd.fields[k];
                            cur_idx = k + 1;
                            break;
                        }
                    }
                } else if (cur_idx < sd.fields.length) {
                    fld = sd.fields[cur_idx];
                    cur_idx++;
                }
                if (fld == null) continue;
                var f = (StructField) fld;
                string fpath = @"$lhs.$(esc_ident (f.name))";
                if ((f.ctype.kind == CTypeKind.STRUCT || f.ctype.kind == CTypeKind.UNION) && il.items[fi] is ExprInitList) {
                    var sub_il = (ExprInitList) il.items[fi];
                    var sub_sd = find_struct (f.ctype.name);
                    if (f.ctype.kind == CTypeKind.STRUCT && sub_sd != null) {
                        emit_struct_init_assigns (sb, fpath, (StructDef) sub_sd, sub_il, level);
                    } else {
                        indent (sb, level);
                        sb.append (@"$fpath = $(emit_compound_struct_or_union (f.ctype, sub_il));\n");
                    }
                } else {
                    string? ft = (f.ctype.kind == CTypeKind.SCALAR || f.ctype.kind == CTypeKind.ENUM)
                        ? vala_type (f.ctype, false) : null;
                    indent (sb, level);
                    sb.append (@"$fpath = $(coerce_value (il.items[fi], ft));\n");
                }
            }
        }

        private void emit_decl (StrBuilder sb, StmtDecl d, int level) throws RefuseError {
            var li = new LocalInfo (d.name, d.ctype, false);
            bool is_malloc_init = is_alloc_call (d.init);
            if (d.ctype.kind == CTypeKind.ARRAY || is_malloc_init)
                li.is_array = true;
            if (cur_prescan != null) {
                var pl = find_local (cur_prescan, d.name);
                if (pl != null) {
                    if (pl.is_array) li.is_array = true;
                    li.has_ptr_arith = pl.has_ptr_arith;
                    li.has_addr_taken = pl.has_addr_taken;
                }
            }
            cur_locals.add (li);
            string dname = esc_ident (d.name);

            // Fixed-size or init-list array `T name[N];` / `T name[] = { ... };`
            if (d.ctype.kind == CTypeKind.ARRAY && d.ctype.inner != null) {
                var elem_ct = (CType) d.ctype.inner;
                string elem_t = vala_type (elem_ct, false);
                if (d.init is ExprInitList) {
                    var il = (ExprInitList) d.init;
                    string len_s = (d.ctype.array_len != null)
                        ? emit_expr ((CExpr) d.ctype.array_len)
                        : @"$(il.items.length)";
                    indent (sb, level);
                    sb.append (@"$elem_t[] $dname = new $elem_t[$len_s];\n");
                    if (elem_ct.kind == CTypeKind.STRUCT) {
                        indent (sb, level);
                        sb.append (@"for (int _c2v_i = 0; _c2v_i < $len_s; _c2v_i++) { $dname[_c2v_i] = new $elem_t (); }\n");
                    }
                    string? etgt = (elem_ct.kind == CTypeKind.SCALAR || elem_ct.kind == CTypeKind.ENUM) ? elem_t : null;
                    int seq_idx = 0;
                    for (int ii = 0; ii < il.items.length; ii++) {
                        CExpr? idx_e = (ii < il.index_exprs.length) ? il.index_exprs[ii] : null;
                        string idx_s;
                        if (idx_e != null) {
                            idx_s = emit_expr ((CExpr) idx_e);
                            if (idx_e is ExprInt)
                                seq_idx = (int) ((ExprInt) idx_e).val + 1;
                        } else {
                            idx_s = @"$seq_idx";
                            seq_idx++;
                        }
                        if (elem_ct.kind == CTypeKind.STRUCT && il.items[ii] is ExprInitList) {
                            var sub_il = (ExprInitList) il.items[ii];
                            var sd = find_struct (elem_ct.name);
                            if (sd != null)
                                emit_struct_init_assigns (sb, @"$dname[$idx_s]", (StructDef) sd, sub_il, level);
                        } else {
                            indent (sb, level);
                            sb.append (@"$dname[$idx_s] = $(coerce_value (il.items[ii], etgt));\n");
                        }
                    }
                    return;
                }
                if (d.ctype.array_len == null) {
                    if (d.init is ExprStr) {
                        string sv = emit_expr ((CExpr) d.init);
                        indent (sb, level);
                        sb.append (@"$elem_t[] $dname = new $elem_t[$(sv.length + 1)];\n");
                        indent (sb, level);
                        sb.append (@"c_strcpy_buf ($dname, $sv);\n");
                        return;
                    }
                    refuse_loc (d.file, d.line, "array without size");
                }
                string len_s = emit_expr ((CExpr) d.ctype.array_len);
                indent (sb, level);
                sb.append (@"$elem_t[] $dname = new $elem_t[$len_s];\n");
                if (elem_ct.kind == CTypeKind.STRUCT) {
                    indent (sb, level);
                    sb.append (@"for (int _c2v_i = 0; _c2v_i < $len_s; _c2v_i++) { $dname[_c2v_i] = new $elem_t (); }\n");
                }
                return;
            }

            if (d.init is ExprInitList) {
                var il = (ExprInitList) d.init;
                if (d.ctype.kind == CTypeKind.STRUCT) {
                    string vt_s = vala_type (d.ctype, false);
                    indent (sb, level);
                    sb.append (@"$vt_s $dname = new $vt_s ();\n");
                    var sd = find_struct (d.ctype.name);
                    if (sd != null)
                        emit_struct_init_assigns (sb, dname, (StructDef) sd, il, level);
                    return;
                }
                refuse_loc (d.file, d.line, "initializer lists are not supported");
            }

            string vt = vala_type (d.ctype, li.is_array);
            assert_supported_type (vt);
            // `&x` needs a box only for scalars; structs/pointers already map
            // to references/arrays in Vala.
            if (li.has_addr_taken && (d.ctype.kind == CTypeKind.SCALAR || d.ctype.kind == CTypeKind.ENUM)) {
                indent (sb, level);
                sb.append (@"$(vt)[] $dname = new $vt[1];\n");
                if (d.init != null) {
                    string? tgt = (d.ctype.kind == CTypeKind.SCALAR || d.ctype.kind == CTypeKind.ENUM) ? vt : null;
                    indent (sb, level);
                    sb.append (@"$dname[0] = $(coerce_value ((CExpr) d.init, tgt));\n");
                }
                return;
            }
            bool alias_arr = li.is_array && d.ctype.kind == CTypeKind.PTR && d.init is ExprIdent;
            string decl_vt = alias_arr ? ("unowned " + vt) : vt;
            indent (sb, level);
            if (d.init != null) {
                if (is_malloc_init) {
                    string alloc_s = emit_alloc ((ExprCall) d.init, li.ctype);
                    sb.append (@"$decl_vt $dname = $alloc_s;\n");
                } else if (d.ctype.kind == CTypeKind.FUNC_PTR && is_null_ptr_expr (d.init)) {
                    sb.append (@"$decl_vt $dname = null;\n");
                } else if (d.ctype.kind == CTypeKind.PTR && is_null_ptr_expr (d.init)) {
                    sb.append (@"$decl_vt $dname = $(ptr_null_value (d.ctype));\n");
                } else if (d.ctype.kind == CTypeKind.PTR && d.init is ExprStr
                           && vala_type (d.ctype, false).has_suffix ("[]")) {
                    // `char *p = "text"` in an array view needs a real buffer.
                    string sv = emit_expr ((CExpr) d.init);
                    sb.append (@"$decl_vt $dname = c_str_to_bytes ($sv);\n");
                } else {
                    string? tgt = (d.ctype.kind == CTypeKind.SCALAR
                                   || d.ctype.kind == CTypeKind.ENUM) ? vt : null;
                    if (d.ctype.kind == CTypeKind.PTR)
                        sb.append (@"$decl_vt $dname = $(coerce_ptr ((CExpr) d.init, d.ctype, null, li.is_array ? 2 : 0));\n");
                    else
                        sb.append (@"$decl_vt $dname = $(coerce_value ((CExpr) d.init, tgt));\n");
                }
            } else {
                if (d.ctype.kind == CTypeKind.STRUCT) {
                    sb.append (@"$vt $dname = new $vt ();\n");
                } else if (d.ctype.kind == CTypeKind.UNION) {
                    unowned var usd = find_struct (d.ctype.name);
                    bool u_class = (usd != null) && union_needs_class (usd);
                    sb.append (u_class ? @"$vt $dname = new $vt ();\n" : @"$vt $dname = $vt ();\n");
                } else if (li.is_array && d.ctype.kind == CTypeKind.PTR && d.ctype.inner != null) {
                    string elem_t = (d.ctype.inner.is_scalar ("char") || d.ctype.inner.is_scalar ("void"))
                        ? "uint8" : vala_type ((CType) d.ctype.inner, false);
                    sb.append (@"$vt $dname = new $elem_t[0];\n");
                } else if (d.ctype.is_struct_ptr () || d.ctype.kind == CTypeKind.FUNC_PTR) {
                    sb.append (@"$vt $dname = null;\n");
                } else if (d.ctype.is_char_ptr ()) {
                    sb.append (@"$vt $dname = \"\";\n");
                } else if (d.ctype.kind == CTypeKind.ENUM) {
                    sb.append (@"$vt $dname = ($vt) 0;\n");
                } else if (d.ctype.is_scalar ("va_list")) {
                    sb.append (@"$vt $dname = va_list ();\n");
                } else if (d.ctype.kind == CTypeKind.PTR) {
                    sb.append (@"$vt $dname = null;\n");
                } else {
                    sb.append (@"$vt $dname = 0;\n");
                }
            }
            if (li.has_ptr_arith) {
                indent (sb, level);
                sb.append (@"int _off_$(d.name) = 0;\n");
            }
        }

        private bool is_var_assigned_array (CStmt s, string name) {
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (is_var_assigned_array (b.stmts[i], name)) return true;
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                if (is_var_assigned_array (ifs.then_branch, name)) return true;
                if (ifs.else_branch != null && is_var_assigned_array ((CStmt) ifs.else_branch, name)) return true;
            } else if (s is StmtWhile) {
                return is_var_assigned_array (((StmtWhile) s).body, name);
            } else if (s is StmtFor) {
                return is_var_assigned_array (((StmtFor) s).body, name);
            } else if (s is StmtExpr) {
                var es = (StmtExpr) s;
                if (es.expr is ExprAssign) {
                    var a = (ExprAssign) es.expr;
                    if (a.lvalue is ExprIdent && ((ExprIdent) a.lvalue).name == name) {
                        if (is_alloc_call (a.rvalue))
                            return true;
                        if (a.rvalue is ExprCall && ((ExprCall) a.rvalue).callee is ExprIdent) {
                            var csig = find_sig (((ExprIdent) ((ExprCall) a.rvalue).callee).name);
                            if (csig != null && csig.ret_is_array)
                                return true;
                        }
                    }
                }
            }
            return false;
        }

        private int sw_counter = 0;
        private string? cur_sw_cont_flag = null;

        private static bool stmt_has_top_continue (CStmt s) {
            if (s is StmtContinue)
                return true;
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (stmt_has_top_continue (b.stmts[i])) return true;
            } else if (s is StmtIf) {
                var ifs = (StmtIf) s;
                if (stmt_has_top_continue (ifs.then_branch)) return true;
                if (ifs.else_branch != null && stmt_has_top_continue ((CStmt) ifs.else_branch)) return true;
            } else if (s is StmtLabel) {
                return stmt_has_top_continue (((StmtLabel) s).stmt);
            }
            return false;
        }

        private void emit_switch (StrBuilder sb, StmtSwitch sw, int level) throws RefuseError {
            bool has_fallthrough = false;
            bool has_cont = false;
            for (int i = 0; i < sw.cases.length; i++) {
                var sc = sw.cases[i];
                if (sc.stmts.length > 0) {
                    var last = sc.stmts[sc.stmts.length - 1];
                    bool terminates = (last is StmtBreak || last is StmtReturn || last is StmtGoto || last is StmtContinue);
                    if (!terminates && i + 1 < sw.cases.length)
                        has_fallthrough = true;
                }
                for (int j = 0; j < sc.stmts.length; j++)
                    if (stmt_has_top_continue (sc.stmts[j])) has_cont = true;
            }

            if (!has_fallthrough) {
                indent (sb, level);
                sb.append (@"switch ($(emit_expr (sw.cond))) {\n");
                for (int i = 0; i < sw.cases.length; i++) {
                    var sc = sw.cases[i];
                    indent (sb, level + 1);
                    if (sc.is_default)
                        sb.append ("default:\n");
                    else
                        sb.append (@"case $(emit_expr ((CExpr) sc.expr)):\n");
                    for (int j = 0; j < sc.stmts.length; j++) {
                        emit_stmt (sb, sc.stmts[j], level + 2);
                    }
                    if (sc.stmts.length > 0 && i == sw.cases.length - 1) {
                        var last = sc.stmts[sc.stmts.length - 1];
                        if (!(last is StmtBreak || last is StmtReturn || last is StmtGoto || last is StmtContinue)) {
                            indent (sb, level + 2);
                            sb.append ("break;\n");
                        }
                    }
                }
                indent (sb, level);
                sb.append ("}\n");
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    if (cur_gotos[gi].switch_case_sw == sw) {
                        indent (sb, level);
                        sb.append (@"if ($(cur_gotos[gi].flag_name)) {\n");
                        indent (sb, level + 1);
                        sb.append (@"$(cur_gotos[gi].flag_name) = false;\n");
                        var tsc = sw.cases[cur_gotos[gi].switch_case_idx];
                        for (int sj = 0; sj < tsc.stmts.length; sj++) {
                            var st = tsc.stmts[sj];
                            if (!(st is StmtBreak))
                                emit_stmt (sb, st, level + 1);
                        }
                        indent (sb, level);
                        sb.append ("}\n");
                    }
                }
                return;
            }

            int id = sw_counter++;
            string sw_var = @"_sw_$id";
            string ft_var = @"_ft_$id";
            string? old_cont = cur_sw_cont_flag;
            string? cont_var = has_cont ? @"_sw_cont_$id" : null;
            if (has_cont)
                cur_sw_cont_flag = cont_var;

            indent (sb, level);
            sb.append (@"var $sw_var = $(emit_expr (sw.cond));\n");
            indent (sb, level);
            sb.append (@"bool $ft_var = false;\n");
            if (cont_var != null) {
                indent (sb, level);
                sb.append (@"bool $cont_var = false;\n");
            }
            indent (sb, level);
            sb.append ("do {\n");

            int ci = 0;
            while (ci < sw.cases.length) {
                var grp_cond = new StrBuilder ();
                grp_cond.append (ft_var);
                bool has_def = false;
                while (ci < sw.cases.length && sw.cases[ci].stmts.length == 0 && !sw.cases[ci].is_default) {
                    grp_cond.append (@" || $sw_var == $(emit_expr ((CExpr) sw.cases[ci].expr))");
                    ci++;
                }
                if (ci >= sw.cases.length)
                    break;
                var sc = sw.cases[ci];
                if (sc.is_default) {
                    has_def = true;
                    // Match default if falling through OR none of the non-default case labels match
                    var neg = new StrBuilder ();
                    int ncase = 0;
                    for (int k = 0; k < sw.cases.length; k++) {
                        if (!sw.cases[k].is_default && sw.cases[k].expr != null) {
                            if (ncase > 0) neg.append (" && ");
                            neg.append (@"$sw_var != $(emit_expr ((CExpr) sw.cases[k].expr))");
                            ncase++;
                        }
                    }
                    if (ncase > 0)
                        grp_cond.append (@" || ($(neg.str))");
                    else
                        grp_cond = new StrBuilder ("true");
                } else {
                    grp_cond.append (@" || $sw_var == $(emit_expr ((CExpr) sc.expr))");
                }
                if (has_def) {}

                indent (sb, level + 1);
                sb.append (@"if ($(grp_cond.str)) {\n");
                indent (sb, level + 2);
                sb.append (@"$ft_var = true;\n");
                for (int j = 0; j < sc.stmts.length; j++)
                    emit_stmt (sb, sc.stmts[j], level + 2);
                indent (sb, level + 1);
                sb.append ("}\n");
                ci++;
            }

            indent (sb, level);
            sb.append ("} while (false);\n");
            cur_sw_cont_flag = old_cont;
            if (cont_var != null) {
                indent (sb, level);
                sb.append (@"if ($cont_var) continue;\n");
            }
        }

        // ---- Expression typing & emission ----

        private CType? infer_type (CExpr e) throws RefuseError {
            if (e is ExprInt) {
                var ei = (ExprInt) e;
                if (ei.is_unsigned && ei.is_long) return CType.scalar ("uint64");
                if (ei.is_long) return CType.scalar ("int64");
                return CType.scalar (ei.is_unsigned ? "uint32" : "int");
            }
            if (e is ExprFloat)
                return CType.scalar (((ExprFloat) e).is_float ? "float" : "double");
            if (e is ExprChar)
                return CType.scalar ("char");
            if (e is ExprStr)
                return CType.make_ptr (CType.scalar ("char"));
            if (e is ExprIdent) {
                string nm = ((ExprIdent) e).name;
                var li = find_local (cur_locals, nm);
                if (li != null)
                    return li.ctype;
                int em = find_enum_member (nm);
                if (em >= 0)
                    return new CType (CTypeKind.ENUM, enum_member_types[em]);
                var fsig = find_sig (nm);
                if (fsig != null) {
                    var fpt = new CType (CTypeKind.FUNC_PTR, "");
                    fpt.fp_ret = fsig.ret_type;
                    return fpt;
                }
                int gi = global_map.get_index (nm);
                if (gi >= 0)
                    return tu.globals[gi].ctype;
                return null;
            }
            if (e is ExprCast)
                return ((ExprCast) e).target_type;
            if (e is ExprCompoundLit)
                return ((ExprCompoundLit) e).target_type;
            if (e is ExprSizeofType || e is ExprSizeofExpr)
                return CType.scalar ("size_t");
            if (e is ExprIndex) {
                var at = infer_type (((ExprIndex) e).array);
                if (at != null && (at.kind == CTypeKind.PTR || at.kind == CTypeKind.ARRAY))
                    return at.inner;
                return null;
            }
            if (e is ExprMember) {
                var m = (ExprMember) e;
                var ot = infer_type (m.obj);
                if (ot != null && ot.kind == CTypeKind.PTR && ot.inner != null)
                    ot = ot.inner;
                if (ot != null && (ot.kind == CTypeKind.STRUCT || ot.kind == CTypeKind.UNION)) {
                    var sd = find_struct (ot.name);
                    if (sd != null) {
                        for (int i = 0; i < sd.fields.length; i++) {
                            if (sd.fields[i].name == m.field)
                                return sd.fields[i].ctype;
                        }
                    }
                }
                return null;
            }
            if (e is ExprBinary) {
                var b = (ExprBinary) e;
                if (b.op == ",")
                    return infer_type (b.right);
                if (b.op == "==" || b.op == "!=" || b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">="
                    || b.op == "&&" || b.op == "||")
                    return CType.scalar ("bool");
                var lt = infer_type (b.left);
                var rt = infer_type (b.right);
                if (lt != null && rt != null && lt.kind == CTypeKind.SCALAR && rt.kind == CTypeKind.SCALAR)
                    return CType.scalar (common_scalar (lt.name, rt.name));
                return lt ?? rt;
            }
            if (e is ExprUnary) {
                var u = (ExprUnary) e;
                if (u.op == "!")
                    return CType.scalar ("bool");
                if (u.op == "*") {
                    var ot = infer_type (u.operand);
                    if (ot != null && (ot.kind == CTypeKind.PTR || ot.kind == CTypeKind.ARRAY))
                        return ot.inner;
                    return null;
                }
                if (u.op == "&") {
                    var ot = infer_type (u.operand);
                    if (ot == null)
                        return null;
                    if (ot.kind == CTypeKind.ARRAY)
                        return ot;
                    return CType.make_ptr (ot);
                }
                return infer_type (u.operand);
            }
            if (e is ExprCall) {
                var c = (ExprCall) e;
                if (c.callee is ExprIdent) {
                    string fn = ((ExprIdent) c.callee).name;
                    if (fn == "strlen" || fn == "strcmp" || fn == "strncmp" || fn == "memcmp"
                        || fn == "printf" || fn == "fprintf"
                        || fn == "__builtin_ctz" || fn == "__builtin_ctzll"
                        || fn == "__builtin_clz" || fn == "__builtin_clzll"
                        || fn == "__builtin_popcount" || fn == "__builtin_popcountll")
                        return CType.scalar ("int");
                    if (fn == "__builtin_bswap16") return CType.scalar ("uint16");
                    if (fn == "__builtin_bswap32") return CType.scalar ("uint32");
                    if (fn == "__builtin_bswap64") return CType.scalar ("uint64");
                    if (fn == "__builtin_expect" && c.args.length >= 1)
                        return infer_type (c.args[0]);
                    if ((fn == "__atomic_load_n" || fn == "__atomic_store_n" || fn == "__atomic_exchange_n"
                         || fn == "__atomic_fetch_add" || fn == "__atomic_fetch_sub") && c.args.length >= 1) {
                        var a0 = c.args[0];
                        if (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                            return infer_type (((ExprUnary) a0).operand);
                        var pt = infer_type (a0);
                        if (pt != null && pt.inner != null)
                            return pt.inner;
                        return CType.scalar ("int");
                    }
                    var li = find_local (cur_locals, fn);
                    if (li != null && li.ctype.kind == CTypeKind.FUNC_PTR)
                        return li.ctype.fp_ret;
                    var sig = find_sig (fn);
                    if (sig != null)
                        return sig.ret_type;
                } else {
                    var ct = infer_type (c.callee);
                    if (ct != null && ct.kind == CTypeKind.FUNC_PTR)
                        return ct.fp_ret;
                }
            }
            return null;
        }

        private static string strip_outer_parens (string s) {
            string cur = s;
            while (cur.length >= 2 && cur[0] == '(' && cur[cur.length - 1] == ')') {
                int depth = 0;
                bool matched_end = true;
                for (int i = 0; i < cur.length; i++) {
                    uint8 ch = cur[i];
                    if (ch == '"' || ch == '\'') {
                        uint8 q = ch;
                        i++;
                        while (i < cur.length) {
                            if (cur[i] == '\\') {
                                i++;
                            } else if (cur[i] == q) {
                                break;
                            }
                            i++;
                        }
                        continue;
                    }
                    if (ch == '(') depth++;
                    else if (ch == ')') {
                        depth--;
                        if (depth == 0 && i < cur.length - 1) {
                            matched_end = false;
                            break;
                        }
                    }
                }
                if (!matched_end || depth != 0)
                    break;
                cur = cur.substring (1, cur.length - 2);
            }
            return cur;
        }

        private string emit_top_cond (CExpr e) throws RefuseError {
            return strip_outer_parens (emit_cond (e));
        }

        private string emit_cond (CExpr e) throws RefuseError {
            var t = infer_type (e);
            string s = emit_expr (e);
            if (t != null && t.is_scalar ("bool"))
                return s;
            if (t != null && (t.kind == CTypeKind.PTR || t.kind == CTypeKind.FUNC_PTR))
                return @"($s != null)";
            return @"($s != 0)";
        }

        // Vala requires an assignment's right-hand side to have exactly the
        // target's type; C converts implicitly. Insert the cast C leaves out.
        private string coerce_value (CExpr value, string? target) throws RefuseError {
            string rt = emit_expr (value);
            if (target == null)
                return rt;
            var vt = infer_type (value);
            if (vt == null || vt.kind != CTypeKind.SCALAR)
                return rt;
            if (vt.name == target)
                return rt;
            return @"($target) $(wrap_operand (rt))";
        }

        // Pointer to a scalar C type (char/int/...), as opposed to an object.
        private static bool is_scalar_ptr_type (CType ct) {
            if ((ct.kind != CTypeKind.PTR && ct.kind != CTypeKind.FUNC_PTR) || ct.inner == null)
                return false;
            return ((CType) ct.inner).kind == CTypeKind.SCALAR
                || ((CType) ct.inner).kind == CTypeKind.ENUM;
        }

        // True for `0`, `NULL`, and casts of those to any pointer type.
        private static bool is_null_ptr_expr (CExpr? e) {
            CExpr? cur = e;
            while (cur is ExprCast)
                cur = ((ExprCast) cur).expr;
            if (cur is ExprInt)
                return ((ExprInt) cur).val == 0;
            return false;
        }

        // Vala arrays are never null, so a C NULL for an array view becomes an
        // empty array.
        private string empty_array_for (CType ct) {
            string elem = "uint8";
            if (ct.inner != null) {
                var inner = (CType) ct.inner;
                if (inner.kind == CTypeKind.STRUCT)
                    elem = esc_ident (inner.name);
                else if (inner.kind == CTypeKind.SCALAR && !inner.is_scalar ("char") && !inner.is_scalar ("void"))
                    elem = inner.name;
                else if (inner.kind == CTypeKind.ENUM)
                    elem = esc_ident (inner.name);
            }
            return @"new $elem[0]";
        }

        // Value for a pointer-typed slot: NULL becomes null or an empty array.
        private string ptr_null_value (CType? target) throws RefuseError {
            if (target != null && target.kind == CTypeKind.PTR) {
                if (target.inner != null && vala_type (target, false).has_suffix ("[]"))
                    return empty_array_for (target);
                if (target.inner != null && ((CType) target.inner).is_scalar ("void"))
                    return empty_array_for (target);
                if (target.is_char_ptr ())
                    return "\"\"";
            }
            return "null";
        }

        // Vala view of a pointer-typed expression: 0 = not a pointer,
        // 1 = `string` (char * that is never indexed/offset), 2 = array.
        private int ptr_view (CExpr e, CType? ct) throws RefuseError {
            if (ct == null || ct.kind != CTypeKind.PTR || ct.inner == null)
                return 0;
            if (e is ExprIdent) {
                var li = find_local (cur_locals, ((ExprIdent) e).name);
                if (li != null && li.is_array)
                    return 2;
            }
            // `void *` is already a byte array in the generated Vala.
            if (!ct.is_char_ptr () && ((CType) ct.inner).is_scalar ("void"))
                return 2;
            if (is_alloc_call (e))
                return 2;
            if (e is ExprCast) {
                var ce = (ExprCast) e;
                var cit = infer_type (ce.expr);
                if (cit != null && cit.kind == CTypeKind.PTR)
                    return ptr_view (ce.expr, cit);
                return 1;
            }
            // `&p[n]` and `p + n` are slices of a buffer: array view.
            if (e is ExprUnary && ((ExprUnary) e).op == "&" && ((ExprUnary) e).operand is ExprIndex)
                return 2;
            if (e is ExprBinary && (((ExprBinary) e).op == "+" || ((ExprBinary) e).op == "-"))
                return 2;
            if (e is ExprCall && ((ExprCall) e).callee is ExprIdent) {
                var csig = find_sig (((ExprIdent) ((ExprCall) e).callee).name);
                if (csig != null && csig.ret_is_array)
                    return 2;
            }
            // A `T *` that is not an array (nothing indexes or offsets it) is
            // the nullable object view `T?`.
            return 1;
        }

        // Converts between the Vala views of a byte pointer: a `char *` that
        // is only read is a `string`; once it is indexed or offset it is a
        // `uint8[]` (see ptr_view). Conversions that would lose the pointer
        // offset or need a NUL-terminated array are refused instead of
        // emitting code that compiles but misbehaves.
        // Runtime helper that stores a value and returns it, replacing Vala's
        // missing assignment expression (see the ExprAssign branch).
        private static string assign_helper (string vt) {
            if (vt == "bool") return "c_assign_b";
            if (vt == "double") return "c_assign_d";
            if (vt == "float") return "c_assign_f";
            if (vt == "char") return "c_assign_c";
            if (vt == "uchar" || vt == "uint8") return "c_assign_u8";
            if (vt == "int8") return "c_assign_i8";
            if (vt == "int16") return "c_assign_i16";
            if (vt == "int" || vt == "int32") return "c_assign_i";
            if (vt == "int64" || vt == "long" || vt == "ssize_t") return "c_assign_i64";
            if (vt == "uint16" || vt == "ushort") return "c_assign_u16";
            if (vt == "uint32" || vt == "uint") return "c_assign_u32";
            if (vt == "uint64" || vt == "ulong" || vt == "size_t") return "c_assign_u64";
            return "";
        }

        // `target_view` forces the Vala view of the destination: 1 = string,
        // 2 = array, 0 = derive it (from `target_expr` or the C type).
        private string coerce_ptr (CExpr value, CType? target, CExpr? target_expr = null,
                                   int target_view = 0) throws RefuseError {
            string rt = emit_expr (value);
            if (target == null || target.kind != CTypeKind.PTR || target.inner == null)
                return rt;
            var vt = infer_type (value);
            int vv = ptr_view (value, vt);
            if (vv == 0) {
                if (is_null_ptr_expr (value))
                    return ptr_null_value (target);
                return rt;
            }
            int tv = target_view;
            if (tv == 0)
                tv = target_expr != null ? ptr_view (target_expr, target) : 1;
            if (vv == 1 && tv == 2) {
                var tinner = (CType) target.inner;
                if (tinner.is_scalar ("void") || tinner.is_scalar ("char"))
                    return @"c_str_to_bytes ($rt)";
                if (tinner.kind == CTypeKind.STRUCT)
                    return @"$(ensure_box_helper (esc_ident (tinner.name)))_arr ($rt)";
            }
            if (vv == 2 && tv == 1) {
                var tinner2 = (CType) target.inner;
                if (tinner2.is_scalar ("char") || tinner2.is_scalar ("void"))
                    return @"(string) $rt";
                if (tinner2.kind == CTypeKind.STRUCT) {
                    string uvt = esc_ident (tinner2.name);
                    return @"$(ensure_box_helper (uvt))_obj ($rt)";
                }
            }
            if (value is ExprIdent && vv == 2) {
                var vli = find_local (cur_locals, ((ExprIdent) value).name);
                if (vli != null && vli.has_ptr_arith && tv == 2 && target_expr == null) {
                    if (vli.ctype.is_char_ptr () || vli.ctype.is_void_ptr ())
                        return @"c_bytes_add ($rt, _off_$(vli.name))";
                    if (vli.ctype.inner != null) {
                        string sh = ensure_slice_helper ((CType) vli.ctype.inner);
                        return @"$sh ($rt, _off_$(vli.name))";
                    }
                    refuse_loc (value.file, value.line, "pointer with offset passed as a value");
                }
            }
            return rt;
        }

        private string coerce_assign (CExpr target, CExpr value) throws RefuseError {
            string? st = scalar_lvalue_type (target);
            if (st == null) {
                var tt = infer_type (target);
                if (tt != null && tt.kind == CTypeKind.PTR) {
                    if (is_null_ptr_expr (value))
                        return ptr_null_value (tt);
                    return coerce_ptr (value, tt, target);
                }
            }
            return coerce_value (value, st);
        }

        // Vala type of a scalar assignment target, or null when it is not one.
        private string? scalar_lvalue_type (CExpr t) throws RefuseError {
            if (t is ExprIdent) {
                var li = find_local (cur_locals, ((ExprIdent) t).name);
                if (li == null || li.is_array)
                    return null;
                if (li.ctype.kind == CTypeKind.ENUM)
                    return li.ctype.name;
                if (li.ctype.kind != CTypeKind.SCALAR)
                    return null;
                return li.ctype.name;
            }
            if (t is ExprUnary && ((ExprUnary) t).op == "*") {
                var et = infer_type (t);
                if (et == null || et.kind != CTypeKind.SCALAR)
                    return null;
                if (et.is_scalar ("char"))
                    return "uint8";
                return et.name;
            }
            if (t is ExprIndex) {
                var et = infer_type (t);
                if (et == null || et.kind != CTypeKind.SCALAR)
                    return null;
                // a `char *` buffer is declared as `uint8[]`
                if (et.is_scalar ("char"))
                    return "uint8";
                return et.name;
            }
            if (t is ExprMember) {
                var mt = infer_type (t);
                if (mt == null)
                    return null;
                if (mt.kind == CTypeKind.ENUM)
                    return mt.name;
                if (mt.kind != CTypeKind.SCALAR)
                    return null;
                return mt.name;
            }
            return null;
        }

        private NameIndexMap lit_map = new NameIndexMap (128);
        private GenericArray<LitHelper> lit_helpers = new GenericArray<LitHelper> ();

        // `(T){ .a = x }` used as a value: Vala has no object-initializer
        // expression in planc, so a static builder is generated instead.
        private string ensure_lit_helper (CType ct, ExprInitList il) throws RefuseError {
            var sd = find_struct (ct.name);
            var fields = new GenericArray<string> ();
            var vtypes = new GenericArray<string> ();
            int cur_idx = 0;
            for (int i = 0; i < il.items.length; i++) {
                string fname = (i < il.field_names.length) ? il.field_names[i] : "";
                CType? ftype = null;
                if (sd != null) {
                    if (fname != "") {
                        for (int fi = 0; fi < sd.fields.length; fi++) {
                            if (sd.fields[fi].name == fname) {
                                ftype = sd.fields[fi].ctype;
                                cur_idx = fi + 1;
                                break;
                            }
                        }
                    } else if (cur_idx < sd.fields.length) {
                        fname = sd.fields[cur_idx].name;
                        ftype = sd.fields[cur_idx].ctype;
                        cur_idx++;
                    }
                }
                if (ftype == null || fname == "")
                    refuse_loc (il.file, il.line, "compound literal field is unknown");
                unowned CType fct = (CType) ftype;
                fields.add (fname);
                vtypes.add (vala_type (fct, fct.kind == CTypeKind.ARRAY));
            }

            var sb = new StrBuilder (ct.name + "|");
            for (int i = 0; i < fields.length; i++)
                sb.append (fields[i] + ",");
            string key = sb.str;
            Host.spin_lock (del_lock);
            int idx = lit_map.get_index (key);
            if (idx >= 0) {
                string existing = lit_helpers[idx].name;
                Host.spin_unlock (del_lock);
                return existing;
            }
            var lh = new LitHelper () { ctype = ct };
            lh.name = @"_c2v_lit_$(esc_ident (ct.name))_$(lit_helpers.length)";
            for (int i = 0; i < fields.length; i++) {
                lh.fields.add (fields[i]);
                lh.vtypes.add (vtypes[i]);
            }
            lit_map.set_index (key, lit_helpers.length);
            lit_helpers.add (lh);
            Host.spin_unlock (del_lock);
            return lh.name;
        }

        private void emit_lit_helpers (StrBuilder sb) throws RefuseError {
            for (int hi = 0; hi < lit_helpers.length; hi++) {
                var lh = lit_helpers[hi];
                string vt = vala_type (lh.ctype, false);
                sb.append (@"private static $vt $(lh.name) (");
                for (int i = 0; i < lh.fields.length; i++) {
                    if (i > 0) sb.append (", ");
                    sb.append (@"$(lh.vtypes[i]) _c2v_a$i");
                }
                sb.append (") {\n");
                unowned StructDef? hsd = find_struct (lh.ctype.name);
                bool is_union = (hsd != null) && hsd.is_union && !union_needs_class (hsd);
                if (is_union)
                    sb.append (@"    $vt r = $vt ();\n");
                else
                    sb.append (@"    $vt r = new $vt ();\n");
                for (int i = 0; i < lh.fields.length; i++) {
                    sb.append (@"    r.$(esc_ident (lh.fields[i])) = _c2v_a$i;\n");
                }
                sb.append ("    return r;\n");
                sb.append ("}\n\n");
            }
        }

        private string emit_compound_struct_or_union (CType ct, ExprInitList il) throws RefuseError {
            var sd = find_struct (ct.name);
            string helper = ensure_lit_helper (ct, il);
            var sb = new StrBuilder (helper);
            sb.append (" (");
            int cur_idx = 0;
            for (int i = 0; i < il.items.length; i++) {
                if (i > 0) sb.append (", ");
                string fname = (i < il.field_names.length) ? il.field_names[i] : "";
                CType? ftype = null;
                if (sd != null) {
                    if (fname != "") {
                        for (int fi = 0; fi < sd.fields.length; fi++) {
                            if (sd.fields[fi].name == fname) {
                                ftype = sd.fields[fi].ctype;
                                cur_idx = fi + 1;
                                break;
                            }
                        }
                    } else if (cur_idx < sd.fields.length) {
                        ftype = sd.fields[cur_idx].ctype;
                        cur_idx++;
                    }
                }
                string? ftgt = null;
                if (ftype != null && (ftype.kind == CTypeKind.SCALAR || ftype.kind == CTypeKind.ENUM))
                    ftgt = vala_type (ftype, false);
                string val_s;
                if (ftype != null && (ftype.kind == CTypeKind.STRUCT || ftype.kind == CTypeKind.UNION) && il.items[i] is ExprInitList)
                    val_s = emit_compound_struct_or_union (ftype, (ExprInitList) il.items[i]);
                else
                    val_s = coerce_value (il.items[i], ftgt);
                sb.append (val_s);
            }
            sb.append (")");
            return sb.str;
        }

        private string lit_arg_key (CType ct, ExprInitList il) throws RefuseError {
            var sb = new StrBuilder (ct.name + "|");
            var sd = find_struct (ct.name);
            int cur_idx = 0;
            for (int i = 0; i < il.items.length; i++) {
                string fname = (i < il.field_names.length) ? il.field_names[i] : "";
                if (fname == "" && sd != null && cur_idx < sd.fields.length) {
                    fname = sd.fields[cur_idx].name;
                    cur_idx++;
                }
                sb.append (fname + ",");
            }
            return sb.str;
        }

        private static int hex_val (uint8 c) {
            if (c >= '0' && c <= '9') return (int) (c - '0');
            if (c >= 'a' && c <= 'f') return 10 + (int) (c - 'a');
            if (c >= 'A' && c <= 'F') return 10 + (int) (c - 'A');
            return -1;
        }

        private static string norm_float_lit (ExprFloat ef) {
            string s = ef.raw;
            if (!(s.has_prefix ("0x") || s.has_prefix ("0X")))
                return s;
            int i = 2;
            double val = 0.0;
            while (i < s.length) {
                int d = hex_val (s[i]);
                if (d < 0) break;
                val = val * 16.0 + (double) d;
                i++;
            }
            int frac_bits = 0;
            if (i < s.length && s[i] == '.') {
                i++;
                while (i < s.length) {
                    int d = hex_val (s[i]);
                    if (d < 0) break;
                    val = val * 16.0 + (double) d;
                    frac_bits += 4;
                    i++;
                }
            }
            int exp2 = -frac_bits;
            if (i < s.length && (s[i] == 'p' || s[i] == 'P')) {
                i++;
                bool neg = false;
                if (i < s.length && s[i] == '-') { neg = true; i++; }
                else if (i < s.length && s[i] == '+') { i++; }
                int ev = 0;
                while (i < s.length && s[i] >= '0' && s[i] <= '9') {
                    ev = ev * 10 + (int) (s[i] - '0');
                    i++;
                }
                exp2 += neg ? -ev : ev;
            }
            while (exp2 > 0) { val *= 2.0; exp2--; }
            while (exp2 < 0) { val *= 0.5; exp2++; }
            string out_s = val.to_string ();
            if (!out_s.contains (".") && !out_s.contains ("e") && !out_s.contains ("E"))
                out_s += ".0";
            if (ef.is_float)
                out_s += "f";
            return out_s;
        }

        private int64 type_size_bytes (CType ct, int depth = 0) {
            if (depth > 16)
                return 8;
            if (ct.kind == CTypeKind.SCALAR) {
                if (ct.name == "bool" || ct.name == "char" || ct.name == "int8" || ct.name == "uint8")
                    return 1;
                if (ct.name == "int16" || ct.name == "uint16")
                    return 2;
                if (ct.name == "int" || ct.name == "int32" || ct.name == "uint32" || ct.name == "float")
                    return 4;
                return 8;
            }
            if (ct.kind == CTypeKind.ENUM)
                return 4;
            if (ct.kind == CTypeKind.PTR || ct.kind == CTypeKind.FUNC_PTR)
                return 8;
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null) {
                int64 elem_sz = type_size_bytes ((CType) ct.inner, depth + 1);
                if (ct.array_len is ExprInt)
                    return ((ExprInt) ct.array_len).val * elem_sz;
                return elem_sz;
            }
            if (ct.kind == CTypeKind.STRUCT || ct.kind == CTypeKind.UNION) {
                var sd = find_struct (ct.name);
                if (sd == null)
                    return 8;
                int64 total = 0;
                for (int i = 0; i < sd.fields.length; i++) {
                    int64 fsz = type_size_bytes (sd.fields[i].ctype, depth + 1);
                    if (ct.kind == CTypeKind.UNION) {
                        if (fsz > total) total = fsz;
                    } else {
                        total += fsz;
                    }
                }
                return total > 0 ? total : 8;
            }
            return 8;
        }

        // Parenthesizes a cast operand only when it is not a bare name or
        // number: planc's parser rejects `(T) (x)`.
        private static string wrap_operand (string s) {
            if (s.length == 0)
                return s;
            for (int i = 0; i < s.length; i++) {
                char ch = s[i];
                bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
                    || (ch >= '0' && ch <= '9') || ch == '_' || ch == '.';
                if (!ok)
                    return @"($s)";
            }
            return s;
        }

        // Expressions that never need parentheses after a cast.
        private bool is_primary_expr (CExpr e) {
            if (e is ExprIdent || e is ExprInt || e is ExprFloat || e is ExprChar || e is ExprStr)
                return true;
            if (e is ExprCall || e is ExprIndex)
                return true;
            if (e is ExprMember)
                return is_primary_expr (((ExprMember) e).obj);
            if (e is ExprSizeofType || e is ExprSizeofExpr)
                return true;
            return false;
        }

        private string emit_expr (CExpr e, bool as_stmt = false) throws RefuseError {
            if (e is ExprInt)
                return norm_int_lit ((ExprInt) e);
            if (e is ExprFloat)
                return norm_float_lit ((ExprFloat) e);
            if (e is ExprChar)
                return ((ExprChar) e).raw;
            if (e is ExprStr)
                return ((ExprStr) e).raw;
            if (e is ExprIdent) {
                string nm = ((ExprIdent) e).name;
                var li = find_local (cur_locals, nm);
                if (li != null) {
                    if (li.has_addr_taken)
                        return @"$(esc_ident (nm))[0]";
                    return esc_ident (nm);
                }
                int em = find_enum_member (nm);
                if (em >= 0)
                    return @"$(esc_ident (enum_member_types[em])).$(esc_ident (nm))";
                if (find_sig (nm) != null)
                    return esc_ident (nm);
                if (global_map.get_index (nm) >= 0)
                    return esc_ident (nm);
                if (nm == "NULL")
                    return "null";
                if (nm == "__LINE__")
                    return @"$(e.line)";
                refuse_loc (e.file, e.line, @"unknown identifier '$nm'");
            }
            if (e is ExprCast) {
                var c = (ExprCast) e;
                bool is_null_zero = (c.expr is ExprInt && ((ExprInt) c.expr).val == 0)
                    || (c.expr is ExprIdent && ((ExprIdent) c.expr).name == "NULL");
                if ((c.target_type.kind == CTypeKind.PTR || c.target_type.kind == CTypeKind.FUNC_PTR)
                    && is_null_zero) {
                    if (c.target_type.is_char_ptr ())
                        return "\"\"";
                    string nvt = vala_type (c.target_type, false);
                    if (nvt.has_suffix ("[]"))
                        return @"new $(nvt.substring (0, nvt.length - 2))[0]";
                    return "null";
                }
                string vt = vala_type (c.target_type, false);
                if (vt.has_suffix ("[]"))
                    return emit_expr (c.expr);
                if (vt == "string") {
                    string inner_c = emit_expr (c.expr);
                    var ict = infer_type (c.expr);
                    if (ict != null && (ict.kind == CTypeKind.ARRAY
                        || (ict.kind == CTypeKind.PTR && ptr_view (c.expr, ict) == 2)))
                        return @"(string) $inner_c";
                    return inner_c;
                }
                var src_t = infer_type (c.expr);
                int src_view = (src_t != null) ? ptr_view (c.expr, src_t) : 0;
                bool tgt_class = (c.target_type.kind == CTypeKind.PTR
                    || c.target_type.kind == CTypeKind.FUNC_PTR);
                if (tgt_class && src_view == 2 && !is_scalar_ptr_type (c.target_type))
                    refuse_loc (e.file, e.line,
                        "cast from a byte buffer to an object pointer needs a manual port");
                // Unwrap redundant identical nested casts: `(T) ((T) x)` -> `(T) x`.
                CExpr inner_expr = c.expr;
                while (inner_expr is ExprCast && vala_type (((ExprCast) inner_expr).target_type, false) == vt)
                    inner_expr = ((ExprCast) inner_expr).expr;
                var inner_t = infer_type (inner_expr);
                if (inner_t != null && !(inner_expr is ExprInt) && !(inner_expr is ExprChar)
                    && inner_t.kind == CTypeKind.SCALAR && c.target_type.kind == CTypeKind.SCALAR
                    && vala_type (inner_t, false) == vt)
                    return emit_expr (inner_expr);
                // planc's parser rejects `(T) (x)` with a parenthesized simple
                // operand, so only complex operands get parentheses.
                return @"(($vt) $(wrap_operand (emit_expr (inner_expr))))";
            }
            if (e is ExprVaArg) {
                var va = (ExprVaArg) e;
                return @"$(emit_expr (va.ap)).arg<$(vala_type (va.target_type, false))> ()";
            }
            if (e is ExprSizeofType) {
                var st = (ExprSizeofType) e;
                if (st.target_type.kind == CTypeKind.SCALAR)
                    return @"sizeof ($(st.target_type.name))";
                if (st.target_type.kind == CTypeKind.ENUM)
                    return "sizeof (int)";
                return @"$(type_size_bytes (st.target_type))";
            }
            if (e is ExprSizeofExpr) {
                var se = (ExprSizeofExpr) e;
                var it = infer_type (se.expr);
                if (it != null) {
                    if (it.kind == CTypeKind.ARRAY && it.inner != null) {
                        int64 esz = type_size_bytes ((CType) it.inner);
                        if (it.array_len != null)
                            return @"((int) ($(emit_expr ((CExpr) it.array_len))) * $esz)";
                        if (se.expr is ExprIdent)
                            return @"($(esc_ident (((ExprIdent) se.expr).name)).length * $esz)";
                    }
                    if (it.kind == CTypeKind.SCALAR)
                        return @"sizeof ($(it.name))";
                    if (it.kind == CTypeKind.ENUM)
                        return "sizeof (int)";
                    return @"$(type_size_bytes (it))";
                }
                refuse_loc (e.file, e.line, "sizeof of a non-scalar");
            }
            if (e is ExprUnary) {
                var u = (ExprUnary) e;
                if (u.op == "&&")
                    refuse_loc (e.file, e.line, "computed gotos (&&label) are not supported");
                if (u.op == "&") {
                    if (u.operand is ExprUnary && ((ExprUnary) u.operand).op == "*")
                        return emit_expr (((ExprUnary) u.operand).operand);
                    if (u.operand is ExprIndex) {
                        // `&arr[n]` is a pointer into `arr`: a slice of it, not
                        // the element the index expression would select.
                        var ix = (ExprIndex) u.operand;
                        var at = infer_type (ix.array);
                        if (at != null && (at.kind == CTypeKind.ARRAY || at.kind == CTypeKind.PTR)
                            && at.inner != null) {
                            string base_e = emit_expr (ix.array);
                            string off_e = @"(int) ($(emit_expr (ix.index)))";
                            if (at.inner.is_scalar ("char") || at.inner.is_scalar ("void")) {
                                if (ptr_view (ix.array, at) == 1)
                                    return @"c_str_add ($base_e, $off_e)";
                                return @"c_bytes_add ($base_e, $off_e)";
                            }
                            if (at.inner.kind != CTypeKind.ARRAY) {
                                string sh = ensure_slice_helper ((CType) at.inner);
                                return @"$sh ($base_e, $off_e)";
                            }
                        }
                        return @"$(emit_expr (ix.array))[(int) $(emit_expr (ix.index))]";
                    }
                    if (u.operand is ExprIdent) {
                        var li = find_local (cur_locals, ((ExprIdent) u.operand).name);
                        if (li != null && li.has_addr_taken)
                            return esc_ident (li.name);
                    }
                    if (u.operand is ExprIdent || u.operand is ExprMember) {
                        var ot = infer_type (u.operand);
                        if (ot != null && (ot.kind == CTypeKind.STRUCT || ot.kind == CTypeKind.UNION || ot.kind == CTypeKind.ARRAY || ot.kind == CTypeKind.FUNC_PTR))
                            return emit_expr (u.operand);
                    }
                    refuse_loc (e.file, e.line, "address-of a non-lvalue");
                }
                if (u.op == "*") {
                    CExpr dop = u.operand;
                    while (dop is ExprCast) dop = ((ExprCast) dop).expr;
                    if (dop is ExprUnary && ((ExprUnary) dop).op == "&")
                        return emit_expr (((ExprUnary) dop).operand);
                    if (u.operand is ExprBinary) {
                        var pb = (ExprBinary) u.operand;
                        if ((pb.op == "+" || pb.op == "-") && pb.left is ExprIdent) {
                            string pnm = ((ExprIdent) pb.left).name;
                            var pli = find_local (cur_locals, pnm);
                            string off_p = (pli != null && pli.has_ptr_arith) ? @"_off_$pnm" : "0";
                            string sign = (pb.op == "+") ? "+" : "-";
                            return @"$(esc_ident (pnm))[$off_p $sign (int) ($(emit_expr (pb.right)))]";
                        }
                    }
                    if (u.operand is ExprIdent) {
                        string pnm = ((ExprIdent) u.operand).name;
                        var pli = find_local (cur_locals, pnm);
                        if (pli != null && pli.has_ptr_arith)
                            return @"$(esc_ident (pnm))[_off_$pnm]";
                    }
                    if (u.operand is ExprUnary) {
                        // *p++ / *++p / *p-- / *--p on an offset-tracked pointer.
                        var iu = (ExprUnary) u.operand;
                        if ((iu.op == "++" || iu.op == "--") && iu.operand is ExprIdent) {
                            string pnm = ((ExprIdent) iu.operand).name;
                            var pli = find_local (cur_locals, pnm);
                            if (pli != null && pli.has_ptr_arith) {
                                string idx = iu.is_post ? @"_off_$pnm$(iu.op)" : @"$(iu.op)_off_$pnm";
                                return @"$(esc_ident (pnm))[$idx]";
                            }
                        }
                    }
                    return @"$(emit_expr (u.operand))[0]";
                }
                if ((u.op == "++" || u.op == "--") && u.operand is ExprIdent) {
                    string pnm = ((ExprIdent) u.operand).name;
                    var pli = find_local (cur_locals, pnm);
                    if (pli != null && pli.has_ptr_arith) {
                        if (u.is_post)
                            return @"_off_$(pnm)$(u.op)";
                        return @"$(u.op)_off_$(pnm)";
                    }
                }
                string op_s = emit_expr (u.operand);
                if (u.op == "!")
                    return @"(!$(emit_cond (u.operand)))";
                if (u.is_post)
                    return @"$op_s$(u.op)";
                return @"$(u.op)$op_s";
            }
            if (e is ExprBinary) {
                var b = (ExprBinary) e;
                if (b.op == ",") {
                    var lt = infer_type (b.left);
                    var rt = infer_type (b.right);
                    if (lt != null && lt.kind == CTypeKind.SCALAR && lt.name == "void")
                        refuse_loc (e.file, e.line, "comma operator outside for/statement is not supported");
                    string l_i64;
                    if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY || lt.kind == CTypeKind.FUNC_PTR))
                        l_i64 = @"((int64) ($(emit_expr (b.left)) != null ? 1 : 0))";
                    else if (lt != null && lt.kind == CTypeKind.SCALAR && lt.name == "bool")
                        l_i64 = @"((int64) ($(emit_expr (b.left)) ? 1 : 0))";
                    else
                        l_i64 = @"((int64) ($(emit_expr (b.left))))";
                    string r_s = emit_expr (b.right);
                    if (rt != null && rt.kind == CTypeKind.SCALAR) {
                        if (rt.name == "bool") return @"c_comma_b ($l_i64, $r_s)";
                        if (rt.name == "double" || rt.name == "float") return @"c_comma_d ($l_i64, (double) ($r_s))";
                        if (rt.name == "int64" || rt.name == "long" || rt.name == "ssize_t") return @"c_comma_i64 ($l_i64, (int64) ($r_s))";
                        if (rt.name == "uint64" || rt.name == "size_t") return @"c_comma_u64 ($l_i64, (uint64) ($r_s))";
                        if (rt.name == "uint32" || rt.name == "uint" || rt.name == "unsigned") return @"c_comma_u32 ($l_i64, (uint32) ($r_s))";
                    }
                    return @"c_comma_i ($l_i64, (int) ($r_s))";
                }
                var lt = infer_type (b.left);
                var rt = infer_type (b.right);
                if (b.op == "&&" || b.op == "||") {
                    return @"($(emit_cond (b.left)) $(b.op) $(emit_cond (b.right)))";
                }
                if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)) {
                    CExpr ul = b.left;
                    while (ul is ExprCast) ul = ((ExprCast) ul).expr;
                    CExpr ur = b.right;
                    while (ur is ExprCast) ur = ((ExprCast) ur).expr;
                    if (b.op == "-" && rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)
                        && ul is ExprIdent && ur is ExprIdent) {
                        string ln = ((ExprIdent) ul).name;
                        string rn = ((ExprIdent) ur).name;
                        var lli = find_local (cur_locals, ln);
                        var rli = find_local (cur_locals, rn);
                        string lo = (lli != null && lli.has_ptr_arith) ? @"_off_$ln" : "0";
                        string ro = (rli != null && rli.has_ptr_arith) ? @"_off_$rn" : "0";
                        return @"($lo - $ro)";
                    }
                    if ((b.op == "+" || b.op == "-") && (rt == null || (rt.kind != CTypeKind.PTR && rt.kind != CTypeKind.ARRAY))) {
                        if (lt.is_char_ptr () && ptr_view (b.left, lt) == 1) {
                            string sign = (b.op == "+") ? "" : "-";
                            return @"c_str_add ($(emit_expr (b.left)), $sign((int) ($(emit_expr (b.right)))))";
                        }
                        if (lt.is_void_ptr () || lt.is_char_ptr ()) {
                            if (b.left is ExprIdent) {
                                string pnm = ((ExprIdent) b.left).name;
                                var pli = find_local (cur_locals, pnm);
                                if (pli != null && pli.has_ptr_arith)
                                    return @"c_bytes_add ($(esc_ident (pnm)), _off_$pnm $(b.op) (int) ($(emit_expr (b.right))))";
                            }
                            if (b.op == "+")
                                return @"c_bytes_add ($(emit_expr (b.left)), (int) ($(emit_expr (b.right))))";
                        }
                        if (b.op == "+" && b.left is ExprCast && lt.kind == CTypeKind.PTR && lt.inner != null) {
                            var inner_e = ((ExprCast) b.left).expr;
                            var it = infer_type (inner_e);
                            if (it != null && (it.is_void_ptr () || it.is_char_ptr ())) {
                                int64 esz = type_size_bytes ((CType) lt.inner);
                                return @"c_bytes_add ($(emit_expr (inner_e)), (int) ($(emit_expr (b.right))) * $((int) esz))";
                            }
                        }
                        if (lt.inner != null && lt.inner.kind != CTypeKind.ARRAY
                            && (lt.inner.kind != CTypeKind.PTR || !vala_type ((CType) lt.inner, false).has_suffix ("[]"))) {
                            if (b.left is ExprIdent) {
                                string pnm = ((ExprIdent) b.left).name;
                                var pli = find_local (cur_locals, pnm);
                                if (pli != null && pli.has_ptr_arith) {
                                    string sh = ensure_slice_helper ((CType) lt.inner);
                                    return @"$sh ($(esc_ident (pnm)), _off_$pnm $(b.op) (int) ($(emit_expr (b.right))))";
                                }
                            }
                            if (b.op == "+") {
                                string sh = ensure_slice_helper ((CType) lt.inner);
                                return @"$sh ($(emit_expr (b.left)), (int) ($(emit_expr (b.right))))";
                            }
                        }
                    }
                    if (b.op == "+" || b.op == "-")
                        refuse_loc (e.file, e.line, "pointer arithmetic is not supported");
                }
                if (b.op == "+" && rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)
                    && (lt == null || (lt.kind != CTypeKind.PTR && lt.kind != CTypeKind.ARRAY))) {
                    if (rt.is_char_ptr () && ptr_view (b.right, rt) == 1)
                        return @"c_str_add ($(emit_expr (b.right)), (int) ($(emit_expr (b.left))))";
                    if (rt.is_void_ptr () || rt.is_char_ptr ())
                        return @"c_bytes_add ($(emit_expr (b.right)), (int) ($(emit_expr (b.left))))";
                    if (rt.inner != null && rt.inner.kind != CTypeKind.ARRAY
                        && (rt.inner.kind != CTypeKind.PTR || !vala_type ((CType) rt.inner, false).has_suffix ("[]"))) {
                        string sh = ensure_slice_helper ((CType) rt.inner);
                        return @"$sh ($(emit_expr (b.right)), (int) ($(emit_expr (b.left))))";
                    }
                    refuse_loc (e.file, e.line, "pointer arithmetic is not supported");
                }
                string ls = emit_expr (b.left);
                string rs = emit_expr (b.right);
                if ((b.op == "==" || b.op == "!=")) {
                    if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY || lt.kind == CTypeKind.FUNC_PTR)
                        && b.right is ExprInt && ((ExprInt) b.right).val == 0) {
                        rs = "null";
                    } else if (rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY || rt.kind == CTypeKind.FUNC_PTR)
                               && b.left is ExprInt && ((ExprInt) b.left).val == 0) {
                        ls = "null";
                    }
                }
                if (lt != null && rt != null && lt.kind == CTypeKind.SCALAR && rt.kind == CTypeKind.SCALAR) {
                    if (lt.name != rt.name && lt.name != "bool" && rt.name != "bool") {
                        string cm = common_scalar (lt.name, rt.name);
                        if (lt.name != cm) ls = @"(($cm) $ls)";
                        if (rt.name != cm) rs = @"(($cm) $rs)";
                    }
                }
                return @"($ls $(b.op) $rs)";
            }
            if (e is ExprAssign) {
                var a = (ExprAssign) e;
                if (!as_stmt && a.op != "=" && (a.lvalue is ExprIdent || a.lvalue is ExprMember)) {
                    string? ost = scalar_lvalue_type (a.lvalue);
                    if (ost != null && assign_helper (ost) != "") {
                        string oh = ensure_op_assign_helper (a.op, ost);
                        return @"$oh ($(coerce_value (a.rvalue, ost)), ref $(emit_expr (a.lvalue)))";
                    }
                }
                if (!as_stmt && a.op == "=") {
                    string? ibase = null;
                    string? iidx = null;
                    string? ielem = null;
                    if (extract_index_lvalue (a.lvalue, ref ibase, ref iidx, ref ielem) && ielem != null) {
                        string ih = ensure_index_set_helper (ielem);
                        return @"$ih ($ibase, $iidx, $(coerce_value (a.rvalue, ielem)))";
                    }
                }
                if (!as_stmt && a.op == "=" && (a.lvalue is ExprIdent || a.lvalue is ExprMember)) {
                    // Vala has no assignment expression. `(n = x) == y` becomes
                    // `c_assign_<type> (x, ref n) == y`, which returns the value
                    // it stored.
                    string? st = scalar_lvalue_type (a.lvalue);
                    string ah = (st != null) ? assign_helper (st) : "";
                    if (ah != "")
                        return @"$ah ($(coerce_value (a.rvalue, st)), ref $(emit_expr (a.lvalue)))";
                    var lt = infer_type (a.lvalue);
                    if (lt != null && lt.kind == CTypeKind.FUNC_PTR) {
                        string fvt = vala_type (lt, false);
                        string fh = ensure_assign_helper (fvt);
                        return @"$fh ($(emit_expr (a.rvalue)), ref $(emit_expr (a.lvalue)))";
                    }
                    if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)) {
                        int lv = ptr_view (a.lvalue, lt);
                        string avt = vala_type (lt, lv == 2);
                        if (avt == "string" || avt.has_suffix ("[]") || avt.has_suffix ("?")) {
                            string ah2 = ensure_assign_helper (avt);
                            return @"$ah2 ($(coerce_ptr (a.rvalue, lt, a.lvalue, lv)), ref $(emit_expr (a.lvalue)))";
                        }
                    }
                }
                if (a.rvalue is ExprAssign && a.op == "=")
                    return @"$(emit_expr (a.lvalue)) = ($(emit_expr (a.rvalue)))";
                if (a.rvalue is ExprAssign)
                    refuse_loc (e.file, e.line, "chained assignment is only supported as a statement");
                if (a.lvalue is ExprIdent) {
                    var li = find_local (cur_locals, ((ExprIdent) a.lvalue).name);
                    if (li != null && li.has_ptr_arith) {
                        if (a.op == "+=" || a.op == "-=")
                            return @"_off_$(li.name) $(a.op) (int) ($(emit_expr (a.rvalue)))";
                        if (a.op == "=" && a.rvalue is ExprBinary) {
                            var rb = (ExprBinary) a.rvalue;
                            if ((rb.op == "+" || rb.op == "-") && rb.left is ExprIdent) {
                                string src = ((ExprIdent) rb.left).name;
                                var sli = find_local (cur_locals, src);
                                string base_off = (sli != null && sli.has_ptr_arith) ? @"_off_$src" : "0";
                                string sign = (rb.op == "+") ? "+" : "-";
                                if (src == li.name)
                                    return @"_off_$(li.name) = $base_off $sign (int) ($(emit_expr (rb.right)))";
                                return @"($(esc_ident (li.name)) = $(esc_ident (src))) != null ? (_off_$(li.name) = $base_off $sign (int) ($(emit_expr (rb.right)))) : 0";
                            }
                        }
                    }
                    if (li != null && is_alloc_call (a.rvalue)) {
                        return @"$(esc_ident (li.name)) = $(emit_alloc ((ExprCall) a.rvalue, li.ctype))";
                    }
                }
                if (a.op == "=")
                    return @"$(emit_expr (a.lvalue)) = $(coerce_assign (a.lvalue, a.rvalue))";
                return @"$(emit_expr (a.lvalue)) $(a.op) $(emit_expr (a.rvalue))";
            }
            if (e is ExprTernary) {                var t = (ExprTernary) e;
                return @"($(emit_cond (t.cond)) ? $(emit_expr (t.if_true)) : $(emit_expr (t.if_false)))";
            }
            if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                string base_s = emit_expr (ix.array);
                string idx_s = @"(int) ($(emit_expr (ix.index)))";
                if (ix.array is ExprIdent) {
                    string pnm = ((ExprIdent) ix.array).name;
                    var pli = find_local (cur_locals, pnm);
                    if (pli != null && pli.has_ptr_arith)
                        idx_s = @"_off_$pnm + $idx_s";
                }
                // `p[i]` where `p` is a nullable object reference: the element
                // is at index 0 of the boxed pointer.
                var at = infer_type (ix.array);
                if (at != null && at.kind == CTypeKind.PTR && at.inner != null
                    && ((CType) at.inner).kind == CTypeKind.STRUCT
                    && ptr_view (ix.array, at) == 1) {
                    string bvt = esc_ident (((CType) at.inner).name);
                    return @"$(ensure_box_helper (bvt))_arr ($base_s)[$idx_s]";
                }
                return @"$base_s[$idx_s]";
            }
            if (e is ExprMember) {
                var m = (ExprMember) e;
                string os = emit_expr (m.obj);
                if (m.is_arrow) {
                    var ot = infer_type (m.obj);
                    if (ot != null && ot.kind == CTypeKind.PTR && ot.inner != null
                        && (ot.inner.kind == CTypeKind.STRUCT || ot.inner.kind == CTypeKind.UNION)) {
                        // A pointer that decayed to an array parameter is indexed
                        // at 0; a real pointer is a nullable class reference,
                        // where `(!)` is the non-null assertion Vala needs.
                        bool arr_view = false;
                        if (ptr_view (m.obj, ot) == 2)
                            arr_view = true;
                        if (arr_view)
                            return @"$os[0].$(esc_ident (m.field))";
                        // Vala accepts member access through a nullable
                        // reference (`p.x`), and planc rejects a `(!)` cast in
                        // statement position, so keep the plain form.
                        return @"$os.$(esc_ident (m.field))";
                    }
                    return @"$os.$(esc_ident (m.field))";
                }
                return @"$os.$(esc_ident (m.field))";
            }
            if (e is ExprCall) {
                return emit_call ((ExprCall) e);
            }
            if (e is ExprCompoundLit) {
                var cl = (ExprCompoundLit) e;
                if (cl.target_type.kind == CTypeKind.ARRAY && cl.target_type.inner != null) {
                    var elem_ct = (CType) cl.target_type.inner;
                    string et = vala_type (elem_ct, false);
                    string? etgt = (elem_ct.kind == CTypeKind.SCALAR || elem_ct.kind == CTypeKind.ENUM) ? et : null;
                    var sb = new StrBuilder (@"new $et[] { ");
                    for (int i = 0; i < cl.init.items.length; i++) {
                        if (i > 0) sb.append (", ");
                        sb.append (coerce_value (cl.init.items[i], etgt));
                    }
                    sb.append (" }");
                    return sb.str;
                }
                if (cl.target_type.kind == CTypeKind.STRUCT || cl.target_type.kind == CTypeKind.UNION)
                    return emit_compound_struct_or_union (cl.target_type, cl.init);
                refuse_loc (e.file, e.line, "unsupported compound literal type");
            }
            if (e is ExprInitList) {
                refuse_loc (e.file, e.line, "initializer lists are not supported");
            }
            refuse_loc (e.file, e.line, "unsupported expression");
            throw new RefuseError.FAILED ("unreachable");
        }

        private string emit_alloc (ExprCall call, CType target_ptr) throws RefuseError {
            string fn = ((ExprIdent) call.callee).name;
            if (target_ptr.kind != CTypeKind.PTR || target_ptr.inner == null)
                refuse_loc (call.file, call.line, "malloc whose size does not imply an element type");
            var inner = (CType) target_ptr.inner;
            if (inner.kind == CTypeKind.STRUCT) {
                if (fn == "malloc" && call.args.length == 1
                    && (call.args[0] is ExprSizeofType || call.args[0] is ExprSizeofExpr))
                    return @"new $(vala_type (inner, false))[1]";
                refuse_loc (call.file, call.line, "malloc of structs is not supported");
            }
            string elem_t = (inner.is_scalar ("char") || inner.is_scalar ("void")) ? "uint8" : vala_type (inner, false);

            if (fn == "realloc") {
                if (call.args.length != 2)
                    refuse_loc (call.file, call.line, "realloc expects 2 arguments");
                if (inner.is_scalar ("char") || inner.is_scalar ("void"))
                    return @"c_realloc_u8 ($(emit_expr (call.args[0])), $(emit_expr (call.args[1])))";
                refuse_loc (call.file, call.line, "realloc is only supported on byte/char buffers");
            }

            if (fn == "calloc") {
                if (call.args.length != 2)
                    refuse_loc (call.file, call.line, "calloc expects 2 arguments");
                string count_s = emit_expr (call.args[0]);
                return @"new $elem_t[$count_s]";
            }

            // malloc(arg)
            if (call.args.length != 1)
                refuse_loc (call.file, call.line, "malloc expects 1 argument");
            var arg = call.args[0];
            // malloc(n * sizeof(T)) or malloc(sizeof(T) * n)
            if (arg is ExprBinary && ((ExprBinary) arg).op == "*") {
                var b = (ExprBinary) arg;
                if (b.right is ExprSizeofType)
                    return @"new $elem_t[$(emit_expr (b.left))]";
                if (b.left is ExprSizeofType)
                    return @"new $elem_t[$(emit_expr (b.right))]";
            }
            // malloc(n) for char* or void* -> new uint8[n]
            if (inner.is_scalar ("char") || inner.is_scalar ("void"))
                return @"new uint8[$(emit_expr (arg))]";

            refuse_loc (call.file, call.line, "malloc whose size does not imply an element type");
            throw new RefuseError.FAILED ("unreachable");
        }

        private string emit_printf_planc (ExprCall c, int fmt_idx = 0, string prefix = "print (") throws RefuseError {
            if (c.args.length <= fmt_idx || !(c.args[fmt_idx] is ExprStr))
                refuse_loc (c.file, c.line, "printf requires a literal format string");
            string raw = ((ExprStr) c.args[fmt_idx]).raw;
            string fmt = raw.length >= 2 ? raw.substring (1, raw.length - 2) : "";
            var sb = new StrBuilder (@"$(prefix)@\"");
            int arg_idx = fmt_idx + 1;
            int i = 0;
            while (i < fmt.length) {
                uint8 ch = fmt[i];
                if (ch == '$') {
                    // Escape literal $ in Vala @"..." template
                    sb.append ("\\$");
                    i++;
                    continue;
                }
                if (ch == '\\' && i + 1 < fmt.length) {
                    sb.append_c ((char) ch);
                    sb.append_c ((char) fmt[i + 1]);
                    i += 2;
                    continue;
                }
                if (ch == '%' && i + 1 < fmt.length) {
                    i++;
                    if (fmt[i] == '%') {
                        sb.append ("%");
                        i++;
                        continue;
                    }
                    // Skip optional flags/width/precision/length modifiers
                    while (i < fmt.length && (fmt[i] == '-' || fmt[i] == '+' || fmt[i] == ' '
                           || fmt[i] == '#' || fmt[i] == '0' || (fmt[i] >= '0' && fmt[i] <= '9')
                           || fmt[i] == '.')) {
                        i++;
                    }
                    while (i < fmt.length && (fmt[i] == 'l' || fmt[i] == 'z' || fmt[i] == 'h')) {
                        i++;
                    }
                    if (i >= fmt.length)
                        break;
                    uint8 spec = fmt[i++];
                    if (arg_idx >= c.args.length)
                        refuse_loc (c.file, c.line, "printf: not enough arguments");
                    var arg_e = c.args[arg_idx++];
                    string arg_s = emit_expr (arg_e);
                    if (spec == 'c') {
                        sb.append (@"$$(c_chr ((int) $arg_s))");
                    } else if (spec == 'x' || spec == 'X') {
                        string up = (spec == 'X') ? "true" : "false";
                        sb.append (@"$$(c_hex ((uint64) $arg_s, $up))");
                    } else if (spec == 's') {
                        // A `char *`/`char []` that is indexed becomes a byte
                        // array in Vala; turn it back into a string to print.
                        var sat = infer_type (arg_e);
                        if (sat != null && (sat.kind == CTypeKind.ARRAY
                            || (sat.kind == CTypeKind.PTR && ptr_view (arg_e, sat) == 2)))
                            sb.append (@"$$((string) $arg_s)");
                        else
                            sb.append (@"$$($arg_s)");
                    } else {
                        var at = infer_type (arg_e);
                        if (at != null && at.kind == CTypeKind.ENUM) {
                            sb.append (@"$$((int) $arg_s)");
                        } else {
                            sb.append (@"$$($arg_s)");
                        }
                    }
                    continue;
                }
                sb.append_c ((char) ch);
                i++;
            }
            sb.append ("\")");
            return sb.str;
        }

        private string emit_fp_call (string callee_s, CType fp_ct, ExprCall c) throws RefuseError {
            var sb = new StrBuilder (@"((!) $callee_s) (");
            for (int i = 0; i < c.args.length; i++) {
                if (i > 0) sb.append (", ");
                if (fp_ct.fp_params != null && i < fp_ct.fp_params.length) {
                    var pt = fp_ct.fp_params[i].ctype;
                    if (pt.kind == CTypeKind.PTR) {
                        if (is_null_ptr_expr (c.args[i])) {
                            sb.append (ptr_null_value (pt));
                            continue;
                        }
                        sb.append (coerce_ptr (c.args[i], pt, null, (pt.is_char_ptr () || pt.is_void_ptr ()) ? 2 : 1));
                        continue;
                    }
                    if (pt.kind == CTypeKind.SCALAR || pt.kind == CTypeKind.ENUM) {
                        sb.append (coerce_value (c.args[i], pt.name));
                        continue;
                    }
                }
                sb.append (emit_expr (c.args[i]));
            }
            sb.append (")");
            return sb.str;
        }

        private string emit_c_str_arg (CExpr e) throws RefuseError {
            string s = emit_expr (e);
            var at = infer_type (e);
            if (at != null && (at.kind == CTypeKind.ARRAY
                || (at.kind == CTypeKind.PTR && ptr_view (e, at) == 2)))
                return @"(string) $s";
            return s;
        }

        private string emit_call (ExprCall c) throws RefuseError {
            if (!(c.callee is ExprIdent)) {
                var ct = infer_type (c.callee);
                if (ct != null && ct.kind == CTypeKind.FUNC_PTR)
                    return emit_fp_call (emit_expr (c.callee), ct, c);
                refuse_loc (c.file, c.line, "indirect calls are not supported");
            }
            string fn = ((ExprIdent) c.callee).name;
            var local_fn = find_local (cur_locals, fn);
            if (local_fn != null && local_fn.ctype.kind == CTypeKind.FUNC_PTR)
                return emit_fp_call (esc_ident (fn), local_fn.ctype, c);

            if (fn == "malloc" || fn == "calloc" || fn == "realloc")
                refuse_loc (c.file, c.line, @"$fn is only supported in a local declaration");

            if (fn == "free") {
                if (c.args.length == 1 && (c.args[0] is ExprIdent || c.args[0] is ExprMember))
                    return @"$(emit_expr (c.args[0])) = null";
                return "/* free */";
            }

            if (fn == "memcpy" || fn == "memmove" || fn == "memset" || fn == "memcmp") {
                if ((fn == "memcpy" || fn == "memmove") && c.args.length == 3
                    && (c.args[2] is ExprSizeofType || c.args[2] is ExprSizeofExpr || c.args[2] is ExprInt)) {
                    var mt0 = infer_type (c.args[0]);
                    var mt1 = infer_type (c.args[1]);
                    if (mt0 != null && mt1 != null
                        && (mt0.kind == CTypeKind.STRUCT || mt0.is_struct_ptr ())
                        && (mt1.kind == CTypeKind.STRUCT || mt1.is_struct_ptr ())) {
                        string sn0 = (mt0.kind == CTypeKind.STRUCT) ? mt0.name : ((CType) mt0.inner).name;
                        string sn1 = (mt1.kind == CTypeKind.STRUCT) ? mt1.name : ((CType) mt1.inner).name;
                        if (sn0 == sn1) {
                            string lhs = (mt0.kind == CTypeKind.STRUCT) ? emit_expr (c.args[0]) : @"$(emit_expr (c.args[0]))[0]";
                            string rhs = (mt1.kind == CTypeKind.STRUCT) ? emit_expr (c.args[1]) : @"$(emit_expr (c.args[1]))[0]";
                            return @"$lhs = $rhs";
                        }
                    }
                }
                for (int mi = 0; mi < c.args.length && mi < 2; mi++) {
                    var mt = infer_type (c.args[mi]);
                    if (mt != null && (mt.kind == CTypeKind.STRUCT || mt.is_struct_ptr ()))
                        refuse_loc (c.file, c.line, @"$fn on a struct is not supported");
                }
                var sb = new StrBuilder (@"c_$fn (");
                for (int i = 0; i < c.args.length; i++) {
                    if (i > 0) sb.append (", ");
                    sb.append (emit_expr (c.args[i]));
                }
                sb.append (")");
                return sb.str;
            }

            if (fn == "__builtin_expect" && c.args.length >= 1)
                return @"($(emit_expr (c.args[0])))";
            if (fn == "__builtin_ctz" || fn == "__builtin_clz" || fn == "__builtin_popcount")
                return @"c_$(fn.substring (10))32 ((uint32) ($(emit_expr (c.args[0]))))";
            if (fn == "__builtin_ctzll" || fn == "__builtin_clzll" || fn == "__builtin_popcountll")
                return @"c_$(fn.substring (10, fn.length - 12))64 ((uint64) ($(emit_expr (c.args[0]))))";
            if (fn == "__builtin_bswap16")
                return @"c_bswap16 ((uint16) ($(emit_expr (c.args[0]))))";
            if (fn == "__builtin_bswap32")
                return @"c_bswap32 ((uint32) ($(emit_expr (c.args[0]))))";
            if (fn == "__builtin_bswap64")
                return @"c_bswap64 ((uint64) ($(emit_expr (c.args[0]))))";

            if (fn == "__builtin_frame_address")
                return "null";
            if (fn == "atomic_store" && c.args.length >= 2)
                return @"$(emit_expr (c.args[0]))[0] = $(emit_expr (c.args[1]))";
            if (fn == "__atomic_load_n" && c.args.length >= 1) {
                var a0 = c.args[0];
                if (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    return emit_expr (((ExprUnary) a0).operand);
                return @"$(emit_expr (a0))[0]";
            }
            if (fn == "__atomic_store_n" && c.args.length >= 2) {
                var a0 = c.args[0];
                string lhs = (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    ? emit_expr (((ExprUnary) a0).operand)
                    : @"$(emit_expr (a0))[0]";
                return @"$lhs = $(emit_expr (c.args[1]))";
            }
            if (fn == "__atomic_fetch_add" && c.args.length >= 2) {
                var a0 = c.args[0];
                string lhs = (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    ? emit_expr (((ExprUnary) a0).operand)
                    : @"$(emit_expr (a0))[0]";
                return @"($lhs += $(emit_expr (c.args[1])))";
            }
            if (fn == "__atomic_fetch_sub" && c.args.length >= 2) {
                var a0 = c.args[0];
                string lhs = (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    ? emit_expr (((ExprUnary) a0).operand)
                    : @"$(emit_expr (a0))[0]";
                return @"($lhs -= $(emit_expr (c.args[1])))";
            }

            if (fn == "assert" && c.args.length >= 1)
                return "assert (true)"; // NDEBUG semantics: the condition is not evaluated
            if (fn == "abort" && c.args.length == 0)
                return "c_abort ()";
            if (fn == "exit" && c.args.length == 1)
                return @"c_exit ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "getenv" && c.args.length == 1) {
                var a0t = infer_type (c.args[0]);
                string a0s = emit_expr (c.args[0]);
                if (a0t != null && (a0t.kind == CTypeKind.ARRAY
                    || (a0t.kind == CTypeKind.PTR && ptr_view (c.args[0], a0t) == 2)))
                    a0s = @"(string) $a0s";
                return @"c_getenv ($a0s)";
            }
            if ((fn == "isspace" || fn == "isdigit" || fn == "isalpha" || fn == "isalnum"
                 || fn == "isxdigit" || fn == "isupper" || fn == "islower"
                 || fn == "tolower" || fn == "toupper") && c.args.length == 1)
                return @"c_$fn ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "puts" && c.args.length == 1)
                return @"c_puts ($(emit_expr (c.args[0])))";
            if (fn == "isnan" && c.args.length == 1)
                return @"c_isnan ((double) ($(emit_expr (c.args[0]))))";
            if (fn == "isfinite" && c.args.length == 1)
                return @"c_isfinite ((double) ($(emit_expr (c.args[0]))))";
            if ((fn == "fabs" || fn == "trunc" || fn == "floor" || fn == "ceil") && c.args.length == 1)
                return @"c_$fn ((double) ($(emit_expr (c.args[0]))))";
            if ((fn == "sqrt" || fn == "cbrt" || fn == "round" || fn == "exp" || fn == "exp2" || fn == "expm1"
                 || fn == "log" || fn == "log2" || fn == "log10" || fn == "log1p"
                 || fn == "sin" || fn == "cos" || fn == "tan" || fn == "asin" || fn == "acos" || fn == "atan"
                 || fn == "sinh" || fn == "cosh" || fn == "tanh" || fn == "asinh" || fn == "acosh" || fn == "atanh")
                && c.args.length == 1)
                return @"Math.$fn ((double) ($(emit_expr (c.args[0]))))";
            if (fn == "lrint" && c.args.length == 1)
                return @"Math.lrint ((double) ($(emit_expr (c.args[0]))))";
            if (fn == "signbit" && c.args.length == 1)
                return @"Math.signbit ((double) ($(emit_expr (c.args[0]))))";
            if ((fn == "pow" || fn == "hypot" || fn == "atan2" || fn == "fmod" || fn == "fmin" || fn == "fmax"
                 || fn == "copysign") && c.args.length == 2)
                return @"Math.$fn ((double) ($(emit_expr (c.args[0]))), (double) ($(emit_expr (c.args[1]))))";
            if (fn == "putchar" && c.args.length == 1)
                return @"c_putchar ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "atoi" && c.args.length == 1)
                return @"c_atoi ($(emit_expr (c.args[0])))";
            if (fn == "strspn" && c.args.length == 2)
                return @"c_strspn ($(emit_expr (c.args[0])), $(emit_expr (c.args[1])))";
            if ((fn == "strchr" || fn == "strrchr") && c.args.length == 2)
                return @"c_$fn ($(emit_expr (c.args[0])), (int) ($(emit_expr (c.args[1]))))";

            if ((fn == "strcpy" || fn == "strcat") && c.args.length == 2) {
                var a0t = infer_type (c.args[0]);
                var a1t = infer_type (c.args[1]);
                string d_s = emit_expr (c.args[0]);
                if (a0t != null && ptr_view (c.args[0], a0t) == 1)
                    d_s = @"c_str_to_bytes ($d_s)";
                string s_s = emit_expr (c.args[1]);
                if (a1t != null && ptr_view (c.args[1], a1t) == 2)
                    s_s = @"(string) $s_s";
                return @"c_$(fn)_buf ($d_s, $s_s)";
            }
            if (fn == "strncpy" && c.args.length == 3) {
                var a0t = infer_type (c.args[0]);
                var a1t = infer_type (c.args[1]);
                string d_s = emit_expr (c.args[0]);
                if (a0t != null && ptr_view (c.args[0], a0t) == 1)
                    d_s = @"c_str_to_bytes ($d_s)";
                string s_s = emit_expr (c.args[1]);
                if (a1t != null && ptr_view (c.args[1], a1t) == 2)
                    s_s = @"(string) $s_s";
                return @"c_strncpy_buf ($d_s, $s_s, (size_t) ($(emit_expr (c.args[2]))))";
            }

            if (fn == "printf") {
                return emit_printf_planc (c);
            }
            if (fn == "fprintf") {
                if (c.args.length < 2)
                    refuse_loc (c.file, c.line, "fprintf needs a stream and format");
                if (c.args[1] is ExprStr)
                    return emit_printf_planc (c, 1, @"$(emit_expr (c.args[0])).puts (");
                var sb = new StrBuilder ();
                sb.append (@"$(emit_expr (c.args[0])).printf (");
                for (int i = 1; i < c.args.length; i++) {
                    if (i > 1) sb.append (", ");
                    sb.append (emit_expr (c.args[i]));
                }
                sb.append (")");
                return sb.str;
            }
            if (fn == "fopen" && c.args.length == 2) {
                return @"FileStream.open ($(emit_c_str_arg (c.args[0])), $(emit_c_str_arg (c.args[1])))";
            }
            if (fn == "fdopen" && c.args.length == 2) {
                return @"FileStream.fdopen ((int) ($(emit_expr (c.args[0]))), $(emit_c_str_arg (c.args[1])))";
            }
            if (fn == "fclose" && c.args.length == 1) {
                if (c.args[0] is ExprIdent)
                    return @"c_fclose (ref $(emit_expr (c.args[0])))";
                return @"c_fclose_val ($(emit_expr (c.args[0])))";
            }
            if (fn == "fputs" && c.args.length == 2) {
                return @"$(emit_expr (c.args[1])).puts ($(emit_c_str_arg (c.args[0])))";
            }
            if ((fn == "fputc" || fn == "putc") && c.args.length == 2) {
                return @"$(emit_expr (c.args[1])).putc ((char) ($(emit_expr (c.args[0]))))";
            }
            if ((fn == "fgetc" || fn == "getc") && c.args.length == 1) {
                return @"$(emit_expr (c.args[0])).getc ()";
            }
            if (fn == "ungetc" && c.args.length == 2) {
                return @"$(emit_expr (c.args[1])).ungetc ((int) ($(emit_expr (c.args[0]))))";
            }
            if (fn == "fflush" && c.args.length == 1) {
                return @"$(emit_expr (c.args[0])).flush ()";
            }
            if (fn == "fseek" && c.args.length == 3) {
                string w_s = "";
                if (c.args[2] is ExprInt) {
                    int64 wv = ((ExprInt) c.args[2]).val;
                    if (wv == 0) w_s = "FileSeek.SET";
                    else if (wv == 1) w_s = "FileSeek.CUR";
                    else if (wv == 2) w_s = "FileSeek.END";
                }
                if (w_s == "")
                    w_s = @"(FileSeek) ($(emit_expr (c.args[2])))";
                return @"$(emit_expr (c.args[0])).seek ((long) ($(emit_expr (c.args[1]))), $w_s)";
            }
            if (fn == "ftell" && c.args.length == 1) {
                return @"$(emit_expr (c.args[0])).tell ()";
            }
            if (fn == "rewind" && c.args.length == 1) {
                return @"$(emit_expr (c.args[0])).rewind ()";
            }
            if (fn == "feof" && c.args.length == 1) {
                return @"($(emit_expr (c.args[0])).eof () ? 1 : 0)";
            }
            if (fn == "ferror" && c.args.length == 1) {
                return @"$(emit_expr (c.args[0])).error ()";
            }
            if (fn == "clearerr" && c.args.length == 1) {
                return @"$(emit_expr (c.args[0])).clearerr ()";
            }
            if (fn == "fileno" && c.args.length == 1) {
                return @"$(emit_expr (c.args[0])).fileno ()";
            }
            if (fn == "fread" && c.args.length == 4) {
                return @"c_fread ($(emit_expr (c.args[0])), (size_t) ($(emit_expr (c.args[1]))), (size_t) ($(emit_expr (c.args[2]))), $(emit_expr (c.args[3])))";
            }
            if (fn == "fwrite" && c.args.length == 4) {
                var a0t = infer_type (c.args[0]);
                string p_s = emit_expr (c.args[0]);
                if (a0t != null && ptr_view (c.args[0], a0t) == 1)
                    p_s = @"($p_s).data";
                return @"c_fwrite ($p_s, (size_t) ($(emit_expr (c.args[1]))), (size_t) ($(emit_expr (c.args[2]))), $(emit_expr (c.args[3])))";
            }
            if (fn == "fgets" && c.args.length == 3) {
                return @"c_fgets ($(emit_expr (c.args[0])), (int) ($(emit_expr (c.args[1]))), $(emit_expr (c.args[2])))";
            }
            if (fn == "remove" && c.args.length == 1) {
                return @"c_remove ($(emit_c_str_arg (c.args[0])))";
            }
            if (fn == "rename" && c.args.length == 2) {
                return @"c_rename ($(emit_c_str_arg (c.args[0])), $(emit_c_str_arg (c.args[1])))";
            }
            if (fn == "strlen" || fn == "strcmp" || fn == "strncmp") {
                var sb = new StrBuilder (@"c_$fn (");
                for (int i = 0; i < c.args.length; i++) {
                    if (i > 0) sb.append (", ");
                    string arg_s = emit_expr (c.args[i]);
                    if (fn != "strncmp" || i < 2) {
                        var at = infer_type (c.args[i]);
                        if (at != null && (at.kind == CTypeKind.ARRAY
                            || (at.kind == CTypeKind.PTR && ptr_view (c.args[i], at) == 2)))
                            arg_s = @"(string) $arg_s";
                    }
                    sb.append (arg_s);
                }
                sb.append (")");
                return sb.str;
            }

            var sig = find_sig (fn);
            if (sig == null)
                refuse_loc (c.file, c.line, @"call to unknown function '$fn'");
            if (sig.is_varargs) {
                if (c.args.length < sig.param_types.length)
                    refuse_loc (c.file, c.line, @"arity mismatch calling '$fn'");
            } else if (c.args.length != sig.param_types.length) {
                refuse_loc (c.file, c.line, @"arity mismatch calling '$fn'");
            }

            var sb = new StrBuilder (@"$(esc_ident (fn)) (");
            for (int i = 0; i < c.args.length; i++) {
                if (i > 0) sb.append (", ");
                if (i >= sig.param_types.length) {
                    sb.append (emit_expr (c.args[i]));
                    continue;
                }
                var pt = sig.param_types[i];
                string? tgt = null;
                if (pt.kind == CTypeKind.SCALAR || pt.kind == CTypeKind.ENUM)
                    tgt = pt.name;
                if ((pt.kind == CTypeKind.PTR || pt.kind == CTypeKind.FUNC_PTR)
                    && is_null_ptr_expr (c.args[i])) {
                    sb.append (ptr_null_value (pt));
                    continue;
                }
                if (pt.kind == CTypeKind.PTR) {
                    bool parr = (i < sig.param_is_array.length) && sig.param_is_array[i];
                    sb.append (coerce_ptr (c.args[i], pt, null, parr ? 2 : 1));
                } else
                    sb.append (coerce_value (c.args[i], tgt));
            }
            sb.append (")");
            return sb.str;
        }
    }
}
