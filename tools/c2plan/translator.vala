// Semantic analysis, array/memory fixpoint, and Plan/Vala emitter for c2plan.

using Planc;

namespace C2Plan {

    public class Translator : Object {
        public bool plan_mode { get; set; default = true; }
        private TranslationUnit tu;
        private GenericArray<FuncSig> sigs = new GenericArray<FuncSig> ();
        private GenericArray<string> enum_member_names = new GenericArray<string> ();
        private GenericArray<string> enum_member_types = new GenericArray<string> ();
        private int64[] enum_member_vals = new int64[256];
        private int enum_member_vals_len = 0;
        private NameIndexMap enum_map = new NameIndexMap (512);
        private NameIndexMap struct_map = new NameIndexMap (2048);
        private NameIndexMap byte_cast_struct_map = new NameIndexMap (256);
        private NameIndexMap sig_map = new NameIndexMap (4096);
        private NameIndexMap global_map = new NameIndexMap (1024);
        private NameIndexMap enum_member_map = new NameIndexMap (8192);
        private NameIndexMap del_sig_map = new NameIndexMap (512);
        private NameIndexMap del_name_map = new NameIndexMap (512);
        private NameIndexMap slice_map = new NameIndexMap (256);
        private GenericArray<string> slice_names = new GenericArray<string> ();
        private GenericArray<string> slice_vtypes = new GenericArray<string> ();
        private NameIndexMap copy_arr_map = new NameIndexMap (256);
        private GenericArray<string> copy_arr_names = new GenericArray<string> ();
        private GenericArray<string> copy_arr_vtypes = new GenericArray<string> ();
        private NameIndexMap fref_map = new NameIndexMap (256);
        private GenericArray<string> fref_names = new GenericArray<string> ();
        private GenericArray<string> fref_vtypes = new GenericArray<string> ();
        private NameIndexMap fref_step_map = new NameIndexMap (256);
        private GenericArray<string> fref_step_names = new GenericArray<string> ();
        private GenericArray<string> fref_step_fref = new GenericArray<string> ();
        private GenericArray<string> fref_step_vtypes = new GenericArray<string> ();
        private GenericArray<string> fref_step_fields = new GenericArray<string> ();
        private NameIndexMap opaque_map = new NameIndexMap (256);
        private GenericArray<string> opaque_names = new GenericArray<string> ();
        private NameIndexMap emitted_globals = new NameIndexMap (1024);
        private int[] del_lock = new int[1];
        private GenericArray<GenericArray<LocalInfo>> fn_locals = new GenericArray<GenericArray<LocalInfo>> ();

        // Monotonic counter for the loop variables of the array allocation
        // statements, so no two allocations in the same scope can collide.
        private int alloc_uniq = 0;

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

        private string ensure_box_helper (string vt_in) {
            string vt = (vt_in == "tm") ? "Time" : vt_in;
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

        private NameIndexMap arr_box_map = new NameIndexMap (128);
        private GenericArray<string> arr_box_names = new GenericArray<string> ();
        private GenericArray<string> arr_box_vtypes = new GenericArray<string> ();

        private string ensure_arr_box_helper (string arr_vt) {
            Host.spin_lock (del_lock);
            int idx = arr_box_map.get_index (arr_vt);
            if (idx >= 0) {
                string existing = arr_box_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            string elem = arr_vt.has_suffix ("[]") ? arr_vt.substring (0, arr_vt.length - 2) : arr_vt;
            var m = new StrBuilder ("_c2v_abox_");
            for (int i = 0; i < elem.length; i++) {
                char ch = elem[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string cls_name = m.str;
            arr_box_map.set_index (arr_vt, arr_box_names.length);
            arr_box_names.add (cls_name);
            arr_box_vtypes.add (arr_vt);
            Host.spin_unlock (del_lock);
            return cls_name;
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

        private string ensure_copy_arr_helper (string vt) {
            Host.spin_lock (del_lock);
            int idx = copy_arr_map.get_index (vt);
            if (idx >= 0) {
                string existing = copy_arr_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            var m = new StrBuilder ("_c2v_copy_arr_");
            for (int i = 0; i < vt.length; i++) {
                char ch = vt[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string fn_name = m.str;
            copy_arr_map.set_index (vt, copy_arr_names.length);
            copy_arr_names.add (fn_name);
            copy_arr_vtypes.add (vt);
            Host.spin_unlock (del_lock);
            return fn_name;
        }

        private string ensure_field_ref_helper (string vt) {
            Host.spin_lock (del_lock);
            int idx = fref_map.get_index (vt);
            if (idx >= 0) {
                string existing = fref_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            var m = new StrBuilder ("_c2v_fref_");
            for (int i = 0; i < vt.length; i++) {
                char ch = vt[i];
                if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_')
                    m.append_c (ch);
                else
                    m.append_c ('_');
            }
            string cls_name = m.str;
            fref_map.set_index (vt, fref_names.length);
            fref_names.add (cls_name);
            fref_vtypes.add (vt);
            Host.spin_unlock (del_lock);
            return cls_name;
        }

        private static string fnv1a_hex (string s) {
            uint32 h = 2166136261u;
            for (int i = 0; i < s.length; i++) {
                h ^= (uint32) s[i];
                h *= 16777619u;
            }
            return Host.hex_u32 (h);
        }

        private static int str_cmp (string a, string b) {
            int na = a.length;
            int nb = b.length;
            int m = na < nb ? na : nb;
            for (int i = 0; i < m; i++) {
                int ca = (int) a[i] & 0xff;
                int cb = (int) b[i] & 0xff;
                if (ca != cb)
                    return ca < cb ? -1 : 1;
            }
            if (na == nb)
                return 0;
            return na < nb ? -1 : 1;
        }

        private static int[] sorted_order (GenericArray<string> names) {
            int n = names.length;
            int[] ord = new int[n];
            for (int i = 0; i < n; i++)
                ord[i] = i;
            for (int i = 1; i < n; i++) {
                int key_idx = ord[i];
                string key_name = names[key_idx];
                int j = i - 1;
                while (j >= 0 && str_cmp (names[ord[j]], key_name) > 0) {
                    ord[j + 1] = ord[j];
                    j--;
                }
                ord[j + 1] = key_idx;
            }
            return ord;
        }

        private string ensure_field_ref_step (string fref_cls, string vt, string field) {
            string key = @"$fref_cls|$field";
            Host.spin_lock (del_lock);
            int idx = fref_step_map.get_index (key);
            if (idx >= 0) {
                string existing = fref_step_names[idx];
                Host.spin_unlock (del_lock);
                return existing;
            }
            string sfn = @"_c2v_step_$(fref_cls)_$(esc_ident (field))";
            fref_step_map.set_index (key, fref_step_names.length);
            fref_step_names.add (sfn);
            fref_step_fref.add (fref_cls);
            fref_step_vtypes.add (vt);
            fref_step_fields.add (esc_ident (field));
            Host.spin_unlock (del_lock);
            return sfn;
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
            this.byte_cast_struct_map = src.byte_cast_struct_map;
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
            this.copy_arr_map = src.copy_arr_map;
            this.copy_arr_names = src.copy_arr_names;
            this.copy_arr_vtypes = src.copy_arr_vtypes;
            this.fref_map = src.fref_map;
            this.fref_names = src.fref_names;
            this.fref_vtypes = src.fref_vtypes;
            this.fref_step_map = src.fref_step_map;
            this.fref_step_names = src.fref_step_names;
            this.fref_step_fref = src.fref_step_fref;
            this.fref_step_vtypes = src.fref_step_vtypes;
            this.fref_step_fields = src.fref_step_fields;
            this.assign_arr_map = src.assign_arr_map;
            this.assign_arr_names = src.assign_arr_names;
            this.assign_arr_vtypes = src.assign_arr_vtypes;
            this.ptr_arr_map = src.ptr_arr_map;
            this.box_map = src.box_map;
            this.box_names = src.box_names;
            this.box_types = src.box_types;
            this.arr_box_map = src.arr_box_map;
            this.arr_box_names = src.arr_box_names;
            this.arr_box_vtypes = src.arr_box_vtypes;
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
            if (s == "DateTime")
                return "_c2v_DateTime";
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
            string h = fnv1a_hex (key);
            string base_name = (hint != "") ? @"_c2v_del_$(hint)_$h" : @"_c2v_del_$h";
            string name = base_name;
            bool clash = (find_struct (name) != null || find_enum (name) != null
                || find_sig (name) != null || del_name_map.get_index (name) >= 0
                || global_map.get_index (name) >= 0);
            if (clash) {
                name = @"_c2v_del_$h";
                int salt = 1;
                while (del_name_map.get_index (name) >= 0) {
                    name = @"_c2v_del_$(h)_$(salt)";
                    salt++;
                }
            }
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
                // `extern int x;` names a global: no local may shadow it.
                if (!d.is_extern) {
                    var li = new LocalInfo (d.name, d.ctype, false);
                    if (d.ctype.kind == CTypeKind.ARRAY)
                        li.is_array = true;
                    locals.add (li);
                }
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

        // Structural form of ptr_pair_base: `(byte *)view + n`, `byte_array + n`
        // and chains of them can be carried as a (buffer, offset) pair.
        private bool is_byte_pair_expr (CExpr e, GenericArray<LocalInfo> locals) throws RefuseError {
            var ce = e;
            bool any_term = false;
            while (ce is ExprBinary) {
                var b = (ExprBinary) ce;
                if (b.op != "+" && b.op != "-")
                    return false;
                var rt = infer_type (b.right);
                if (rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY))
                    return false;
                any_term = true;
                ce = b.left;
            }
            if (!any_term)
                return false;
            if (ce is ExprCast) {
                var c = (ExprCast) ce;
                var ct = c.target_type;
                if (ct.kind != CTypeKind.PTR || ct.inner == null)
                    return false;
                var ci = (CType) ct.inner;
                if (!(ci.is_scalar ("char") || ci.is_scalar ("void") || ci.is_scalar ("uchar")
                      || ci.is_scalar ("uint8") || ci.is_scalar ("int8")))
                    return false;
                ce = c.expr;
            }
            if (!(ce is ExprIdent))
                return false;
            string an = ((ExprIdent) ce).name;
            var li = find_local (locals, an);
            if (li != null) {
                if (li.ctype.kind == CTypeKind.PTR && li.ctype.inner != null) {
                    var inn = (CType) li.ctype.inner;
                    if (inn.kind == CTypeKind.STRUCT || inn.kind == CTypeKind.UNION) {
                        if (byte_cast_struct_map.get_index (inn.name) < 0)
                            return false;
                        var sd = find_struct (inn.name);
                        return sd != null && sd.fields.length > 0;
                    }
                    return inn.is_scalar ("uint8") || inn.is_scalar ("uchar")
                        || inn.is_scalar ("char") || inn.is_scalar ("void");
                }
                if (li.is_array && li.ctype.kind != CTypeKind.PTR)
                    return true;
                if (li.ctype.kind == CTypeKind.ARRAY && li.ctype.inner != null) {
                    var ain = (CType) li.ctype.inner;
                    return ain.is_scalar ("uint8") || ain.is_scalar ("uchar")
                        || ain.is_scalar ("char") || ain.is_scalar ("void");
                }
                return false;
            }
            var gt = infer_type (ce);
            return gt != null && gt.inner != null
                && (gt.kind == CTypeKind.ARRAY || gt.kind == CTypeKind.PTR)
                && (((CType) gt.inner).is_scalar ("uint8") || ((CType) gt.inner).is_scalar ("uchar")
                    || ((CType) gt.inner).is_scalar ("char") || ((CType) gt.inner).is_scalar ("void"));
        }

        private bool scan_stmt_for_arrays (CStmt s, GenericArray<LocalInfo> locals, FuncSig cur_sig) throws RefuseError {
            bool changed = false;
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (scan_stmt_for_arrays (b.stmts[i], locals, cur_sig)) changed = true;
            } else if (s is StmtDecl) {
                var d = (StmtDecl) s;
                if (d.is_extern)
                    return false;
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
                    } else if (d.init is ExprBinary) {
                        // `p = row_of_2d + n`: the row is a reference, so `p`
                        // carries an offset instead of a copied slice.
                        var ib0 = (ExprBinary) d.init;
                        if ((ib0.op == "+" || ib0.op == "-") && ib0.left is ExprIndex
                            && is_row_of_2d (((ExprIndex) ib0.left).array)) {
                            var li = find_local (locals, d.name);
                            if (li != null) {
                                if (!li.is_array) { li.is_array = true; changed = true; }
                                if (!li.has_ptr_arith) { li.has_ptr_arith = true; changed = true; }
                            }
                        }
                        if ((ib0.op == "+" || ib0.op == "-") && is_byte_pair_expr (ib0, locals)) {
                            var li = find_local (locals, d.name);
                            if (li != null) {
                                if (!li.is_array) { li.is_array = true; changed = true; }
                                if (!li.has_ptr_arith) { li.has_ptr_arith = true; changed = true; }
                            }
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
                            || li.ctype.kind == CTypeKind.PTR)) {
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
                        if (a.op == "=" && a.rvalue is ExprBinary) {
                            // `p = row_of_2d + n` needs an offset, not a copy.
                            var ar = (ExprBinary) a.rvalue;
                            if ((ar.op == "+" || ar.op == "-") && ar.left is ExprIndex
                                && is_row_of_2d (((ExprIndex) ar.left).array)) {
                                if (!li.is_array) { li.is_array = true; changed = true; }
                                if (!li.has_ptr_arith) { li.has_ptr_arith = true; changed = true; }
                            }
                            // `p = (byte *)view + n` carries the view's buffer
                            // plus an offset; a slice would copy the lump.
                            if ((ar.op == "+" || ar.op == "-") && is_byte_pair_expr (ar, locals)) {
                                if (!li.is_array) { li.is_array = true; changed = true; }
                                if (!li.has_ptr_arith) { li.has_ptr_arith = true; changed = true; }
                            }
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

        // planc now supports `union[]`, `struct[]`, and `delegate[]` (`Delegate?[]`).
        private void assert_supported_type (string vt) throws RefuseError {
        }

        private string vala_type (CType ct, bool as_array = false) throws RefuseError {
            if (ct.kind == CTypeKind.FUNC_PTR)
                return esc_ident (ensure_delegate (ct, ct.name)) + "?";
            if (ct.kind == CTypeKind.SCALAR)
                return (ct.name == "char") ? "uint8" : ct.name;
            if (ct.kind == CTypeKind.ENUM)
                return esc_ident (ct.name);
            if (ct.kind == CTypeKind.STRUCT || ct.kind == CTypeKind.UNION) {
                if (ct.name == "FILE" || ct.name == "_c2v_FILE")
                    return "FileStream";
                if (ct.name == "tm")
                    return "Time";
                if (ct.name == "_c2v_pthread_t")
                    return "Thread?";
                if (ct.name == "pthread_mutex_t")
                    return "RecMutex";
                if (ct.name == "pthread_cond_t")
                    return "Cond";
                if (ct.name == "pthread_mutexattr_t" || ct.name == "pthread_condattr_t" || ct.name == "pthread_attr_t")
                    return "int";
                if (find_struct (ct.name) == null)
                    ensure_opaque_struct (ct.name);
                return esc_ident (ct.name);
            }
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null) {
                if (((CType) ct.inner).is_scalar ("char"))
                    return "uint8[]";
                return vala_type ((CType) ct.inner, false) + "[]";
            }
            if (ct.kind == CTypeKind.PTR && ct.inner != null) {
                var inner = (CType) ct.inner;
                if (inner.is_scalar ("void"))
                    return "uint8[]?";
                if (as_array) {
                    if (inner.is_scalar ("char"))
                        return "uint8[]?";
                    string ia = vala_type (inner, false);
                    if (ia.has_suffix ("[]") || ia.has_suffix ("[]?"))
                        return @"$(ensure_arr_box_helper (ia.has_suffix ("?") ? ia.substring (0, ia.length - 1) : ia))?";
                    return ia + "[]?";
                }
                if (inner.is_scalar ("char"))
                    return "string";
                if (inner.kind == CTypeKind.STRUCT) {
                    if (inner.name == "FILE" || inner.name == "_c2v_FILE")
                        return "FileStream?";
                    if (inner.name == "tm")
                        return "Time";
                    if (inner.name == "_c2v_pthread_t")
                        return "Thread?";
                    if (inner.name == "pthread_mutex_t")
                        return "RecMutex?";
                    if (inner.name == "pthread_cond_t")
                        return "Cond?";
                    if (inner.name == "pthread_mutexattr_t" || inner.name == "pthread_condattr_t" || inner.name == "pthread_attr_t")
                        return "int[]?";
                    if (find_struct (inner.name) == null)
                        ensure_opaque_struct (inner.name);
                    return esc_ident (inner.name) + "?";
                }
                string ib = vala_type (inner, false);
                if (ib.has_suffix ("[]") || ib.has_suffix ("[]?"))
                    return @"$(ensure_arr_box_helper (ib.has_suffix ("?") ? ib.substring (0, ib.length - 1) : ib))?";
                return ib + "[]?";
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
                        mt_fn_code[fi] = @"// c2vala refused $(fn.name): $(e.message)\n\n";
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
            // The array fixpoint needs the byte-view map: `(byte *)view + n`
            // is carried as a buffer plus an offset, and that is only valid for
            // structs that got a byte view.
            for (int fi_b = 0; fi_b < tu.funcs.length; fi_b++) {
                var bfn = tu.funcs[fi_b];
                if (bfn.body != null)
                    scan_stmt_byte_casts ((CStmt) bfn.body);
            }
            build_sigs_and_fixpoint ();

            for (int fi_s = 0; fi_s < tu.funcs.length; fi_s++) {
                var sfn = tu.funcs[fi_s];
                if (sfn.body != null)
                    scan_stmt_byte_casts ((CStmt) sfn.body);
            }

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
            sb.append ("// Generated by c2plan.\n\n");
            if (ns_name != "")
                sb.append (@"namespace $ns_name {\n\n");
            int[] opaque_ord = sorted_order (opaque_names);
            for (int oi = 0; oi < opaque_ord.length; oi++) {
                sb.append (@"[Compact]\npublic sealed class $(esc_ident (opaque_names[opaque_ord[oi]])) {}\n");
            }
            if (opaque_names.length > 0)
                sb.append ("\n");
            sb.append (types_sb.str);
            int[] del_ord = sorted_order (del_names);
            for (int di_i = 0; di_i < del_ord.length; di_i++) {
                int di = del_ord[di_i];
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
            int[] slice_ord = sorted_order (slice_names);
            for (int si2_i = 0; si2_i < slice_ord.length; si2_i++) {
                int si2 = slice_ord[si2_i];
                string sfn = slice_names[si2];
                string svt = slice_vtypes[si2];
                // An array element type makes `$svt[]` a 2-dimensional array,
                // whose `.length` needs the outermost dimension.
                string alen = svt.has_suffix ("[]") ? "arr.length[0]" : "arr.length";
                sb.append (@"private static $svt[]? $sfn ($svt[]? arr, int off) {\n");
                sb.append ("    if (arr == null) return null;\n");
                sb.append ("    if (off <= 0) return arr;\n");
                sb.append ("    if (off >= " + alen + ") return null;\n");
                sb.append ("    int n = " + alen + " - off;\n");
                sb.append (@"    $svt[] res = new $svt[n];\n");
                sb.append ("    for (int i = 0; i < n; i++) res[i] = arr[off + i];\n");
                sb.append ("    return res;\n");
                sb.append ("}\n\n");
            }
            int[] copy_ord = sorted_order (copy_arr_names);
            for (int cai_i = 0; cai_i < copy_ord.length; cai_i++) {
                int cai = copy_ord[cai_i];
                string cfn = copy_arr_names[cai];
                string cvt = copy_arr_vtypes[cai];
                string dlen = cvt.has_suffix ("[]") ? "dst.length[0]" : "dst.length";
                string slen = cvt.has_suffix ("[]") ? "src.length[0]" : "src.length";
                sb.append (@"private static void $cfn ($cvt[] dst, int doff, $cvt[] src, int soff, int n) {\n");
                sb.append ("    for (int i = 0; i < n; i++) {\n");
                sb.append ("        if (doff + i < " + dlen + " && soff + i < " + slen + ")\n");
                sb.append ("            dst[doff + i] = src[soff + i];\n");
                sb.append ("    }\n");
                sb.append ("}\n\n");
            }
            int[] fref_ord = sorted_order (fref_names);
            for (int fri_i = 0; fri_i < fref_ord.length; fri_i++) {
                int fri = fref_ord[fri_i];
                string fcls = fref_names[fri];
                string fvt = fref_vtypes[fri];
                string gdel = @"_c2v_fget_$fcls";
                string sdel = @"_c2v_fset_$fcls";
                sb.append (@"public delegate $fvt $gdel ();\n");
                sb.append (@"public delegate void $sdel ($fvt v);\n");
                sb.append (@"public sealed class $fcls : Object {\n");
                sb.append (@"    public $gdel get_val;\n");
                sb.append (@"    public $sdel set_val;\n");
                sb.append (@"    public $fcls ($gdel g, $sdel s) { get_val = g; set_val = s; }\n");
                sb.append (@"    public $fcls.at_idx ($fvt[] arr, int idx) {\n");
                sb.append ("        get_val = () => { return arr[idx]; };\n");
                sb.append ("        set_val = (v) => { arr[idx] = v; };\n");
                sb.append ("    }\n");
                sb.append ("}\n\n");
            }
            int[] fref_step_ord = sorted_order (fref_step_names);
            for (int fsi_i = 0; fsi_i < fref_step_ord.length; fsi_i++) {
                int fsi = fref_step_ord[fsi_i];
                string sfn = fref_step_names[fsi];
                string fcls = fref_step_fref[fsi];
                string fvt = fref_step_vtypes[fsi];
                string fld = fref_step_fields[fsi];
                sb.append (@"private static $fcls $sfn ($fcls? r) {\n");
                sb.append (@"    $fvt _c = (r != null) ? ((!) r).get_val () : null;\n");
                sb.append (@"    return new $fcls (() => { return _c.$fld; }, (v) => { _c.$fld = v; });\n");
                sb.append ("}\n\n");
            }
            int[] op_assign_ord = sorted_order (op_assign_names);
            for (int oi2_i = 0; oi2_i < op_assign_ord.length; oi2_i++) {
                int oi2 = op_assign_ord[oi2_i];
                string ovt = op_assign_vtypes[oi2];
                sb.append (@"private static $ovt $(op_assign_names[oi2]) ($ovt v, ref $ovt t) {\n");
                sb.append (@"    t $(op_assign_ops[oi2])= v;\n");
                sb.append ("    return t;\n");
                sb.append ("}\n\n");
            }
            int[] box_ord = sorted_order (box_names);
            for (int bi_i = 0; bi_i < box_ord.length; bi_i++) {
                int bi = box_ord[bi_i];
                string bvt = box_types[bi];
                if (bvt == "Time" || bvt == "RecMutex" || bvt == "Cond") {
                    sb.append (@"private static $bvt[] $(box_names[bi])_arr ($bvt v) {\n");
                    sb.append (@"    $bvt[] r = new $bvt[1];\n");
                    sb.append ("    r[0] = v;\n");
                    sb.append ("    return r;\n");
                    sb.append ("}\n\n");
                    sb.append (@"private static $bvt $(box_names[bi])_obj ($bvt[] a) {\n");
                    sb.append (@"    if (a.length == 0) return $bvt ();\n");
                    sb.append ("    return a[0];\n");
                    sb.append ("}\n\n");
                } else {
                    sb.append (@"private static $bvt[]? $(box_names[bi])_arr ($bvt? v) {\n");
                    sb.append ("    if (v == null) return null;\n");
                    sb.append (@"    $bvt[] r = new $bvt[1];\n");
                    sb.append ("    r[0] = v;\n");
                    sb.append ("    return r;\n");
                    sb.append ("}\n\n");
                    sb.append (@"private static $bvt? $(box_names[bi])_obj ($bvt[]? a) {\n");
                    sb.append ("    if (a == null || a.length == 0) return null;\n");
                    sb.append ("    return a[0];\n");
                    sb.append ("}\n\n");
                }
            }
            emit_lit_helpers (sb);
            int[] idx_set_ord = sorted_order (idx_set_names);
            for (int xi_i = 0; xi_i < idx_set_ord.length; xi_i++) {
                int xi = idx_set_ord[xi_i];
                string xvt = idx_set_vtypes[xi];
                sb.append (@"private static $xvt $(idx_set_names[xi]) ($xvt[] arr, int idx, $xvt v) {\n");
                sb.append ("    arr[idx] = v;\n");
                sb.append ("    return v;\n");
                sb.append ("}\n\n");
            }
            int[] assign_arr_ord = sorted_order (assign_arr_names);
            for (int ai_i = 0; ai_i < assign_arr_ord.length; ai_i++) {
                int ai = assign_arr_ord[ai_i];
                string avt = assign_arr_vtypes[ai];
                sb.append (@"private static $avt $(assign_arr_names[ai]) ($avt v, ref $avt t) {\n");
                sb.append ("    t = v;\n");
                sb.append ("    return v;\n");
                sb.append ("}\n\n");
            }
            int[] arr_box_ord = sorted_order (arr_box_names);
            for (int abi_i = 0; abi_i < arr_box_ord.length; abi_i++) {
                int abi = arr_box_ord[abi_i];
                string abcls = arr_box_names[abi];
                string abvt = arr_box_vtypes[abi];
                sb.append (@"public sealed class $abcls : Object {\n");
                sb.append (@"    public $abvt val;\n");
                sb.append (@"    public $abcls ($abvt v) { val = v; }\n");
                sb.append ("}\n\n");
            }
            sb.append (body_sb.str);
            if (ns_name != "")
                sb.append ("}\n");
            return plan_mode ? strip_plan_semis (sb.str) : sb.str;
        }

        private static string strip_plan_semis (string src) {
            var out_sb = new StrBuilder ();
            int pos = 0;
            int slen = src.length;
            while (pos < slen) {
                int nl = src.index_of ("\n", pos);
                int end = (nl >= 0) ? nl : slen;
                string line = src.substring (pos, end - pos);
                int ls = 0;
                while (ls < line.length && (line[ls] == ' ' || line[ls] == '\t'))
                    ls++;
                int le = line.length;
                while (le > ls && (line[le - 1] == ' ' || line[le - 1] == '\t' || line[le - 1] == '\r'))
                    le--;
                string trimmed = (le > ls) ? line.substring (ls, le - ls) : "";
                if (trimmed.length > 1 && trimmed.has_suffix (";")
                    && !trimmed.has_prefix ("//")
                    && !trimmed.has_prefix ("/*")
                    && !trimmed.has_prefix ("*")
                    && !trimmed.has_prefix ("for (")
                    && !trimmed.has_prefix ("for(")
                    && !trimmed.has_prefix ("while (")
                    && !trimmed.has_prefix ("while(")
                    && !trimmed.has_prefix ("if (")
                    && !trimmed.has_prefix ("if(")
                    && !trimmed.has_prefix ("else")) {
                    line = line.substring (0, le - 1);
                }
                out_sb.append (line);
                if (nl >= 0)
                    out_sb.append ("\n");
                pos = (nl >= 0) ? nl + 1 : slen;
            }
            return out_sb.str;
        }

        private static void emit_ignored_attrs (StrBuilder sb, GenericArray<string> attrs, int level = 0) {
            for (int i = 0; i < attrs.length; i++) {
                indent (sb, level);
                sb.append (@"// c2vala ignored: $(attrs[i])\n");
            }
        }

        private GenericArray<GlobalVarDef> runtime_globals = new GenericArray<GlobalVarDef> ();
        private GenericArray<GlobalVarDef> hoisted_statics = new GenericArray<GlobalVarDef> ();
        private int static_seq = 0;

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
                // A global struct needs an instance: planc has no implicit
                // default value for a class-typed global.
                if (g.ctype.kind == CTypeKind.STRUCT || g.ctype.kind == CTypeKind.UNION) {
                    sb.append (@"public $vt $gname;\n");
                    runtime_globals.add (g);
                    return;
                }
                sb.append (@"public $vt $gname;\n");
                if (g.ctype.kind == CTypeKind.ARRAY && g.ctype.array_len != null)
                    runtime_globals.add (g);
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
                string sv = emit_expr ((CExpr) g.init);
                sb.append (@"public const string $gname = $sv;\n");
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
            for (int hi = 0; hi < hoisted_statics.length; hi++) {
                var hg = hoisted_statics[hi];
                string hvt = vala_type (hg.ctype, true);
                sb.append (@"public $hvt $(hg.name);\n");
                runtime_globals.add (hg);
            }
            if (hoisted_statics.length > 0)
                sb.append ("\n");
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

        private static bool is_zero_init_list (ExprInitList il) {
            if (il.items.length != 1)
                return false;
            if (il.index_exprs.length > 0 && il.index_exprs[0] != null)
                return false;
            var it = il.items[0];
            if (it is ExprInt && ((ExprInt) it).val == 0)
                return true;
            if (it is ExprChar && ((ExprChar) it).val == 0)
                return true;
            return false;
        }

        private static bool can_emit_inline_array_init (CType elem_ct, ExprInitList il, CExpr? array_len) {
            if (il.items.length == 0)
                return false;
            if (elem_ct.kind != CTypeKind.SCALAR && elem_ct.kind != CTypeKind.ENUM)
                return false;
            if (array_len != null) {
                if (!(array_len is ExprInt) || ((ExprInt) array_len).val != il.items.length)
                    return false;
            }
            for (int i = 0; i < il.items.length; i++) {
                if (i < il.index_exprs.length && il.index_exprs[i] != null)
                    return false;
                if (il.items[i] is ExprInitList)
                    return false;
            }
            return true;
        }

        private void emit_inline_array_lit (StrBuilder sb, CType elem_ct, string elem_t, ExprInitList il, int level) throws RefuseError {
            string etgt = elem_t;
            sb.append (@"new $elem_t[] { ");
            for (int ii = 0; ii < il.items.length; ii++) {
                if (ii > 0) {
                    if ((ii % 16) == 0) {
                        sb.append (",\n");
                        indent (sb, level + 1);
                    } else {
                        sb.append (", ");
                    }
                }
                sb.append (coerce_value (il.items[ii], etgt));
            }
            sb.append (" }");
        }

        private void emit_array_init_elems (StrBuilder sb, string lhs, CType elem_ct, string elem_t, ExprInitList il, int level) throws RefuseError {
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
                if (elem_ct.kind == CTypeKind.ARRAY && elem_ct.inner != null && il.items[ii] is ExprInitList) {
                    var sub_il = (ExprInitList) il.items[ii];
                    var sub_elem = (CType) elem_ct.inner;
                    string sub_et = vala_type (sub_elem, false);
                    if (can_emit_inline_array_init (sub_elem, sub_il, elem_ct.array_len)) {
                        indent (sb, level);
                        sb.append (@"$lhs[$idx_s] = ");
                        emit_inline_array_lit (sb, sub_elem, sub_et, sub_il, level);
                        sb.append (";\n");
                    } else {
                        string sub_len = (elem_ct.array_len != null)
                            ? emit_expr ((CExpr) elem_ct.array_len)
                            : @"$(sub_il.items.length)";
                        indent (sb, level);
                        sb.append (@"$lhs[$idx_s] = new $sub_et[$sub_len];\n");
                        if (sub_elem.kind == CTypeKind.STRUCT || sub_elem.kind == CTypeKind.UNION) {
                            indent (sb, level);
                            sb.append (@"for (int _c2v_j = 0; _c2v_j < $sub_len; _c2v_j++) { $lhs[$idx_s][_c2v_j] = new $sub_et (); }\n");
                        }
                        if (!is_zero_init_list (sub_il) || sub_elem.kind == CTypeKind.STRUCT || sub_elem.kind == CTypeKind.UNION)
                            emit_array_init_elems (sb, @"$lhs[$idx_s]", sub_elem, sub_et, sub_il, level);
                    }
                } else if (elem_ct.kind == CTypeKind.STRUCT && il.items[ii] is ExprInitList) {
                    var sd = find_struct (elem_ct.name);
                    if (sd != null)
                        emit_struct_init_assigns (sb, @"$lhs[$idx_s]", (StructDef) sd, (ExprInitList) il.items[ii], level);
                } else if (elem_t == "string" && is_null_ptr_expr (il.items[ii])) {
                    // Not stored: the slot is left as `new T[n]` made it, and a
                    // C NULL terminator carries no data.
                } else {
                    indent (sb, level);
                    sb.append (@"$lhs[$idx_s] = $(coerce_value (il.items[ii], etgt));\n");
                }
            }
        }

        private void emit_global_init (StrBuilder sb, GlobalVarDef g) throws RefuseError {
            string gname = esc_ident (g.name);
            if (g.init == null) {
                if (g.ctype.kind == CTypeKind.STRUCT || g.ctype.kind == CTypeKind.UNION) {
                    var gsd0 = find_struct (g.ctype.name);
                    bool u0 = (gsd0 != null) && gsd0.is_union && !union_needs_class ((StructDef) gsd0);
                    sb.append (u0
                        ? @"    $gname = $(esc_ident (g.ctype.name)) ();\n"
                        : @"    $gname = new $(esc_ident (g.ctype.name)) ();\n");
                    return;
                }
                if (g.ctype.kind == CTypeKind.ARRAY && g.ctype.inner != null && g.ctype.array_len != null) {
                    int d_uniq = alloc_uniq;
                    emit_array_alloc_stmts (sb, gname, g.ctype, 1, ref d_uniq);
                    alloc_uniq = d_uniq;
                }
                return;
            }
            CExpr init = (CExpr) g.init;

            if (g.ctype.kind == CTypeKind.STRUCT || g.ctype.kind == CTypeKind.UNION) {
                if (g.ctype.kind == CTypeKind.STRUCT && (g.ctype.name == "pthread_mutex_t" || g.ctype.name == "pthread_cond_t")) {
                    sb.append (@"    $gname = new $(vala_type (g.ctype, false)) ();\n");
                    return;
                }
                var gsd = find_struct (g.ctype.name);
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
                    if (can_emit_inline_array_init (elem_ct, il, g.ctype.array_len)) {
                        sb.append (@"    $gname = ");
                        emit_inline_array_lit (sb, elem_ct, elem_t, il, 1);
                        sb.append (";\n");
                    } else {
                        string len_s = (g.ctype.array_len != null)
                            ? emit_expr ((CExpr) g.ctype.array_len)
                            : @"$(init_list_len (elem_t, il))";
                        if (g.ctype.array_len != null) {
                            var galt2 = infer_type ((CExpr) g.ctype.array_len);
                            if (galt2 != null && galt2.kind == CTypeKind.ENUM)
                                len_s = @"(int) ($len_s)";
                        }
                        if (elem_ct.kind == CTypeKind.ARRAY) {
                            // Multi-dimensional: allocate every level, not just
                            // the outer one, or the rows stay null.
                            int il_uniq = alloc_uniq;
                            emit_array_alloc_stmts (sb, gname, g.ctype, 1, ref il_uniq);
                            alloc_uniq = il_uniq;
                        } else {
                            sb.append (@"    $gname = new $elem_t[$len_s];\n");
                            if (elem_ct.kind == CTypeKind.STRUCT || elem_ct.kind == CTypeKind.UNION)
                                sb.append (@"    for (int _c2v_i = 0; _c2v_i < $gname.length; _c2v_i++) { $gname[_c2v_i] = new $elem_t (); }\n");
                        }
                        if (!is_zero_init_list (il) || elem_ct.kind == CTypeKind.STRUCT || elem_ct.kind == CTypeKind.UNION)
                            emit_array_init_elems (sb, gname, elem_ct, elem_t, il, 1);
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
        private void scan_stmt_byte_casts (CStmt s) {
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    scan_stmt_byte_casts (b.stmts[i]);
            } else if (s is StmtIf) {
                var is_ = (StmtIf) s;
                scan_expr_byte_casts (is_.cond);
                scan_stmt_byte_casts (is_.then_branch);
                if (is_.else_branch != null)
                    scan_stmt_byte_casts ((CStmt) is_.else_branch);
            } else if (s is StmtWhile) {
                var ws = (StmtWhile) s;
                scan_expr_byte_casts (ws.cond);
                scan_stmt_byte_casts (ws.body);
            } else if (s is StmtFor) {
                var fs = (StmtFor) s;
                if (fs.init_decl != null && ((StmtDecl) fs.init_decl).init != null)
                    scan_expr_byte_casts ((CExpr) ((StmtDecl) fs.init_decl).init);
                if (fs.init_expr != null)
                    scan_expr_byte_casts ((CExpr) fs.init_expr);
                if (fs.cond != null)
                    scan_expr_byte_casts ((CExpr) fs.cond);
                if (fs.next != null)
                    scan_expr_byte_casts ((CExpr) fs.next);
                scan_stmt_byte_casts (fs.body);
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                if (sw.cond != null)
                    scan_expr_byte_casts ((CExpr) sw.cond);
                for (int i = 0; i < sw.cases.length; i++) {
                    for (int j = 0; j < sw.cases[i].stmts.length; j++)
                        scan_stmt_byte_casts (sw.cases[i].stmts[j]);
                }
            } else if (s is StmtReturn) {
                var rs = (StmtReturn) s;
                if (rs.expr != null)
                    scan_expr_byte_casts ((CExpr) rs.expr);
            } else if (s is StmtExpr) {
                scan_expr_byte_casts (((StmtExpr) s).expr);
            } else if (s is StmtDecl) {
                var ds = (StmtDecl) s;
                if (ds.init != null)
                    scan_expr_byte_casts ((CExpr) ds.init);
            } else if (s is StmtLabel) {
                scan_stmt_byte_casts (((StmtLabel) s).stmt);
            }
        }

        private void scan_expr_byte_casts (CExpr? e) {
            if (e == null)
                return;
            if (e is ExprCast) {
                var c = (ExprCast) e;
                if (c.target_type.kind == CTypeKind.PTR && c.target_type.inner != null
                    && !is_scalar_ptr_type (c.target_type)
                    && !is_null_ptr_expr (c.expr)) {
                    var inner = (CType) c.target_type.inner;
                    if (inner.kind == CTypeKind.STRUCT || inner.kind == CTypeKind.UNION)
                        byte_cast_struct_map.set_index (inner.name, 1);
                }
                scan_expr_byte_casts (c.expr);
            } else if (e is ExprUnary) {
                scan_expr_byte_casts (((ExprUnary) e).operand);
            } else if (e is ExprBinary) {
                var b = (ExprBinary) e;
                scan_expr_byte_casts (b.left);
                scan_expr_byte_casts (b.right);
            } else if (e is ExprAssign) {
                var a = (ExprAssign) e;
                scan_expr_byte_casts (a.lvalue);
                scan_expr_byte_casts (a.rvalue);
            } else if (e is ExprTernary) {
                var t = (ExprTernary) e;
                scan_expr_byte_casts (t.cond);
                scan_expr_byte_casts (t.if_true);
                scan_expr_byte_casts (t.if_false);
            } else if (e is ExprCall) {
                var cal = (ExprCall) e;
                if (cal.callee is ExprIdent && ((ExprIdent) cal.callee).name == "memcpy"
                    && cal.args.length == 3 && cal.args[0] is ExprUnary && ((ExprUnary) cal.args[0]).op == "&") {
                    try {
                        var dt = infer_type (((ExprUnary) cal.args[0]).operand);
                        if (dt != null && (dt.kind == CTypeKind.STRUCT || dt.kind == CTypeKind.UNION))
                            byte_cast_struct_map.set_index (dt.name, 1);
                    } catch (RefuseError err) {}
                }
                scan_expr_byte_casts (cal.callee);
                for (int i = 0; i < cal.args.length; i++)
                    scan_expr_byte_casts (cal.args[i]);
            } else if (e is ExprMember) {
                scan_expr_byte_casts (((ExprMember) e).obj);
            } else if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                scan_expr_byte_casts (ix.array);
                scan_expr_byte_casts (ix.index);
            } else if (e is ExprInitList) {
                var il = (ExprInitList) e;
                for (int i = 0; i < il.items.length; i++)
                    scan_expr_byte_casts (il.items[i]);
            }
        }

        private bool union_needs_class (StructDef sd) {
            return sd.is_union;
        }

        private static int union_scalar_bytes (string vt) {
            if (vt == "bool" || vt == "int8" || vt == "uint8" || vt == "uchar" || vt == "char")
                return 1;
            if (vt == "int16" || vt == "uint16")
                return 2;
            if (vt == "int32" || vt == "uint32" || vt == "int" || vt == "uint" || vt == "float")
                return 4;
            if (vt == "int64" || vt == "uint64" || vt == "size_t" || vt == "ssize_t" || vt == "double")
                return 8;
            return 0;
        }

        // Fixed-size scalar array fields of a byte-view struct (e.g. patch_t's
        // `int columnofs[8]`) must read from the backing bytes: a plain
        // `int[]` field is null for `.at` views and C code indexes it.
        private void emit_byte_view_array (StrBuilder sb, StructField f, string fn, string vt, ref int foff, bool is_last) {
            string elem = vt.has_suffix ("[]") ? vt.substring (0, vt.length - 2) : "uint8";
            int alen = (f.ctype.array_len is ExprInt) ? (int) ((ExprInt) f.ctype.array_len).val : 0;
            int eb = (f.ctype.inner != null) ? (int) type_size_bytes ((CType) f.ctype.inner) : 1;
            if (eb < 1)
                eb = 1;
            foff = (foff + eb - 1) & ~(eb - 1);
            string off_s = @"_off + $(foff)";
            string rd;
            string wr;
            if (elem == "float") {
                rd = @"c_u32_to_f32 (c_u_get_u32_at ((!) _c2v_data, $off_s + _i * 4))";
                wr = @"c_u_set_u32_at ((!) _c2v_data, $off_s + _i * 4, c_f32_to_u32 (value[_i]))";
            } else if (elem == "double") {
                rd = @"c_u64_to_f64 (c_u_get_u64_at ((!) _c2v_data, $off_s + _i * 8))";
                wr = @"c_u_set_u64_at ((!) _c2v_data, $off_s + _i * 8, c_f64_to_u64 (value[_i]))";
            } else if (eb == 1) {
                rd = @"(($elem) c_u_get_u8_at ((!) _c2v_data, $off_s + _i))";
                wr = @"c_u_set_u8_at ((!) _c2v_data, $off_s + _i, (uint8) value[_i])";
            } else if (eb == 2) {
                rd = @"(($elem) c_u_get_u16_at ((!) _c2v_data, $off_s + _i * 2))";
                wr = @"c_u_set_u16_at ((!) _c2v_data, $off_s + _i * 2, (uint16) value[_i])";
            } else if (eb == 4) {
                rd = @"(($elem) c_u_get_u32_at ((!) _c2v_data, $off_s + _i * 4))";
                wr = @"c_u_set_u32_at ((!) _c2v_data, $off_s + _i * 4, (uint32) value[_i])";
            } else {
                rd = @"(($elem) c_u_get_u64_at ((!) _c2v_data, $off_s + _i * 8))";
                wr = @"c_u_set_u64_at ((!) _c2v_data, $off_s + _i * 8, (uint64) value[_i])";
            }
            sb.append (@"    private $vt _$fn = new $elem[$(alen)];\n");
            sb.append (@"    public $vt $fn {\n");
            // The getter builds the array from the buffer, so it hands over
            // ownership (valac rejects a plain `get` that returns a local).
            sb.append ("        owned get {\n");
            sb.append (@"            if (_c2v_data == null) return _$fn;\n");
            // A trailing array in a C struct is a flexible member: the byte
            // buffer, not the declared length, bounds it (e.g. patch_t's
            // columnofs[8] holds `width` entries).
            string count_s;
            if (is_last) {
                sb.append (@"            int _n = (((!) _c2v_data).length - ($off_s)) / $eb;\n");
                sb.append ("            if (_n < 0) _n = 0;\n");
                count_s = "_n";
            } else {
                count_s = @"$(alen)";
            }
            sb.append (@"            $elem[] _r = new $elem[$count_s];\n");
            sb.append (@"            for (int _i = 0; _i < $count_s; _i++)\n");
            sb.append (@"                _r[_i] = $rd;\n");
            sb.append ("            return _r;\n");
            sb.append ("        }\n");
            sb.append ("        set {\n");
            sb.append (@"            if (_c2v_data == null) { _$fn = value; return; }\n");
            if (is_last)
                sb.append (@"            int _n = (((!) _c2v_data).length - ($off_s)) / $eb;\n");
            sb.append (@"            for (int _i = 0; _i < $count_s && _i < value.length; _i++)\n");
            sb.append (@"                $wr;\n");
            sb.append ("        }\n");
            sb.append ("    }\n");
            // Single-element accessors: `p->field[i]` must read the buffer
            // directly, because the property above materialises every element
            // that is left in the buffer (a flexible member like patch_t's
            // columnofs would copy the whole lump on each access).
            string wr_v = replace_all (wr, "value[_i]", "_v");
            sb.append (@"    public $elem $(fn)_at (int _i) {\n");
            sb.append (@"        if (_c2v_data == null) return _$fn[_i];\n");
            sb.append (@"        return $rd;\n");
            sb.append ("    }\n");
            sb.append (@"    public void $(fn)_set (int _i, $elem _v) {\n");
            sb.append (@"        if (_c2v_data == null) { _$fn[_i] = _v; return; }\n");
            sb.append (@"        $wr_v;\n");
            sb.append ("    }\n");
            foff += alen * eb;
        }

        // Length to allocate for an unsized array initializer. A trailing NULL
        // terminator (`{ "a", "b", 0 }`) is not stored: planc's string arrays
        // hold no nulls, so the slot is dropped and `.length` stays meaningful.
        private static int init_list_len (string elem_t, ExprInitList il) {
            int n = il.items.length;
            if (elem_t == "string") {
                while (n > 0 && is_null_ptr_expr (il.items[n - 1]))
                    n--;
            }
            return n;
        }

        // Length expression of a C array type, cast when it names an enum.
        private string array_len_expr (CType arr_ct) throws RefuseError {
            if (arr_ct.array_len is ExprInt)
                return ((ExprInt) arr_ct.array_len).val.to_string ();
            string s = emit_expr ((CExpr) arr_ct.array_len);
            var t = infer_type ((CExpr) arr_ct.array_len);
            if (t != null && t.kind == CTypeKind.ENUM)
                s = @"(int) ($s)";
            return s;
        }

        // C array storage is inline; the Vala model is a reference, so every
        // array has to be allocated level by level (rows of a 2-D array, one
        // object per struct element). Scalar levels need nothing else: `new T[n]`
        // hands out zeroed slots (and `""` for non-nullable string elements).
        private void emit_array_alloc_stmts (StrBuilder body, string target, CType arr_ct,
                                             int indent, ref int uniq) throws RefuseError {
            if (arr_ct.inner == null || arr_ct.array_len == null)
                return;
            var elem_ct = (CType) arr_ct.inner;
            // Derive the element type from the array's own Vala type: a char
            // array is a byte array (`uint8[]`) even though the scalar leaf is
            // `char`, so recomputing it from the element yields a type mismatch.
            string arr_vt = vala_type (arr_ct, false);
            if (!arr_vt.has_suffix ("[]"))
                return;
            string elem_t = arr_vt.substring (0, arr_vt.length - 2);
            string len_s = array_len_expr (arr_ct);
            string pad = "";
            for (int k = 0; k < indent; k++)
                pad += "    ";
            body.append (@"$pad$target = new $elem_t[$len_s];\n");
            string iv = @"_c2v_ai$(uniq)";
            uniq++;
            // A 2-D target must spell out which dimension it means; dim 0 is the
            // outer (row) count, which is what the per-row allocation loops over.
            string elem_core = elem_t.has_suffix ("?")
                ? elem_t.substring (0, elem_t.length - 1) : elem_t;
            string lenc = (elem_core.has_suffix ("[]") && !elem_core.has_suffix ("[][]"))
                ? ".length[0]" : ".length";
            if (elem_ct.kind == CTypeKind.ARRAY) {
                body.append (@"$pad" + @"for (int $iv = 0; $iv < $target$lenc; $iv++) {" + "\n");
                emit_array_alloc_stmts (body, @"$target[$iv]", elem_ct, indent + 1, ref uniq);
                body.append (@"$pad}" + "\n");
            } else if (elem_ct.kind == CTypeKind.STRUCT || elem_ct.kind == CTypeKind.UNION) {
                body.append (@"$pad" + @"for (int $iv = 0; $iv < $target$lenc; $iv++) { $target[$iv] = new $elem_t (); }" + "\n");
            }
        }

        private void emit_struct (StrBuilder sb, StructDef sd) throws RefuseError {
            if (sd.name == "_c2v_FILE" || sd.name == "FILE" || sd.name == "tm"
                || sd.name == "_c2v_pthread_t" || sd.name == "pthread_mutex_t"
                || sd.name == "pthread_cond_t" || sd.name == "pthread_mutexattr_t"
                || sd.name == "pthread_condattr_t" || sd.name == "pthread_attr_t")
                return;
            emit_ignored_attrs (sb, sd.ignored_attrs);
            string sname = esc_ident (sd.name);
            sb.append (@"public sealed class $sname : Object {\n");

            if (sd.is_union) {
                int ubytes = 8;
                for (int i = 0; i < sd.fields.length; i++) {
                    var f = sd.fields[i];
                    if (f.name == "")
                        continue;
                    if (f.ctype.kind == CTypeKind.ARRAY && f.ctype.array_len is ExprInt) {
                        int elem_b = 1;
                        if (f.ctype.inner != null) {
                            string ev = vala_type ((CType) f.ctype.inner, false);
                            int sb_e = union_scalar_bytes (ev);
                            if (sb_e > 0) elem_b = sb_e;
                        }
                        int arr_b = ((int) ((ExprInt) f.ctype.array_len).val) * elem_b;
                        if (arr_b > ubytes) ubytes = arr_b;
                    } else {
                        string vt = vala_type (f.ctype, false);
                        int nb = union_scalar_bytes (vt);
                        if (nb > ubytes) ubytes = nb;
                    }
                }
                sb.append (@"    public uint8[] data = new uint8[$ubytes];\n");
                var arc_fields = new GenericArray<string> ();
                for (int i = 0; i < sd.fields.length; i++) {
                    var f = sd.fields[i];
                    if (f.name == "")
                        continue;
                    string vt = vala_type (f.ctype, false);
                    string fn = (sd.name == "tm") ? map_tm_field (f.name) : esc_ident (f.name);
                    int nb = union_scalar_bytes (vt);
                    if (f.ctype.kind == CTypeKind.ARRAY && vt == "uint8[]") {
                        sb.append (@"    public uint8[] $fn {\n");
                        sb.append ("        get { return data; }\n");
                        sb.append ("    }\n");
                    } else if (f.ctype.kind == CTypeKind.ENUM) {
                        sb.append (@"    public $vt $fn {\n");
                        sb.append (@"        get { return ($vt) ((int) ((int32) c_u_get_u32 (data))); }\n");
                        sb.append ("        set { c_u_set_u32 (data, (uint32) ((int32) value)); }\n");
                        sb.append ("    }\n");
                    } else if (nb > 0) {
                        sb.append (@"    public $vt $fn {\n");
                        if (vt == "float") {
                            sb.append ("        get { return c_u32_to_f32 (c_u_get_u32 (data)); }\n");
                            sb.append ("        set { c_u_set_u32 (data, c_f32_to_u32 (value)); }\n");
                        } else if (vt == "double") {
                            sb.append ("        get { return c_u64_to_f64 (c_u_get_u64_le (data)); }\n");
                            sb.append ("        set { c_u_set_u64_le (data, c_f64_to_u64 (value)); }\n");
                        } else if (vt == "bool") {
                            sb.append ("        get { return data[0] != 0; }\n");
                            sb.append ("        set { data[0] = value ? ((uint8) 1) : ((uint8) 0); }\n");
                        } else if (nb == 1) {
                            sb.append (@"        get { return ($vt) data[0]; }\n");
                            sb.append ("        set { data[0] = (uint8) value; }\n");
                        } else if (nb == 2) {
                            sb.append (@"        get { return ($vt) c_u_get_u16 (data); }\n");
                            sb.append ("        set { c_u_set_u16 (data, (uint16) value); }\n");
                        } else if (nb == 4) {
                            sb.append (@"        get { return ($vt) c_u_get_u32 (data); }\n");
                            sb.append ("        set { c_u_set_u32 (data, (uint32) value); }\n");
                        } else {
                            sb.append (@"        get { return ($vt) c_u_get_u64_le (data); }\n");
                            sb.append ("        set { c_u_set_u64_le (data, (uint64) value); }\n");
                        }
                        sb.append ("    }\n");
                    } else {
                        sb.append (@"    public $vt $fn;\n");
                        arc_fields.add (fn);
                    }
                }
                sb.append (@"    public $sname () {}\n");
                sb.append (@"    public $sname.at (uint8[] buf, int off = 0) {\n");
                sb.append ("        data = (off <= 0) ? buf : c_bytes_add (buf, off);\n");
                sb.append ("    }\n");
                sb.append (@"    public $sname copy_from ($sname src) {\n");
                sb.append ("        c_u_copy (data, src.data);\n");
                for (int i = 0; i < arc_fields.length; i++)
                    sb.append (@"        this.$(arc_fields[i]) = src.$(arc_fields[i]);\n");
                sb.append ("        return this;\n");
                sb.append ("    }\n");
                sb.append ("}\n");
                return;
            }

            bool has_bf = false;
            for (int i = 0; i < sd.fields.length; i++) {
                if (sd.fields[i].bit_width >= 0) {
                    has_bf = true;
                    break;
                }
            }

            if (!has_bf) {
                bool need_byte_view = (byte_cast_struct_map.get_index (sd.name) >= 0) && sd.fields.length > 0;
                if (need_byte_view) {
                    sb.append ("    public uint8[]? _c2v_data = null;\n");
                    sb.append ("    public int _off = 0;\n");
                    sb.append (@"    public $sname.at (uint8[] buf, int off = 0) {\n");
                    sb.append ("        _c2v_data = buf;\n");
                    sb.append ("        _off = off;\n");
                    sb.append ("    }\n");
                }
                int foff = 0;
                for (int i = 0; i < sd.fields.length; i++) {
                    var f = sd.fields[i];
                    if (f.name == "")
                        continue;
                    string vt = vala_type (f.ctype, false);
                    string fn = (sd.name == "tm") ? map_tm_field (f.name) : esc_ident (f.name);
                    int nb = union_scalar_bytes (vt);
                    if (need_byte_view && f.ctype.kind == CTypeKind.ENUM) {
                        foff = (foff + 3) & ~3;
                        sb.append (@"    private $vt _$fn;\n");
                        sb.append (@"    public $vt $fn {\n");
                        sb.append (@"        get { return (_c2v_data != null) ? (($vt) ((int) ((int32) c_u_get_u32_at ((!) _c2v_data, _off + $foff)))) : _$fn; }\n");
                        sb.append (@"        set { if (_c2v_data != null) c_u_set_u32_at ((!) _c2v_data, _off + $foff, (uint32) ((int32) value)); else _$fn = value; }\n");
                        sb.append ("    }\n");
                        foff += 4;
                    } else if (need_byte_view && nb > 0) {
                        int align = (nb >= 8) ? 8 : nb;
                        foff = (foff + align - 1) & ~(align - 1);
                        sb.append (@"    private $vt _$fn;\n");
                        sb.append (@"    public $vt $fn {\n");
                        if (vt == "float") {
                            sb.append (@"        get { return (_c2v_data != null) ? c_u32_to_f32 (c_u_get_u32_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u32_at ((!) _c2v_data, _off + $foff, c_f32_to_u32 (value)); else _$fn = value; }\n");
                        } else if (vt == "double") {
                            sb.append (@"        get { return (_c2v_data != null) ? c_u64_to_f64 (c_u_get_u64_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u64_at ((!) _c2v_data, _off + $foff, c_f64_to_u64 (value)); else _$fn = value; }\n");
                        } else if (vt == "bool") {
                            sb.append (@"        get { return (_c2v_data != null) ? (c_u_get_u8_at ((!) _c2v_data, _off + $foff) != 0) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u8_at ((!) _c2v_data, _off + $foff, value ? ((uint8) 1) : ((uint8) 0)); else _$fn = value; }\n");
                        } else if (nb == 1) {
                            sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u8_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u8_at ((!) _c2v_data, _off + $foff, (uint8) value); else _$fn = value; }\n");
                        } else if (nb == 2) {
                            sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u16_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u16_at ((!) _c2v_data, _off + $foff, (uint16) value); else _$fn = value; }\n");
                        } else if (nb == 4) {
                            sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u32_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u32_at ((!) _c2v_data, _off + $foff, (uint32) value); else _$fn = value; }\n");
                        } else {
                            sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u64_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u64_at ((!) _c2v_data, _off + $foff, (uint64) value); else _$fn = value; }\n");
                        }
                        sb.append ("    }\n");
                        foff += nb;
                    } else if (need_byte_view && f.ctype.kind == CTypeKind.ARRAY
                               && f.ctype.array_len is ExprInt && f.ctype.inner != null
                               && (f.ctype.inner.kind == CTypeKind.SCALAR || f.ctype.inner.kind == CTypeKind.ENUM)) {
                        emit_byte_view_array (sb, f, fn, vt, ref foff, i == sd.fields.length - 1);
                    } else {
                        sb.append (@"    public $vt $fn;\n");
                        if (f.ctype.kind == CTypeKind.ARRAY && vt == "uint8[]" && f.ctype.array_len is ExprInt)
                            foff += (int) ((ExprInt) f.ctype.array_len).val;
                        else
                            foff = (foff + 7) & ~7;
                    }
                }
                emit_struct_array_ctor (sb, sd, sname, need_byte_view);
                sb.append ("}\n");
                return;
            }

            bool need_byte_view = (byte_cast_struct_map.get_index (sd.name) >= 0) && sd.fields.length > 0;
            if (need_byte_view) {
                sb.append ("    public uint8[]? _c2v_data = null;\n");
                sb.append ("    public int _off = 0;\n");
                sb.append (@"    public $sname.at (uint8[] buf, int off = 0) {\n");
                sb.append ("        _c2v_data = buf;\n");
                sb.append ("        _off = off;\n");
                sb.append ("    }\n");
            }
            int bf_word = -1;
            int bf_off = 64;
            int bf_byte_off = 0;
            int foff = 0;
            var bf_sb = new StrBuilder ();
            for (int i = 0; i < sd.fields.length; i++) {
                var f = sd.fields[i];
                if (f.bit_width < 0) {
                    if (f.name != "") {
                        string vt = vala_type (f.ctype, false);
                        string fn = (sd.name == "tm") ? map_tm_field (f.name) : esc_ident (f.name);
                        int nb = union_scalar_bytes (vt);
                        if (need_byte_view && f.ctype.kind == CTypeKind.ENUM) {
                            foff = (foff + 3) & ~3;
                            sb.append (@"    private $vt _$fn;\n");
                            sb.append (@"    public $vt $fn {\n");
                            sb.append (@"        get { return (_c2v_data != null) ? (($vt) ((int) ((int32) c_u_get_u32_at ((!) _c2v_data, _off + $foff)))) : _$fn; }\n");
                            sb.append (@"        set { if (_c2v_data != null) c_u_set_u32_at ((!) _c2v_data, _off + $foff, (uint32) ((int32) value)); else _$fn = value; }\n");
                            sb.append ("    }\n");
                            foff += 4;
                        } else if (need_byte_view && nb > 0) {
                            int align = (nb >= 8) ? 8 : nb;
                            foff = (foff + align - 1) & ~(align - 1);
                            sb.append (@"    private $vt _$fn;\n");
                            sb.append (@"    public $vt $fn {\n");
                            if (vt == "float") {
                                sb.append (@"        get { return (_c2v_data != null) ? c_u32_to_f32 (c_u_get_u32_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                                sb.append (@"        set { if (_c2v_data != null) c_u_set_u32_at ((!) _c2v_data, _off + $foff, c_f32_to_u32 (value)); else _$fn = value; }\n");
                            } else if (vt == "double") {
                                sb.append (@"        get { return (_c2v_data != null) ? c_u64_to_f64 (c_u_get_u64_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                                sb.append (@"        set { if (_c2v_data != null) c_u_set_u64_at ((!) _c2v_data, _off + $foff, c_f64_to_u64 (value)); else _$fn = value; }\n");
                            } else if (vt == "bool") {
                                sb.append (@"        get { return (_c2v_data != null) ? (c_u_get_u8_at ((!) _c2v_data, _off + $foff) != 0) : _$fn; }\n");
                                sb.append (@"        set { if (_c2v_data != null) c_u_set_u8_at ((!) _c2v_data, _off + $foff, value ? ((uint8) 1) : ((uint8) 0)); else _$fn = value; }\n");
                            } else if (nb == 1) {
                                sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u8_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                                sb.append (@"        set { if (_c2v_data != null) c_u_set_u8_at ((!) _c2v_data, _off + $foff, (uint8) value); else _$fn = value; }\n");
                            } else if (nb == 2) {
                                sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u16_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                                sb.append (@"        set { if (_c2v_data != null) c_u_set_u16_at ((!) _c2v_data, _off + $foff, (uint16) value); else _$fn = value; }\n");
                            } else if (nb == 4) {
                                sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u32_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                                sb.append (@"        set { if (_c2v_data != null) c_u_set_u32_at ((!) _c2v_data, _off + $foff, (uint32) value); else _$fn = value; }\n");
                            } else {
                                sb.append (@"        get { return (_c2v_data != null) ? (($vt) c_u_get_u64_at ((!) _c2v_data, _off + $foff)) : _$fn; }\n");
                                sb.append (@"        set { if (_c2v_data != null) c_u_set_u64_at ((!) _c2v_data, _off + $foff, (uint64) value); else _$fn = value; }\n");
                            }
                            sb.append ("    }\n");
                            foff += nb;
                        } else if (need_byte_view && f.ctype.kind == CTypeKind.ARRAY
                                   && f.ctype.array_len is ExprInt && f.ctype.inner != null
                                   && (f.ctype.inner.kind == CTypeKind.SCALAR || f.ctype.inner.kind == CTypeKind.ENUM)) {
                            emit_byte_view_array (sb, f, fn, vt, ref foff, i == sd.fields.length - 1);
                        } else {
                            sb.append (@"    public $vt $fn;\n");
                            if (f.ctype.kind == CTypeKind.ARRAY && vt == "uint8[]" && f.ctype.array_len is ExprInt)
                                foff += (int) ((ExprInt) f.ctype.array_len).val;
                            else
                                foff = (foff + 7) & ~7;
                        }
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
                    foff = (foff + 7) & ~7;
                    bf_byte_off = foff;
                    foff += 8;
                    sb.append (@"    private uint64 _bf$bf_word;\n");
                }
                if (f.name != "") {
                    string vt = vala_type (f.ctype, false);
                    string fn = (sd.name == "tm") ? map_tm_field (f.name) : esc_ident (f.name);
                    uint64 mask = (w >= 64) ? uint64.MAX : (((uint64) 1 << w) - 1);
                    string mask_s = @"((uint64) $(mask.to_string ()))";
                    bool is_signed = !is_unsigned_kind (vt) && vt != "bool";
                    bf_sb.append (@"    public $vt $fn {\n");
                    bf_sb.append ("        get {\n");
                    if (need_byte_view)
                        bf_sb.append (@"            uint64 _w = (data != null) ? c_u_get_u64_at ((!) data, _off + $bf_byte_off) : _bf$bf_word;\n            uint64 raw = (_w >> $bf_off) & $mask_s;\n");
                    else
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
                    if (need_byte_view) {
                        bf_sb.append (@"            if (data != null) {\n");
                        bf_sb.append (@"                uint64 _w = c_u_get_u64_at ((!) data, _off + $bf_byte_off);\n");
                        bf_sb.append (@"                c_u_set_u64_at ((!) data, _off + $bf_byte_off, (_w & ~($mask_s << $bf_off)) | (($vcast & $mask_s) << $bf_off));\n");
                        bf_sb.append ("            } else {\n");
                        bf_sb.append (@"                _bf$bf_word = (_bf$bf_word & ~($mask_s << $bf_off)) | (($vcast & $mask_s) << $bf_off);\n");
                        bf_sb.append ("            }\n");
                    } else {
                        bf_sb.append (@"            _bf$bf_word = (_bf$bf_word & ~($mask_s << $bf_off)) | (($vcast & $mask_s) << $bf_off);\n");
                    }
                    bf_sb.append ("        }\n");
                    bf_sb.append ("    }\n");
                }
                bf_off += w;
            }
            sb.append (bf_sb.str);
            emit_struct_array_ctor (sb, sd, sname, need_byte_view);
            sb.append ("}\n");
        }

        // Inline C arrays are modelled as references, so the default constructor
        // has to allocate them; without this every instance of the struct starts
        // with null array members (the DOOM `sprtemp[i].lump` bug). Fields that
        // `need_byte_view` turns into byte-slice properties already carry their
        // own backing initializer and are skipped here.
        private void emit_struct_array_ctor (StrBuilder sb, StructDef sd, string sname,
                                             bool need_byte_view) throws RefuseError {
            var saved_locals = cur_locals;
            var saved_fn = cur_fn;
            cur_locals = new GenericArray<LocalInfo> ();
            cur_fn = null;
            var ctor_body = new StrBuilder ();
            int ctor_uniq = alloc_uniq;
            try {
                for (int ci = 0; ci < sd.fields.length; ci++) {
                    var cf = sd.fields[ci];
                    if (cf.name == "")
                        continue;
                    if (cf.ctype.kind != CTypeKind.ARRAY || cf.ctype.inner == null || cf.ctype.array_len == null)
                        continue;
                    if (need_byte_view && cf.ctype.array_len is ExprInt
                        && (cf.ctype.inner.kind == CTypeKind.SCALAR || cf.ctype.inner.kind == CTypeKind.ENUM))
                        continue;
                    string cfn = (sd.name == "tm") ? map_tm_field (cf.name) : esc_ident (cf.name);
                    emit_array_alloc_stmts (ctor_body, @"this.$cfn", cf.ctype, 2, ref ctor_uniq);
                }
            } finally {
                alloc_uniq = ctor_uniq;
                cur_locals = saved_locals;
                cur_fn = saved_fn;
            }
            if (ctor_body.str.length > 0) {
                sb.append (@"    public $sname () {\n");
                sb.append (ctor_body.str);
                sb.append ("    }\n");
            } else {
                sb.append (@"    public $sname () {}\n");
            }
        }

        // ---- Function emission ----

        private GenericArray<LocalInfo> cur_locals = new GenericArray<LocalInfo> ();
        private GenericArray<GotoPlan> cur_gotos = new GenericArray<GotoPlan> ();
        private FuncDef? cur_fn = null;
        private FuncSig? cur_sig = null;
        private PtrAnalysis? cur_ptr_analysis = null;
        private bool cur_allow_out_ref = false;
        private bool cur_in_call_arg = false;
        private int out_ref_id = 0;
        private GenericArray<string> out_ref_decls = new GenericArray<string> ();
        private GenericArray<string> out_ref_writebacks = new GenericArray<string> ();

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
                return "null";
            }
            if (ct.kind == CTypeKind.FUNC_PTR)
                return "null";
            if (ct.kind == CTypeKind.STRUCT)
                return @"new $vt ()";
            if (ct.kind == CTypeKind.UNION)
                return @"new $vt ()";
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
            cur_ptr_analysis = PtrAnalyzer.analyze_func (fn);
            string ptr_summary = cur_ptr_analysis.format_summary ();
            if (ptr_summary != "")
                sb.append (@"// c2vala-ptrs: $ptr_summary\n");
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
                if (fn.params.length >= 1) {
                    var p0 = fn.params[0];
                    sb.append (@"    int $(esc_ident (p0.name)) = args.length;\n");
                    cur_locals.add (new LocalInfo (p0.name, p0.ctype, true));
                }
                if (fn.params.length >= 2) {
                    var p1 = fn.params[1];
                    sb.append (@"    string[] $(esc_ident (p1.name)) = args;\n");
                    var li1 = new LocalInfo (p1.name, p1.ctype, true);
                    li1.is_array = true;
                    cur_locals.add (li1);
                }
            } else {
                var prescan_p = fn_locals[func_idx];
                string ret_t = vala_type (fn.ret_type, sig.ret_is_array);
                assert_supported_type (ret_t);
                if (plan_mode)
                    sb.append ("[Wrap]\n");
                sb.append (@"$ret_t $(esc_ident (fn.name)) (");
                for (int i = 0; i < fn.params.length; i++) {
                    var p = fn.params[i];
                    string pt = vala_type (p.ctype, sig.param_is_array[i]);
                    assert_supported_type (pt);
                    if (i > 0)
                        sb.append (", ");
                    var ppl = find_local (prescan_p, p.name);
                    bool p_is_fref = (cur_ptr_analysis != null && cur_ptr_analysis.is_field_ref (p.name)
                        && p.ctype.kind == CTypeKind.PTR && p.ctype.inner != null);
                    string pname = ((ppl != null && ppl.has_addr_taken && !sig.param_is_array[i]) || p_is_fref)
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
                    if (cur_ptr_analysis != null && cur_ptr_analysis.is_field_ref (cur_locals[pi].name)
                        && cur_locals[pi].is_param
                        && cur_locals[pi].ctype.kind == CTypeKind.PTR && cur_locals[pi].ctype.inner != null) {
                        cur_locals[pi].is_field_ref = true;
                        string fvt = vala_type ((CType) cur_locals[pi].ctype.inner, false);
                        string fcls = ensure_field_ref_helper (fvt);
                        string en = esc_ident (cur_locals[pi].name);
                        string pn = esc_ident (@"_p_$(cur_locals[pi].name)");
                        sb.append (@"    $fcls? $en = ($pn != null) ? new $fcls (() => { return $pn.val; }, (v) => { $pn.val = v; }) : null;\n");
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
                if (!is_root && b.stmts.length > 0
                    && (b.stmts[b.stmts.length - 1] is StmtReturn || b.stmts[b.stmts.length - 1] is StmtGoto)) {
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
            } else if (s is StmtWhile) {
                return find_hoisted_tail_label (((StmtWhile) s).body, label, out out_if, out out_blk, out out_idx, false);
            } else if (s is StmtFor) {
                return find_hoisted_tail_label (((StmtFor) s).body, label, out out_if, out out_blk, out out_idx, false);
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                for (int i = 0; i < sw.cases.length; i++) {
                    for (int j = 0; j < sw.cases[i].stmts.length; j++) {
                        if (find_hoisted_tail_label (sw.cases[i].stmts[j], label, out out_if, out out_blk, out out_idx, false))
                            return true;
                    }
                }
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
                out_ref_decls.length = 0;
                out_ref_writebacks.length = 0;
                bool prev_aor_if = cur_allow_out_ref;
                cur_allow_out_ref = true;
                string cond_s = emit_top_cond (ifs.cond);
                cur_allow_out_ref = prev_aor_if;
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    var ntb = cur_gotos[gi].nested_target_block;
                    if (ntb != null) {
                        if (stmt_contains_block (ifs.then_branch, (StmtBlock) ntb))
                            cond_s = @"(($cond_s) || $(cur_gotos[gi].flag_name))";
                        else if (ifs.else_branch != null && stmt_contains_block (ifs.else_branch, (StmtBlock) ntb))
                            cond_s = @"(($cond_s) && !$(cur_gotos[gi].flag_name))";
                    }
                }
                if (out_ref_decls.length > 0) {
                    for (int ori = 0; ori < out_ref_decls.length; ori++) {
                        indent (sb, level);
                        sb.append (out_ref_decls[ori] + "\n");
                    }
                    string ctmp = @"_c2v_cond_$(out_ref_id++)";
                    indent (sb, level);
                    sb.append (@"bool $ctmp = $cond_s;\n");
                    for (int ori = 0; ori < out_ref_writebacks.length; ori++) {
                        indent (sb, level);
                        sb.append (out_ref_writebacks[ori] + "\n");
                    }
                    cond_s = ctmp;
                }
                out_ref_decls.length = 0;
                out_ref_writebacks.length = 0;
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
                var prev_multi_next = cur_loop_multi_next;
                cur_loop_multi_next = null;
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
                    out_ref_decls.length = 0;
                    out_ref_writebacks.length = 0;
                    bool prev_aor_w = cur_allow_out_ref;
                    cur_allow_out_ref = true;
                    string wcond_s = emit_top_cond (ws.cond);
                    cur_allow_out_ref = prev_aor_w;
                    if (out_ref_decls.length > 0) {
                        var decls_copy = new GenericArray<string> ();
                        for (int ori = 0; ori < out_ref_decls.length; ori++) decls_copy.add (out_ref_decls[ori]);
                        var wb_copy = new GenericArray<string> ();
                        for (int ori = 0; ori < out_ref_writebacks.length; ori++) wb_copy.add (out_ref_writebacks[ori]);
                        out_ref_decls.length = 0;
                        out_ref_writebacks.length = 0;
                        indent (sb, level);
                        sb.append (plan_mode ? "loop {\n" : "while (true) {\n");
                        for (int ori = 0; ori < decls_copy.length; ori++) {
                            indent (sb, level + 1);
                            sb.append (decls_copy[ori] + "\n");
                        }
                        string ctmp = @"_c2v_cond_$(out_ref_id++)";
                        indent (sb, level + 1);
                        sb.append (@"bool $ctmp = $wcond_s;\n");
                        for (int ori = 0; ori < wb_copy.length; ori++) {
                            indent (sb, level + 1);
                            sb.append (wb_copy[ori] + "\n");
                        }
                        indent (sb, level + 1);
                        sb.append (@"if (!$ctmp) break;\n");
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
                        sb.append ("}\n");
                    } else {
                        out_ref_decls.length = 0;
                        out_ref_writebacks.length = 0;
                        indent (sb, level);
                        if (plan_mode && wcond_s == "true") {
                            sb.append ("loop ");
                        } else {
                            sb.append ("while (");
                            sb.append (wcond_s);
                            sb.append (") ");
                        }
                        emit_loop_body (sb, ws.body, level, gf);
                    }
                }
                cur_loop_stmt = prev_loop;
                cur_loop_multi_next = prev_multi_next;
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
                if (try_emit_foreach_for (sb, fs, level))
                    return;
                var prev_loop = cur_loop_stmt;
                cur_loop_stmt = s;
                // Vala has no comma operator: `for (a, b; ...)` starts with the
                // initializers hoisted into a block in front of the loop.
                bool init_ptr_assign = false;
                if (fs.init_decl == null && fs.init_expr is ExprAssign) {
                    var ia = (ExprAssign) fs.init_expr;
                    if (ia.lvalue is ExprIdent) {
                        var ili = find_local (cur_locals, ((ExprIdent) ia.lvalue).name);
                        if (ili != null && ili.has_ptr_arith)
                            init_ptr_assign = true;
                    }
                }
                bool hoist = (fs.init_decl == null && ((fs.init_expr is ExprBinary
                    && ((ExprBinary) fs.init_expr).op == ",") || init_ptr_assign));
                int loop_level = level;
                if (hoist) {
                    indent (sb, level);
                    sb.append ("{\n");
                    loop_level = level + 1;
                    if (init_ptr_assign)
                        emit_stmt (sb, new StmtExpr () { expr = (CExpr) fs.init_expr, file = fs.file, line = fs.line }, loop_level);
                    else
                        emit_comma_stmts (sb, (CExpr) fs.init_expr, loop_level);
                }
                if (plan_mode && !hoist && fs.init_decl == null && fs.init_expr == null
                    && fs.cond == null && fs.next == null) {
                    string? loop_gf = all_goto_cond (s);
                    var prev_multi_next = cur_loop_multi_next;
                    cur_loop_multi_next = null;
                    indent (sb, loop_level);
                    sb.append ("loop ");
                    emit_loop_body (sb, fs.body, loop_level, loop_gf);
                    cur_loop_stmt = prev_loop;
                    cur_loop_multi_next = prev_multi_next;
                    if (prev_loop != null) {
                        for (int gi = 0; gi < cur_gotos.length; gi++) {
                            if (cur_gotos[gi].loop_continue_stmt == prev_loop) {
                                indent (sb, loop_level);
                                sb.append (@"if ($(cur_gotos[gi].flag_name)) { $(cur_gotos[gi].flag_name) = false; continue; }\n");
                            }
                        }
                    }
                    return;
                }
                indent (sb, loop_level);
                sb.append ("for (");
                if (fs.init_decl != null) {
                    var d = (StmtDecl) fs.init_decl;
                    string vt = vala_type (d.ctype, false);
                    var li = new LocalInfo (d.name, d.ctype, false);
                    cur_locals.add (li);
                    sb.append (@"$vt $(esc_ident (d.name))");
                    if (d.init != null) {
                        string iv = emit_expr ((CExpr) d.init);
                        sb.append (@" = $iv");
                    }
                } else if (fs.init_expr != null && !hoist) {
                    sb.append (emit_comma_list ((CExpr) fs.init_expr));
                }
                sb.append ("; ");
                if (fs.cond != null)
                    sb.append (emit_top_cond ((CExpr) fs.cond));
                sb.append ("; ");
                bool next_multi = (fs.next is ExprBinary && ((ExprBinary) fs.next).op == ",");
                if (fs.next != null && !next_multi)
                    sb.append (emit_comma_list ((CExpr) fs.next));
                string? loop_gf = all_goto_cond (s);
                var prev_multi_next = cur_loop_multi_next;
                cur_loop_multi_next = next_multi ? fs.next : null;
                if (next_multi) {
                    // Vala's for-increment is a single expression: run the
                    // increments at the end of the body (and before any continue).
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
                cur_loop_multi_next = prev_multi_next;
                cur_loop_multi_next = prev_multi_next;
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
                if (cur_sw_cont_flag != null) {
                    indent (sb, level);
                    sb.append (@"{ $cur_sw_cont_flag = true; break; }\n");
                } else {
                    emit_continue_with_multi (sb, level);
                }
                return;
            }
            if (s is StmtReturn) {
                var rs = (StmtReturn) s;
                if (rs.expr == null) {
                    indent (sb, level);
                    sb.append ("return;\n");
                } else if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.PTR
                           && is_null_ptr_expr ((CExpr) rs.expr)) {
                    indent (sb, level);
                    sb.append (@"return $(ptr_null_value (cur_fn.ret_type));\n");
                } else {
                    out_ref_decls.length = 0;
                    out_ref_writebacks.length = 0;
                    bool prev_aor = cur_allow_out_ref;
                    cur_allow_out_ref = true;
                    var rt = infer_type ((CExpr) rs.expr);
                    string ex = "";
                    if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.SCALAR
                        && rt != null && rt.kind == CTypeKind.ENUM) {
                        string rxs = emit_expr ((CExpr) rs.expr);
                        ex = @"(($(cur_fn.ret_type.name)) $rxs)";
                    } else if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.SCALAR
                               && !cur_fn.ret_type.is_scalar ("void")) {
                        ex = coerce_value ((CExpr) rs.expr, cur_fn.ret_type.name);
                    } else if (cur_fn != null && cur_fn.ret_type.kind == CTypeKind.PTR
                               && cur_fn.ret_type.inner != null
                               && !((CType) cur_fn.ret_type.inner).is_scalar ("void")) {
                        int ret_view = vala_type (cur_fn.ret_type, cur_sig != null && cur_sig.ret_is_array).has_suffix ("[]") ? 2 : 1;
                        var rexpr = (CExpr) rs.expr;
                        if (!is_null_ptr_expr (rexpr)) {
                            ex = coerce_ptr (rexpr, cur_fn.ret_type, null, ret_view);
                        } else {
                            ex = (ret_view == 2) ? empty_array_for (cur_fn.ret_type) : ptr_null_value (cur_fn.ret_type);
                        }
                    } else {
                        ex = emit_expr ((CExpr) rs.expr);
                    }
                    cur_allow_out_ref = prev_aor;
                    for (int ori = 0; ori < out_ref_decls.length; ori++) {
                        indent (sb, level);
                        sb.append (out_ref_decls[ori] + "\n");
                    }
                    if (out_ref_writebacks.length > 0 && cur_fn != null && !cur_fn.ret_type.is_scalar ("void")) {
                        string rvt = vala_type (cur_fn.ret_type, cur_sig != null && cur_sig.ret_is_array);
                        string rtmp = @"_c2v_ret_$(out_ref_id++)";
                        indent (sb, level);
                        sb.append (@"$rvt $rtmp = $ex;\n");
                        for (int ori = 0; ori < out_ref_writebacks.length; ori++) {
                            indent (sb, level);
                            sb.append (out_ref_writebacks[ori] + "\n");
                        }
                        indent (sb, level);
                        sb.append (@"return $rtmp;\n");
                    } else {
                        indent (sb, level);
                        sb.append (@"return $ex;\n");
                    }
                    out_ref_decls.length = 0;
                    out_ref_writebacks.length = 0;
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
                // Handle `*p++ = val;` / `*p-- = val;` when `p` does not use `_off_p` (e.g. globals)
                if (es.expr is ExprAssign && ((ExprAssign) es.expr).op == "="
                    && ((ExprAssign) es.expr).lvalue is ExprUnary
                    && ((ExprUnary) ((ExprAssign) es.expr).lvalue).op == "*") {
                    var ea = (ExprAssign) es.expr;
                    var uo = ((ExprUnary) ea.lvalue).operand;
                    if (uo is ExprUnary && ((ExprUnary) uo).is_post
                        && (((ExprUnary) uo).op == "++" || ((ExprUnary) uo).op == "--")
                        && ((ExprUnary) uo).operand is ExprIdent) {
                        var iu = (ExprUnary) uo;
                        string pnm = ((ExprIdent) iu.operand).name;
                        var pli = find_local (cur_locals, pnm);
                        if (pli == null || !pli.has_ptr_arith) {
                            var pt = infer_type (iu.operand);
                            if (pt != null && (pt.is_void_ptr () || pt.is_char_ptr () || is_byte_or_char_ptr (pt))) {
                                string ep = esc_ident (pnm);
                                string step = (iu.op == "++") ? "1" : "-1";
                                indent (sb, level);
                                sb.append (@"$ep[0] = (uint8) ($(emit_expr (ea.rvalue)));\n");
                                indent (sb, level);
                                sb.append (@"$ep = c_bytes_add ($ep, $step);\n");
                                return;
                            }
                        }
                    }
                }
                // Handle `p++;` / `++p;` on byte/char pointer without `_off_p` (e.g. globals)
                if (es.expr is ExprUnary) {
                    var eu = (ExprUnary) es.expr;
                    if ((eu.op == "++" || eu.op == "--") && eu.operand is ExprIdent) {
                        string pnm = ((ExprIdent) eu.operand).name;
                        var pli = find_local (cur_locals, pnm);
                        if (pli == null || !pli.has_ptr_arith) {
                            var pt = infer_type (eu.operand);
                            if (pt != null && (pt.is_void_ptr () || pt.is_char_ptr () || is_byte_or_char_ptr (pt))) {
                                string ep = esc_ident (pnm);
                                string step = (eu.op == "++") ? "1" : "-1";
                                indent (sb, level);
                                sb.append (@"$ep = c_bytes_add ($ep, $step);\n");
                                return;
                            }
                        }
                    }
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
                    if (call.callee is ExprIdent && ((ExprIdent) call.callee).name == "assert") {
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
                        if (mt != null && (mt.kind == CTypeKind.ARRAY || mt.kind == CTypeKind.PTR)
                            && mt.inner != null && mt.inner.kind == CTypeKind.SCALAR
                            && !mt.inner.is_scalar ("char") && !mt.inner.is_scalar ("uint8")
                            && !mt.inner.is_scalar ("uchar") && !mt.inner.is_scalar ("void")) {
                            string arr_s = emit_expr (call.args[0]);
                            string esz = emit_sizeof_ctype ((CType) mt.inner);
                            string cnt_s = @"(((int) ($(emit_expr (call.args[2])))) / (int) ($esz))";
                            indent (sb, level);
                            sb.append (@"for (int _c2v_mi = 0; _c2v_mi < $cnt_s && _c2v_mi < $arr_s.length; _c2v_mi++) { $arr_s[_c2v_mi] = 0; }\n");
                            return;
                        }
                        if (mt != null && (mt.kind == CTypeKind.STRUCT || mt.is_struct_ptr ())) {
                            string sname = (mt.kind == CTypeKind.STRUCT) ? mt.name : ((CType) mt.inner).name;
                            var sd = find_struct (sname);
                            if (sd != null) {
                                string lhs_s = emit_expr (call.args[0]);
                                if (mt.kind == CTypeKind.PTR && ptr_view (call.args[0], mt) == 2) {
                                    string off_s = "0";
                                    if (call.args[0] is ExprIdent) {
                                        var mli = find_local (cur_locals, ((ExprIdent) call.args[0]).name);
                                        if (mli != null && mli.has_ptr_arith)
                                            off_s = @"_off_$(mli.name)";
                                    }
                                    lhs_s = @"$lhs_s[$off_s]";
                                }
                                emit_struct_zero (sb, lhs_s, (StructDef) sd, level);
                                return;
                            }
                        }
                        if (call.args[0] is ExprUnary && ((ExprUnary) call.args[0]).op == "&"
                            && ((ExprUnary) call.args[0]).operand is ExprMember) {
                            var mem = (ExprMember) ((ExprUnary) call.args[0]).operand;
                            var mot = infer_type (mem.obj);
                            if (mot != null && (mot.kind == CTypeKind.STRUCT || mot.is_struct_ptr ())) {
                                string sname = (mot.kind == CTypeKind.STRUCT) ? mot.name : ((CType) mot.inner).name;
                                var sd = find_struct (sname);
                                if (sd != null) {
                                    int start_fi = -1;
                                    for (int fi = 0; fi < sd.fields.length; fi++) {
                                        if (sd.fields[fi].name == mem.field) {
                                            start_fi = fi;
                                            break;
                                        }
                                    }
                                    if (start_fi >= 0) {
                                        string obj_s = emit_expr (mem.obj);
                                        if (mot.kind == CTypeKind.PTR && ptr_view (mem.obj, mot) == 2) {
                                            string off_s = "0";
                                            if (mem.obj is ExprIdent) {
                                                var mli = find_local (cur_locals, ((ExprIdent) mem.obj).name);
                                                if (mli != null && mli.has_ptr_arith)
                                                    off_s = @"_off_$(mli.name)";
                                            }
                                            obj_s = @"$obj_s[$off_s]";
                                        }
                                        emit_struct_zero (sb, obj_s, (StructDef) sd, level, start_fi);
                                        return;
                                    }
                                }
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
                out_ref_decls.length = 0;
                out_ref_writebacks.length = 0;
                bool prev_aor_s = cur_allow_out_ref;
                cur_allow_out_ref = true;
                string stmt_s = emit_expr ((CExpr) es.expr, true);
                cur_allow_out_ref = prev_aor_s;
                for (int ori = 0; ori < out_ref_decls.length; ori++) {
                    indent (sb, level);
                    sb.append (out_ref_decls[ori] + "\n");
                }
                indent (sb, level);
                sb.append (stmt_s);
                sb.append (";\n");
                for (int ori = 0; ori < out_ref_writebacks.length; ori++) {
                    indent (sb, level);
                    sb.append (out_ref_writebacks[ori] + "\n");
                }
                out_ref_decls.length = 0;
                out_ref_writebacks.length = 0;
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

        // True when `e` names a 2-D array (or pointer-to-pointer), so indexing
        // it once yields a row that is itself a reference to a slice.
        private bool is_row_of_2d (CExpr e) throws RefuseError {
            var t = infer_type (e);
            if (t == null)
                return false;
            if (t.kind != CTypeKind.PTR && t.kind != CTypeKind.ARRAY)
                return false;
            if (t.inner == null)
                return false;
            var inn = (CType) t.inner;
            return inn.kind == CTypeKind.PTR || inn.kind == CTypeKind.ARRAY;
        }

        // Splits an additive chain over a byte view of a struct pointer
        // (`(byte *)column + column->length + 4`) into the view's underlying
        // buffer and the summed offset. The buffer can then be aliased instead
        // of copying a slice of it, which is what made per-post reads of a
        // patch quadratic in the lump size.
        private bool byte_view_base (CExpr e, out string buf_s, out string off_s) throws RefuseError {
            buf_s = "";
            off_s = "";
            var terms = new GenericArray<string> ();
            CExpr cur = e;
            while (cur is ExprBinary) {
                var b = (ExprBinary) cur;
                if (b.op != "+" && b.op != "-")
                    break;
                var rt = infer_type (b.right);
                if (rt == null || rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)
                    break;
                string t_s = @"(int) ($(emit_expr (b.right)))";
                terms.add ((b.op == "+") ? t_s : @"(-($t_s))");
                cur = b.left;
            }
            if (cur is ExprCast) {
                var ce = (ExprCast) cur;
                var ct = ce.target_type;
                if (ct.kind != CTypeKind.PTR || ct.inner == null)
                    return false;
                var ci = (CType) ct.inner;
                if (!(ci.is_scalar ("char") || ci.is_scalar ("void") || ci.is_scalar ("uchar")
                      || ci.is_scalar ("uint8") || ci.is_scalar ("int8")))
                    return false;
                cur = ce.expr;
            }
            if (!(cur is ExprIdent))
                return false;
            string vn = ((ExprIdent) cur).name;
            var vli = find_local (cur_locals, vn);
            if (vli == null || vli.ctype.kind != CTypeKind.PTR || vli.ctype.inner == null)
                return false;
            var vinner = (CType) vli.ctype.inner;
            if (vinner.kind != CTypeKind.STRUCT && vinner.kind != CTypeKind.UNION)
                return false;
            var bsd = find_struct (vinner.name);
            if (bsd == null || bsd.fields.length == 0)
                return false;
            if (byte_cast_struct_map.get_index (vinner.name) < 0)
                return false;
            if (ptr_view (cur, vli.ctype) != 1)
                return false;
            buf_s = @"((!) $(esc_ident (vn))._c2v_data)";
            var osb = new StrBuilder ();
            osb.append (@"$(esc_ident (vn))._off");
            for (int ti = terms.length - 1; ti >= 0; ti--)
                osb.append (@" + $(terms[ti])");
            off_s = osb.str;
            return true;
        }

        // (buffer, offset) for a value that is a byte array plus additive
        // offsets, so `p = buffer + i + j` keeps the buffer instead of copying
        // its tail. Handles the byte views of struct pointers and plain byte
        // arrays (locals or globals).
        private bool ptr_pair_base (CExpr e, out string buf_s, out string off_s) throws RefuseError {
            buf_s = "";
            off_s = "";
            var terms = new GenericArray<string> ();
            CExpr cur = e;
            while (cur is ExprBinary) {
                var b = (ExprBinary) cur;
                if (b.op != "+" && b.op != "-")
                    break;
                var rt = infer_type (b.right);
                if (rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY))
                    break;
                string t_s = @"(int) ($(emit_expr (b.right)))";
                terms.add ((b.op == "+") ? t_s : @"(-($t_s))");
                cur = b.left;
            }
            var probe = cur;
            if (probe is ExprCast) {
                var ce = (ExprCast) probe;
                var ct = ce.target_type;
                if (ct.kind == CTypeKind.PTR && ct.inner != null) {
                    var ci = (CType) ct.inner;
                    if (ci.is_scalar ("char") || ci.is_scalar ("void") || ci.is_scalar ("uchar")
                        || ci.is_scalar ("uint8") || ci.is_scalar ("int8"))
                        probe = ce.expr;
                }
            }
            if (probe is ExprIdent) {
                string vn = ((ExprIdent) probe).name;
                var vli = find_local (cur_locals, vn);
                if (vli != null && vli.ctype.kind == CTypeKind.PTR && vli.ctype.inner != null) {
                    var vinner = (CType) vli.ctype.inner;
                    if ((vinner.kind == CTypeKind.STRUCT || vinner.kind == CTypeKind.UNION)
                        && byte_cast_struct_map.get_index (vinner.name) >= 0
                        && ptr_view (probe, vli.ctype) == 1) {
                        var bsd = find_struct (vinner.name);
                        if (bsd != null && bsd.fields.length > 0) {
                            buf_s = @"((!) $(esc_ident (vn))._c2v_data)";
                            var osb = new StrBuilder ();
                            osb.append (@"$(esc_ident (vn))._off");
                            for (int ti = terms.length - 1; ti >= 0; ti--)
                                osb.append (@" + $(terms[ti])");
                            off_s = osb.str;
                            return true;
                        }
                    }
                }
            }
            if (!(cur is ExprIdent))
                return false;
            string an = ((ExprIdent) cur).name;
            var ali = find_local (cur_locals, an);
            bool is_bytes = false;
            if (ali != null) {
                is_bytes = ali.is_array && ali.ctype.kind != CTypeKind.PTR;
                if (!is_bytes && ali.ctype.inner != null
                    && (ali.ctype.kind == CTypeKind.ARRAY || ali.ctype.kind == CTypeKind.PTR)) {
                    var ain = (CType) ali.ctype.inner;
                    is_bytes = ain.is_scalar ("uint8") || ain.is_scalar ("uchar")
                        || ain.is_scalar ("char") || ain.is_scalar ("void");
                }
            } else {
                var gt = infer_type (cur);
                is_bytes = gt != null && gt.inner != null
                    && (gt.kind == CTypeKind.ARRAY || gt.kind == CTypeKind.PTR)
                    && (((CType) gt.inner).is_scalar ("uint8") || ((CType) gt.inner).is_scalar ("uchar")
                        || ((CType) gt.inner).is_scalar ("char") || ((CType) gt.inner).is_scalar ("void"));
            }
            if (!is_bytes)
                return false;
            buf_s = esc_ident (an);
            var osb2 = new StrBuilder ();
            bool first = true;
            if (ali != null && ali.has_ptr_arith) {
                osb2.append (@"_off_$an");
                first = false;
            }
            for (int ti = terms.length - 1; ti >= 0; ti--) {
                if (!first)
                    osb2.append (" + ");
                osb2.append (terms[ti]);
                first = false;
            }
            off_s = first ? "0" : osb2.str;
            return true;
        }

        // Statement form of `p = ...` when `p` tracks a pointer offset: Vala
        // cannot express the offset bookkeeping as a ternary in statement
        // position, so the assignment and the offset update are two statements.
        private void emit_ptr_assign_stmt (StrBuilder sb, ExprAssign a, LocalInfo pli, int level) throws RefuseError {
            string lname = esc_ident (pli.name);
            CExpr rv = a.rvalue;
            if (is_alloc_call (rv)) {
                indent (sb, level);
                string alloc_s = emit_alloc ((ExprCall) rv, pli.ctype);
                sb.append (@"$lname = $alloc_s;\n");
                indent (sb, level);
                sb.append (@"_off_$(pli.name) = 0;\n");
                return;
            }
            // A byte buffer plus offsets keeps the buffer and the offset:
            // copying its tail would duplicate the screen (or the whole lump)
            // on every patch, block or column.
            if (rv is ExprBinary) {
                string pb_buf;
                string pb_off;
                if (ptr_pair_base (rv, out pb_buf, out pb_off)) {
                    indent (sb, level);
                    sb.append (@"$lname = $pb_buf;\n");
                    indent (sb, level);
                    sb.append (@"_off_$(pli.name) = $pb_off;\n");
                    return;
                }
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
                if (rb.op == "+" && rb.right is ExprIdent) {
                    var rbt = infer_type (rb.right);
                    if (rbt != null && (rbt.kind == CTypeKind.PTR || rbt.kind == CTypeKind.ARRAY)) {
                        string src = ((ExprIdent) rb.right).name;
                        var sli = find_local (cur_locals, src);
                        string base_off = (sli != null && sli.has_ptr_arith) ? @"_off_$src" : "0";
                        indent (sb, level);
                        if (src == pli.name)
                            sb.append (@"$lname = $(emit_expr (rb.right));\n");
                        else
                            sb.append (@"$lname = $(coerce_ptr (rb.right, pli.ctype, a.lvalue));\n");
                        indent (sb, level);
                        sb.append (@"_off_$(pli.name) = $base_off + (int) ($(emit_expr (rb.left)));\n");
                        return;
                    }
                }
                // The base may also be a *row* of a 2-D array
                // (`ylookup[y] + columnofs[x]`): that row is already a
                // reference, so it must not be copied. Only rows qualify;
                // a cast such as `(byte *)column + 3` still needs a view.
                if ((rb.op == "+" || rb.op == "-") && rb.left is ExprIndex) {
                    var bix = (ExprIndex) rb.left;
                    if (is_row_of_2d (bix.array)) {
                        indent (sb, level);
                        sb.append (@"$lname = $(emit_expr (bix));\n");
                        indent (sb, level);
                        sb.append (@"_off_$(pli.name) = (int) ($(emit_expr (rb.right)));\n");
                        return;
                    }
                }
                if (rb.op == "+" && rb.right is ExprIndex) {
                    var bix2 = (ExprIndex) rb.right;
                    if (is_row_of_2d (bix2.array)) {
                        indent (sb, level);
                        sb.append (@"$lname = $(emit_expr (bix2));\n");
                        indent (sb, level);
                        sb.append (@"_off_$(pli.name) = (int) ($(emit_expr (rb.left)));\n");
                        return;
                    }
                }
            }
            // `source = (byte *)column + 3`: alias the byte view's buffer and
            // keep the offset in `_off_source`.
            string bv_buf;
            string bv_off;
            if (byte_view_base (rv, out bv_buf, out bv_off)) {
                indent (sb, level);
                sb.append (@"$lname = $bv_buf;\n");
                indent (sb, level);
                sb.append (@"_off_$(pli.name) = $bv_off;\n");
                return;
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

        private void emit_struct_zero (StrBuilder sb, string lhs, StructDef sd, int level, int start_fi = 0) throws RefuseError {
            for (int i = start_fi; i < sd.fields.length; i++) {
                var f = sd.fields[i];
                if (f.name == "") continue;
                string fn = (sd.name == "tm") ? map_tm_field (f.name) : esc_ident (f.name);
                indent (sb, level);
                if (f.ctype.kind == CTypeKind.STRUCT) {
                    string vt = vala_type (f.ctype, false);
                    if (vt.has_suffix ("?"))
                        sb.append (@"$lhs.$fn = null;\n");
                    else if (vt == "Time" || vt == "RecMutex" || vt == "Cond")
                        sb.append (@"$lhs.$fn = $vt ();\n");
                    else
                        sb.append (@"$lhs.$fn = new $vt ();\n");
                } else if (f.ctype.kind == CTypeKind.UNION) {
                    string vt = vala_type (f.ctype, false);
                    var usd = find_struct (f.ctype.name);
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
                } else if ((f.ctype.kind == CTypeKind.PTR || f.ctype.kind == CTypeKind.FUNC_PTR) && is_null_ptr_expr (il.items[fi])) {
                    indent (sb, level);
                    sb.append (@"$fpath = $(ptr_null_value (f.ctype));\n");
                } else if (f.ctype.kind == CTypeKind.ARRAY && il.items[fi] is ExprStr
                           && vala_type (f.ctype, false) == "uint8[]") {
                    // `char name[8] = "pistol"`: copy the bytes, the field is a
                    // byte slice rather than a Vala string.
                    indent (sb, level);
                    sb.append (@"c_strcpy_buf ($fpath, $(emit_expr (il.items[fi])));\n");
                } else if (f.ctype.kind == CTypeKind.PTR && il.items[fi] is ExprUnary
                           && ((ExprUnary) il.items[fi]).op == "&"
                           && ((ExprUnary) il.items[fi]).operand is ExprIndex) {
                    // `link = &S_sfx[sfx_pistol]`: a pointer into the array is
                    // the element itself once arrays are references.
                    var link_operand = (CExpr) ((ExprUnary) il.items[fi]).operand;
                    string link_s = emit_expr (link_operand);
                    indent (sb, level);
                    sb.append (@"$fpath = $link_s;\n");
                } else {
                    string? ft = (f.ctype.kind == CTypeKind.SCALAR || f.ctype.kind == CTypeKind.ENUM)
                        ? vala_type (f.ctype, false) : null;
                    indent (sb, level);
                    sb.append (@"$fpath = $(coerce_value (il.items[fi], ft));\n");
                }
            }
        }

        private void emit_decl (StrBuilder sb, StmtDecl d, int level) throws RefuseError {
            // `extern int x;` only re-states a global declaration.
            if (d.is_extern)
                return;
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
            if (cur_ptr_analysis != null && cur_ptr_analysis.is_field_ref_native (d.name))
                li.is_native_ptr = true;
            else if (cur_ptr_analysis != null && cur_ptr_analysis.is_field_ref (d.name))
                li.is_field_ref = true;
            cur_locals.add (li);
            if (d.is_static && d.ctype.kind == CTypeKind.ARRAY && d.ctype.array_len != null
                && d.ctype.inner != null && d.ctype.inner.kind != CTypeKind.ARRAY
                && d.init == null && !li.has_addr_taken && !li.has_ptr_arith
                && !li.is_field_ref && !li.is_native_ptr) {
                string sname = @"_c2v_s_$(static_seq++)_$(d.name)";
                li.static_global_name = sname;
                var hg = new GlobalVarDef (sname, d.ctype, null, d.file, d.line);
                hoisted_statics.add (hg);
                return;
            }
            string dname = esc_ident (d.name);

            if (li.is_native_ptr && d.ctype.kind == CTypeKind.PTR && d.ctype.inner != null) {
                string fvt = vala_type ((CType) d.ctype.inner, false);
                indent (sb, level);
                if (d.init != null && d.init is ExprUnary && ((ExprUnary) d.init).op == "&") {
                    string init_s = emit_native_ptr_addr ((ExprUnary) d.init);
                    sb.append (@"$fvt* $dname = $init_s;\n");
                } else if (d.init != null && !is_null_ptr_expr (d.init)) {
                    string init_s = emit_expr ((CExpr) d.init);
                    sb.append (@"$fvt* $dname = $init_s;\n");
                } else {
                    sb.append (@"$fvt* $dname = null;\n");
                }
                return;
            }

            if (li.is_field_ref && d.ctype.kind == CTypeKind.PTR && d.ctype.inner != null) {
                string fvt = vala_type ((CType) d.ctype.inner, false);
                string fcls = ensure_field_ref_helper (fvt);
                indent (sb, level);
                if (d.init != null && d.init is ExprUnary && ((ExprUnary) d.init).op == "&") {
                    string init_s = emit_field_ref_addr ((ExprUnary) d.init, fcls, fvt);
                    sb.append (@"$fcls? $dname = $init_s;\n");
                } else if (d.init != null && !is_null_ptr_expr (d.init)) {
                    string init_s = emit_expr ((CExpr) d.init);
                    sb.append (@"$fcls? $dname = $init_s;\n");
                } else {
                    sb.append (@"$fcls? $dname = null;\n");
                }
                return;
            }

            // Fixed-size or init-list array `T name[N];` / `T name[] = { ... };`
            if (d.ctype.kind == CTypeKind.ARRAY && d.ctype.inner != null) {
                var elem_ct = (CType) d.ctype.inner;
                // A C char buffer is a byte buffer, so give it the `uint8[]`
                // view the runtime shims (c_fgets, c_fread, ...) accept.
                string elem_t = (elem_ct.is_scalar ("char") || elem_ct.is_scalar ("void"))
                    ? "uint8" : vala_type (elem_ct, false);
                if (d.init is ExprInitList) {
                    var il = (ExprInitList) d.init;
                    if (can_emit_inline_array_init (elem_ct, il, d.ctype.array_len)) {
                        indent (sb, level);
                        sb.append (@"$elem_t[] $dname = ");
                        emit_inline_array_lit (sb, elem_ct, elem_t, il, level);
                        sb.append (";\n");
                        return;
                    }
                    string len_s = (d.ctype.array_len != null)
                        ? emit_expr ((CExpr) d.ctype.array_len)
                        : @"$(il.items.length)";
                    indent (sb, level);
                    sb.append (@"$elem_t[] $dname = new $elem_t[$len_s];\n");
                    if (elem_ct.kind == CTypeKind.STRUCT || elem_ct.kind == CTypeKind.UNION) {
                        indent (sb, level);
                        sb.append (@"for (int _c2v_i = 0; _c2v_i < $len_s; _c2v_i++) { $dname[_c2v_i] = new $elem_t (); }\n");
                    }
                    if (!is_zero_init_list (il) || elem_ct.kind == CTypeKind.STRUCT || elem_ct.kind == CTypeKind.UNION)
                        emit_array_init_elems (sb, dname, elem_ct, elem_t, il, level);
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
                var alt = infer_type ((CExpr) d.ctype.array_len);
                if (alt != null && alt.kind == CTypeKind.ENUM)
                    len_s = @"(int) ($len_s)";
                indent (sb, level);
                sb.append (@"$elem_t[] $dname = new $elem_t[$len_s];\n");
                if (elem_ct.kind == CTypeKind.STRUCT || elem_ct.kind == CTypeKind.UNION) {
                    indent (sb, level);
                    sb.append (@"for (int _c2v_i = 0; _c2v_i < $len_s; _c2v_i++) { $dname[_c2v_i] = new $elem_t (); }\n");
                } else if (elem_ct.kind == CTypeKind.ARRAY && elem_ct.inner != null && elem_ct.array_len != null) {
                    string sub_et = vala_type ((CType) elem_ct.inner, false);
                    string sub_len = emit_expr ((CExpr) elem_ct.array_len);
                    indent (sb, level);
                    sb.append (@"for (int _c2v_i = 0; _c2v_i < $len_s; _c2v_i++) { $dname[_c2v_i] = new $sub_et[$sub_len]; }\n");
                }
                return;
            }

            if (d.init is ExprInitList) {
                var il = (ExprInitList) d.init;
                if (d.ctype.kind == CTypeKind.STRUCT) {
                    string vt_s = vala_type (d.ctype, false);
                    indent (sb, level);
                    sb.append (@"$vt_s $dname = new $vt_s ();\n");
                    if (d.ctype.name == "pthread_mutex_t" || d.ctype.name == "pthread_cond_t")
                        return;
                    var sd = find_struct (d.ctype.name);
                    if (sd != null)
                        emit_struct_init_assigns (sb, dname, (StructDef) sd, il, level);
                    return;
                }
                refuse_loc (d.file, d.line, "initializer lists are not supported");
            }

            string vt = vala_type (d.ctype, li.is_array);
            assert_supported_type (vt);
            // `T *p = row_of_2d + n;` keeps the row as the base and n as an
            // offset, so writes through `p` land in the 2-D array.
            if (d.init is ExprBinary && vt.has_suffix ("[]")) {
                var ib = (ExprBinary) d.init;
                if ((ib.op == "+" || ib.op == "-") && ib.left is ExprIndex
                    && is_row_of_2d (((ExprIndex) ib.left).array)) {
                    var row_ix = (ExprIndex) ib.left;
                    indent (sb, level);
                    sb.append (@"$vt $dname = $(emit_expr (row_ix));\n");
                    indent (sb, level);
                    sb.append (@"int _off_$(d.name) = (int) ($(emit_expr (ib.right)));\n");
                    return;
                }
            }
            // `&x` needs a box only for scalars; structs/pointers already map
            // to references/arrays in Vala.
            if (li.has_addr_taken && d.ctype.kind == CTypeKind.PTR && vt.has_suffix ("[]")) {
                string init_v = (d.init != null && !is_null_ptr_expr (d.init))
                    ? coerce_ptr ((CExpr) d.init, d.ctype, null, 2)
                    : ptr_null_value (d.ctype);
                string abcls = ensure_arr_box_helper (vt);
                indent (sb, level);
                sb.append (@"$abcls $dname = new $abcls ($init_v);\n");
                return;
            }
            if (li.has_addr_taken && (d.ctype.kind == CTypeKind.SCALAR || d.ctype.kind == CTypeKind.ENUM
                || ((d.ctype.is_char_ptr () || d.ctype.is_struct_ptr ()) && !vt.has_suffix ("[]")))) {
                indent (sb, level);
                sb.append (@"$(vt)[] $dname = new $vt[1];\n");
                if (d.init != null) {
                    string? tgt = (d.ctype.kind == CTypeKind.SCALAR || d.ctype.kind == CTypeKind.ENUM) ? vt : null;
                    indent (sb, level);
                    if (d.ctype.kind == CTypeKind.PTR) {
                        string cp = coerce_ptr ((CExpr) d.init, d.ctype, null, 0);
                        sb.append (@"$dname[0] = $cp;\n");
                    } else {
                        string cv = coerce_value ((CExpr) d.init, tgt);
                        sb.append (@"$dname[0] = $cv;\n");
                    }
                }
                return;
            }
            bool alias_arr = li.is_array && d.ctype.kind == CTypeKind.PTR && d.init is ExprIdent;
            string decl_vt = alias_arr ? ("unowned " + vt) : vt;
            if (d.init != null) {
                if (is_malloc_init) {
                    indent (sb, level);
                    string alloc_s = emit_alloc ((ExprCall) d.init, li.ctype);
                    sb.append (@"$decl_vt $dname = $alloc_s;\n");
                } else if (d.ctype.kind == CTypeKind.FUNC_PTR && is_null_ptr_expr (d.init)) {
                    indent (sb, level);
                    sb.append (@"$decl_vt $dname = null;\n");
                } else if (d.ctype.kind == CTypeKind.PTR && is_null_ptr_expr (d.init)) {
                    indent (sb, level);
                    sb.append (@"$decl_vt $dname = $(ptr_null_value (d.ctype));\n");
                } else if (d.ctype.kind == CTypeKind.PTR && d.init is ExprStr
                           && vala_type (d.ctype, false).has_suffix ("[]")) {
                    // Read-only `char *p = "text"` uses zero-copy `.data`;
                    // mutated buffers get a fresh mutable copy via `c_str_to_bytes`.
                    indent (sb, level);
                    string sv = emit_expr ((CExpr) d.init);
                    bool written = (cur_ptr_analysis == null) || cur_ptr_analysis.is_ptr_written (d.name);
                    string rhs_s = written ? @"c_str_to_bytes ($sv)" : @"$sv.data";
                    sb.append (@"$decl_vt $dname = $rhs_s;\n");
                } else {
                    out_ref_decls.length = 0;
                    out_ref_writebacks.length = 0;
                    bool prev_aor_d = cur_allow_out_ref;
                    cur_allow_out_ref = true;
                    string? tgt = (d.ctype.kind == CTypeKind.SCALAR
                                   || d.ctype.kind == CTypeKind.ENUM) ? vt : null;
                    string init_rhs = (d.ctype.kind == CTypeKind.PTR)
                        ? coerce_ptr ((CExpr) d.init, d.ctype, null, li.is_array ? 2 : 0)
                        : coerce_value ((CExpr) d.init, tgt);
                    cur_allow_out_ref = prev_aor_d;
                    for (int ori = 0; ori < out_ref_decls.length; ori++) {
                        indent (sb, level);
                        sb.append (out_ref_decls[ori] + "\n");
                    }
                    indent (sb, level);
                    sb.append (@"$decl_vt $dname = $init_rhs;\n");
                    for (int ori = 0; ori < out_ref_writebacks.length; ori++) {
                        indent (sb, level);
                        sb.append (out_ref_writebacks[ori] + "\n");
                    }
                    out_ref_decls.length = 0;
                    out_ref_writebacks.length = 0;
                }
            } else {
                indent (sb, level);
                if (d.ctype.kind == CTypeKind.STRUCT) {
                    if (d.ctype.name == "tm")
                        sb.append (@"$vt $dname = $vt ();\n");
                    else if (d.ctype.name == "_c2v_pthread_t")
                        sb.append (@"$vt $dname = null;\n");
                    else if (d.ctype.name == "pthread_mutexattr_t" || d.ctype.name == "pthread_condattr_t" || d.ctype.name == "pthread_attr_t")
                        sb.append (@"$vt $dname = 0;\n");
                    else
                        sb.append (@"$vt $dname = new $vt ();\n");
                } else if (d.ctype.kind == CTypeKind.UNION) {
                    var usd = find_struct (d.ctype.name);
                    bool u_class = (usd != null) && union_needs_class (usd);
                    sb.append (u_class ? @"$vt $dname = new $vt ();\n" : @"$vt $dname = $vt ();\n");
                } else if (li.is_array && d.ctype.kind == CTypeKind.PTR && d.ctype.inner != null) {
                    sb.append (@"$vt $dname = null;\n");
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

        private string? cur_fe_arr = null;
        private string? cur_fe_idx = null;
        private string? cur_fe_elem = null;
        private int fe_counter = 0;

        private bool expr_only_uses_idx_on_arr (CExpr e, string idx_name, ref string? arr_name) {
            if (e is ExprIdent)
                return ((ExprIdent) e).name != idx_name;
            if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                if (ix.array is ExprIdent && ix.index is ExprIdent && ((ExprIdent) ix.index).name == idx_name) {
                    string an = ((ExprIdent) ix.array).name;
                    if (arr_name == null) arr_name = an;
                    return arr_name == an;
                }
                return expr_only_uses_idx_on_arr (ix.array, idx_name, ref arr_name)
                    && expr_only_uses_idx_on_arr (ix.index, idx_name, ref arr_name);
            }
            if (e is ExprUnary)
                return !(((ExprUnary) e).op.has_suffix ("++") || ((ExprUnary) e).op.has_suffix ("--") || ((ExprUnary) e).op == "&")
                    && expr_only_uses_idx_on_arr (((ExprUnary) e).operand, idx_name, ref arr_name);
            if (e is ExprBinary) {
                var b = (ExprBinary) e;
                return expr_only_uses_idx_on_arr (b.left, idx_name, ref arr_name)
                    && expr_only_uses_idx_on_arr (b.right, idx_name, ref arr_name);
            }
            if (e is ExprAssign) {
                var a = (ExprAssign) e;
                if (a.lvalue is ExprIndex && ((ExprIndex) a.lvalue).index is ExprIdent
                    && ((ExprIdent) ((ExprIndex) a.lvalue).index).name == idx_name)
                    return false;
                return expr_only_uses_idx_on_arr (a.lvalue, idx_name, ref arr_name)
                    && expr_only_uses_idx_on_arr (a.rvalue, idx_name, ref arr_name);
            }
            if (e is ExprCall) {
                var c = (ExprCall) e;
                for (int i = 0; i < c.args.length; i++)
                    if (!expr_only_uses_idx_on_arr (c.args[i], idx_name, ref arr_name)) return false;
                return true;
            }
            if (e is ExprMember)
                return expr_only_uses_idx_on_arr (((ExprMember) e).obj, idx_name, ref arr_name);
            if (e is ExprCast)
                return expr_only_uses_idx_on_arr (((ExprCast) e).expr, idx_name, ref arr_name);
            if (e is ExprTernary) {
                var t = (ExprTernary) e;
                return expr_only_uses_idx_on_arr (t.cond, idx_name, ref arr_name)
                    && expr_only_uses_idx_on_arr (t.if_true, idx_name, ref arr_name)
                    && expr_only_uses_idx_on_arr (t.if_false, idx_name, ref arr_name);
            }
            return e is ExprInt || e is ExprFloat || e is ExprChar || e is ExprStr || e is ExprSizeofType || e is ExprSizeofExpr;
        }

        private bool stmt_only_uses_idx_on_arr (CStmt s, string idx_name, ref string? arr_name) {
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (!stmt_only_uses_idx_on_arr (b.stmts[i], idx_name, ref arr_name)) return false;
                return true;
            }
            if (s is StmtExpr) {
                var es = (StmtExpr) s;
                return es.expr == null || expr_only_uses_idx_on_arr ((CExpr) es.expr, idx_name, ref arr_name);
            }
            if (s is StmtIf) {
                var ifs = (StmtIf) s;
                return expr_only_uses_idx_on_arr (ifs.cond, idx_name, ref arr_name)
                    && stmt_only_uses_idx_on_arr (ifs.then_branch, idx_name, ref arr_name)
                    && (ifs.else_branch == null || stmt_only_uses_idx_on_arr ((CStmt) ifs.else_branch, idx_name, ref arr_name));
            }
            if (s is StmtReturn) {
                var rs = (StmtReturn) s;
                return rs.expr == null || expr_only_uses_idx_on_arr ((CExpr) rs.expr, idx_name, ref arr_name);
            }
            return s is StmtBreak;
        }

        private bool expr_mentions_ident (CExpr e, string name) {
            if (e is ExprIdent)
                return ((ExprIdent) e).name == name;
            if (e is ExprUnary)
                return expr_mentions_ident (((ExprUnary) e).operand, name);
            if (e is ExprBinary) {
                var b = (ExprBinary) e;
                return expr_mentions_ident (b.left, name) || expr_mentions_ident (b.right, name);
            }
            if (e is ExprAssign) {
                var a = (ExprAssign) e;
                return expr_mentions_ident (a.lvalue, name) || expr_mentions_ident (a.rvalue, name);
            }
            if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                return expr_mentions_ident (ix.array, name) || expr_mentions_ident (ix.index, name);
            }
            if (e is ExprCall) {
                var c = (ExprCall) e;
                if (expr_mentions_ident (c.callee, name)) return true;
                for (int i = 0; i < c.args.length; i++)
                    if (expr_mentions_ident (c.args[i], name)) return true;
                return false;
            }
            if (e is ExprMember)
                return expr_mentions_ident (((ExprMember) e).obj, name);
            if (e is ExprCast)
                return expr_mentions_ident (((ExprCast) e).expr, name);
            if (e is ExprTernary) {
                var t = (ExprTernary) e;
                return expr_mentions_ident (t.cond, name)
                    || expr_mentions_ident (t.if_true, name)
                    || expr_mentions_ident (t.if_false, name);
            }
            if (e is ExprInt || e is ExprFloat || e is ExprChar || e is ExprStr
                || e is ExprSizeofType || e is ExprSizeofExpr)
                return false;
            return true;
        }

        private bool stmt_mentions_ident (CStmt s, string name) {
            if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    if (stmt_mentions_ident (b.stmts[i], name)) return true;
                return false;
            }
            if (s is StmtExpr) {
                var es = (StmtExpr) s;
                return es.expr != null && expr_mentions_ident ((CExpr) es.expr, name);
            }
            if (s is StmtIf) {
                var ifs = (StmtIf) s;
                return expr_mentions_ident (ifs.cond, name)
                    || stmt_mentions_ident (ifs.then_branch, name)
                    || (ifs.else_branch != null && stmt_mentions_ident ((CStmt) ifs.else_branch, name));
            }
            if (s is StmtReturn) {
                var rs = (StmtReturn) s;
                return rs.expr != null && expr_mentions_ident ((CExpr) rs.expr, name);
            }
            if (s is StmtDecl) {
                var sd = (StmtDecl) s;
                return sd.name == name || (sd.init != null && expr_mentions_ident ((CExpr) sd.init, name));
            }
            if (s is StmtBreak || s is StmtContinue)
                return false;
            return true;
        }

        private bool try_emit_foreach_for (StrBuilder sb, StmtFor fs, int level) throws RefuseError {
            if (cur_fe_arr != null || all_goto_cond (fs) != null)
                return false;
            // Plan optimization: `for (int i = 0; i < N; i++)` where `i` is unused -> `loop (N)`
            if (plan_mode && fs.init_decl is StmtDecl) {
                var id0 = (StmtDecl) fs.init_decl;
                if (id0.init is ExprInt && ((ExprInt) id0.init).val == 0
                    && fs.cond is ExprBinary && ((ExprBinary) fs.cond).op == "<"
                    && ((ExprBinary) fs.cond).left is ExprIdent
                    && ((ExprIdent) ((ExprBinary) fs.cond).left).name == id0.name
                    && fs.next is ExprUnary) {
                    var eu0 = (ExprUnary) fs.next;
                    if ((eu0.op == "++" || eu0.op == "post++")
                        && eu0.operand is ExprIdent && ((ExprIdent) eu0.operand).name == id0.name
                        && !stmt_mentions_ident (fs.body, id0.name)) {
                        string cnt_s = emit_expr (((ExprBinary) fs.cond).right);
                        indent (sb, level);
                        sb.append (@"loop ((int) ($cnt_s)) ");
                        emit_loop_body (sb, fs.body, level, null);
                        return true;
                    }
                }
            }
            // Plan optimization: `for (int i = N - 1; i >= 0; i--)` read-only on `arr[i]` -> `inverse_foreach`
            if (plan_mode && fs.init_decl is StmtDecl) {
                var idr = (StmtDecl) fs.init_decl;
                if (idr.init is ExprBinary && ((ExprBinary) idr.init).op == "-"
                    && ((ExprBinary) idr.init).right is ExprInt
                    && ((ExprInt) ((ExprBinary) idr.init).right).val == 1
                    && fs.cond is ExprBinary && ((ExprBinary) fs.cond).op == ">="
                    && ((ExprBinary) fs.cond).left is ExprIdent
                    && ((ExprIdent) ((ExprBinary) fs.cond).left).name == idr.name
                    && ((ExprBinary) fs.cond).right is ExprInt
                    && ((ExprInt) ((ExprBinary) fs.cond).right).val == 0
                    && fs.next is ExprUnary) {
                    var eur = (ExprUnary) fs.next;
                    if ((eur.op == "--" || eur.op == "post--")
                        && eur.operand is ExprIdent && ((ExprIdent) eur.operand).name == idr.name) {
                        string? r_arr = null;
                        if (stmt_only_uses_idx_on_arr (fs.body, idr.name, ref r_arr) && r_arr != null) {
                            var r_ali = find_local (cur_locals, (!) r_arr);
                            var r_at = infer_type (new ExprIdent () { name = (!) r_arr });
                            if ((r_ali == null || !r_ali.has_ptr_arith)
                                && r_at != null && (r_at.kind == CTypeKind.ARRAY
                                    || (r_at.kind == CTypeKind.PTR && ptr_view (new ExprIdent () { name = (!) r_arr }, r_at) == 2))
                                && !vala_type ((CType) r_at, false).contains ("[,]")) {
                                int rfid = fe_counter++;
                                string rlim_v = @"_c2v_felim_$rfid";
                                string rel_v = @"_c2v_fe_$rfid";
                                string rarr_s = esc_ident ((!) r_arr);
                                string rbound_s = emit_expr (((ExprBinary) idr.init).left);
                                indent (sb, level);
                                sb.append ("{\n");
                                indent (sb, level + 1);
                                sb.append (@"int $rlim_v = (int) ($rbound_s);\n");
                                indent (sb, level + 1);
                                sb.append (@"if ($rarr_s != null && $rlim_v > $rarr_s.length) $rlim_v = $rarr_s.length;\n");
                                indent (sb, level + 1);
                                sb.append (@"if ($rarr_s != null && $rlim_v > 0) inverse_foreach (unowned var $rel_v in $rarr_s[0:$rlim_v]) {\n");
                                cur_fe_arr = r_arr;
                                cur_fe_idx = idr.name;
                                cur_fe_elem = rel_v;
                                emit_stmt (sb, fs.body, level + 2);
                                cur_fe_arr = null;
                                cur_fe_idx = null;
                                cur_fe_elem = null;
                                indent (sb, level + 1);
                                sb.append ("}\n");
                                indent (sb, level);
                                sb.append ("}\n");
                                return true;
                            }
                        }
                    }
                }
            }
            string? idx_name = null;
            if (fs.init_decl is StmtDecl) {
                var id = (StmtDecl) fs.init_decl;
                if (id.init is ExprInt && ((ExprInt) id.init).val == 0)
                    idx_name = id.name;
            } else if (fs.init_decl == null && fs.init_expr is ExprAssign) {
                var ia = (ExprAssign) fs.init_expr;
                if (ia.op == "=" && ia.lvalue is ExprIdent && ia.rvalue is ExprInt && ((ExprInt) ia.rvalue).val == 0)
                    idx_name = ((ExprIdent) ia.lvalue).name;
            }
            if (idx_name == null)
                return false;
            if (!(fs.cond is ExprBinary))
                return false;
            var cb = (ExprBinary) fs.cond;
            if (cb.op != "<" || !(cb.left is ExprIdent) || ((ExprIdent) cb.left).name != (!) idx_name)
                return false;
            bool next_ok = false;
            if (fs.next is ExprUnary) {
                var eu = (ExprUnary) fs.next;
                next_ok = ((eu.op == "++" || eu.op == "post++") && eu.operand is ExprIdent && ((ExprIdent) eu.operand).name == (!) idx_name);
            }
            if (!next_ok)
                return false;
            string? arr_name = null;
            if (!stmt_only_uses_idx_on_arr (fs.body, (!) idx_name, ref arr_name) || arr_name == null)
                return false;
            var ali = find_local (cur_locals, (!) arr_name);
            if (ali != null && ali.has_ptr_arith)
                return false;
            var at = infer_type (new ExprIdent () { name = (!) arr_name });
            if (at == null || (at.kind != CTypeKind.ARRAY && !(at.kind == CTypeKind.PTR && ptr_view (new ExprIdent () { name = (!) arr_name }, at) == 2)))
                return false;
            string vt = vala_type ((CType) at, false);
            if (vt.contains ("[,]"))
                return false;
            int fid = fe_counter++;
            string lim_v = @"_c2v_felim_$fid";
            string el_v = @"_c2v_fe_$fid";
            string arr_s = esc_ident ((!) arr_name);
            string bound_s = emit_expr (cb.right);
            indent (sb, level);
            sb.append ("{\n");
            indent (sb, level + 1);
            sb.append (@"int $lim_v = (int) ($bound_s);\n");
            indent (sb, level + 1);
            sb.append (@"if ($arr_s != null && $lim_v > $arr_s.length) $lim_v = $arr_s.length;\n");
            indent (sb, level + 1);
            sb.append (@"if ($arr_s != null && $lim_v > 0) foreach (unowned var $el_v in $arr_s[0:$lim_v]) {\n");
            cur_fe_arr = arr_name;
            cur_fe_idx = idx_name;
            cur_fe_elem = el_v;
            emit_stmt (sb, fs.body, level + 2);
            cur_fe_arr = null;
            cur_fe_idx = null;
            cur_fe_elem = null;
            indent (sb, level + 1);
            sb.append ("}\n");
            indent (sb, level);
            sb.append ("}\n");
            return true;
        }

        private int sw_counter = 0;
        private string? cur_sw_cont_flag = null;
        private CExpr? cur_loop_multi_next = null;

        private void emit_continue_with_multi (StrBuilder sb, int level) throws RefuseError {
            if (cur_loop_multi_next != null) {
                indent (sb, level);
                sb.append ("{\n");
                emit_comma_stmts (sb, (CExpr) cur_loop_multi_next, level + 1);
                indent (sb, level + 1);
                sb.append ("continue;\n");
                indent (sb, level);
                sb.append ("}\n");
            } else {
                indent (sb, level);
                sb.append ("continue;\n");
            }
        }

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
                    if (sc.is_default) {
                        sb.append ("default:\n");
                    } else {
                        string ce = emit_expr ((CExpr) sc.expr);
                        sb.append (@"case $ce:\n");
                    }
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
                    string ce = emit_expr ((CExpr) sw.cases[ci].expr);
                    grp_cond.append (@" || $sw_var == $ce");
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
                            string ke = emit_expr ((CExpr) sw.cases[k].expr);
                            neg.append (@"$sw_var != $ke");
                            ncase++;
                        }
                    }
                    if (ncase > 0)
                        grp_cond.append (@" || ($(neg.str))");
                    else
                        grp_cond = new StrBuilder ("true");
                } else {
                    string sce = emit_expr ((CExpr) sc.expr);
                    grp_cond.append (@" || $sw_var == $sce");
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
                if (cur_loop_multi_next != null) {
                    indent (sb, level);
                    sb.append (@"if ($cont_var) {\n");
                    emit_comma_stmts (sb, (CExpr) cur_loop_multi_next, level + 1);
                    indent (sb, level + 1);
                    sb.append ("continue;\n");
                    indent (sb, level);
                    sb.append ("}\n");
                } else {
                    indent (sb, level);
                    sb.append (@"if ($cont_var) continue;\n");
                }
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
                if (b.op == "-" && lt != null && rt != null
                    && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)
                    && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY))
                    return CType.scalar ("int64");
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
                    if (ot != null && ot.kind == CTypeKind.FUNC_PTR)
                        return ot;
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
                        || fn == "strcasecmp" || fn == "strncasecmp" || fn == "abs" || fn == "system"
                        || fn == "isnan" || fn == "isfinite" || fn == "isinf"
                        || fn == "printf" || fn == "fprintf"
                        || fn == "__builtin_ctz" || fn == "__builtin_ctzll"
                        || fn == "__builtin_clz" || fn == "__builtin_clzll"
                        || fn == "__builtin_popcount" || fn == "__builtin_popcountll")
                        return CType.scalar ("int");
                    if (fn == "labs" || fn == "llabs")
                        return CType.scalar ("int64");
                    if (fn == "atof")
                        return CType.scalar ("double");
                    if (fn == "strdup" || fn == "strstr" || fn == "strchr" || fn == "strrchr") {
                        var cp = new CType (CTypeKind.PTR, "");
                        cp.inner = CType.scalar ("char");
                        return cp;
                    }
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
            if (t != null && (t.kind == CTypeKind.PTR || t.kind == CTypeKind.FUNC_PTR)) {
                if (t.kind == CTypeKind.PTR && ptr_view (e, (CType) t) == 2 && (e is ExprIdent || e is ExprMember))
                    return @"($s != null && $s.length > 0)";
                return @"($s != null)";
            }
            return @"($s != 0)";
        }

        // Vala requires an assignment's right-hand side to have exactly the
        // target's type; C converts implicitly. Insert the cast C leaves out.
        private string coerce_value (CExpr value, string? target) throws RefuseError {
            string rt = emit_expr (value);
            if (target == null)
                return rt;
            var vt = infer_type (value);
            if (vt == null)
                return rt;
            if (vt.kind == CTypeKind.ENUM) {
                string ev = vala_type (vt, false);
                if (ev == target)
                    return rt;
                return @"($target) $(wrap_operand (rt))";
            }
            if (vt.kind != CTypeKind.SCALAR) {
                if (target == "bool" && (vt.kind == CTypeKind.PTR || vt.kind == CTypeKind.FUNC_PTR))
                    return emit_cond (value);
                return rt;
            }
            if (target == "bool") {
                if (vt.name == "bool")
                    return rt;
                return emit_cond (value);
            }
            if (vt.name == "bool")
                return @"($target) ($(wrap_operand (rt)) ? 1 : 0)";
            if (vt.name == target) {
                // C's char is a byte and a `char *` buffer is a Vala `uint8[]`,
                // so reading an element into a Vala `char` needs the narrowing
                // cast valac insists on; planc treats both as the same width.
                if (target == "char" && is_byte_element_read (value))
                    return @"(char) $(wrap_operand (rt))";
                return rt;
            }
            return @"($target) $(wrap_operand (rt))";
        }

        private bool is_byte_element_read (CExpr e) throws RefuseError {
            if (!(e is ExprIndex))
                return false;
            var arr_t = infer_type (((ExprIndex) e).array);
            if (arr_t == null || arr_t.inner == null)
                return false;
            if (arr_t.kind != CTypeKind.PTR && arr_t.kind != CTypeKind.ARRAY)
                return false;
            var inn_t = (CType) arr_t.inner;
            return inn_t.kind == CTypeKind.SCALAR
                && (inn_t.is_scalar ("char") || inn_t.is_scalar ("uint8") || inn_t.is_scalar ("uchar"));
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

        private string ptr_null_value (CType? target) throws RefuseError {
            if (target != null && target.kind == CTypeKind.PTR && target.is_char_ptr ()) {
                string vt = vala_type (target, false);
                if (!vt.has_suffix ("[]?"))
                    return "\"\"";
            }
            return "null";
        }

        // Vala view of a pointer-typed expression: 0 = not a pointer,
        // 1 = `string` (char * that is never indexed/offset), 2 = array.
        private int ptr_view (CExpr e, CType? ct) throws RefuseError {
            if (ct == null || ct.inner == null)
                return 0;
            if (ct.kind == CTypeKind.ARRAY)
                return 2;
            if (ct.kind != CTypeKind.PTR)
                return 0;
            if (e is ExprIdent) {
                var li = find_local (cur_locals, ((ExprIdent) e).name);
                if (li != null && li.is_array)
                    return 2;
            }
            // Any scalar pointer other than `char *` (e.g. `void *`, `uint8 *`,
            // `int *`) is always emitted as a Vala array `T[]` (view 2).
            var ct_inner = (CType) ct.inner;
            if (ct_inner.kind == CTypeKind.SCALAR && !ct_inner.is_scalar ("char"))
                return 2;
            if (is_alloc_call (e))
                return 2;
            if (e is ExprCast) {
                var ce = (ExprCast) e;
                if (ce.target_type.is_char_ptr ())
                    return 1;
                if (ce.target_type.kind == CTypeKind.PTR && ce.target_type.inner != null
                    && !is_scalar_ptr_type (ce.target_type)) {
                    var inner_ct = (CType) ce.target_type.inner;
                    if ((inner_ct.kind == CTypeKind.STRUCT || inner_ct.kind == CTypeKind.UNION)
                        && byte_cast_struct_map.get_index (inner_ct.name) >= 0) {
                        var bsd = find_struct (inner_ct.name);
                        if (bsd != null && bsd.fields.length > 0)
                            return 1;
                    }
                }
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
                if ((tinner.is_scalar ("void") || tinner.is_scalar ("char"))
                    && vt != null && vt.is_char_ptr ())
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
                    if (vt != null && (vt.is_void_ptr () || vt.is_char_ptr () || is_byte_or_char_ptr (vt))
                        && byte_cast_struct_map.get_index (tinner2.name) >= 0) {
                        var bsd = find_struct (tinner2.name);
                        if (bsd != null && bsd.fields.length > 0)
                            return @"new $uvt.at ($rt, 0)";
                    }
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
                if (tt != null && (tt.kind == CTypeKind.PTR || tt.kind == CTypeKind.FUNC_PTR)) {
                    if (is_null_ptr_expr (value))
                        return ptr_null_value (tt);
                    if (tt.kind == CTypeKind.PTR)
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
            lh.name = @"_c2v_lit_$(esc_ident (ct.name))_$(fnv1a_hex (key))";
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
            var lit_names = new GenericArray<string> ();
            for (int hi = 0; hi < lit_helpers.length; hi++)
                lit_names.add (lit_helpers[hi].name);
            int[] ord = sorted_order (lit_names);
            for (int hi_i = 0; hi_i < ord.length; hi_i++) {
                var lh = lit_helpers[ord[hi_i]];
                string vt = vala_type (lh.ctype, false);
                sb.append (@"private static $vt $(lh.name) (");
                for (int i = 0; i < lh.fields.length; i++) {
                    if (i > 0) sb.append (", ");
                    sb.append (@"$(lh.vtypes[i]) _c2v_a$i");
                }
                sb.append (") {\n");
                StructDef? hsd = find_struct (lh.ctype.name);
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
                else if (ftype != null && (ftype.kind == CTypeKind.PTR || ftype.kind == CTypeKind.FUNC_PTR) && is_null_ptr_expr (il.items[i]))
                    val_s = ptr_null_value (ftype);
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
            if (!(s.has_prefix ("0x") || s.has_prefix ("0X"))) {
                if (s.has_prefix ("."))
                    return "0" + s;
                return s;
            }
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

        private string emit_sizeof_ctype (CType ct) throws RefuseError {
            if (ct.kind == CTypeKind.SCALAR) {
                if (ct.is_scalar ("void"))
                    return "0";
                // C's sizeof, not planc's slot-based sizeof: planc reports one
                // 8-byte slot for every scalar, so `9 * sizeof(char)` would be
                // 72 instead of 9 and overflow the target array.
                return @"$(type_size_bytes (ct))";
            }
            if (ct.kind == CTypeKind.ENUM)
                return "4";
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null) {
                string esz = emit_sizeof_ctype ((CType) ct.inner);
                if (ct.array_len != null) {
                    string al = emit_expr ((CExpr) ct.array_len);
                    return @"((int) ($al) * (int) ($esz))";
                }
                return esz;
            }
            return @"$(type_size_bytes (ct))";
        }

        private int64 type_align_bytes (CType ct, int depth = 0) {
            if (depth > 16)
                return 8;
            if (ct.kind == CTypeKind.SCALAR) {
                if (ct.name == "bool" || ct.name == "char" || ct.name == "uchar" || ct.name == "int8" || ct.name == "uint8")
                    return 1;
                if (ct.name == "short" || ct.name == "ushort" || ct.name == "int16" || ct.name == "uint16")
                    return 2;
                if (ct.name == "int" || ct.name == "uint" || ct.name == "unsigned" || ct.name == "int32" || ct.name == "uint32" || ct.name == "float")
                    return 4;
                return 8;
            }
            if (ct.kind == CTypeKind.ENUM)
                return 4;
            if (ct.kind == CTypeKind.PTR || ct.kind == CTypeKind.FUNC_PTR)
                return 8;
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null)
                return type_align_bytes ((CType) ct.inner, depth + 1);
            if (ct.kind == CTypeKind.STRUCT || ct.kind == CTypeKind.UNION) {
                var sd = find_struct (ct.name);
                if (sd == null)
                    return 8;
                int64 max_a = 1;
                for (int i = 0; i < sd.fields.length; i++) {
                    int64 fa = type_align_bytes (sd.fields[i].ctype, depth + 1);
                    if (fa > max_a) max_a = fa;
                }
                return max_a;
            }
            return 8;
        }

        private int64 type_size_bytes (CType ct, int depth = 0) {
            if (depth > 16)
                return 8;
            if (ct.kind == CTypeKind.SCALAR) {
                if (ct.name == "bool" || ct.name == "char" || ct.name == "uchar" || ct.name == "int8" || ct.name == "uint8")
                    return 1;
                if (ct.name == "short" || ct.name == "ushort" || ct.name == "int16" || ct.name == "uint16")
                    return 2;
                if (ct.name == "int" || ct.name == "uint" || ct.name == "unsigned" || ct.name == "int32" || ct.name == "uint32" || ct.name == "float")
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
                int64 max_a = 1;
                for (int i = 0; i < sd.fields.length; i++) {
                    int64 fsz = type_size_bytes (sd.fields[i].ctype, depth + 1);
                    int64 fa = type_align_bytes (sd.fields[i].ctype, depth + 1);
                    if (fa > max_a) max_a = fa;
                    if (ct.kind == CTypeKind.UNION) {
                        if (fsz > total) total = fsz;
                    } else {
                        if (fa > 1 && (total % fa) != 0)
                            total += fa - (total % fa);
                        total += fsz;
                    }
                }
                if (max_a > 1 && (total % max_a) != 0)
                    total += max_a - (total % max_a);
                return total > 0 ? total : 8;
            }
            return 8;
        }

        private static bool is_byte_or_char_ptr (CType? ct) {
            if (ct == null)
                return false;
            if ((ct.kind == CTypeKind.PTR || ct.kind == CTypeKind.ARRAY) && ct.inner != null) {
                var inn = (CType) ct.inner;
                return inn.is_scalar ("char") || inn.is_scalar ("uint8")
                    || inn.is_scalar ("uchar") || inn.is_scalar ("void");
            }
            return false;
        }

        private string emit_byte_ptr_diff (CExpr ul, CType lt, CExpr ur, CType rt) throws RefuseError {
            if (ul is ExprIdent && ur is ExprIdent) {
                string ln = ((ExprIdent) ul).name;
                string rn = ((ExprIdent) ur).name;
                var lli = find_local (cur_locals, ln);
                var rli = find_local (cur_locals, rn);
                if ((lli != null && lli.has_ptr_arith) || (rli != null && rli.has_ptr_arith)) {
                    string lo = (lli != null && lli.has_ptr_arith) ? @"_off_$ln" : "0";
                    string ro = (rli != null && rli.has_ptr_arith) ? @"_off_$rn" : "0";
                    return @"($lo - $ro)";
                }
            }
            if (ul is ExprUnary && ((ExprUnary) ul).op == "&" && ((ExprUnary) ul).operand is ExprIndex) {
                var ix = (ExprIndex) ((ExprUnary) ul).operand;
                if (ix.array is ExprIdent && ur is ExprIdent) {
                    string an = ((ExprIdent) ix.array).name;
                    string rn = ((ExprIdent) ur).name;
                    var ali = find_local (cur_locals, an);
                    var rli = find_local (cur_locals, rn);
                    if ((ali != null && ali.has_ptr_arith) || (rli != null && rli.has_ptr_arith)) {
                        string ao = (ali != null && ali.has_ptr_arith) ? @"_off_$an" : "0";
                        string ro = (rli != null && rli.has_ptr_arith) ? @"_off_$rn" : "0";
                        return @"(($ao + (int) ($(emit_expr (ix.index)))) - $ro)";
                    }
                }
                string arr_s = emit_expr (ix.array);
                string ur_s = emit_expr (ur);
                return @"(($(wrap_operand (ur_s))).length - (($(wrap_operand (arr_s))).length - (int) ($(emit_expr (ix.index)))))";
            }
            string ls = emit_expr (ul);
            string rs = emit_expr (ur);
            return @"(($(wrap_operand (rs))).length - ($(wrap_operand (ls))).length)";
        }

        // Parenthesizes an operand when it is not a bare name or number so
        // member access (`.length`, `.data`) and casts preserve precedence.
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

        private string emit_native_ptr_addr (ExprUnary u) throws RefuseError {
            var op = u.operand;
            if (op is ExprMember) {
                var m = (ExprMember) op;
                return @"&($(emit_expr (m.obj)).$(esc_ident (m.field)))";
            }
            if (op is ExprIndex) {
                var ix = (ExprIndex) op;
                return @"&($(emit_expr (ix.array))[(int) ($(emit_expr (ix.index)))])";
            }
            return @"&($(emit_expr (op)))";
        }

        private string emit_field_ref_addr (ExprUnary u, string fcls, string fvt) throws RefuseError {
            var op = u.operand;
            if (op is ExprMember) {
                var m = (ExprMember) op;
                if (m.obj is ExprUnary && ((ExprUnary) m.obj).op == "*"
                    && ((ExprUnary) m.obj).operand is ExprIdent) {
                    string pn = ((ExprIdent) ((ExprUnary) m.obj).operand).name;
                    var pli = find_local (cur_locals, pn);
                    if (pli != null && pli.is_field_ref) {
                        string step_fn = ensure_field_ref_step (fcls, fvt, m.field);
                        return @"$step_fn ($(esc_ident (pn)))";
                    }
                }
                string obj_s = emit_expr (m.obj);
                string fld_s = esc_ident (m.field);
                return @"new $fcls (() => { return $obj_s.$fld_s; }, (v) => { $obj_s.$fld_s = v; })";
            }
            if (op is ExprIndex) {
                var ix = (ExprIndex) op;
                return @"new $fcls.at_idx ($(emit_expr (ix.array)), (int) ($(emit_expr (ix.index))))";
            }
            string id_s = emit_expr (op);
            return @"new $fcls (() => { return $id_s; }, (v) => { $id_s = v; })";
        }

        // `string.replace` is a GLib 2.68+ API that planc does not provide.
        private static string replace_all (string s, string from, string to) {
            if (from == "" || s.index_of (from, 0) < 0)
                return s;
            var rsb = new StrBuilder ();
            int i = 0;
            while (true) {
                int j = s.index_of (from, i);
                if (j < 0) {
                    rsb.append (s.substring (i));
                    break;
                }
                rsb.append (s.substring (i, j - i));
                rsb.append (to);
                i = j + from.length;
            }
            return rsb.str;
        }

        // True for an inline scalar array field of a struct, which gets the
        // single-element accessors emitted above.
        private bool is_inline_scalar_array_field (StructDef sd, string fname) throws RefuseError {
            for (int i = 0; i < sd.fields.length; i++) {
                var f = sd.fields[i];
                if (f.name == "" || esc_ident (f.name) != fname)
                    continue;
                if (f.ctype.kind != CTypeKind.ARRAY || f.ctype.inner == null)
                    return false;
                string ev = vala_type ((CType) f.ctype.inner, false);
                if (ev.has_suffix ("[]") || ev.has_suffix ("?"))
                    return false;
                return union_scalar_bytes (ev) > 0;
            }
            return false;
        }

        // `p->field[i]` on an inline array of a byte view: read the buffer, do
        // not build the whole array.
        private string? inline_array_read (CExpr array, CExpr index) throws RefuseError {
            if (!(array is ExprMember))
                return null;
            var im = (ExprMember) array;
            if (!im.is_arrow)
                return null;
            var omt = infer_type (im.obj);
            var ome = (omt != null && omt.kind == CTypeKind.PTR && omt.inner != null) ? (CType) omt.inner : omt;
            if (ome == null || (ome.kind != CTypeKind.STRUCT && ome.kind != CTypeKind.UNION))
                return null;
            if (byte_cast_struct_map.get_index (ome.name) < 0)
                return null;
            var osd = find_struct (ome.name);
            if (osd == null)
                return null;
            string of = esc_ident (im.field);
            if (!is_inline_scalar_array_field (osd, of))
                return null;
            // An offset tracked for the base local is not part of the view.
            if (im.obj is ExprIdent) {
                var oli = find_local (cur_locals, ((ExprIdent) im.obj).name);
                if (oli != null && oli.has_ptr_arith)
                    return null;
            }
            string obj_s = emit_expr (im.obj);
            return @"$obj_s.$(of)_at ((int) ($(emit_expr (index))))";
        }

        // `p->field[i] = v` (and `op=`) on an inline array of a byte view:
        // store straight into the buffer instead of building the array.
        private string? inline_array_write (ExprIndex ix, CExpr value, string op = "=") throws RefuseError {
            if (!(ix.array is ExprMember))
                return null;
            var im = (ExprMember) ix.array;
            if (!im.is_arrow)
                return null;
            var omt = infer_type (im.obj);
            var ome = (omt != null && omt.kind == CTypeKind.PTR && omt.inner != null) ? (CType) omt.inner : omt;
            if (ome == null || (ome.kind != CTypeKind.STRUCT && ome.kind != CTypeKind.UNION))
                return null;
            if (byte_cast_struct_map.get_index (ome.name) < 0)
                return null;
            var osd = find_struct (ome.name);
            if (osd == null)
                return null;
            string of = esc_ident (im.field);
            if (!is_inline_scalar_array_field (osd, of))
                return null;
            if (im.obj is ExprIdent) {
                var oli = find_local (cur_locals, ((ExprIdent) im.obj).name);
                if (oli != null && oli.has_ptr_arith)
                    return null;
            }
            string obj_s = emit_expr (im.obj);
            string idx_s = @"(int) ($(emit_expr (ix.index)))";
            if (op != "=") {
                string bin = op.substring (0, op.length - 1);
                return @"$obj_s.$(of)_set ($idx_s, $obj_s.$(of)_at ($idx_s) $bin ($(emit_expr (value))))";
            }
            return @"$obj_s.$(of)_set ($idx_s, $(emit_expr (value)))";
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
                    if (li.static_global_name != null)
                        return li.static_global_name;
                    if (li.has_addr_taken) {
                        if (li.ctype.kind == CTypeKind.PTR && vala_type (li.ctype, false).has_suffix ("[]"))
                            return @"$(esc_ident (nm)).val";
                        return @"$(esc_ident (nm))[0]";
                    }
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
                int pconst = map_posix_const (nm);
                if (pconst >= 0)
                    return @"$pconst";
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
                    return "null";
                }
                if (c.target_type.kind == CTypeKind.FUNC_PTR && c.expr is ExprIdent) {
                    string fnm = ((ExprIdent) c.expr).name;
                    if (find_sig (fnm) != null)
                        return esc_ident (fnm);
                }
                string vt = vala_type (c.target_type, false);
                if (vt.has_suffix ("[]") || vt.has_suffix ("[]?")) {
                    var cit = infer_type (c.expr);
                    if (cit != null && cit.is_char_ptr () && ptr_view (c.expr, cit) == 1
                        && c.target_type.kind == CTypeKind.PTR && c.target_type.inner != null
                        && (c.target_type.is_void_ptr () || c.target_type.inner.is_scalar ("uint8")
                            || c.target_type.inner.is_scalar ("uchar")))
                        return @"c_str_to_bytes ($(emit_expr (c.expr)))";
                    return emit_expr (c.expr);
                }
                if (vt == "string") {
                    string inner_c = emit_expr (c.expr);
                    var ict = infer_type (c.expr);
                    if (ict != null && (ict.kind == CTypeKind.ARRAY
                        || (ict.kind == CTypeKind.PTR && ptr_view (c.expr, ict) == 2))) {
                        if (c.expr is ExprIdent) {
                            var pli = find_local (cur_locals, ((ExprIdent) c.expr).name);
                            if (pli != null && pli.has_ptr_arith)
                                return @"(string) c_bytes_add ($inner_c, _off_$(pli.name))";
                        }
                        return @"(string) $inner_c";
                    }
                    return inner_c;
                }
                var src_t = infer_type (c.expr);
                int src_view = (src_t != null) ? ptr_view (c.expr, src_t) : 0;
                bool src_is_bytes = (src_view == 2)
                    || (src_t != null && src_t.kind == CTypeKind.ARRAY && src_t.inner != null
                        && (src_t.inner.is_scalar ("char") || src_t.inner.is_scalar ("uint8")
                            || src_t.inner.is_scalar ("uchar") || src_t.inner.is_scalar ("void")));
                bool tgt_class = (c.target_type.kind == CTypeKind.PTR
                    || c.target_type.kind == CTypeKind.FUNC_PTR);
                if (tgt_class && src_is_bytes && !is_scalar_ptr_type (c.target_type)) {
                    if (c.target_type.kind == CTypeKind.PTR && c.target_type.inner != null) {
                        var inner_ct = (CType) c.target_type.inner;
                        if ((inner_ct.kind == CTypeKind.STRUCT || inner_ct.kind == CTypeKind.UNION)
                            && byte_cast_struct_map.get_index (inner_ct.name) >= 0) {
                            var bsd = find_struct (inner_ct.name);
                            if (bsd != null && bsd.fields.length > 0) {
                                // Rebase a byte view instead of slicing the
                                // buffer: `(post_t *)((byte *)column + n)`.
                                string bv_buf;
                                string bv_off;
                                if (byte_view_base (c.expr, out bv_buf, out bv_off))
                                    return @"new $(esc_ident (bsd.name)).at ($bv_buf, $bv_off)";
                                if (c.expr is ExprBinary) {
                                    var cb = (ExprBinary) c.expr;
                                    if (cb.op == "+" || cb.op == "-") {
                                        string base_off = "";
                                        if (cb.left is ExprIdent) {
                                            var pli = find_local (cur_locals, ((ExprIdent) cb.left).name);
                                            if (pli != null && pli.has_ptr_arith)
                                                base_off = @"_off_$(pli.name) $(cb.op) ";
                                        }
                                        if (base_off != "")
                                            return @"new $(esc_ident (bsd.name)).at ($(emit_expr (cb.left)), $base_off(int) ($(emit_expr (cb.right))))";
                                        string sign_s = (cb.op == "-") ? "-" : "";
                                        return @"new $(esc_ident (bsd.name)).at ($(emit_expr (cb.left)), $sign_s(int) ($(emit_expr (cb.right))))";
                                    }
                                }
                                if (c.expr is ExprIdent) {
                                    var pli = find_local (cur_locals, ((ExprIdent) c.expr).name);
                                    if (pli != null && pli.has_ptr_arith)
                                        return @"new $(esc_ident (bsd.name)).at ($(emit_expr (c.expr)), _off_$(pli.name))";
                                }
                                return @"new $(esc_ident (bsd.name)).at ($(emit_expr (c.expr)), 0)";
                            }
                        }
                    }
                    refuse_loc (e.file, e.line,
                        "cast from a byte buffer to an object pointer needs a manual port");
                }
                bool is_ptr_diff = (c.expr is ExprBinary && ((ExprBinary) c.expr).op == "-");
                if (is_ptr_diff) {
                    var dt2 = infer_type (((ExprBinary) c.expr).right);
                    if (dt2 == null || dt2.kind != CTypeKind.PTR)
                        is_ptr_diff = false;
                }
                bool tgt_is_int_ptr = (vt == "uint64" || vt == "int64" || vt == "size_t" || vt == "ssize_t"
                    || vt == "ulong" || vt == "long" || vt == "uint" || vt == "int"
                    || vt == "uintptr" || vt == "uintptr_t" || vt == "intptr_t");
                bool src_is_byte_ptr_or_arr = (src_t != null && (src_t.is_void_ptr ()
                    || (src_t.is_char_ptr () && src_view == 2)
                    || ((src_t.kind == CTypeKind.ARRAY || src_t.kind == CTypeKind.PTR) && src_t.inner != null
                        && (src_t.inner.is_scalar ("char") || src_t.inner.is_scalar ("uint8") || src_t.inner.is_scalar ("uchar")))));
                if (!is_ptr_diff && (src_is_bytes || src_is_byte_ptr_or_arr) && c.target_type.kind == CTypeKind.SCALAR && tgt_is_int_ptr
                    && src_is_byte_ptr_or_arr) {
                    string ptr_s = @"c_ptr_u64 ($(emit_expr (c.expr)))";
                    if (c.expr is ExprIdent) {
                        var pli = find_local (cur_locals, ((ExprIdent) c.expr).name);
                        if (pli != null && pli.has_ptr_arith)
                            ptr_s = @"($ptr_s + (uint64) _off_$(pli.name))";
                    }
                    return (vt == "uint64") ? ptr_s : @"(($vt) $ptr_s)";
                }
                if (!is_ptr_diff && src_t != null && src_t.is_struct_ptr () && ptr_view (c.expr, src_t) == 1
                    && c.target_type.kind == CTypeKind.SCALAR && tgt_is_int_ptr) {
                    string ptr_s = @"uintptr.from_pointer ((void*) $(emit_expr (c.expr)))";
                    return (vt == "uint64") ? @"(uint64) $ptr_s" : @"(($vt) $ptr_s)";
                }
                if (c.target_type.is_scalar ("bool"))
                    return emit_cond (c.expr);
                // Unwrap redundant identical nested casts: `(T) ((T) x)` -> `(T) x`.
                CExpr inner_expr = c.expr;
                while (inner_expr is ExprCast && vala_type (((ExprCast) inner_expr).target_type, false) == vt)
                    inner_expr = ((ExprCast) inner_expr).expr;
                var inner_t = infer_type (inner_expr);
                if (inner_t != null && inner_t.is_scalar ("bool") && c.target_type.kind == CTypeKind.SCALAR) {
                    string cond_s = wrap_operand (emit_expr (inner_expr));
                    return (vt == "int") ? @"($cond_s ? 1 : 0)" : @"(($vt) ($cond_s ? 1 : 0))";
                }
                if (inner_t != null && !(inner_expr is ExprInt) && !(inner_expr is ExprChar)
                    && inner_t.kind == CTypeKind.SCALAR && c.target_type.kind == CTypeKind.SCALAR
                    && vala_type (inner_t, false) == vt
                    && !(vt == "char" && is_byte_element_read (inner_expr)))
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
                return emit_sizeof_ctype (((ExprSizeofType) e).target_type);
            }
            if (e is ExprSizeofExpr) {
                var se = (ExprSizeofExpr) e;
                var it = infer_type (se.expr);
                if (it != null) {
                    if (it.kind == CTypeKind.ARRAY && it.inner != null) {
                        string esz = emit_sizeof_ctype ((CType) it.inner);
                        if (it.array_len != null) {
                            string al = emit_expr ((CExpr) it.array_len);
                            return @"((int) ($al) * (int) ($esz))";
                        }
                        string arr_s = wrap_operand (emit_expr (se.expr));
                        // An array of arrays is 2-dimensional in Vala, so its
                        // outermost length needs an explicit dimension.
                        string lsel = vala_type ((CType) it.inner, false).has_suffix ("[]")
                            ? ".length[0]" : ".length";
                        return @"($arr_s$lsel * (int) ($esz))";
                    }
                    return emit_sizeof_ctype (it);
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
                        if (cur_allow_out_ref && cur_in_call_arg && ot != null
                            && (ot.kind == CTypeKind.SCALAR || ot.kind == CTypeKind.ENUM
                                || ot.kind == CTypeKind.PTR)) {
                            LocalInfo? oli = (u.operand is ExprIdent)
                                ? find_local (cur_locals, ((ExprIdent) u.operand).name) : null;
                            bool is_mem_glob_or_local = (u.operand is ExprMember)
                                || (u.operand is ExprIdent
                                    && ((oli != null && !oli.has_addr_taken)
                                        || (oli == null && global_map.get_index (((ExprIdent) u.operand).name) >= 0)));
                            if (is_mem_glob_or_local) {
                                bool as_arr = (oli != null && oli.is_array);
                                string rvt = vala_type (ot, as_arr);
                                string lval_s = emit_expr (u.operand);
                                string init_s = lval_s;
                                if (oli != null && oli.has_ptr_arith && rvt.has_suffix ("[]"))
                                    init_s = @"($lval_s != null ? $(lval_s)[_off_$(oli.name):$(lval_s).length] : null)";
                                string rtmp = @"_c2v_ref_$(out_ref_id++)";
                                if (rvt.has_suffix ("[]")) {
                                    string abcls = ensure_arr_box_helper (rvt);
                                    if (oli != null && oli.has_ptr_arith) {
                                        string orig = @"_c2v_orig_$(out_ref_id++)";
                                        out_ref_decls.add (@"$abcls $rtmp = new $abcls ($init_s);");
                                        out_ref_decls.add (@"unowned $rvt $orig = $rtmp.val;");
                                        out_ref_writebacks.add (@"if ($rtmp.val != $orig) { $lval_s = $rtmp.val; _off_$(oli.name) = 0; }");
                                    } else {
                                        out_ref_decls.add (@"$abcls $rtmp = new $abcls ($init_s);");
                                        out_ref_writebacks.add (@"$lval_s = $rtmp.val;");
                                    }
                                } else {
                                    out_ref_decls.add (@"$rvt[] $rtmp = { $init_s };");
                                    out_ref_writebacks.add (@"$lval_s = $rtmp[0];");
                                }
                                return rtmp;
                            }
                        }
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
                        if (pb.op == "+" && pb.right is ExprIdent) {
                            var pbt = infer_type (pb.right);
                            if (pbt != null && (pbt.kind == CTypeKind.PTR || pbt.kind == CTypeKind.ARRAY)) {
                                string pnm = ((ExprIdent) pb.right).name;
                                var pli = find_local (cur_locals, pnm);
                                string off_p = (pli != null && pli.has_ptr_arith) ? @"_off_$pnm" : "0";
                                return @"$(esc_ident (pnm))[$off_p + (int) ($(emit_expr (pb.left)))]";
                            }
                        }
                    }
                    if (u.operand is ExprIdent) {
                        string pnm = ((ExprIdent) u.operand).name;
                        var pli = find_local (cur_locals, pnm);
                        if (pli != null && pli.is_native_ptr)
                            return @"(*$(esc_ident (pnm)))";
                        if (pli != null && pli.is_field_ref)
                            return @"((!) $(esc_ident (pnm))).get_val ()";
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
                    var uot = infer_type (u.operand);
                    if (uot != null && uot.kind == CTypeKind.PTR && uot.inner != null
                        && vala_type ((CType) uot.inner, false).has_suffix ("[]")) {
                        return @"$(wrap_operand (emit_expr (u.operand))).val";
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
                if (u.op == "~") {
                    var ut = infer_type (u.operand);
                    if (ut != null && ut.kind == CTypeKind.ENUM)
                        return @"(~(int) ($(op_s)))";
                }
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
                    string lc_s = emit_cond (b.left);
                    bool prev_aor_b = cur_allow_out_ref;
                    cur_allow_out_ref = false;
                    string rc_s = emit_cond (b.right);
                    cur_allow_out_ref = prev_aor_b;
                    return @"($lc_s $(b.op) $rc_s)";
                }
                if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)) {
                    CExpr ul = b.left;
                    while (ul is ExprCast) ul = ((ExprCast) ul).expr;
                    CExpr ur = b.right;
                    while (ur is ExprCast) ur = ((ExprCast) ur).expr;
                    if (b.op == "-" && rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)) {
                        if (ul is ExprIdent && ur is ExprIdent) {
                            string ln = ((ExprIdent) ul).name;
                            string rn = ((ExprIdent) ur).name;
                            var lli = find_local (cur_locals, ln);
                            var rli = find_local (cur_locals, rn);
                            string lo = (lli != null && lli.has_ptr_arith) ? @"_off_$ln" : "0";
                            string ro = (rli != null && rli.has_ptr_arith) ? @"_off_$rn" : "0";
                            return @"($lo - $ro)";
                        }
                        if (ul is ExprIdent) {
                            string ln = ((ExprIdent) ul).name;
                            var lli = find_local (cur_locals, ln);
                            if (lli != null && lli.has_ptr_arith)
                                return @"_off_$ln";
                        }
                        if (is_byte_or_char_ptr (lt) && is_byte_or_char_ptr (rt))
                            return emit_byte_ptr_diff (ul, lt, ur, rt);
                        if (vala_type (lt, ptr_view (ul, lt) == 2).has_suffix ("[]")
                            && vala_type (rt, ptr_view (ur, rt) == 2).has_suffix ("[]")) {
                            string ls = emit_expr (ul);
                            string rs = emit_expr (ur);
                            return @"(($(wrap_operand (rs))).length - ($(wrap_operand (ls))).length)";
                        }
                    }
                    if ((b.op == "+" || b.op == "-") && (rt == null || (rt.kind != CTypeKind.PTR && rt.kind != CTypeKind.ARRAY))) {
                        if (b.left is ExprBinary) {
                            var terms = new GenericArray<string> ();
                            CExpr cur_b = b;
                            while (cur_b is ExprBinary) {
                                var cb = (ExprBinary) cur_b;
                                if (cb.op != "+" && cb.op != "-")
                                    break;
                                var cblt = infer_type (cb.left);
                                if (cblt == null || (cblt.kind != CTypeKind.PTR && cblt.kind != CTypeKind.ARRAY))
                                    break;
                                string t_s = @"(int) ($(emit_expr (cb.right)))";
                                terms.add ((cb.op == "+") ? t_s : @"(-($t_s))");
                                cur_b = cb.left;
                            }
                            if (terms.length >= 2) {
                                var base_t = infer_type (cur_b);
                                if (base_t != null && (base_t.kind == CTypeKind.PTR || base_t.kind == CTypeKind.ARRAY)) {
                                    var off_sb = new StrBuilder ();
                                    if (cur_b is ExprIdent) {
                                        var bli = find_local (cur_locals, ((ExprIdent) cur_b).name);
                                        if (bli != null && bli.has_ptr_arith)
                                            off_sb.append (@"_off_$(bli.name) + ");
                                    }
                                    for (int ti = terms.length - 1; ti >= 0; ti--) {
                                        if (ti < terms.length - 1) off_sb.append (" + ");
                                        off_sb.append (terms[ti]);
                                    }
                                    string base_s = emit_expr (cur_b);
                                    string off_s = off_sb.str;
                                    if (base_t.is_char_ptr () && ptr_view (cur_b, base_t) == 1)
                                        return @"c_str_add ($base_s, $off_s)";
                                    if (base_t.is_void_ptr () || base_t.is_char_ptr ())
                                        return @"c_bytes_add ($base_s, $off_s)";
                                    if (base_t.inner != null && base_t.inner.kind != CTypeKind.ARRAY
                                        && (base_t.inner.kind != CTypeKind.PTR || !vala_type ((CType) base_t.inner, false).has_suffix ("[]"))) {
                                        string sh = ensure_slice_helper ((CType) base_t.inner);
                                        return @"$sh ($base_s, $off_s)";
                                    }
                                }
                            }
                        }
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
                            return @"new C2VPtr.from_bytes ($(emit_expr (b.left)), 0).add (-(int) ($(emit_expr (b.right)))).as_bytes ()";
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
                    if (rt.is_void_ptr () || rt.is_char_ptr ()) {
                        if (b.right is ExprIdent) {
                            string pnm = ((ExprIdent) b.right).name;
                            var pli = find_local (cur_locals, pnm);
                            if (pli != null && pli.has_ptr_arith)
                                return @"c_bytes_add ($(esc_ident (pnm)), _off_$pnm + (int) ($(emit_expr (b.left))))";
                        }
                        return @"c_bytes_add ($(emit_expr (b.right)), (int) ($(emit_expr (b.left))))";
                    }
                    if (rt.inner != null && rt.inner.kind != CTypeKind.ARRAY
                        && (rt.inner.kind != CTypeKind.PTR || !vala_type ((CType) rt.inner, false).has_suffix ("[]"))) {
                        string sh = ensure_slice_helper ((CType) rt.inner);
                        if (b.right is ExprIdent) {
                            string pnm = ((ExprIdent) b.right).name;
                            var pli = find_local (cur_locals, pnm);
                            if (pli != null && pli.has_ptr_arith)
                                return @"$sh ($(esc_ident (pnm)), _off_$pnm + (int) ($(emit_expr (b.left))))";
                        }
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
                    } else if (lt != null && rt != null
                               && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)
                               && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)) {
                        CExpr ul = b.left;
                        while (ul is ExprCast) ul = ((ExprCast) ul).expr;
                        CExpr ur = b.right;
                        while (ur is ExprCast) ur = ((ExprCast) ur).expr;
                        if (ul is ExprIdent && ur is ExprIdent) {
                            string ln = ((ExprIdent) ul).name;
                            string rn = ((ExprIdent) ur).name;
                            var lli = find_local (cur_locals, ln);
                            var rli = find_local (cur_locals, rn);
                            if ((lli != null && lli.has_ptr_arith) || (rli != null && rli.has_ptr_arith)) {
                                string lo = (lli != null && lli.has_ptr_arith) ? @"_off_$ln" : "0";
                                string ro = (rli != null && rli.has_ptr_arith) ? @"_off_$rn" : "0";
                                if (b.op == "==")
                                    return @"($ls == $rs && $lo == $ro)";
                                return @"($ls != $rs || $lo != $ro)";
                            }
                        }
                    }
                } else if ((b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">=")
                           && lt != null && rt != null
                           && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)
                           && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)) {
                    CExpr ul = b.left;
                    while (ul is ExprCast) ul = ((ExprCast) ul).expr;
                    CExpr ur = b.right;
                    while (ur is ExprCast) ur = ((ExprCast) ur).expr;
                    if (ul is ExprIdent && ur is ExprIdent) {
                        string ln = ((ExprIdent) ul).name;
                        string rn = ((ExprIdent) ur).name;
                        var lli = find_local (cur_locals, ln);
                        var rli = find_local (cur_locals, rn);
                        if ((lli != null && lli.has_ptr_arith) || (rli != null && rli.has_ptr_arith)) {
                            string lo = (lli != null && lli.has_ptr_arith) ? @"_off_$ln" : "0";
                            string ro = (rli != null && rli.has_ptr_arith) ? @"_off_$rn" : "0";
                            return @"($ls == $rs ? ($lo $(b.op) $ro) : (uintptr.from_pointer ((void*) ($ls)) $(b.op) uintptr.from_pointer ((void*) ($rs))))";
                        }
                    }
                    return @"(uintptr.from_pointer ((void*) ($ls)) $(b.op) uintptr.from_pointer ((void*) ($rs)))";
                }
                if (lt != null && rt != null && lt.kind == CTypeKind.SCALAR && rt.kind == CTypeKind.SCALAR) {
                    if (lt.name != rt.name && lt.name != "bool" && rt.name != "bool") {
                        string cm = common_scalar (lt.name, rt.name);
                        if (lt.name != cm) ls = @"(($cm) $ls)";
                        if (rt.name != cm) rs = @"(($cm) $rs)";
                    }
                } else if ((b.op == "<<" || b.op == ">>" || b.op == "&" || b.op == "|" || b.op == "^"
                            || b.op == "+" || b.op == "-" || b.op == "*" || b.op == "/" || b.op == "%"
                            || b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">="
                            || b.op == "==" || b.op == "!=")
                           && !(lt != null && rt != null && lt.kind == CTypeKind.ENUM && rt.kind == CTypeKind.ENUM && lt.name == rt.name)) {
                    if (lt != null && lt.kind == CTypeKind.ENUM)
                        ls = @"((int) $ls)";
                    if (rt != null && rt.kind == CTypeKind.ENUM)
                        rs = @"((int) $rs)";
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
                    if (li != null && li.is_native_ptr && a.op == "=" && a.rvalue is ExprUnary && ((ExprUnary) a.rvalue).op == "&" && li.ctype.inner != null) {
                        string npa = emit_native_ptr_addr ((ExprUnary) a.rvalue);
                        return @"$(esc_ident (li.name)) = $npa";
                    }
                    if (li != null && li.is_field_ref && a.op == "=" && a.rvalue is ExprUnary && ((ExprUnary) a.rvalue).op == "&" && li.ctype.inner != null) {
                        string fvt = vala_type ((CType) li.ctype.inner, false);
                        string fcls = ensure_field_ref_helper (fvt);
                        string fra = emit_field_ref_addr ((ExprUnary) a.rvalue, fcls, fvt);
                        return @"$(esc_ident (li.name)) = $fra";
                    }
                    if (li != null && is_alloc_call (a.rvalue)) {
                        string als = emit_alloc ((ExprCall) a.rvalue, li.ctype);
                        return @"$(esc_ident (li.name)) = $als";
                    }
                }
                if (a.op == "=" && a.lvalue is ExprUnary && ((ExprUnary) a.lvalue).op == "*" && ((ExprUnary) a.lvalue).operand is ExprIdent) {
                    var li = find_local (cur_locals, ((ExprIdent) ((ExprUnary) a.lvalue).operand).name);
                    if (li != null && li.is_native_ptr && li.ctype.inner != null) {
                        string cp = coerce_ptr (a.rvalue, (CType) li.ctype.inner, null, 1);
                        return @"*$(esc_ident (li.name)) = $cp";
                    }
                    if (li != null && li.is_field_ref && li.ctype.inner != null) {
                        string cp = coerce_ptr (a.rvalue, (CType) li.ctype.inner, null, 1);
                        return @"((!) $(esc_ident (li.name))).set_val ($cp)";
                    }
                }
                if (a.lvalue is ExprIndex && a.op.has_suffix ("=") && a.op != "=") {
                    string? iset_c = inline_array_write ((ExprIndex) a.lvalue, a.rvalue, a.op);
                    if (iset_c != null)
                        return iset_c;
                }
                if (a.op == "=") {
                    var lt = infer_type (a.lvalue);
                    var rt = infer_type (a.rvalue);
                    if (lt != null && rt != null && is_union_type (lt) && is_union_type (rt) && lt.name == rt.name)
                        return @"$(emit_expr (a.lvalue)).copy_from ($(emit_expr (a.rvalue)))";
                    if (a.lvalue is ExprIndex) {
                        string? iset = inline_array_write ((ExprIndex) a.lvalue, a.rvalue);
                        if (iset != null)
                            return iset;
                    }
                    return @"$(emit_expr (a.lvalue)) = $(coerce_assign (a.lvalue, a.rvalue))";
                }
                if (a.lvalue is ExprMember && a.op.has_suffix ("=")) {
                    var am = (ExprMember) a.lvalue;
                    var aot = infer_type (am.obj);
                    if (aot != null && (is_union_type (aot) || (aot.kind == CTypeKind.PTR && aot.inner != null && is_union_type ((CType) aot.inner)))) {
                        string bin_op = a.op.substring (0, a.op.length - 1);
                        string lhs_s = emit_expr (a.lvalue);
                        var alt = infer_type (a.lvalue);
                        string cast_s = (alt != null && alt.kind == CTypeKind.SCALAR) ? @"($(alt.name)) " : "";
                        return @"$lhs_s = $cast_s($lhs_s $bin_op ($(emit_expr (a.rvalue))))";
                    }
                }
                string? st = scalar_lvalue_type (a.lvalue);
                if (st != null)
                    return @"$(emit_expr (a.lvalue)) $(a.op) $(coerce_value (a.rvalue, st))";
                return @"$(emit_expr (a.lvalue)) $(a.op) $(emit_expr (a.rvalue))";
            }
            if (e is ExprTernary) {                var t = (ExprTernary) e;
                return @"($(emit_cond (t.cond)) ? $(emit_expr (t.if_true)) : $(emit_expr (t.if_false)))";
            }
            if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                if (cur_fe_arr != null && cur_fe_idx != null && cur_fe_elem != null
                    && ix.array is ExprIdent && ((ExprIdent) ix.array).name == (!) cur_fe_arr
                    && ix.index is ExprIdent && ((ExprIdent) ix.index).name == (!) cur_fe_idx)
                    return (!) cur_fe_elem;
                string? iar = inline_array_read (ix.array, ix.index);
                if (iar != null)
                    return iar;
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
                var ot = infer_type (m.obj);
                var base_ot = (ot != null && ot.kind == CTypeKind.PTR && ot.inner != null) ? (CType) ot.inner : ot;
                string mf = (base_ot != null && base_ot.kind == CTypeKind.STRUCT && base_ot.name == "tm")
                    ? map_tm_field (m.field) : esc_ident (m.field);
                if (m.is_arrow) {
                    if (m.obj is ExprIdent) {
                        string onm = ((ExprIdent) m.obj).name;
                        var oli = find_local (cur_locals, onm);
                        if (oli != null && oli.has_ptr_arith && ot != null && ot.kind == CTypeKind.PTR
                            && ot.inner != null && (ot.inner.kind == CTypeKind.STRUCT || ot.inner.kind == CTypeKind.UNION))
                            return @"$(esc_ident (onm))[_off_$onm].$mf";
                    }
                    if (m.obj is ExprBinary) {
                        var mb = (ExprBinary) m.obj;
                        if ((mb.op == "+" || mb.op == "-") && ot != null && ot.kind == CTypeKind.PTR
                            && ot.inner != null && (ot.inner.kind == CTypeKind.STRUCT || ot.inner.kind == CTypeKind.UNION)) {
                            var lbt = infer_type (mb.left);
                            if (lbt != null && (lbt.kind == CTypeKind.ARRAY || ptr_view (mb.left, lbt) == 2)) {
                                string sign_s = (mb.op == "-") ? "-" : "";
                                if (mb.left is ExprIdent) {
                                    string lnm = ((ExprIdent) mb.left).name;
                                    var lli = find_local (cur_locals, lnm);
                                    if (lli != null && lli.has_ptr_arith)
                                        return @"$(esc_ident (lnm))[_off_$lnm $(mb.op) (int) ($(emit_expr (mb.right)))].$mf";
                                }
                                return @"$(emit_expr (mb.left))[$sign_s(int) ($(emit_expr (mb.right)))].$mf";
                            }
                        }
                    }
                    string os = emit_expr (m.obj);
                    if (ot != null && ot.kind == CTypeKind.PTR && ot.inner != null
                        && (ot.inner.kind == CTypeKind.STRUCT || ot.inner.kind == CTypeKind.UNION)) {
                        // A pointer that decayed to an array parameter is indexed
                        // at 0; a real pointer is a nullable class reference,
                        // where `(!)` is the non-null assertion Vala needs.
                        bool arr_view = false;
                        if (ptr_view (m.obj, ot) == 2)
                            arr_view = true;
                        if (arr_view)
                            return @"$os[0].$mf";
                        // Vala accepts member access through a nullable
                        // reference (`p.x`), and planc rejects a `(!)` cast in
                        // statement position, so keep the plain form.
                        return @"$os.$mf";
                    }
                    return @"$os.$mf";
                }
                string os2 = emit_expr (m.obj);
                return @"$os2.$mf";
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
                        bool prev_ca = cur_in_call_arg;
                        cur_in_call_arg = !pt.is_void_ptr ();
                        string arg_coerced = coerce_ptr (c.args[i], pt, null, (pt.is_char_ptr () || pt.is_void_ptr ()) ? 2 : 1);
                        cur_in_call_arg = prev_ca;
                        sb.append (arg_coerced);
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

        private static string map_tm_field (string f) {
            switch (f) {
                case "tm_sec":   return "second";
                case "tm_min":   return "minute";
                case "tm_hour":  return "hour";
                case "tm_mday":  return "day";
                case "tm_mon":   return "month";
                case "tm_year":  return "year";
                case "tm_wday":  return "weekday";
                case "tm_yday":  return "day_of_year";
                case "tm_isdst": return "isdst";
                default:         return esc_ident (f);
            }
        }

        private string emit_time_ptr_val (CExpr arg) throws RefuseError {
            if (arg is ExprUnary && ((ExprUnary) arg).op == "&") {
                string op_s = emit_expr (((ExprUnary) arg).operand);
                return @"(int64) ($op_s)";
            }
            return @"(int64) ($(emit_expr (arg))[0])";
        }

        private string emit_tm_arg (CExpr arg) throws RefuseError {
            if (arg is ExprUnary && ((ExprUnary) arg).op == "&")
                return emit_expr (((ExprUnary) arg).operand);
            return emit_expr (arg);
        }

        private string emit_c_str_arg (CExpr e) throws RefuseError {
            string s = emit_expr (e);
            var at = infer_type (e);
            if (at != null && (at.kind == CTypeKind.ARRAY
                || (at.kind == CTypeKind.PTR && ptr_view (e, at) == 2)))
                return @"(string) $s";
            return s;
        }

        private string emit_struct_arg_val (CExpr arg, CType mt) throws RefuseError {
            if (mt.kind == CTypeKind.STRUCT)
                return emit_expr (arg);
            if (arg is ExprUnary && ((ExprUnary) arg).op == "&")
                return emit_expr (((ExprUnary) arg).operand);
            return @"$(emit_expr (arg))[0]";
        }

        private bool extract_struct_arr_arg (CExpr arg, out CExpr? base_expr, out CExpr? off_expr, out string? struct_name) throws RefuseError {
            base_expr = arg;
            off_expr = null;
            struct_name = null;
            CExpr a = arg;
            while (a is ExprCast) a = ((ExprCast) a).expr;
            if (a is ExprUnary && ((ExprUnary) a).op == "&" && ((ExprUnary) a).operand is ExprIndex) {
                var ix = (ExprIndex) ((ExprUnary) a).operand;
                var at = infer_type (ix.array);
                if (at != null && (at.kind == CTypeKind.ARRAY || at.kind == CTypeKind.PTR)
                    && at.inner != null && ((CType) at.inner).kind == CTypeKind.STRUCT) {
                    base_expr = ix.array;
                    off_expr = ix.index;
                    struct_name = ((CType) at.inner).name;
                    return true;
                }
            }
            var mt = infer_type (a);
            if (mt != null && (mt.kind == CTypeKind.ARRAY || mt.is_struct_ptr ()) && mt.inner != null) {
                base_expr = a;
                off_expr = null;
                struct_name = ((CType) mt.inner).name;
                return true;
            }
            return false;
        }

        private bool is_sizeof_struct (CExpr e, string sname) throws RefuseError {
            CExpr se = e;
            while (se is ExprCast) se = ((ExprCast) se).expr;
            if (se is ExprSizeofType) {
                var tt = ((ExprSizeofType) se).target_type;
                return tt.kind == CTypeKind.STRUCT && tt.name == sname;
            }
            if (se is ExprSizeofExpr) {
                var it = infer_type (((ExprSizeofExpr) se).expr);
                return it != null && it.kind == CTypeKind.STRUCT && it.name == sname;
            }
            return false;
        }

        private string? extract_struct_count_expr (CExpr sz_expr, string sname) throws RefuseError {
            CExpr se = sz_expr;
            while (se is ExprCast) se = ((ExprCast) se).expr;
            if (is_sizeof_struct (se, sname))
                return "1";
            if (se is ExprBinary && ((ExprBinary) se).op == "*") {
                var b = (ExprBinary) se;
                if (is_sizeof_struct (b.left, sname))
                    return @"(int) ($(emit_expr (b.right)))";
                if (is_sizeof_struct (b.right, sname))
                    return @"(int) ($(emit_expr (b.left)))";
            }
            return null;
        }

        private static int map_posix_const (string nm) {
            switch (nm) {
                case "PROT_NONE":       return 0;
                case "PROT_READ":       return 1;
                case "PROT_WRITE":      return 2;
                case "PROT_EXEC":       return 4;
                case "MAP_SHARED":      return 1;
                case "MAP_PRIVATE":     return 2;
                case "ENOENT":          return 2;
                case "EINTR":           return 4;
                case "EIO":             return 5;
                case "EAGAIN":          return 11;
                case "EACCES":          return 13;
                case "EBUSY":           return 16;
                case "EEXIST":          return 17;
                case "EISDIR":          return 21;
                case "EINVAL":          return 22;
                case "F_OK":            return 0;
                case "X_OK":            return 1;
                case "W_OK":            return 2;
                case "R_OK":            return 4;
                case "CLOCK_REALTIME":  return 0;
                case "CLOCK_MONOTONIC": return 1;
                default:                return -1;
            }
        }

        private static CExpr unwrap_void_ptr_cast (CExpr e) {
            CExpr cur = e;
            while (cur is ExprCast && ((ExprCast) cur).target_type.is_void_ptr ())
                cur = ((ExprCast) cur).expr;
            return cur;
        }

        private string emit_call (ExprCall c) throws RefuseError {
            if (!(c.callee is ExprIdent)) {
                CExpr ce = c.callee;
                while (ce is ExprUnary && ((ExprUnary) ce).op == "*")
                    ce = ((ExprUnary) ce).operand;
                var ct = infer_type (ce);
                if (ct != null && ct.kind == CTypeKind.FUNC_PTR)
                    return emit_fp_call (emit_expr (ce), ct, c);
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
                if ((fn == "memcpy" || fn == "memmove") && c.args.length == 3) {
                    // `memcpy (screen + ofs, back + ofs, n)`: pass the buffers
                    // and the offsets, so neither argument slices the buffer.
                    string bp_db = "";
                    string bp_dof = "";
                    string bp_sb = "";
                    string bp_sof = "";
                    if (ptr_pair_base (c.args[0], out bp_db, out bp_dof)
                        && ptr_pair_base (c.args[1], out bp_sb, out bp_sof)) {
                        string bh = (fn == "memcpy") ? "c_memcpy_off" : "c_memmove_off";
                        return @"$bh ($bp_db, $bp_dof, $bp_sb, $bp_sof, (size_t) ($(emit_expr (c.args[2]))))";
                    }
                    CExpr? d_base = null;
                    CExpr? d_off = null;
                    string? d_sname = null;
                    CExpr? s_base = null;
                    CExpr? s_off = null;
                    string? s_sname = null;
                    if (extract_struct_arr_arg (c.args[0], out d_base, out d_off, out d_sname)
                        && extract_struct_arr_arg (c.args[1], out s_base, out s_off, out s_sname)
                        && d_sname != null && d_sname == s_sname && d_base != null && s_base != null) {
                        string? cnt_s = extract_struct_count_expr (c.args[2], (!) d_sname);
                        if (cnt_s != null) {
                            var dt_b = infer_type ((!) d_base);
                            var st_b = infer_type ((!) s_base);
                            bool d_is_arr = (d_off != null) || (dt_b != null && (dt_b.kind == CTypeKind.ARRAY || ptr_view ((!) d_base, dt_b) == 2));
                            bool s_is_arr = (s_off != null) || (st_b != null && (st_b.kind == CTypeKind.ARRAY || ptr_view ((!) s_base, st_b) == 2));
                            if (d_is_arr && !s_is_arr && cnt_s == "1") {
                                string db_s = emit_expr ((!) d_base);
                                string doff_s = "0";
                                if (d_off != null) {
                                    string do_e = emit_expr ((!) d_off);
                                    doff_s = @"(int) ($do_e)";
                                }
                                return @"$db_s[$doff_s] = $(emit_expr (s_base))";
                            }
                            if (d_is_arr && s_is_arr) {
                                string helper = ensure_copy_arr_helper (esc_ident ((!) d_sname));
                                string db_s = emit_expr ((!) d_base);
                                string sb_s = emit_expr ((!) s_base);
                                string doff_s = "0";
                                if (d_off != null) {
                                    string do_e = emit_expr ((!) d_off);
                                    doff_s = @"(int) ($do_e)";
                                }
                                string soff_s = "0";
                                if (s_off != null) {
                                    string so_e = emit_expr ((!) s_off);
                                    soff_s = @"(int) ($so_e)";
                                }
                                return @"$helper ($db_s, $doff_s, $sb_s, $soff_s, $cnt_s)";
                            }
                        }
                    }
                    var ma0 = unwrap_void_ptr_cast (c.args[0]);
                    var ma1 = unwrap_void_ptr_cast (c.args[1]);
                    var mt0 = infer_type (ma0);
                    var mt1 = infer_type (ma1);
                    if (mt0 != null && mt1 != null
                        && (mt0.kind == CTypeKind.STRUCT || mt0.is_struct_ptr ())
                        && (mt1.kind == CTypeKind.STRUCT || mt1.is_struct_ptr ())) {
                        string sn0 = (mt0.kind == CTypeKind.STRUCT) ? mt0.name : ((CType) mt0.inner).name;
                        string sn1 = (mt1.kind == CTypeKind.STRUCT) ? mt1.name : ((CType) mt1.inner).name;
                        if (sn0 == sn1) {
                            string lhs = emit_struct_arg_val (ma0, mt0);
                            string rhs = emit_struct_arg_val (ma1, mt1);
                            return @"$lhs = $rhs";
                        }
                    }
                    if (mt0 != null && (mt0.kind == CTypeKind.STRUCT || mt0.is_struct_ptr ())) {
                        string sn0 = (mt0.kind == CTypeKind.STRUCT) ? mt0.name : ((CType) mt0.inner).name;
                        CExpr se = c.args[1];
                        while (se is ExprCast) se = ((ExprCast) se).expr;
                        var set = infer_type (se);
                        if (is_byte_or_char_ptr (set) && byte_cast_struct_map.get_index (sn0) >= 0) {
                            var bsd = find_struct (sn0);
                            if (bsd != null && bsd.fields.length > 0) {
                                string lhs = emit_struct_arg_val (c.args[0], mt0);
                                return @"$lhs = new $(esc_ident (sn0)).at ($(emit_expr (se)), 0)";
                            }
                        }
                    }
                }
                if (fn == "memcpy" && c.args.length == 3
                    && c.args[0] is ExprUnary && ((ExprUnary) c.args[0]).op == "&"
                    && c.args[1] is ExprUnary && ((ExprUnary) c.args[1]).op == "&") {
                    var dst_op = ((ExprUnary) c.args[0]).operand;
                    var src_op = ((ExprUnary) c.args[1]).operand;
                    var dt = infer_type (dst_op);
                    var st = infer_type (src_op);
                    if (dt != null && st != null
                        && (dt.kind == CTypeKind.SCALAR || dt.kind == CTypeKind.ENUM)
                        && (st.kind == CTypeKind.SCALAR || st.kind == CTypeKind.ENUM)) {
                        string ds = emit_expr (dst_op);
                        string ss = emit_expr (src_op);
                        if (dt.name == "double" && (st.name == "int64" || st.name == "uint64"))
                            return @"$ds = c_u64_to_f64 ((uint64) ($ss))";
                        if ((dt.name == "int64" || dt.name == "uint64") && st.name == "double")
                            return @"$ds = ($(dt.name)) c_f64_to_u64 ((double) ($ss))";
                        if (dt.name == "float" && (st.name == "int32" || st.name == "uint32" || st.name == "int" || st.name == "uint"))
                            return @"$ds = c_u32_to_f32 ((uint32) ($ss))";
                        if ((dt.name == "int32" || dt.name == "uint32" || dt.name == "int" || dt.name == "uint") && st.name == "float")
                            return @"$ds = ($(dt.name)) c_f32_to_u32 ((float) ($ss))";
                        if (vala_type (dt, false) == vala_type (st, false))
                            return @"$ds = $ss";
                    }
                }
                if (fn == "memcpy" && c.args.length == 3
                    && c.args[1] is ExprUnary && ((ExprUnary) c.args[1]).op == "&") {
                    var dst_t = infer_type (c.args[0]);
                    var src_op = ((ExprUnary) c.args[1]).operand;
                    var src_t = infer_type (src_op);
                    if (is_byte_or_char_ptr (dst_t) && src_t != null
                        && (src_t.kind == CTypeKind.SCALAR || src_t.kind == CTypeKind.ENUM)) {
                        return @"c_u_set_u64 ($(emit_expr (c.args[0])), (int) ($(emit_expr (c.args[2]))), (uint64) ($(emit_expr (src_op))))";
                    }
                }
                if (fn == "memcmp" && c.args.length == 3
                    && (c.args[2] is ExprSizeofType || c.args[2] is ExprSizeofExpr || c.args[2] is ExprInt)) {
                    var ma0 = unwrap_void_ptr_cast (c.args[0]);
                    var ma1 = unwrap_void_ptr_cast (c.args[1]);
                    var mt0 = infer_type (ma0);
                    var mt1 = infer_type (ma1);
                    if (mt0 != null && mt1 != null
                        && (mt0.kind == CTypeKind.STRUCT || mt0.is_struct_ptr ())
                        && (mt1.kind == CTypeKind.STRUCT || mt1.is_struct_ptr ())) {
                        string sn0 = (mt0.kind == CTypeKind.STRUCT) ? mt0.name : ((CType) mt0.inner).name;
                        string sn1 = (mt1.kind == CTypeKind.STRUCT) ? mt1.name : ((CType) mt1.inner).name;
                        var sd = (sn0 == sn1) ? find_struct (sn0) : null;
                        if (sd != null && sd.fields.length > 0) {
                            bool all_scalar = true;
                            for (int fi = 0; fi < sd.fields.length; fi++) {
                                var ft = sd.fields[fi].ctype;
                                var fk = ft.kind;
                                if (fk == CTypeKind.SCALAR || fk == CTypeKind.ENUM)
                                    continue;
                                if (fk == CTypeKind.ARRAY && ft.array_len is ExprInt
                                    && ((ExprInt) ft.array_len).val > 0 && ((ExprInt) ft.array_len).val <= 16
                                    && ft.inner != null && (ft.inner.kind == CTypeKind.SCALAR || ft.inner.kind == CTypeKind.ENUM))
                                    continue;
                                all_scalar = false;
                                break;
                            }
                            if (all_scalar) {
                                string lhs = emit_struct_arg_val (ma0, mt0);
                                string rhs = emit_struct_arg_val (ma1, mt1);
                                var csb = new StrBuilder ("((");
                                bool first_cmp = true;
                                for (int fi = 0; fi < sd.fields.length; fi++) {
                                    var ft = sd.fields[fi].ctype;
                                    string fnm = esc_ident (sd.fields[fi].name);
                                    if (ft.kind == CTypeKind.ARRAY && ft.array_len is ExprInt) {
                                        int alen = (int) ((ExprInt) ft.array_len).val;
                                        for (int ai = 0; ai < alen; ai++) {
                                            if (!first_cmp) csb.append (" && ");
                                            first_cmp = false;
                                            csb.append (@"$lhs.$fnm[$ai] == $rhs.$fnm[$ai]");
                                        }
                                    } else {
                                        if (!first_cmp) csb.append (" && ");
                                        first_cmp = false;
                                        csb.append (@"$lhs.$fnm == $rhs.$fnm");
                                    }
                                }
                                csb.append (") ? 0 : 1)");
                                return csb.str;
                            }
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
                    string a_s = emit_expr (c.args[i]);
                    if ((i == 0 && (fn == "memcpy" || fn == "memmove" || fn == "memset" || fn == "memcmp"))
                        || (i == 1 && (fn == "memcpy" || fn == "memmove" || fn == "memcmp"))) {
                        if (c.args[i] is ExprStr) {
                            a_s = (i == 0 && fn != "memcmp") ? @"c_str_to_bytes ($a_s)" : @"$(wrap_operand (a_s)).data";
                        } else {
                            var at = infer_type (c.args[i]);
                            if (at != null && at.kind == CTypeKind.PTR && ptr_view (c.args[i], at) == 1
                                && !a_s.has_prefix ("_c2v_slice_")) {
                                a_s = (i == 0 && fn != "memcmp") ? @"c_str_to_bytes ($a_s)" : @"$(wrap_operand (a_s)).data";
                            }
                        }
                    }
                    sb.append (a_s);
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
            if ((fn == "__atomic_fetch_add" || fn == "atomic_fetch_add") && c.args.length >= 2) {
                var a0 = c.args[0];
                string lhs = (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    ? emit_expr (((ExprUnary) a0).operand)
                    : @"$(emit_expr (a0))[0]";
                return @"($lhs += $(emit_expr (c.args[1])))";
            }
            if ((fn == "__atomic_fetch_sub" || fn == "atomic_fetch_sub") && c.args.length >= 2) {
                var a0 = c.args[0];
                string lhs = (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    ? emit_expr (((ExprUnary) a0).operand)
                    : @"$(emit_expr (a0))[0]";
                return @"($lhs -= $(emit_expr (c.args[1])))";
            }
            if (fn == "atomic_load" && c.args.length >= 1) {
                var a0 = c.args[0];
                return (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    ? emit_expr (((ExprUnary) a0).operand)
                    : @"$(emit_expr (a0))[0]";
            }
            if (fn == "atomic_store" && c.args.length >= 2) {
                var a0 = c.args[0];
                string lhs = (a0 is ExprUnary && ((ExprUnary) a0).op == "&")
                    ? emit_expr (((ExprUnary) a0).operand)
                    : @"$(emit_expr (a0))[0]";
                return @"($lhs = $(emit_expr (c.args[1])))";
            }

            if (fn == "assert" && c.args.length >= 1)
                return "assert (true)"; // NDEBUG semantics: the condition is not evaluated
            if (fn == "abort" && c.args.length == 0)
                return "Process.abort ()";
            if (fn == "exit" && c.args.length == 1)
                return @"Process.exit ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "getenv" && c.args.length == 1) {
                var a0t = infer_type (c.args[0]);
                string a0s = emit_expr (c.args[0]);
                if (a0t != null && (a0t.kind == CTypeKind.ARRAY
                    || (a0t.kind == CTypeKind.PTR && ptr_view (c.args[0], a0t) == 2)))
                    a0s = @"(string) $a0s";
                return @"(Environment.get_variable ($a0s) ?? \"\")";
            }
            if ((fn == "isspace" || fn == "isdigit" || fn == "isalpha" || fn == "isalnum"
                 || fn == "isxdigit" || fn == "isupper" || fn == "islower"
                 || fn == "tolower" || fn == "toupper") && c.args.length == 1)
                return @"c_$fn ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "puts" && c.args.length == 1)
                return @"c_puts ($(emit_expr (c.args[0])))";
            if (fn == "isnan" && c.args.length == 1)
                return @"Math.isnan ((double) ($(emit_expr (c.args[0]))))";
            if (fn == "isfinite" && c.args.length == 1)
                return @"Math.isfinite ((double) ($(emit_expr (c.args[0]))))";
            if ((fn == "fabs" || fn == "trunc" || fn == "floor" || fn == "ceil") && c.args.length == 1)
                return @"Math.$fn ((double) ($(emit_expr (c.args[0]))))";
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
            if (fn == "abs" && c.args.length == 1)
                return @"int.abs ((int) ($(emit_expr (c.args[0]))))";
            if ((fn == "labs" || fn == "llabs") && c.args.length == 1)
                return @"int64.abs ((int64) ($(emit_expr (c.args[0]))))";
            if (fn == "isnan" && c.args.length == 1)
                return @"(double.is_nan ((double) ($(emit_expr (c.args[0])))) ? 1 : 0)";
            if (fn == "isfinite" && c.args.length == 1)
                return @"(double.is_finite ((double) ($(emit_expr (c.args[0])))) ? 1 : 0)";
            if (fn == "isinf" && c.args.length == 1)
                return @"(double.is_infinity ((double) ($(emit_expr (c.args[0])))) ? 1 : 0)";
            if (fn == "strdup" && c.args.length == 1)
                return @"($(emit_expr (c.args[0])))";
            if (fn == "strstr" && c.args.length == 2)
                return @"c_strstr ($(emit_expr (c.args[0])), $(emit_expr (c.args[1])))";
            if (fn == "atof" && c.args.length == 1)
                return @"double.parse ($(emit_expr (c.args[0])))";
            if (fn == "system" && c.args.length == 1)
                return "-1";
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

            if (fn == "sprintf" && c.args.length >= 2) {
                var a0t = infer_type (c.args[0]);
                string d_s = emit_expr (c.args[0]);
                if (a0t != null && ptr_view (c.args[0], a0t) == 1)
                    d_s = @"c_str_to_bytes ($d_s)";
                string fmt_s = emit_c_str_arg (c.args[1]);
                if (c.args.length == 2)
                    return @"c_sprintf_buf ($d_s, $fmt_s)";
                var sb = new StrBuilder (@"c_sprintf_buf ($d_s, ($fmt_s).printf (");
                for (int i = 2; i < c.args.length; i++) {
                    if (i > 2) sb.append (", ");
                    sb.append (emit_expr (c.args[i]));
                }
                sb.append ("))");
                return sb.str;
            }
            if (fn == "snprintf" && c.args.length >= 3) {
                var a0t = infer_type (c.args[0]);
                string d_s = emit_expr (c.args[0]);
                if (a0t != null && ptr_view (c.args[0], a0t) == 1)
                    d_s = @"c_str_to_bytes ($d_s)";
                string n_s = emit_expr (c.args[1]);
                string fmt_s = emit_c_str_arg (c.args[2]);
                if (c.args.length == 3)
                    return @"c_snprintf_buf ($d_s, (size_t) ($n_s), $fmt_s)";
                var sb = new StrBuilder (@"c_snprintf_buf ($d_s, (size_t) ($n_s), ($fmt_s).printf (");
                for (int i = 3; i < c.args.length; i++) {
                    if (i > 3) sb.append (", ");
                    sb.append (emit_expr (c.args[i]));
                }
                sb.append ("))");
                return sb.str;
            }
            if (fn == "usleep" && c.args.length == 1)
                return @"c_usleep ((uint32) ($(emit_expr (c.args[0]))))";
            if (fn == "sleep" && c.args.length == 1)
                return @"c_sleep ((uint) ($(emit_expr (c.args[0]))))";
            if (fn == "clock_gettime" && c.args.length == 2)
                return @"c_clock_gettime ((int) ($(emit_expr (c.args[0]))), $(emit_expr (c.args[1])))";
            if (fn == "S_ISLNK" && c.args.length == 1)
                return @"c_s_islnk ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "S_ISDIR" && c.args.length == 1)
                return @"c_s_isdir ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "S_ISREG" && c.args.length == 1)
                return @"c_s_isreg ((int) ($(emit_expr (c.args[0]))))";
            if (fn == "getpid" && c.args.length == 0)
                return "c_getpid ()";
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
            if (fn == "time" && c.args.length == 1) {
                if (is_null_ptr_expr (c.args[0]))
                    return "c_time_now ()";
                return @"c_time ($(emit_expr (c.args[0])))";
            }
            if (fn == "clock" && c.args.length == 0) {
                return "get_real_time ()";
            }
            if (fn == "difftime" && c.args.length == 2) {
                return @"((double) ($(emit_expr (c.args[0])) - $(emit_expr (c.args[1]))))";
            }
            if (fn == "gmtime" && c.args.length == 1) {
                return @"Time.gm ($(emit_time_ptr_val (c.args[0])))";
            }
            if (fn == "localtime" && c.args.length == 1) {
                return @"Time.local ($(emit_time_ptr_val (c.args[0])))";
            }
            if (fn == "gmtime_r" && c.args.length == 2) {
                return @"$(emit_tm_arg (c.args[1])) = Time.gm ($(emit_time_ptr_val (c.args[0])))";
            }
            if (fn == "localtime_r" && c.args.length == 2) {
                return @"$(emit_tm_arg (c.args[1])) = Time.local ($(emit_time_ptr_val (c.args[0])))";
            }
            if (fn == "mktime" && c.args.length == 1) {
                return @"$(emit_tm_arg (c.args[0])).mktime ()";
            }
            if (fn == "strftime" && c.args.length == 4) {
                return @"$(emit_tm_arg (c.args[3])).strftime ($(emit_expr (c.args[0])), $(emit_c_str_arg (c.args[2])))";
            }
            if (fn == "pthread_create" && c.args.length == 4) {
                string tid_s = emit_tm_arg (c.args[0]);
                string fn_s = emit_expr (c.args[2]);
                string arg_s = is_null_ptr_expr (c.args[3]) ? "null" : emit_expr (c.args[3]);
                return @"c_pthread_create (out $tid_s, $fn_s, $arg_s)";
            }
            if (fn == "pthread_join" && c.args.length == 2) {
                return @"c_pthread_join_null ($(emit_expr (c.args[0])))";
            }
            if (fn == "pthread_detach" && c.args.length == 1) {
                return "0";
            }
            if ((fn == "pthread_mutex_init" || fn == "pthread_cond_init") && c.args.length == 2) {
                return "0";
            }
            if ((fn == "pthread_mutex_destroy" || fn == "pthread_cond_destroy"
                 || fn == "pthread_mutexattr_init" || fn == "pthread_mutexattr_destroy") && c.args.length == 1) {
                return "0";
            }
            if (fn == "pthread_mutexattr_settype" && c.args.length == 2) {
                return "0";
            }
            if (fn == "pthread_mutex_lock" && c.args.length == 1) {
                return @"c_pthread_mutex_lock ($(emit_tm_arg (c.args[0])))";
            }
            if (fn == "pthread_mutex_trylock" && c.args.length == 1) {
                return @"c_pthread_mutex_trylock ($(emit_tm_arg (c.args[0])))";
            }
            if (fn == "pthread_mutex_unlock" && c.args.length == 1) {
                return @"c_pthread_mutex_unlock ($(emit_tm_arg (c.args[0])))";
            }
            if (fn == "pthread_cond_wait" && c.args.length == 2) {
                return @"c_pthread_cond_wait ($(emit_tm_arg (c.args[0])), $(emit_tm_arg (c.args[1])))";
            }
            if (fn == "pthread_cond_timedwait" && c.args.length == 3) {
                return @"c_pthread_cond_timedwait ($(emit_tm_arg (c.args[0])), $(emit_tm_arg (c.args[1])), $(emit_expr (c.args[2])))";
            }
            if (fn == "mkdir" && c.args.length == 2) {
                return @"DirUtils.create ($(emit_c_str_arg (c.args[0])), (int) ($(emit_expr (c.args[1]))))";
            }
            if (fn == "rmdir" && c.args.length == 1) {
                return @"DirUtils.remove ($(emit_c_str_arg (c.args[0])))";
            }
            if (fn == "pthread_cond_signal" && c.args.length == 1) {
                return @"c_pthread_cond_signal ($(emit_tm_arg (c.args[0])))";
            }
            if (fn == "pthread_cond_broadcast" && c.args.length == 1) {
                return @"c_pthread_cond_broadcast ($(emit_tm_arg (c.args[0])))";
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
            if (fn == "strlen" || fn == "strcmp" || fn == "strncmp" || fn == "strcasecmp" || fn == "strncasecmp") {
                string callee_name = (fn == "strcasecmp") ? "GLib.ascii_strcasecmp"
                    : (fn == "strncasecmp") ? "GLib.ascii_strncasecmp" : @"c_$fn";
                var sb = new StrBuilder (@"$callee_name (");
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
                    bool prev_ca = cur_in_call_arg;
                    cur_in_call_arg = !pt.is_void_ptr ();
                    string arg_coerced = coerce_ptr (c.args[i], pt, null, parr ? 2 : 1);
                    cur_in_call_arg = prev_ca;
                    sb.append (arg_coerced);
                } else
                    sb.append (coerce_value (c.args[i], tgt));
            }
            sb.append (")");
            return sb.str;
        }
    }
}
