// Pointer usage analyzer for c2vala: classifies pointers by usage, assigns
// descriptive suffixes (_obj, _arr, _buf, _ptr), and recommends Vala helpers.
using Planc;

namespace C2Vala {

    public enum PtrUsage {
        NONE = 0,
        INDEXED = 1,
        ARITH = 2,
        DEREF = 4,
        ADDR_TAKEN = 8,
        CAST_TO_OBJ = 16,
        WRITTEN = 32,
        NULL_CHECKED = 64,
        STR_INIT = 128,
        PTR_DIFF = 256,
        ARROW_ACCESS = 512,
        FIELD_REF_ASSIGN = 1024,
        FIELD_REF_LOCAL_ADDR = 2048
    }

    public enum PtrKind {
        NONE,
        SINGLE_OBJ,
        SLICE_ARR,
        BYTE_BUF,
        OPAQUE_PTR,
        DOUBLE_PTR,
        CURSOR,
        FIELD_REF
    }

    public class PtrInfo : Object {
        public string name;
        public CType ctype;
        public bool is_param = false;
        public int usage = 0;
        public PtrKind kind = PtrKind.NONE;
        public GenericArray<string> cast_targets = new GenericArray<string> ();

        public PtrInfo (string name, CType ctype, bool is_param = false) {
            this.name = name;
            this.ctype = ctype;
            this.is_param = is_param;
        }

        public void add_cast_target (string tname) {
            for (int i = 0; i < cast_targets.length; i++) {
                if (cast_targets[i] == tname)
                    return;
            }
            cast_targets.add (tname);
        }

        public string suffix () {
            switch (kind) {
                case PtrKind.FIELD_REF:  return "_fref";
                case PtrKind.CURSOR:     return "_cur";
                case PtrKind.DOUBLE_PTR: return "_pp";
                case PtrKind.OPAQUE_PTR: return "_ptr";
                case PtrKind.BYTE_BUF:   return "_buf";
                case PtrKind.SLICE_ARR:  return "_arr";
                case PtrKind.SINGLE_OBJ: return "_obj";
                default:                 return "";
            }
        }

        public bool is_written () {
            return (usage & (int) PtrUsage.WRITTEN) != 0;
        }

        public string helper_type () {
            switch (kind) {
                case PtrKind.FIELD_REF:
                    return "_c2v_fref<T>";
                case PtrKind.CURSOR:
                    return "(T[],int)";
                case PtrKind.DOUBLE_PTR:
                    return "C2VBox<T[]>";
                case PtrKind.OPAQUE_PTR:
                    if (cast_targets.length == 1)
                        return @"$(cast_targets[0]).at";
                    return "C2VPtr";
                case PtrKind.BYTE_BUF:
                    if (!is_written () && (usage & (int) PtrUsage.STR_INIT) != 0)
                        return "string.data";
                    return is_written () ? "uint8[]" : "uint8[](ro)";
                case PtrKind.SLICE_ARR:
                    return "T[]";
                case PtrKind.SINGLE_OBJ:
                    return "T?";
                default:
                    return "";
            }
        }

        public string format_tag () {
            var sb = new StrBuilder (name);
            sb.append (suffix ());
            sb.append ("[");
            bool first = true;
            if ((usage & (int) PtrUsage.INDEXED) != 0) { sb.append ("IDX"); first = false; }
            if ((usage & (int) PtrUsage.ARITH) != 0) { if (!first) sb.append ("|"); sb.append ("ARITH"); first = false; }
            if ((usage & (int) PtrUsage.DEREF) != 0) { if (!first) sb.append ("|"); sb.append ("DEREF"); first = false; }
            if ((usage & (int) PtrUsage.ADDR_TAKEN) != 0) { if (!first) sb.append ("|"); sb.append ("ADDR"); first = false; }
            if ((usage & (int) PtrUsage.CAST_TO_OBJ) != 0) { if (!first) sb.append ("|"); sb.append ("CAST"); first = false; }
            if ((usage & (int) PtrUsage.WRITTEN) != 0) { if (!first) sb.append ("|"); sb.append ("WR"); first = false; }
            if ((usage & (int) PtrUsage.NULL_CHECKED) != 0) { if (!first) sb.append ("|"); sb.append ("NULL"); first = false; }
            if ((usage & (int) PtrUsage.ARROW_ACCESS) != 0) { if (!first) sb.append ("|"); sb.append ("ARROW"); first = false; }
            if (first) sb.append ("PLAIN");
            if (cast_targets.length > 0) {
                sb.append ("->");
                for (int i = 0; i < cast_targets.length; i++) {
                    if (i > 0) sb.append (",");
                    sb.append (cast_targets[i]);
                }
            }
            sb.append ("]=>");
            sb.append (helper_type ());
            return sb.str;
        }
    }

    public class PtrAnalysis : Object {
        public GenericArray<PtrInfo> entries = new GenericArray<PtrInfo> ();

        public PtrInfo? find (string name) {
            for (int i = 0; i < entries.length; i++) {
                if (entries[i].name == name)
                    return entries[i];
            }
            return null;
        }

        public PtrInfo ensure (string name, CType ctype, bool is_param = false) {
            var existing = find (name);
            if (existing != null)
                return (!) existing;
            var pi = new PtrInfo (name, ctype, is_param);
            entries.add (pi);
            return pi;
        }

        public bool is_ptr_written (string name) {
            var pi = find (name);
            if (pi == null)
                return true;
            return pi.is_written ();
        }

        public bool is_field_ref (string name) {
            var pi = find (name);
            return pi != null && pi.kind == PtrKind.FIELD_REF;
        }

        public bool is_field_ref_native (string name) {
            var pi = find (name);
            return pi != null && pi.kind == PtrKind.FIELD_REF
                && !pi.is_param
                && (pi.usage & (int) PtrUsage.FIELD_REF_LOCAL_ADDR) == 0;
        }

        public string format_summary () {
            var sb = new StrBuilder ();
            int shown = 0;
            for (int i = 0; i < entries.length; i++) {
                var pi = entries[i];
                if (pi.kind == PtrKind.NONE)
                    continue;
                if (shown > 0) sb.append (" ");
                sb.append (pi.format_tag ());
                shown++;
            }
            return sb.str;
        }
    }

    public class PtrAnalyzer : Object {

        private static bool is_byte_ptr_ct (CType ct) {
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null) {
                var inn = (CType) ct.inner;
                return inn.is_scalar ("char") || inn.is_scalar ("uint8")
                    || inn.is_scalar ("uchar") || inn.is_scalar ("void");
            }
            if (ct.kind == CTypeKind.PTR && ct.inner != null) {
                var inn = (CType) ct.inner;
                return inn.is_scalar ("char") || inn.is_scalar ("uint8")
                    || inn.is_scalar ("uchar") || inn.is_scalar ("void");
            }
            return false;
        }

        private static void classify_info (PtrInfo pi) {
            bool is_ptr_or_arr = (pi.ctype.kind == CTypeKind.PTR || pi.ctype.kind == CTypeKind.ARRAY);
            if (!is_ptr_or_arr) {
                if ((pi.usage & (int) PtrUsage.ADDR_TAKEN) != 0)
                    pi.kind = PtrKind.SLICE_ARR;
                return;
            }
            if (pi.ctype.kind == CTypeKind.PTR && pi.ctype.inner != null) {
                var inn = (CType) pi.ctype.inner;
                if (inn.is_struct_ptr () && (pi.usage & (int) PtrUsage.FIELD_REF_ASSIGN) != 0
                    && (pi.usage & (int) (PtrUsage.INDEXED | PtrUsage.ARITH)) == 0) {
                    pi.kind = PtrKind.FIELD_REF;
                    return;
                }
                if ((inn.kind == CTypeKind.PTR || inn.kind == CTypeKind.ARRAY) && !inn.is_char_ptr ()) {
                    pi.kind = PtrKind.DOUBLE_PTR;
                    return;
                }
            }
            if ((pi.usage & (int) PtrUsage.CAST_TO_OBJ) != 0 || (pi.ctype.kind == CTypeKind.PTR && pi.ctype.inner != null && ((CType) pi.ctype.inner).is_scalar ("void"))) {
                pi.kind = PtrKind.OPAQUE_PTR;
                return;
            }
            if (is_byte_ptr_ct (pi.ctype) && ((pi.usage & ((int) PtrUsage.INDEXED | (int) PtrUsage.ARITH | (int) PtrUsage.WRITTEN)) != 0 || pi.ctype.kind == CTypeKind.ARRAY)) {
                pi.kind = PtrKind.BYTE_BUF;
                return;
            }
            if ((pi.usage & (int) PtrUsage.PTR_DIFF) != 0 && (pi.usage & (int) PtrUsage.ARITH) != 0) {
                pi.kind = PtrKind.CURSOR;
                return;
            }
            if ((pi.usage & ((int) PtrUsage.INDEXED | (int) PtrUsage.ARITH)) != 0 || pi.ctype.kind == CTypeKind.ARRAY) {
                pi.kind = PtrKind.SLICE_ARR;
                return;
            }
            pi.kind = PtrKind.SINGLE_OBJ;
        }

        private static void scan_stmt (CStmt s, PtrAnalysis pa) {
            if (s is StmtDecl) {
                var d = (StmtDecl) s;
                if (d.ctype.kind == CTypeKind.PTR || d.ctype.kind == CTypeKind.ARRAY) {
                    var pi = pa.ensure (d.name, d.ctype, false);
                    if (d.init is ExprStr)
                        pi.usage |= (int) PtrUsage.STR_INIT;
                    if (d.init is ExprUnary && ((ExprUnary) d.init).op == "&") {
                        var op = ((ExprUnary) d.init).operand;
                        if (op is ExprMember || op is ExprIndex || op is ExprIdent)
                            pi.usage |= (int) PtrUsage.FIELD_REF_ASSIGN;
                        if (op is ExprIdent)
                            pi.usage |= (int) PtrUsage.FIELD_REF_LOCAL_ADDR;
                    }
                }
                if (d.init != null)
                    scan_expr ((CExpr) d.init, pa);
            } else if (s is StmtBlock) {
                var b = (StmtBlock) s;
                for (int i = 0; i < b.stmts.length; i++)
                    scan_stmt (b.stmts[i], pa);
            } else if (s is StmtIf) {
                var is_ = (StmtIf) s;
                scan_expr (is_.cond, pa);
                scan_stmt (is_.then_branch, pa);
                if (is_.else_branch != null)
                    scan_stmt ((CStmt) is_.else_branch, pa);
            } else if (s is StmtWhile) {
                var ws = (StmtWhile) s;
                scan_expr (ws.cond, pa);
                scan_stmt (ws.body, pa);
            } else if (s is StmtFor) {
                var fs = (StmtFor) s;
                if (fs.init_decl != null)
                    scan_stmt ((CStmt) fs.init_decl, pa);
                if (fs.init_expr != null)
                    scan_expr ((CExpr) fs.init_expr, pa);
                if (fs.cond != null)
                    scan_expr ((CExpr) fs.cond, pa);
                if (fs.next != null)
                    scan_expr ((CExpr) fs.next, pa);
                scan_stmt (fs.body, pa);
            } else if (s is StmtSwitch) {
                var sw = (StmtSwitch) s;
                if (sw.cond != null)
                    scan_expr ((CExpr) sw.cond, pa);
                for (int i = 0; i < sw.cases.length; i++) {
                    for (int j = 0; j < sw.cases[i].stmts.length; j++)
                        scan_stmt (sw.cases[i].stmts[j], pa);
                }
            } else if (s is StmtReturn) {
                var rs = (StmtReturn) s;
                if (rs.expr != null)
                    scan_expr ((CExpr) rs.expr, pa);
            } else if (s is StmtExpr) {
                scan_expr (((StmtExpr) s).expr, pa);
            } else if (s is StmtLabel) {
                scan_stmt (((StmtLabel) s).stmt, pa);
            }
        }

        private static string? root_ident (CExpr e) {
            if (e is ExprIdent)
                return ((ExprIdent) e).name;
            if (e is ExprCast)
                return root_ident (((ExprCast) e).expr);
            if (e is ExprUnary && ((ExprUnary) e).op == "*")
                return root_ident (((ExprUnary) e).operand);
            if (e is ExprIndex)
                return root_ident (((ExprIndex) e).array);
            if (e is ExprBinary) {
                var b = (ExprBinary) e;
                if (b.op == "+" || b.op == "-")
                    return root_ident (b.left);
            }
            return null;
        }

        private static void mark_usage (PtrAnalysis pa, string name, PtrUsage flag) {
            var pi = pa.find (name);
            if (pi != null)
                pi.usage |= (int) flag;
        }

        private static void scan_expr (CExpr? e, PtrAnalysis pa) {
            if (e == null)
                return;
            if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                string? nm = root_ident (ix.array);
                if (nm != null)
                    mark_usage (pa, (!) nm, PtrUsage.INDEXED);
                scan_expr (ix.array, pa);
                scan_expr (ix.index, pa);
            } else if (e is ExprMember) {
                var m = (ExprMember) e;
                if (m.is_arrow) {
                    string? nm = root_ident (m.obj);
                    if (nm != null)
                        mark_usage (pa, (!) nm, PtrUsage.DEREF | PtrUsage.ARROW_ACCESS);
                }
                scan_expr (m.obj, pa);
            } else if (e is ExprUnary) {
                var u = (ExprUnary) e;
                if (u.op == "*") {
                    string? nm = root_ident (u.operand);
                    if (nm != null)
                        mark_usage (pa, (!) nm, PtrUsage.DEREF);
                } else if (u.op == "&" && u.operand is ExprIdent) {
                    string vnm = ((ExprIdent) u.operand).name;
                    var pi = pa.find (vnm);
                    if (pi != null)
                        pi.usage |= (int) PtrUsage.ADDR_TAKEN;
                } else if (u.op == "++" || u.op == "--") {
                    string? nm = root_ident (u.operand);
                    if (nm != null)
                        mark_usage (pa, (!) nm, PtrUsage.ARITH);
                } else if (u.op == "!") {
                    string? nm = root_ident (u.operand);
                    if (nm != null)
                        mark_usage (pa, (!) nm, PtrUsage.NULL_CHECKED);
                }
                scan_expr (u.operand, pa);
            } else if (e is ExprCast) {
                var c = (ExprCast) e;
                if (c.target_type.kind == CTypeKind.PTR && c.target_type.inner != null) {
                    var inn = (CType) c.target_type.inner;
                    if (inn.kind == CTypeKind.STRUCT || inn.kind == CTypeKind.UNION) {
                        string? nm = root_ident (c.expr);
                        if (nm != null) {
                            var pi = pa.find ((!) nm);
                            if (pi != null) {
                                pi.usage |= (int) PtrUsage.CAST_TO_OBJ;
                                pi.add_cast_target (inn.name);
                            }
                        }
                    }
                }
                scan_expr (c.expr, pa);
            } else if (e is ExprAssign) {
                var a = (ExprAssign) e;
                if (a.lvalue is ExprIndex) {
                    string? nm = root_ident (((ExprIndex) a.lvalue).array);
                    if (nm != null)
                        mark_usage (pa, (!) nm, PtrUsage.INDEXED | PtrUsage.WRITTEN);
                } else if (a.lvalue is ExprUnary && ((ExprUnary) a.lvalue).op == "*") {
                    string? nm = root_ident (((ExprUnary) a.lvalue).operand);
                    if (nm != null)
                        mark_usage (pa, (!) nm, PtrUsage.DEREF | PtrUsage.WRITTEN);
                } else if (a.lvalue is ExprMember && ((ExprMember) a.lvalue).is_arrow) {
                    string? nm = root_ident (((ExprMember) a.lvalue).obj);
                    if (nm != null)
                        mark_usage (pa, (!) nm, PtrUsage.DEREF | PtrUsage.WRITTEN);
                } else if ((a.op == "+=" || a.op == "-=") && a.lvalue is ExprIdent) {
                    mark_usage (pa, ((ExprIdent) a.lvalue).name, PtrUsage.ARITH);
                } else if (a.op == "=" && a.lvalue is ExprIdent
                           && a.rvalue is ExprUnary && ((ExprUnary) a.rvalue).op == "&") {
                    var rop = ((ExprUnary) a.rvalue).operand;
                    if (rop is ExprMember || rop is ExprIndex || rop is ExprIdent)
                        mark_usage (pa, ((ExprIdent) a.lvalue).name, PtrUsage.FIELD_REF_ASSIGN);
                    if (rop is ExprIdent)
                        mark_usage (pa, ((ExprIdent) a.lvalue).name, PtrUsage.FIELD_REF_LOCAL_ADDR);
                }
                scan_expr (a.lvalue, pa);
                scan_expr (a.rvalue, pa);
            } else if (e is ExprBinary) {
                var b = (ExprBinary) e;
                if (b.op == "+" || b.op == "-") {
                    string? lnm = root_ident (b.left);
                    if (lnm != null)
                        mark_usage (pa, (!) lnm, PtrUsage.ARITH);
                    if (b.op == "-") {
                        string? rnm = root_ident (b.right);
                        if (lnm != null && rnm != null) {
                            mark_usage (pa, (!) lnm, PtrUsage.PTR_DIFF);
                            mark_usage (pa, (!) rnm, PtrUsage.PTR_DIFF);
                        }
                    }
                } else if (b.op == "==" || b.op == "!=") {
                    string? lnm = root_ident (b.left);
                    if (lnm != null)
                        mark_usage (pa, (!) lnm, PtrUsage.NULL_CHECKED);
                }
                scan_expr (b.left, pa);
                scan_expr (b.right, pa);
            } else if (e is ExprTernary) {
                var t = (ExprTernary) e;
                scan_expr (t.cond, pa);
                scan_expr (t.if_true, pa);
                scan_expr (t.if_false, pa);
            } else if (e is ExprCall) {
                var cal = (ExprCall) e;
                if (cal.callee is ExprIdent && cal.args.length >= 1) {
                    string fn = ((ExprIdent) cal.callee).name;
                    if (fn == "memcpy" || fn == "memmove" || fn == "memset"
                        || fn == "strcpy" || fn == "strncpy" || fn == "strcat" || fn == "strncat"
                        || fn == "sprintf" || fn == "snprintf" || fn == "fread" || fn == "fgets"
                        || fn == "strftime") {
                        string? nm = root_ident (cal.args[0]);
                        if (nm != null)
                            mark_usage (pa, (!) nm, PtrUsage.WRITTEN);
                    }
                }
                scan_expr (cal.callee, pa);
                for (int i = 0; i < cal.args.length; i++)
                    scan_expr (cal.args[i], pa);
            } else if (e is ExprInitList) {
                var il = (ExprInitList) e;
                for (int i = 0; i < il.items.length; i++)
                    scan_expr (il.items[i], pa);
            }
        }

        public static PtrAnalysis analyze_func (FuncDef fn) {
            var pa = new PtrAnalysis ();
            for (int i = 0; i < fn.params.length; i++) {
                var p = fn.params[i];
                if (p.ctype.kind == CTypeKind.PTR || p.ctype.kind == CTypeKind.ARRAY)
                    pa.ensure (p.name, p.ctype, true);
            }
            if (fn.body != null)
                scan_stmt ((CStmt) fn.body, pa);
            for (int i = 0; i < pa.entries.length; i++)
                classify_info (pa.entries[i]);
            return pa;
        }
    }
}
