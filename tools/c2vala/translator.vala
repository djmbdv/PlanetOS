// Semantic analysis, array/memory fixpoint, and Vala emitter for c2vala.

using Planc;

namespace C2Vala {

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
        private int64[] enum_member_vals = new int64[0];

        // Grow-by-one append. `GenericArray<int64>` would be shorter but valac
        // rejects value types as generic arguments and planc rejects the
        // `int64?` box that valac demands, so the shared source uses an array.
        private void push_enum_val (int64 v) {
            var bigger = new int64[enum_member_vals.length + 1];
            for (int i = 0; i < enum_member_vals.length; i++)
                bigger[i] = enum_member_vals[i];
            bigger[enum_member_vals.length] = v;
            enum_member_vals = bigger;
        }

        public GenericArray<ReportEntry> report_entries = new GenericArray<ReportEntry> ();
        public int translated_count = 0;
        public int refused_count = 0;

        public Translator (TranslationUnit tu) {
            this.tu = tu;
        }

        private static void refuse_loc (string file, int line, string msg) throws RefuseError {
            if (file != "")
                throw new RefuseError.FAILED (@"$file:$line: $msg");
            throw new RefuseError.FAILED (msg);
        }

        private EnumDef? find_enum (string name) {
            for (int i = 0; i < tu.enums.length; i++) {
                if (tu.enums[i].name == name)
                    return tu.enums[i];
            }
            return null;
        }

        private StructDef? find_struct (string name) {
            for (int i = 0; i < tu.structs.length; i++) {
                if (tu.structs[i].name == name)
                    return tu.structs[i];
            }
            return null;
        }

        private FuncDef? find_func (string name) {
            for (int i = 0; i < tu.funcs.length; i++) {
                if (tu.funcs[i].name == name)
                    return tu.funcs[i];
            }
            return null;
        }

        private FuncSig? find_sig (string name) {
            for (int i = 0; i < sigs.length; i++) {
                if (sigs[i].name == name)
                    return sigs[i];
            }
            return null;
        }

        private int find_enum_member (string name) {
            for (int i = 0; i < enum_member_names.length; i++) {
                if (enum_member_names[i] == name)
                    return i;
            }
            return -1;
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
            for (int i = 0; i < del_sigs.length; i++) {
                if (del_sigs[i] == key)
                    return del_names[i];
            }
            string base_name = (hint != "") ? hint : @"_c2v_del_$(del_names.length)";
            string name = base_name;
            bool clash = (find_struct (name) != null || find_enum (name) != null || find_sig (name) != null);
            for (int i = 0; i < del_names.length; i++) {
                if (del_names[i] == name) {
                    clash = true;
                    break;
                }
            }
            if (clash)
                name = @"_c2v_del_$(del_names.length)";
            del_names.add (name);
            del_sigs.add (key);
            del_ctypes.add (fp);
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
                    enum_member_names.add (m.name);
                    enum_member_types.add (ed.name);
                    push_enum_val (next_val);
                    next_val++;
                }
            }
        }

        // ---- Whole-program array fixpoint ----

        private void build_sigs_and_fixpoint () {
            for (int fi = 0; fi < tu.funcs.length; fi++) {
                var fn = tu.funcs[fi];
                var sig = new FuncSig (fn.name, fn.ret_type);
                for (int pi = 0; pi < fn.params.length; pi++) {
                    sig.param_types.add (fn.params[pi].ctype);
                    sig.param_is_array.add (false);
                }
                sigs.add (sig);
            }

            // Fixpoint: propagate array-ness across calls and returns
            bool changed = true;
            while (changed) {
                changed = false;
                for (int fi = 0; fi < tu.funcs.length; fi++) {
                    var fn = tu.funcs[fi];
                    var sig = sigs[fi];
                    var locals = new GenericArray<LocalInfo> ();
                    for (int pi = 0; pi < fn.params.length; pi++) {
                        var li = new LocalInfo (fn.params[pi].name, fn.params[pi].ctype, true);
                        li.is_array = sig.param_is_array[pi];
                        locals.add (li);
                    }
                    if (fn.body != null) {
                        collect_locals_for_fixpoint ((CStmt) fn.body, locals);
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
                                changed = true;
                            }
                        }
                    }
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
                    return true;
                }
            }
            return false;
        }

        private bool scan_stmt_for_arrays (CStmt s, GenericArray<LocalInfo> locals, FuncSig cur_sig) {
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

        private bool scan_expr_for_arrays (CExpr e, GenericArray<LocalInfo> locals) {
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
                if (scan_expr_for_arrays (ix.array, locals)) changed = true;
                if (scan_expr_for_arrays (ix.index, locals)) changed = true;
            } else if (e is ExprUnary) {
                var u = (ExprUnary) e;
                if (u.op == "&" && u.operand is ExprIndex) {
                    var ix = (ExprIndex) u.operand;
                    if (mark_expr_array (ix.array, locals)) changed = true;
                } else if (u.op == "*") {
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
                    }
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

        private string vala_type (CType ct, bool as_array = false) throws RefuseError {
            if (ct.kind == CTypeKind.FUNC_PTR)
                return esc_ident (ensure_delegate (ct, ct.name)) + "?";
            if (ct.kind == CTypeKind.SCALAR)
                return ct.name;
            if (ct.kind == CTypeKind.ENUM)
                return esc_ident (ct.name);
            if (ct.kind == CTypeKind.STRUCT || ct.kind == CTypeKind.UNION)
                return esc_ident (ct.name);
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null) {
                return vala_type ((CType) ct.inner, false) + "[]";
            }
            if (ct.kind == CTypeKind.PTR && ct.inner != null) {
                var inner = (CType) ct.inner;
                if (as_array) {
                    if (inner.is_scalar ("char"))
                        return "uint8[]";
                    return vala_type (inner, false) + "[]";
                }
                if (inner.is_scalar ("char"))
                    return "string";
                if (inner.kind == CTypeKind.STRUCT)
                    return esc_ident (inner.name) + "?";
                return vala_type (inner, false) + "[]";
            }
            throw new RefuseError.FAILED ("unsupported type");
        }

        // ---- Main translation entry point ----

        public string translate (bool report_mode) throws RefuseError {
            if (tu.refused_global_reason != null) {
                refuse_loc (tu.refused_global_file ?? "", tu.refused_global_line, tu.refused_global_reason);
            }

            resolve_enums ();
            build_sigs_and_fixpoint ();

            var body_sb = new StrBuilder ();

            int ei = 0;
            int si = 0;
            int fi = 0;
            int gi = 0;
            for (int ti = 0; ti < tu.top_order.length; ti++) {
                string kind = tu.top_kinds[ti];
                if (kind == "enum") {
                    emit_enum (body_sb, tu.enums[ei++]);
                    body_sb.append ("\n");
                } else if (kind == "struct") {
                    emit_struct (body_sb, tu.structs[si++]);
                    body_sb.append ("\n");
                } else if (kind == "global") {
                    emit_global (body_sb, tu.globals[gi++]);
                    body_sb.append ("\n");
                } else if (kind == "func") {
                    var fn = tu.funcs[fi];
                    var sig = sigs[fi];
                    fi++;
                    if (report_mode) {
                        try {
                            var fsb = new StrBuilder ();
                            emit_func (fsb, fn, sig);
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
                        emit_func (body_sb, fn, sig);
                        body_sb.append ("\n");
                        report_entries.add (new ReportEntry (fn.name, true));
                        translated_count++;
                    }
                }
            }

            var sb = new StrBuilder ();
            sb.append ("// Generated by c2vala.\n\n");
            for (int di = 0; di < del_names.length; di++) {
                var fp = del_ctypes[di];
                string rtype = fp.fp_ret != null ? vala_type ((CType) fp.fp_ret, false) : "void";
                sb.append (@"public delegate $rtype $(esc_ident (del_names[di])) (");
                if (fp.fp_params != null) {
                    for (int pi = 0; pi < fp.fp_params.length; pi++) {
                        if (pi > 0) sb.append (", ");
                        var prm = fp.fp_params[pi];
                        sb.append (@"$(vala_type (prm.ctype, false)) $(esc_ident (prm.name))");
                    }
                }
                sb.append (");\n");
            }
            if (del_names.length > 0)
                sb.append ("\n");
            sb.append (body_sb.str);
            return sb.str;
        }

        private static void emit_ignored_attrs (StrBuilder sb, GenericArray<string> attrs, int level = 0) {
            for (int i = 0; i < attrs.length; i++) {
                indent (sb, level);
                sb.append (@"// c2vala ignored: $(attrs[i])\n");
            }
        }

        private void emit_global (StrBuilder sb, GlobalVarDef g) throws RefuseError {
            emit_ignored_attrs (sb, g.ignored_attrs);
            bool is_arr = (g.ctype.kind == CTypeKind.ARRAY);
            string vt = vala_type (g.ctype, is_arr);
            string gname = esc_ident (g.name);
            if (g.init == null) {
                sb.append (@"public $vt $gname;\n");
                return;
            }
            if (g.init is ExprInitList) {
                sb.append (@"public $vt $gname;\n");
                return;
            }
            string iv = emit_expr ((CExpr) g.init);
            if (g.ctype.is_const && !is_arr && (g.init is ExprInt || g.init is ExprStr || g.init is ExprChar))
                sb.append (@"public const $vt $gname = $iv;\n");
            else
                sb.append (@"public $vt $gname = $iv;\n");
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

        private void emit_struct (StrBuilder sb, StructDef sd) throws RefuseError {
            emit_ignored_attrs (sb, sd.ignored_attrs);
            string sname = esc_ident (sd.name);
            if (sd.is_union)
                sb.append (@"public union $sname {\n");
            else
                sb.append (@"public class $sname : Object {\n");

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

        private void emit_func (StrBuilder sb, FuncDef fn, FuncSig sig) throws RefuseError {
            if (fn.is_varargs)
                refuse_loc (fn.file, fn.line, "varargs are not supported");
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
                for (int gi = 0; gi < tu.globals.length; gi++) {
                    var g = tu.globals[gi];
                    string gname = esc_ident (g.name);
                    if (g.ctype.kind == CTypeKind.ARRAY) {
                        string elem_t = (g.ctype.inner != null) ? vala_type ((CType) g.ctype.inner, false) : "int";
                        if (g.init != null && g.init is ExprInitList) {
                            var il = (ExprInitList) g.init;
                            string sz_s = (g.ctype.array_len != null)
                                ? emit_expr ((CExpr) g.ctype.array_len)
                                : @"$(il.items.length)";
                            sb.append (@"    $gname = new $elem_t[$sz_s];\n");
                            for (int ii = 0; ii < il.items.length; ii++) {
                                string iv = coerce_value (il.items[ii], elem_t);
                                sb.append (@"    $gname[$ii] = $iv;\n");
                            }
                        } else if (g.ctype.array_len != null) {
                            string len_s = emit_expr ((CExpr) g.ctype.array_len);
                            sb.append (@"    $gname = new $elem_t[$len_s];\n");
                        }
                    } else if (g.ctype.kind == CTypeKind.STRUCT && g.init != null && g.init is ExprInitList) {
                        var sd = find_struct (g.ctype.name);
                        var il = (ExprInitList) g.init;
                        sb.append (@"    $gname = new $(esc_ident (g.ctype.name)) ();\n");
                        if (sd != null) {
                            for (int ii = 0; ii < il.items.length && ii < sd.fields.length; ii++) {
                                var fld = sd.fields[ii];
                                string? ft = (fld.ctype.kind == CTypeKind.SCALAR || fld.ctype.kind == CTypeKind.ENUM) ? vala_type (fld.ctype, false) : null;
                                sb.append (@"    $gname.$(esc_ident (fld.name)) = $(coerce_value (il.items[ii], ft));\n");
                            }
                        }
                    }
                }
            } else {
                string ret_t = vala_type (fn.ret_type, sig.ret_is_array);
                sb.append (@"$ret_t $(esc_ident (fn.name)) (");
                for (int i = 0; i < fn.params.length; i++) {
                    var p = fn.params[i];
                    string pt = vala_type (p.ctype, sig.param_is_array[i]);
                    if (i > 0)
                        sb.append (", ");
                    sb.append (@"$pt $(esc_ident (p.name))");
                    var li = new LocalInfo (p.name, p.ctype, true);
                    li.is_array = sig.param_is_array[i];
                    cur_locals.add (li);
                }
                sb.append (") {\n");
            }

            if (fn.body != null) {
                var blk = (StmtBlock) fn.body;
                // Pre-scan pointer arithmetic on params/locals so `_off_` offsets can be emitted at declaration
                var prescan_locals = new GenericArray<LocalInfo> ();
                for (int pi = 0; pi < cur_locals.length; pi++) {
                    var orig = cur_locals[pi];
                    var cpy = new LocalInfo (orig.name, orig.ctype, orig.is_param);
                    cpy.is_array = orig.is_array;
                    prescan_locals.add (cpy);
                }
                collect_locals_for_fixpoint (blk, prescan_locals);
                bool ps_ch = true;
                while (ps_ch)
                    ps_ch = scan_stmt_for_arrays (blk, prescan_locals, sig);
                for (int pi = 0; pi < cur_locals.length; pi++) {
                    var pl = find_local (prescan_locals, cur_locals[pi].name);
                    if (pl != null) {
                        cur_locals[pi].has_ptr_arith = pl.has_ptr_arith;
                        if (pl.has_ptr_arith && cur_locals[pi].is_param)
                            sb.append (@"    int _off_$(cur_locals[pi].name) = 0;\n");
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

        private string? all_goto_cond () {
            if (cur_gotos.length == 0)
                return null;
            var sb = new StrBuilder ();
            for (int i = 0; i < cur_gotos.length; i++) {
                if (i > 0) sb.append (" || ");
                sb.append (cur_gotos[i].flag_name);
            }
            return sb.str;
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
        }

        private void plan_gotos (StmtBlock blk) throws RefuseError {
            var gotos = new GenericArray<StmtGoto> ();
            collect_gotos (blk, gotos);
            if (gotos.length == 0)
                return;

            for (int gi = 0; gi < gotos.length; gi++) {
                var g = gotos[gi];
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

        private string emit_comma_list (CExpr e) throws RefuseError {
            if (e is ExprBinary && ((ExprBinary) e).op == ",") {
                var b = (ExprBinary) e;
                return @"$(emit_comma_list (b.left)), $(emit_comma_list (b.right))";
            }
            return emit_expr (e);
        }

        private void emit_stmt (StrBuilder sb, CStmt s, int level, string? loop_goto_flag = null) throws RefuseError {
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
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
                indent (sb, level);
                sb.append ("if (");
                sb.append (emit_cond (ifs.cond));
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
                string? gf = all_goto_cond ();
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
                    sb.append (emit_cond (ws.cond));
                    sb.append (");\n");
                } else {
                    indent (sb, level);
                    sb.append ("while (");
                    sb.append (emit_cond (ws.cond));
                    sb.append (") ");
                    emit_loop_body (sb, ws.body, level, gf);
                }
                return;
            }
            if (s is StmtFor) {
                var fs = (StmtFor) s;
                string? gf = cur_gotos.length > 0 ? cur_gotos[0].flag_name : null;
                indent (sb, level);
                sb.append ("for (");
                if (fs.init_decl != null) {
                    var d = (StmtDecl) fs.init_decl;
                    string vt = vala_type (d.ctype, false);
                    var li = new LocalInfo (d.name, d.ctype, false);
                    cur_locals.add (li);
                    sb.append (@"$vt $(esc_ident (d.name))");
                    if (d.init != null)
                        sb.append (@" = $(emit_expr ((CExpr) d.init))");
                } else if (fs.init_expr != null) {
                    sb.append (emit_comma_list ((CExpr) fs.init_expr));
                }
                sb.append ("; ");
                if (fs.cond != null)
                    sb.append (emit_cond ((CExpr) fs.cond));
                sb.append ("; ");
                if (fs.next != null)
                    sb.append (emit_comma_list ((CExpr) fs.next));
                sb.append (") ");
                emit_loop_body (sb, fs.body, level, all_goto_cond ());
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
                           && rs.expr is ExprInt && ((ExprInt) rs.expr).val == 0) {
                    sb.append ("return null;\n");
                } else {
                    string ex = emit_expr ((CExpr) rs.expr);
                    var rt = infer_type ((CExpr) rs.expr);
                    if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.SCALAR
                        && rt != null && rt.kind == CTypeKind.ENUM) {
                        ex = @"(($(cur_fn.ret_type.name)) $ex)";
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
                // Handle chained assignment `a = b = c;`
                if (es.expr is ExprAssign && ((ExprAssign) es.expr).rvalue is ExprAssign) {
                    emit_chained_assign (sb, (ExprAssign) es.expr, level);
                    return;
                }
                // Handle free(p)
                if (es.expr is ExprCall) {
                    var call = (ExprCall) es.expr;
                    if (call.callee is ExprIdent && ((ExprIdent) call.callee).name == "free") {
                        string arg_s = call.args.length > 0 ? emit_expr (call.args[0]) : "";
                        indent (sb, level);
                        sb.append (@"// free ($arg_s): the GC owns the array\n");
                        return;
                    }
                }
                indent (sb, level);
                sb.append (emit_expr ((CExpr) es.expr));
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

        private void emit_struct_init_assigns (StrBuilder sb, string lhs, StructDef sd, ExprInitList il, int level) throws RefuseError {
            for (int fi = 0; fi < il.items.length; fi++) {
                string fname = (fi < il.field_names.length) ? il.field_names[fi] : "";
                StructField? fld = null;
                if (fname != "") {
                    for (int k = 0; k < sd.fields.length; k++) {
                        if (sd.fields[k].name == fname) {
                            fld = sd.fields[k];
                            break;
                        }
                    }
                } else if (fi < sd.fields.length) {
                    fld = sd.fields[fi];
                }
                if (fld == null) continue;
                var f = (StructField) fld;
                string? ft = (f.ctype.kind == CTypeKind.SCALAR || f.ctype.kind == CTypeKind.ENUM)
                    ? vala_type (f.ctype, false) : null;
                indent (sb, level);
                sb.append (@"$lhs.$(esc_ident (f.name)) = $(coerce_value (il.items[fi], ft));\n");
            }
        }

        private void emit_decl (StrBuilder sb, StmtDecl d, int level) throws RefuseError {
            var li = new LocalInfo (d.name, d.ctype, false);
            bool is_malloc_init = is_alloc_call (d.init);
            if (d.ctype.kind == CTypeKind.ARRAY || is_malloc_init)
                li.is_array = true;
            // Check if pre-marked in fixpoint? If pointer and assigned malloc later, mark array!
            if (d.ctype.kind == CTypeKind.PTR && cur_fn != null && cur_fn.body != null) {
                if (is_var_assigned_array ((CStmt) cur_fn.body, d.name))
                    li.is_array = true;
            }
            if (cur_prescan != null) {
                var pl = find_local (cur_prescan, d.name);
                if (pl != null) {
                    if (pl.is_array) li.is_array = true;
                    li.has_ptr_arith = pl.has_ptr_arith;
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
                    for (int ii = 0; ii < il.items.length; ii++) {
                        if (elem_ct.kind == CTypeKind.STRUCT && il.items[ii] is ExprInitList) {
                            var sub_il = (ExprInitList) il.items[ii];
                            var sd = find_struct (elem_ct.name);
                            if (sd != null)
                                emit_struct_init_assigns (sb, @"$dname[$ii]", (StructDef) sd, sub_il, level);
                        } else {
                            indent (sb, level);
                            sb.append (@"$dname[$ii] = $(coerce_value (il.items[ii], etgt));\n");
                        }
                    }
                    return;
                }
                if (d.ctype.array_len == null)
                    refuse_loc (d.file, d.line, "array without size");
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
            bool alias_arr = li.is_array && d.ctype.kind == CTypeKind.PTR && d.init is ExprIdent;
            string decl_vt = alias_arr ? ("unowned " + vt) : vt;
            indent (sb, level);
            if (d.init != null) {
                if (is_malloc_init) {
                    string alloc_s = emit_alloc ((ExprCall) d.init, li.ctype);
                    sb.append (@"$decl_vt $dname = $alloc_s;\n");
                } else if (d.ctype.kind == CTypeKind.FUNC_PTR && d.init is ExprInt && ((ExprInt) d.init).val == 0) {
                    sb.append (@"$decl_vt $dname = null;\n");
                } else {
                    string? tgt = (d.ctype.kind == CTypeKind.SCALAR
                                   || d.ctype.kind == CTypeKind.ENUM) ? vt : null;
                    sb.append (@"$decl_vt $dname = $(coerce_value ((CExpr) d.init, tgt));\n");
                }
            } else {
                if (d.ctype.kind == CTypeKind.STRUCT) {
                    sb.append (@"$vt $dname = new $vt ();\n");
                } else if (d.ctype.kind == CTypeKind.UNION) {
                    sb.append (@"$vt $dname = $vt ();\n");
                } else if (li.is_array && d.ctype.kind == CTypeKind.PTR && d.ctype.inner != null) {
                    string elem_t = d.ctype.is_char_ptr () ? "uint8" : vala_type ((CType) d.ctype.inner, false);
                    sb.append (@"$vt $dname = new $elem_t[0];\n");
                } else if (d.ctype.is_struct_ptr () || d.ctype.kind == CTypeKind.FUNC_PTR) {
                    sb.append (@"$vt $dname = null;\n");
                } else if (d.ctype.is_char_ptr ()) {
                    sb.append (@"$vt $dname = \"\";\n");
                } else if (d.ctype.kind == CTypeKind.ENUM) {
                    sb.append (@"$vt $dname = ($vt) 0;\n");
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
                if (ot != null && ot.kind == CTypeKind.STRUCT) {
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
            return @"($target) ($rt)";
        }

        private string coerce_assign (CExpr target, CExpr value) throws RefuseError {
            return coerce_value (value, scalar_lvalue_type (target));
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

        private string emit_compound_struct_or_union (CType ct, ExprInitList il) throws RefuseError {
            string vt = vala_type (ct, false);
            var sd = find_struct (ct.name);
            var sb = new StrBuilder ();
            if (ct.kind == CTypeKind.UNION)
                sb.append (@"$vt () { ");
            else
                sb.append (@"new $vt () { ");
            for (int i = 0; i < il.items.length; i++) {
                if (i > 0) sb.append (", ");
                string fname = (i < il.field_names.length) ? il.field_names[i] : "";
                CType? ftype = null;
                if (sd != null) {
                    if (fname != "") {
                        for (int fi = 0; fi < sd.fields.length; fi++) {
                            if (sd.fields[fi].name == fname) {
                                ftype = sd.fields[fi].ctype;
                                break;
                            }
                        }
                    } else if (i < sd.fields.length) {
                        fname = sd.fields[i].name;
                        ftype = sd.fields[i].ctype;
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
                sb.append (@"$(esc_ident (fname)) = $val_s");
            }
            sb.append (" }");
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

        private string emit_expr (CExpr e) throws RefuseError {
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
                if (find_local (cur_locals, nm) != null)
                    return esc_ident (nm);
                int em = find_enum_member (nm);
                if (em >= 0)
                    return @"$(esc_ident (enum_member_types[em])).$(esc_ident (nm))";
                if (find_sig (nm) != null)
                    return esc_ident (nm);
                if (nm == "NULL")
                    return "null";
                refuse_loc (e.file, e.line, @"unknown identifier '$nm'");
            }
            if (e is ExprCast) {
                var c = (ExprCast) e;
                if ((c.target_type.kind == CTypeKind.PTR || c.target_type.kind == CTypeKind.FUNC_PTR)
                    && c.expr is ExprInt && ((ExprInt) c.expr).val == 0)
                    return "null";
                string vt = vala_type (c.target_type, false);
                return @"(($vt) ($(emit_expr (c.expr))))";
            }
            if (e is ExprSizeofType) {
                var st = (ExprSizeofType) e;
                if (st.target_type.kind != CTypeKind.SCALAR)
                    refuse_loc (e.file, e.line, "sizeof of a non-scalar");
                return @"sizeof ($(st.target_type.name))";
            }
            if (e is ExprSizeofExpr) {
                refuse_loc (e.file, e.line, "sizeof of a non-scalar");
            }
            if (e is ExprUnary) {
                var u = (ExprUnary) e;
                if (u.op == "&") {
                    if (u.operand is ExprIndex) {
                        var ix = (ExprIndex) u.operand;
                        return @"$(emit_expr (ix.array))[(int) $(emit_expr (ix.index))]";
                    }
                    if (u.operand is ExprIdent) {
                        var ot = infer_type (u.operand);
                        if (ot != null && (ot.kind == CTypeKind.STRUCT || ot.kind == CTypeKind.FUNC_PTR))
                            return emit_expr (u.operand);
                    }
                    refuse_loc (e.file, e.line, "address-of a non-lvalue");
                }
                if (u.op == "*") {
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
                if (b.op == ",")
                    refuse_loc (e.file, e.line, "comma operator outside for/statement is not supported");
                var lt = infer_type (b.left);
                var rt = infer_type (b.right);
                if (b.op == "&&" || b.op == "||") {
                    return @"($(emit_cond (b.left)) $(b.op) $(emit_cond (b.right)))";
                }
                if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)) {
                    if (b.op == "-" && rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)
                        && b.left is ExprIdent && b.right is ExprIdent) {
                        string ln = ((ExprIdent) b.left).name;
                        string rn = ((ExprIdent) b.right).name;
                        var lli = find_local (cur_locals, ln);
                        var rli = find_local (cur_locals, rn);
                        string lo = (lli != null && lli.has_ptr_arith) ? @"_off_$ln" : "0";
                        string ro = (rli != null && rli.has_ptr_arith) ? @"_off_$rn" : "0";
                        return @"($lo - $ro)";
                    }
                    if (b.op == "+" || b.op == "-")
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
                if (ix.array is ExprIdent) {
                    string pnm = ((ExprIdent) ix.array).name;
                    var pli = find_local (cur_locals, pnm);
                    if (pli != null && pli.has_ptr_arith)
                        return @"$(esc_ident (pnm))[_off_$pnm + (int) ($(emit_expr (ix.index)))]";
                }
                return @"$(emit_expr (ix.array))[(int) $(emit_expr (ix.index))]";
            }
            if (e is ExprMember) {
                var m = (ExprMember) e;
                string os = emit_expr (m.obj);
                if (m.is_arrow) {
                    var ot = infer_type (m.obj);
                    if (ot != null && ot.kind == CTypeKind.PTR && ot.inner != null && ot.inner.kind == CTypeKind.STRUCT) {
                        string st_name = esc_ident (ot.inner.name);
                        return @"(($st_name) $os).$(esc_ident (m.field))";
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
            if (inner.kind == CTypeKind.STRUCT)
                refuse_loc (call.file, call.line, "malloc of structs is not supported");
            string elem_t = inner.is_scalar ("char") ? "uint8" : vala_type (inner, false);

            if (fn == "realloc") {
                if (call.args.length != 2)
                    refuse_loc (call.file, call.line, "realloc expects 2 arguments");
                if (inner.is_scalar ("char"))
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
            // malloc(n) for char* -> new uint8[n]
            if (inner.is_scalar ("char"))
                return @"new uint8[$(emit_expr (arg))]";

            refuse_loc (call.file, call.line, "malloc whose size does not imply an element type");
            throw new RefuseError.FAILED ("unreachable");
        }

        private string emit_printf_planc (ExprCall c) throws RefuseError {
            if (c.args.length < 1 || !(c.args[0] is ExprStr))
                refuse_loc (c.file, c.line, "printf requires a literal format string");
            string raw = ((ExprStr) c.args[0]).raw;
            string fmt = raw.length >= 2 ? raw.substring (1, raw.length - 2) : "";
            var sb = new StrBuilder ("print (@\"");
            int arg_idx = 1;
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
                string? tgt = null;
                if (fp_ct.fp_params != null && i < fp_ct.fp_params.length) {
                    var pt = fp_ct.fp_params[i].ctype;
                    if (pt.kind == CTypeKind.SCALAR || pt.kind == CTypeKind.ENUM)
                        tgt = pt.name;
                }
                sb.append (coerce_value (c.args[i], tgt));
            }
            sb.append (")");
            return sb.str;
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

            if (fn == "strcpy" || fn == "strncpy" || fn == "strcat")
                refuse_loc (c.file, c.line, @"$fn on buffers is not supported yet");

            if (fn == "printf") {
                return emit_printf_planc (c);
            }
            if (fn == "fprintf") {
                if (c.args.length < 1)
                    refuse_loc (c.file, c.line, "fprintf needs a stream");
                var sb = new StrBuilder ();
                sb.append (@"$(emit_expr (c.args[0])).printf (");
                for (int i = 1; i < c.args.length; i++) {
                    if (i > 1) sb.append (", ");
                    sb.append (emit_expr (c.args[i]));
                }
                sb.append (")");
                return sb.str;
            }
            if (fn == "strlen" || fn == "strcmp" || fn == "strncmp") {
                var sb = new StrBuilder (@"c_$fn (");
                for (int i = 0; i < c.args.length; i++) {
                    if (i > 0) sb.append (", ");
                    sb.append (emit_expr (c.args[i]));
                }
                sb.append (")");
                return sb.str;
            }

            var sig = find_sig (fn);
            if (sig == null)
                refuse_loc (c.file, c.line, @"call to unknown function '$fn'");
            if (c.args.length != sig.param_types.length)
                refuse_loc (c.file, c.line, @"arity mismatch calling '$fn'");

            var sb = new StrBuilder (@"$(esc_ident (fn)) (");
            for (int i = 0; i < c.args.length; i++) {
                if (i > 0) sb.append (", ");
                var pt = sig.param_types[i];
                string? tgt = null;
                if (pt.kind == CTypeKind.SCALAR || pt.kind == CTypeKind.ENUM)
                    tgt = pt.name;
                sb.append (coerce_value (c.args[i], tgt));
            }
            sb.append (")");
            return sb.str;
        }
    }
}
