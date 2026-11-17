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

        public GotoPlan (string label, string flag_name) {
            this.label = label;
            this.flag_name = flag_name;
        }
    }

    public class Translator : Object {
        private TranslationUnit tu;
        private GenericArray<FuncSig> sigs = new GenericArray<FuncSig> ();
        private GenericArray<string> enum_member_names = new GenericArray<string> ();
        private GenericArray<string> enum_member_types = new GenericArray<string> ();
        private GenericArray<int64> enum_member_vals = new GenericArray<int64> ();

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
            if (k == "long" || k == "ulong" || k == "size_t" || k == "int64" || k == "uint64") return 5;
            if (k == "float") return 6;
            if (k == "double") return 7;
            return 4;
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
                refuse_loc (e.file, e.line, @"unsupported constant operator '$(b.op)'");
            }
            refuse_loc (e.file, e.line, "non-constant enum initializer");
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
                    enum_member_vals.add (next_val);
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
                return nm == "malloc" || nm == "calloc";
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
                }
                if (scan_expr_for_arrays (u.operand, locals)) changed = true;
            } else if (e is ExprAssign) {
                var a = (ExprAssign) e;
                if (a.lvalue is ExprIdent) {
                    var li = find_local (locals, ((ExprIdent) a.lvalue).name);
                    if (li != null && !li.is_array) {
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
                if (scan_expr_for_arrays (a.lvalue, locals)) changed = true;
                if (scan_expr_for_arrays (a.rvalue, locals)) changed = true;
            } else if (e is ExprCall) {
                var c = (ExprCall) e;
                if (c.callee is ExprIdent) {
                    var csig = find_sig (((ExprIdent) c.callee).name);
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
                throw new RefuseError.FAILED ("function pointers are not supported");
            if (ct.kind == CTypeKind.SCALAR)
                return ct.name;
            if (ct.kind == CTypeKind.ENUM)
                return ct.name;
            if (ct.kind == CTypeKind.STRUCT || ct.kind == CTypeKind.UNION)
                return ct.name;
            if (ct.kind == CTypeKind.ARRAY && ct.inner != null) {
                return vala_type ((CType) ct.inner, false) + "[]";
            }
            if (ct.kind == CTypeKind.PTR && ct.inner != null) {
                var inner = (CType) ct.inner;
                if (as_array) {
                    if (inner.is_scalar ("char"))
                        return "uchar[]";
                    return vala_type (inner, false) + "[]";
                }
                if (inner.is_scalar ("char"))
                    return "string";
                if (inner.kind == CTypeKind.STRUCT)
                    return inner.name + "?";
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

            var sb = new StrBuilder ();
            sb.append ("// Generated by c2vala.\n\n");

            int ei = 0;
            int si = 0;
            int fi = 0;
            for (int ti = 0; ti < tu.top_order.length; ti++) {
                string kind = tu.top_kinds[ti];
                if (kind == "enum") {
                    emit_enum (sb, tu.enums[ei++]);
                    sb.append ("\n");
                } else if (kind == "struct") {
                    emit_struct (sb, tu.structs[si++]);
                    sb.append ("\n");
                } else if (kind == "func") {
                    var fn = tu.funcs[fi];
                    var sig = sigs[fi];
                    fi++;
                    if (report_mode) {
                        try {
                            var fsb = new StrBuilder ();
                            emit_func (fsb, fn, sig);
                            sb.append (fsb.str);
                            sb.append ("\n");
                            report_entries.add (new ReportEntry (fn.name, true));
                            translated_count++;
                        } catch (RefuseError e) {
                            sb.append (@"// c2vala refused $(fn.name): $(e.message)\n\n");
                            report_entries.add (new ReportEntry (fn.name, false, e.message));
                            refused_count++;
                        }
                    } else {
                        emit_func (sb, fn, sig);
                        sb.append ("\n");
                        report_entries.add (new ReportEntry (fn.name, true));
                        translated_count++;
                    }
                }
            }

            return sb.str;
        }

        private void emit_enum (StrBuilder sb, EnumDef ed) {
            sb.append (@"public enum $(ed.name) {\n");
            for (int i = 0; i < ed.members.length; i++) {
                var m = ed.members[i];
                string comma = (i + 1 < ed.members.length) ? "," : "";
                sb.append (@"    $(m.name) = $(m.val)$comma\n");
            }
            sb.append ("}\n");
        }

        private void emit_struct (StrBuilder sb, StructDef sd) throws RefuseError {
            if (sd.is_union)
                sb.append (@"public union $(sd.name) {\n");
            else
                sb.append (@"public class $(sd.name) : Object {\n");
            for (int i = 0; i < sd.fields.length; i++) {
                var f = sd.fields[i];
                string vt = vala_type (f.ctype, false);
                sb.append (@"    public $vt $(f.name);\n");
            }
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

            cur_fn = fn;
            cur_sig = sig;
            cur_locals = new GenericArray<LocalInfo> ();
            cur_gotos = new GenericArray<GotoPlan> ();

            if (fn.name == "main") {
                sb.append ("int main (string[] args) {\n");
            } else {
                string ret_t = vala_type (fn.ret_type, sig.ret_is_array);
                sb.append (@"$ret_t $(fn.name) (");
                for (int i = 0; i < fn.params.length; i++) {
                    var p = fn.params[i];
                    string pt = vala_type (p.ctype, sig.param_is_array[i]);
                    if (i > 0)
                        sb.append (", ");
                    sb.append (@"$pt $(p.name)");
                    var li = new LocalInfo (p.name, p.ctype, true);
                    li.is_array = sig.param_is_array[i];
                    cur_locals.add (li);
                }
                sb.append (") {\n");
            }

            if (fn.body != null) {
                plan_gotos ((StmtBlock) fn.body);
                for (int gi = 0; gi < cur_gotos.length; gi++) {
                    sb.append (@"    bool $(cur_gotos[gi].flag_name) = false;\n");
                }
                var blk = (StmtBlock) fn.body;
                emit_stmt_list (sb, blk.stmts, 1);
            }
            sb.append ("}\n");
        }

        private void plan_gotos (StmtBlock blk) throws RefuseError {
            // Check if any goto targets a label immediately after a loop in this block
            var gotos = new GenericArray<StmtGoto> ();
            collect_gotos (blk, gotos);
            if (gotos.length == 0)
                return;

            for (int gi = 0; gi < gotos.length; gi++) {
                var g = gotos[gi];
                bool found = false;
                for (int i = 0; i + 1 < blk.stmts.length; i++) {
                    var cur_s = blk.stmts[i];
                    var nxt_s = blk.stmts[i + 1];
                    if ((cur_s is StmtFor || cur_s is StmtWhile) && nxt_s is StmtLabel) {
                        var ls = (StmtLabel) nxt_s;
                        if (ls.label == g.label) {
                            found = true;
                            bool already = false;
                            for (int pi = 0; pi < cur_gotos.length; pi++) {
                                if (cur_gotos[pi].label == g.label) {
                                    already = true;
                                    break;
                                }
                            }
                            if (!already)
                                cur_gotos.add (new GotoPlan (g.label, "c2v_goto_" + g.label));
                            break;
                        }
                    }
                }
                if (!found)
                    refuse_loc (g.file, g.line, "goto: the label must be a top-level statement after the loop");
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
                string? gf = cur_gotos.length > 0 ? cur_gotos[0].flag_name : null;
                if (ws.is_do) {
                    indent (sb, level);
                    sb.append ("do ");
                    emit_loop_body (sb, ws.body, level, gf);
                    indent (sb, level);
                    sb.append ("while (");
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
                    sb.append (@"$vt $(d.name)");
                    if (d.init != null)
                        sb.append (@" = $(emit_expr ((CExpr) d.init))");
                } else if (fs.init_expr != null) {
                    sb.append (emit_expr ((CExpr) fs.init_expr));
                }
                sb.append ("; ");
                if (fs.cond != null)
                    sb.append (emit_cond ((CExpr) fs.cond));
                sb.append ("; ");
                if (fs.next != null)
                    sb.append (emit_expr ((CExpr) fs.next));
                sb.append (") ");
                emit_loop_body (sb, fs.body, level, gf);
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
                sb.append ("continue;\n");
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

        private void emit_decl (StrBuilder sb, StmtDecl d, int level) throws RefuseError {
            if (d.init is ExprInitList)
                refuse_loc (d.file, d.line, "initializer lists are not supported");

            var li = new LocalInfo (d.name, d.ctype, false);
            bool is_malloc_init = is_alloc_call (d.init);
            if (d.ctype.kind == CTypeKind.ARRAY || is_malloc_init)
                li.is_array = true;
            // Check if pre-marked in fixpoint? If pointer and assigned malloc later, mark array!
            if (d.ctype.kind == CTypeKind.PTR && cur_fn != null && cur_fn.body != null) {
                if (is_var_assigned_array ((CStmt) cur_fn.body, d.name))
                    li.is_array = true;
            }
            cur_locals.add (li);

            // Fixed-size array `T name[N];`
            if (d.ctype.kind == CTypeKind.ARRAY && d.ctype.inner != null) {
                if (d.ctype.array_len == null)
                    refuse_loc (d.file, d.line, "array without size");
                string elem_t = vala_type ((CType) d.ctype.inner, false);
                string len_s = emit_expr ((CExpr) d.ctype.array_len);
                indent (sb, level);
                sb.append (@"$elem_t[] $(d.name) = new $elem_t[$len_s];\n");
                if (((CType) d.ctype.inner).kind == CTypeKind.STRUCT) {
                    indent (sb, level);
                    sb.append (@"for (int _c2v_i = 0; _c2v_i < $len_s; _c2v_i++) { $(d.name)[_c2v_i] = new $elem_t (); }\n");
                }
                return;
            }

            string vt = vala_type (d.ctype, li.is_array);
            indent (sb, level);
            if (d.init != null) {
                if (is_malloc_init) {
                    string alloc_s = emit_alloc ((ExprCall) d.init, li.ctype);
                    sb.append (@"$vt $(d.name) = $alloc_s;\n");
                } else {
                    sb.append (@"$vt $(d.name) = $(emit_expr ((CExpr) d.init));\n");
                }
            } else {
                if (d.ctype.kind == CTypeKind.STRUCT) {
                    sb.append (@"$vt $(d.name) = new $vt ();\n");
                } else if (d.ctype.kind == CTypeKind.UNION) {
                    sb.append (@"$vt $(d.name) = $vt ();\n");
                } else if (li.is_array && d.ctype.kind == CTypeKind.PTR && d.ctype.inner != null) {
                    string elem_t = d.ctype.is_char_ptr () ? "uchar" : vala_type ((CType) d.ctype.inner, false);
                    sb.append (@"$vt $(d.name) = new $elem_t[0];\n");
                } else if (d.ctype.is_struct_ptr ()) {
                    sb.append (@"$vt $(d.name) = null;\n");
                } else if (d.ctype.is_char_ptr ()) {
                    sb.append (@"$vt $(d.name) = \"\";\n");
                } else if (d.ctype.kind == CTypeKind.ENUM) {
                    sb.append (@"$vt $(d.name) = ($vt) 0;\n");
                } else {
                    sb.append (@"$vt $(d.name) = 0;\n");
                }
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

        private void emit_switch (StrBuilder sb, StmtSwitch sw, int level) throws RefuseError {
            // Check for fallthrough with statements
            for (int i = 0; i < sw.cases.length; i++) {
                var sc = sw.cases[i];
                if (sc.stmts.length > 0) {
                    var last = sc.stmts[sc.stmts.length - 1];
                    bool terminates = (last is StmtBreak || last is StmtReturn || last is StmtGoto || last is StmtContinue);
                    if (!terminates && i + 1 < sw.cases.length) {
                        refuse_loc (last.file, last.line, "switch fallthrough with statements is not supported");
                    }
                }
            }

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
        }

        // ---- Expression typing & emission ----

        private CType? infer_type (CExpr e) throws RefuseError {
            if (e is ExprInt) {
                var ei = (ExprInt) e;
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
                return null;
            }
            if (e is ExprCast)
                return ((ExprCast) e).target_type;
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
                return infer_type (u.operand);
            }
            if (e is ExprCall) {
                var c = (ExprCall) e;
                if (c.callee is ExprIdent) {
                    string fn = ((ExprIdent) c.callee).name;
                    if (fn == "strlen" || fn == "strcmp" || fn == "strncmp" || fn == "printf" || fn == "fprintf")
                        return CType.scalar ("int");
                    var sig = find_sig (fn);
                    if (sig != null)
                        return sig.ret_type;
                }
            }
            return null;
        }

        private string emit_cond (CExpr e) throws RefuseError {
            var t = infer_type (e);
            string s = emit_expr (e);
            if (t != null && t.is_scalar ("bool"))
                return s;
            if (t != null && t.kind == CTypeKind.PTR)
                return @"($s != null)";
            return @"($s != 0)";
        }

        private string emit_expr (CExpr e) throws RefuseError {
            if (e is ExprInt)
                return ((ExprInt) e).raw;
            if (e is ExprFloat)
                return ((ExprFloat) e).raw;
            if (e is ExprChar)
                return ((ExprChar) e).raw;
            if (e is ExprStr)
                return ((ExprStr) e).raw;
            if (e is ExprIdent) {
                string nm = ((ExprIdent) e).name;
                if (find_local (cur_locals, nm) != null)
                    return nm;
                int em = find_enum_member (nm);
                if (em >= 0)
                    return @"$(enum_member_types[em]).$nm";
                if (nm == "NULL")
                    return "null";
                refuse_loc (e.file, e.line, @"unknown identifier '$nm'");
            }
            if (e is ExprCast) {
                var c = (ExprCast) e;
                string vt = vala_type (c.target_type, false);
                return @"(($vt) $(emit_expr (c.expr)))";
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
                        if (ot != null && ot.kind == CTypeKind.STRUCT)
                            return emit_expr (u.operand);
                    }
                    refuse_loc (e.file, e.line, "address-of a non-lvalue");
                }
                if (u.op == "*")
                    refuse_loc (e.file, e.line, "pointer dereference is not supported");
                string op_s = emit_expr (u.operand);
                if (u.op == "!")
                    return @"(!$(emit_cond (u.operand)))";
                if (u.is_post)
                    return @"$op_s$(u.op)";
                return @"$(u.op)$op_s";
            }
            if (e is ExprBinary) {
                var b = (ExprBinary) e;
                var lt = infer_type (b.left);
                var rt = infer_type (b.right);
                if (b.op == "&&" || b.op == "||") {
                    return @"($(emit_cond (b.left)) $(b.op) $(emit_cond (b.right)))";
                }
                if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)) {
                    if (b.op == "+" || b.op == "-")
                        refuse_loc (e.file, e.line, "pointer arithmetic is not supported");
                }
                string ls = emit_expr (b.left);
                string rs = emit_expr (b.right);
                if ((b.op == "==" || b.op == "!=")) {
                    if (lt != null && (lt.kind == CTypeKind.PTR || lt.kind == CTypeKind.ARRAY)
                        && b.right is ExprInt && ((ExprInt) b.right).val == 0) {
                        rs = "null";
                    } else if (rt != null && (rt.kind == CTypeKind.PTR || rt.kind == CTypeKind.ARRAY)
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
                if (is_alloc_call (a.rvalue) && a.lvalue is ExprIdent) {
                    var li = find_local (cur_locals, ((ExprIdent) a.lvalue).name);
                    if (li != null) {
                        return @"$(li.name) = $(emit_alloc ((ExprCall) a.rvalue, li.ctype))";
                    }
                }
                return @"$(emit_expr (a.lvalue)) $(a.op) $(emit_expr (a.rvalue))";
            }
            if (e is ExprTernary) {
                var t = (ExprTernary) e;
                return @"($(emit_cond (t.cond)) ? $(emit_expr (t.if_true)) : $(emit_expr (t.if_false)))";
            }
            if (e is ExprIndex) {
                var ix = (ExprIndex) e;
                return @"$(emit_expr (ix.array))[(int) $(emit_expr (ix.index))]";
            }
            if (e is ExprMember) {
                var m = (ExprMember) e;
                string os = emit_expr (m.obj);
                if (m.is_arrow) {
                    var ot = infer_type (m.obj);
                    if (ot != null && ot.kind == CTypeKind.PTR && ot.inner != null && ot.inner.kind == CTypeKind.STRUCT) {
                        string st_name = ot.inner.name;
                        return @"(($st_name) $os).$(m.field)";
                    }
                    return @"$os.$(m.field)";
                }
                return @"$os.$(m.field)";
            }
            if (e is ExprCall) {
                return emit_call ((ExprCall) e);
            }
            if (e is ExprInitList) {
                refuse_loc (e.file, e.line, "initializer lists are not supported");
            }
            refuse_loc (e.file, e.line, "unsupported expression");
        }

        private string emit_alloc (ExprCall call, CType target_ptr) throws RefuseError {
            string fn = ((ExprIdent) call.callee).name;
            if (target_ptr.kind != CTypeKind.PTR || target_ptr.inner == null)
                refuse_loc (call.file, call.line, "malloc whose size does not imply an element type");
            var inner = (CType) target_ptr.inner;
            if (inner.kind == CTypeKind.STRUCT)
                refuse_loc (call.file, call.line, "malloc of structs is not supported");
            string elem_t = inner.is_scalar ("char") ? "uchar" : vala_type (inner, false);

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
            // malloc(n) for char* -> new uchar[n]
            if (inner.is_scalar ("char"))
                return @"new uchar[$(emit_expr (arg))]";

            refuse_loc (call.file, call.line, "malloc whose size does not imply an element type");
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

        private string emit_call (ExprCall c) throws RefuseError {
            if (!(c.callee is ExprIdent))
                refuse_loc (c.file, c.line, "indirect calls are not supported");
            string fn = ((ExprIdent) c.callee).name;

            if (fn == "malloc" || fn == "calloc")
                refuse_loc (c.file, c.line, @"$fn is only supported in a local declaration");

            if (fn == "memcpy" || fn == "memmove" || fn == "memset"
                || fn == "strcpy" || fn == "strncpy" || fn == "strcat" || fn == "realloc")
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

            var sb = new StrBuilder (@"$fn (");
            for (int i = 0; i < c.args.length; i++) {
                if (i > 0) sb.append (", ");
                sb.append (emit_expr (c.args[i]));
            }
            sb.append (")");
            return sb.str;
        }
    }
}
