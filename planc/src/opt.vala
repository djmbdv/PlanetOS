// AST optimization pass for planc (-O1 / -O2):
// - Constant folding (int/bool/string arithmetic, bitwise, comparisons, ternary)
// - Algebraic identities & strength reduction (x * 2^k -> x << k, x + 0 -> x)
// - Dead-code elimination (if(true/false), while(false), unreachable after return/break/continue)

namespace Planc {

    private static GenericArray<Function> mt_opt_funcs;
    private static GenericArray<string> mt_opt_owners;
    private static Program mt_opt_prog;
    private static int mt_opt_level = 0;
    private static int mt_opt_next = 0;
    private static int[] mt_opt_lock;

    public sealed class Optimizer : Object {
        private int level = 0;
        private Program? cur_prog = null;
        private string cur_owner = "";
        private string cur_file = "";
        private Function? cur_func = null;
        private GenericArray<string> active_locals = new GenericArray<string> ();
        private GenericArray<string> arr_vnames = new GenericArray<string> ();
        private int licm_counter = 0;
        private int sra_counter = 0;
        private int fe_counter = 0;

        private static void mt_opt_worker (int wid) {
            var opt = new Optimizer ();
            opt.level = mt_opt_level;
            opt.cur_prog = mt_opt_prog;
            int n = mt_opt_funcs.length;
            while (true) {
                Host.spin_lock (mt_opt_lock);
                int i = mt_opt_next++;
                Host.spin_unlock (mt_opt_lock);
                if (i >= n)
                    break;
                opt.cur_owner = mt_opt_owners[i];
                opt.opt_func (mt_opt_funcs[i]);
            }
        }

        private static bool class_has_subclasses (Program prog, string cname) {
            for (int i = 0; i < prog.classes.length; i++) {
                if (prog.classes[i].base_name == cname)
                    return true;
            }
            return false;
        }

        private static unowned Function? find_class_method_opt (ClassDecl cd, string mname) {
            for (int i = 0; i < cd.methods.length; i++) {
                if (cd.methods[i].method_name == mname || cd.methods[i].name == mname)
                    return cd.methods[i];
            }
            return null;
        }

        private static bool cd_has_field (ClassDecl cd, string fname) {
            for (int i = 0; i < cd.fields.length; i++) {
                if (cd.fields[i].name == fname)
                    return true;
            }
            return false;
        }

        private static bool expr_is_inline_leaf (Expr? e) {
            if (e == null) return false;
            if (e is IntLiteral || e is FloatLiteral || e is BoolLiteral
                || e is StringLiteral || e is NullLiteral || e is VarRef)
                return true;
            if (e is UnaryExpr) return expr_is_inline_leaf (((UnaryExpr) e).operand);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return expr_is_inline_leaf (b.left) && expr_is_inline_leaf (b.right);
            }
            if (e is MemberAccessExpr) return expr_is_inline_leaf (((MemberAccessExpr) e).target);
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return expr_is_inline_leaf (ix.target) && expr_is_inline_leaf (ix.index);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return expr_is_inline_leaf (te.condition)
                    && expr_is_inline_leaf (te.then_expr)
                    && expr_is_inline_leaf (te.else_expr);
            }
            if (e is TypeCheckExpr) return expr_is_inline_leaf (((TypeCheckExpr) e).operand);
            return false;
        }

        private static int count_var_uses (Expr? e, string name) {
            if (e == null) return 0;
            if (e is VarRef) return (((VarRef) e).name == name) ? 1 : 0;
            if (e is UnaryExpr) return count_var_uses (((UnaryExpr) e).operand, name);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return count_var_uses (b.left, name) + count_var_uses (b.right, name);
            }
            if (e is MemberAccessExpr) return count_var_uses (((MemberAccessExpr) e).target, name);
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return count_var_uses (ix.target, name) + count_var_uses (ix.index, name);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return count_var_uses (te.condition, name)
                    + count_var_uses (te.then_expr, name)
                    + count_var_uses (te.else_expr, name);
            }
            return 0;
        }

        private static bool is_pure_arg (Expr e) {
            return (e is IntLiteral) || (e is BoolLiteral) || (e is NullLiteral) || (e is VarRef);
        }

        private static Expr subst_inline_expr (Program prog, Expr e,
                                               GenericArray<string> pnames,
                                               GenericArray<Expr> pargs,
                                               ClassDecl? cd, string? this_var) {
            if (e is VarRef) {
                var vr = (VarRef) e;
                for (int i = 0; i < pnames.length; i++) {
                    if (pnames[i] == vr.name)
                        return prog.clone_expr_plain (pargs[i]);
                }
                if (cd != null && this_var != null) {
                    if (vr.name == "this")
                        return new VarRef () { name = this_var, line = e.line, column = e.column };
                    if (cd_has_field (cd, vr.name))
                        return new MemberAccessExpr () {
                            target = new VarRef () { name = this_var, line = e.line, column = e.column },
                            member = vr.name,
                            line = e.line,
                            column = e.column
                        };
                }
                return e;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = subst_inline_expr (prog, u.operand, pnames, pargs, cd, this_var);
                return u;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = subst_inline_expr (prog, b.left, pnames, pargs, cd, this_var);
                b.right = subst_inline_expr (prog, b.right, pnames, pargs, cd, this_var);
                return b;
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                ma.target = subst_inline_expr (prog, ma.target, pnames, pargs, cd, this_var);
                return ma;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = subst_inline_expr (prog, ix.target, pnames, pargs, cd, this_var);
                ix.index = subst_inline_expr (prog, ix.index, pnames, pargs, cd, this_var);
                return ix;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = subst_inline_expr (prog, te.condition, pnames, pargs, cd, this_var);
                te.then_expr = subst_inline_expr (prog, te.then_expr, pnames, pargs, cd, this_var);
                te.else_expr = subst_inline_expr (prog, te.else_expr, pnames, pargs, cd, this_var);
                return te;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++)
                    c.args[i] = subst_inline_expr (prog, c.args[i], pnames, pargs, cd, this_var);
                return c;
            }
            return e;
        }

        private static bool expr_only_uses_scope (Expr? e, Function fn, ClassDecl? cd) {
            if (e == null) return true;
            if (e is VarRef) {
                string name = ((VarRef) e).name;
                for (int i = 0; i < fn.params.length; i++) {
                    if (fn.params[i].name == name)
                        return true;
                }
                if (cd != null && (name == "this" || cd_has_field (cd, name)))
                    return true;
                return false;
            }
            if (e is UnaryExpr) return expr_only_uses_scope (((UnaryExpr) e).operand, fn, cd);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return expr_only_uses_scope (b.left, fn, cd) && expr_only_uses_scope (b.right, fn, cd);
            }
            if (e is MemberAccessExpr) return expr_only_uses_scope (((MemberAccessExpr) e).target, fn, cd);
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return expr_only_uses_scope (ix.target, fn, cd) && expr_only_uses_scope (ix.index, fn, cd);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return expr_only_uses_scope (te.condition, fn, cd)
                    && expr_only_uses_scope (te.then_expr, fn, cd)
                    && expr_only_uses_scope (te.else_expr, fn, cd);
            }
            return true;
        }

        private static int inline_seq = 0;

        private static Expr? try_extract_inline_ret_expr (Function fn) {
            if (fn.body == null) return null;
            if (fn.body.length == 1 && fn.body[0] is ReturnStatement) {
                return ((ReturnStatement) fn.body[0]).value;
            }
            if (fn.body.length == 1 && fn.body[0] is IfStatement) {
                var ifs = (IfStatement) fn.body[0];
                var r1 = unwrap_single_ret (ifs.then_body);
                var r2 = unwrap_single_ret (ifs.else_body);
                if (r1 != null && r2 != null) {
                    return new TernaryExpr () {
                        condition = ifs.condition,
                        then_expr = r1,
                        else_expr = r2,
                        line = ifs.line,
                        column = ifs.column
                    };
                }
            }
            if (fn.body.length == 2 && fn.body[0] is IfStatement && fn.body[1] is ReturnStatement) {
                var ifs = (IfStatement) fn.body[0];
                var r1 = (ifs.else_body == null) ? unwrap_single_ret (ifs.then_body) : null;
                var r2 = ((ReturnStatement) fn.body[1]).value;
                if (r1 != null && r2 != null) {
                    return new TernaryExpr () {
                        condition = ifs.condition,
                        then_expr = r1,
                        else_expr = r2,
                        line = ifs.line,
                        column = ifs.column
                    };
                }
            }
            return null;
        }

        private static Expr? unwrap_single_ret (Statement? s) {
            if (s == null) return null;
            if (s is ReturnStatement) return ((ReturnStatement) s).value;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                if (blk.statements.length == 1 && blk.statements[0] is ReturnStatement)
                    return ((ReturnStatement) blk.statements[0]).value;
            }
            return null;
        }

        private static bool can_inline_fn (Function fn, int arg_count, int param_offset, GenericArray<Expr> args, Expr body_expr, ClassDecl? cd = null, bool allow_devirt = false) {
            if (fn.is_async || fn.is_asm_body || fn.can_throw || fn.is_varargs || fn.is_abstract)
                return false;
            if ((fn.is_virtual || fn.is_override) && !allow_devirt)
                return false;
            if (fn.params.length != arg_count + param_offset)
                return false;
            for (int i = 0; i < fn.params.length; i++) {
                if (fn.params[i].is_ref || fn.params[i].is_out || fn.params[i].param_type == ValaType.STRUCT)
                    return false;
            }
            if (!expr_is_inline_leaf (body_expr))
                return false;
            if (!expr_only_uses_scope (body_expr, fn, cd))
                return false;
            for (int i = 0; i < arg_count; i++) {
                if (!is_pure_arg (args[i]) && count_var_uses (body_expr, fn.params[i + param_offset].name) > 1)
                    return false;
            }
            return true;
        }

        private static string? lookup_var_class (GenericArray<string> vnames, GenericArray<string> vclasses, string name) {
            for (int i = vnames.length - 1; i >= 0; i--) {
                if (vnames[i] == name)
                    return vclasses[i];
            }
            return null;
        }

        private static Expr inline_expr (Program prog, Expr e,
                                         GenericArray<string> vnames, GenericArray<string> vclasses) {
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = inline_expr (prog, u.operand, vnames, vclasses);
                return u;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = inline_expr (prog, b.left, vnames, vclasses);
                b.right = inline_expr (prog, b.right, vnames, vclasses);
                return b;
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                ma.target = inline_expr (prog, ma.target, vnames, vclasses);
                return ma;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = inline_expr (prog, ix.target, vnames, vclasses);
                ix.index = inline_expr (prog, ix.index, vnames, vclasses);
                return ix;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = inline_expr (prog, te.condition, vnames, vclasses);
                te.then_expr = inline_expr (prog, te.then_expr, vnames, vclasses);
                te.else_expr = inline_expr (prog, te.else_expr, vnames, vclasses);
                return te;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++)
                    c.args[i] = inline_expr (prog, c.args[i], vnames, vclasses);
                unowned var fn = prog.find (c.callee);
                if (fn != null) {
                    var body_e = try_extract_inline_ret_expr (fn);
                    if (body_e != null && can_inline_fn (fn, c.args.length, 0, c.args, body_e)) {
                        var pnames = new GenericArray<string> ();
                        for (int i = 0; i < fn.params.length; i++)
                            pnames.add (fn.params[i].name);
                        var cloned = prog.clone_expr_plain (body_e);
                        return subst_inline_expr (prog, cloned, pnames, c.args, null, null);
                    }
                }
                return c;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    mc.target = inline_expr (prog, mc.target, vnames, vclasses);
                for (int i = 0; i < mc.args.length; i++)
                    mc.args[i] = inline_expr (prog, mc.args[i], vnames, vclasses);
                if (mc.target is VarRef) {
                    string obj = ((VarRef) mc.target).name;
                    string? cname = lookup_var_class (vnames, vclasses, obj);
                    if (cname != null && !class_has_subclasses (prog, cname)) {
                        unowned var cd = prog.find_class (cname);
                        if (cd != null && (cd.base_name == "" || cd.base_name == "Object")) {
                            unowned var fn = find_class_method_opt (cd, mc.method_name);
                            int poff = (fn != null && fn.params.length >= 1 && fn.params[0].name == "this") ? 1 : 0;
                            if (fn != null && !fn.is_static) {
                                var body_e = try_extract_inline_ret_expr (fn);
                                if (body_e != null && can_inline_fn (fn, mc.args.length, poff, mc.args, body_e, cd, true)) {
                                    var pnames = new GenericArray<string> ();
                                    for (int i = poff; i < fn.params.length; i++)
                                        pnames.add (fn.params[i].name);
                                    var cloned = prog.clone_expr_plain (body_e);
                                    return subst_inline_expr (prog, cloned, pnames, mc.args, cd, obj);
                                }
                            }
                        }
                    }
                }
                return mc;
            }
            return e;
        }

        private static bool expr_only_uses_multi_scope (Program prog, Expr? e, Function fn, ClassDecl? cd, GenericArray<string> lnames) {
            if (e == null) return true;
            if (e is VarRef) {
                string name = ((VarRef) e).name;
                for (int i = 0; i < fn.params.length; i++) {
                    if (fn.params[i].name == name) return true;
                }
                for (int i = 0; i < lnames.length; i++) {
                    if (lnames[i] == name) return true;
                }
                if (cd != null && (name == "this" || cd_has_field (cd, name)))
                    return true;
                return false;
            }
            if (e is UnaryExpr) return expr_only_uses_multi_scope (prog, ((UnaryExpr) e).operand, fn, cd, lnames);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return expr_only_uses_multi_scope (prog, b.left, fn, cd, lnames)
                    && expr_only_uses_multi_scope (prog, b.right, fn, cd, lnames);
            }
            if (e is MemberAccessExpr) return expr_only_uses_multi_scope (prog, ((MemberAccessExpr) e).target, fn, cd, lnames);
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return expr_only_uses_multi_scope (prog, ix.target, fn, cd, lnames)
                    && expr_only_uses_multi_scope (prog, ix.index, fn, cd, lnames);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return expr_only_uses_multi_scope (prog, te.condition, fn, cd, lnames)
                    && expr_only_uses_multi_scope (prog, te.then_expr, fn, cd, lnames)
                    && expr_only_uses_multi_scope (prog, te.else_expr, fn, cd, lnames);
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                unowned var cf = prog.find (c.callee);
                if (cf == null || cf.owner_class != "") return false;
                for (int i = 0; i < c.args.length; i++) {
                    if (!expr_only_uses_multi_scope (prog, c.args[i], fn, cd, lnames)) return false;
                }
                return true;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target == null || !expr_only_uses_multi_scope (prog, mc.target, fn, cd, lnames)) return false;
                for (int i = 0; i < mc.args.length; i++) {
                    if (!expr_only_uses_multi_scope (prog, mc.args[i], fn, cd, lnames)) return false;
                }
                return true;
            }
            return (e is IntLiteral) || (e is FloatLiteral) || (e is BoolLiteral)
                || (e is StringLiteral) || (e is NullLiteral);
        }

        private static bool stmt_ok_for_multi_inline (Program prog, Statement? s, Function fn, ClassDecl? cd,
                                                      GenericArray<string> lnames, bool allow_ret, bool is_last) {
            if (s == null) return true;
            string fn_name = fn.name;
            if (s is ReturnStatement) {
                if (!allow_ret || !is_last) return false;
                var rs = (ReturnStatement) s;
                return rs.value != null && !expr_calls_fn (rs.value, fn_name)
                    && expr_only_uses_multi_scope (prog, rs.value, fn, cd, lnames);
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (expr_calls_fn (d.init, fn_name) || !expr_only_uses_multi_scope (prog, d.init, fn, cd, lnames))
                    return false;
                lnames.add (d.name);
                return true;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                bool lhs_ok = false;
                for (int i = 0; i < fn.params.length; i++) {
                    if (fn.params[i].name == a.name) { lhs_ok = true; break; }
                }
                for (int i = 0; i < lnames.length && !lhs_ok; i++) {
                    if (lnames[i] == a.name) { lhs_ok = true; break; }
                }
                if (!lhs_ok && cd != null && cd_has_field (cd, a.name)) lhs_ok = true;
                return lhs_ok && !expr_calls_fn (a.value, fn_name)
                    && expr_only_uses_multi_scope (prog, a.value, fn, cd, lnames);
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return !expr_calls_fn (fa.target, fn_name) && !expr_calls_fn (fa.value, fn_name)
                    && expr_only_uses_multi_scope (prog, fa.target, fn, cd, lnames)
                    && expr_only_uses_multi_scope (prog, fa.value, fn, cd, lnames);
            }
            if (s is ExprStatement) {
                var ex = ((ExprStatement) s).expr;
                return !expr_calls_fn (ex, fn_name) && expr_only_uses_multi_scope (prog, ex, fn, cd, lnames);
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                if (expr_calls_fn (ifs.condition, fn_name) || !expr_only_uses_multi_scope (prog, ifs.condition, fn, cd, lnames))
                    return false;
                int m1 = lnames.length;
                bool ok1 = stmt_ok_for_multi_inline (prog, ifs.then_body, fn, cd, lnames, false, false);
                while (lnames.length > m1) lnames.remove_index (lnames.length - 1);
                if (!ok1) return false;
                bool ok2 = stmt_ok_for_multi_inline (prog, ifs.else_body, fn, cd, lnames, false, false);
                while (lnames.length > m1) lnames.remove_index (lnames.length - 1);
                return ok2;
            }
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                int m1 = lnames.length;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (!stmt_ok_for_multi_inline (prog, blk.statements[i], fn, cd, lnames, false, false)) {
                        while (lnames.length > m1) lnames.remove_index (lnames.length - 1);
                        return false;
                    }
                }
                while (lnames.length > m1) lnames.remove_index (lnames.length - 1);
                return true;
            }
            return false;
        }

        private static bool expr_calls_fn (Expr? e, string fn_name) {
            if (e == null) return false;
            if (e is CallExpr) {
                var c = (CallExpr) e;
                if (c.callee == fn_name) return true;
                for (int i = 0; i < c.args.length; i++) {
                    if (expr_calls_fn (c.args[i], fn_name)) return true;
                }
                return false;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.method_name == fn_name) return true;
                if (expr_calls_fn (mc.target, fn_name)) return true;
                for (int i = 0; i < mc.args.length; i++) {
                    if (expr_calls_fn (mc.args[i], fn_name)) return true;
                }
                return false;
            }
            if (e is UnaryExpr) return expr_calls_fn (((UnaryExpr) e).operand, fn_name);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return expr_calls_fn (b.left, fn_name) || expr_calls_fn (b.right, fn_name);
            }
            if (e is MemberAccessExpr) return expr_calls_fn (((MemberAccessExpr) e).target, fn_name);
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return expr_calls_fn (ix.target, fn_name) || expr_calls_fn (ix.index, fn_name);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return expr_calls_fn (te.condition, fn_name)
                    || expr_calls_fn (te.then_expr, fn_name)
                    || expr_calls_fn (te.else_expr, fn_name);
            }
            return false;
        }

        private static bool can_inline_multi_fn (Program prog, Function fn, int arg_count, int param_offset,
                                                 ClassDecl? cd, bool allow_ret, bool allow_devirt) {
            if (fn.is_async || fn.is_asm_body || fn.can_throw || fn.is_varargs || fn.is_abstract)
                return false;
            if (cd == null && fn.owner_class != "")
                return false;
            if ((fn.is_virtual || fn.is_override) && !allow_devirt)
                return false;
            if (fn.params.length != arg_count + param_offset)
                return false;
            for (int i = 0; i < fn.params.length; i++) {
                if (fn.params[i].is_ref || fn.params[i].is_out || fn.params[i].param_type == ValaType.STRUCT)
                    return false;
            }
            if (fn.body == null || fn.body.length == 0 || fn.body.length > 8)
                return false;
            var lnames = new GenericArray<string> ();
            for (int i = 0; i < fn.body.length; i++) {
                bool is_last = (i == fn.body.length - 1);
                if (!stmt_ok_for_multi_inline (prog, fn.body[i], fn, cd, lnames, allow_ret, is_last))
                    return false;
            }
            return true;
        }

        private static string? lookup_rename (GenericArray<string> old_n, GenericArray<string> new_n, string name) {
            for (int i = old_n.length - 1; i >= 0; i--) {
                if (old_n[i] == name) return new_n[i];
            }
            return null;
        }

        private static Expr subst_multi_expr (Program prog, Expr e,
                                              GenericArray<string> old_n, GenericArray<string> new_n,
                                              ClassDecl? cd, string? obj_var) {
            if (e is VarRef) {
                var vr = (VarRef) e;
                string? rn = lookup_rename (old_n, new_n, vr.name);
                if (rn != null)
                    return new VarRef () { name = rn, line = e.line, column = e.column };
                if (cd != null && obj_var != null) {
                    if (vr.name == "this")
                        return new VarRef () { name = obj_var, line = e.line, column = e.column };
                    if (cd_has_field (cd, vr.name))
                        return new MemberAccessExpr () {
                            target = new VarRef () { name = obj_var, line = e.line, column = e.column },
                            member = vr.name,
                            line = e.line,
                            column = e.column
                        };
                }
                return e;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = subst_multi_expr (prog, u.operand, old_n, new_n, cd, obj_var);
                return u;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = subst_multi_expr (prog, b.left, old_n, new_n, cd, obj_var);
                b.right = subst_multi_expr (prog, b.right, old_n, new_n, cd, obj_var);
                return b;
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                ma.target = subst_multi_expr (prog, ma.target, old_n, new_n, cd, obj_var);
                return ma;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = subst_multi_expr (prog, ix.target, old_n, new_n, cd, obj_var);
                ix.index = subst_multi_expr (prog, ix.index, old_n, new_n, cd, obj_var);
                return ix;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = subst_multi_expr (prog, te.condition, old_n, new_n, cd, obj_var);
                te.then_expr = subst_multi_expr (prog, te.then_expr, old_n, new_n, cd, obj_var);
                te.else_expr = subst_multi_expr (prog, te.else_expr, old_n, new_n, cd, obj_var);
                return te;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++)
                    c.args[i] = subst_multi_expr (prog, c.args[i], old_n, new_n, cd, obj_var);
                return c;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    mc.target = subst_multi_expr (prog, mc.target, old_n, new_n, cd, obj_var);
                for (int i = 0; i < mc.args.length; i++)
                    mc.args[i] = subst_multi_expr (prog, mc.args[i], old_n, new_n, cd, obj_var);
                return mc;
            }
            return e;
        }

        private static Statement clone_subst_stmt (Program prog, Statement s, int seq,
                                                   GenericArray<string> old_n, GenericArray<string> new_n,
                                                   ClassDecl? cd, string? obj_var,
                                                   string? assign_lhs, bool is_ret) {
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                string rn = @"__inl_$(seq)_$(d.name)";
                var nd = new VarDeclStatement () {
                    name = rn,
                    decl_type = d.decl_type,
                    decl_type_name = d.decl_type_name,
                    infer_type = d.infer_type,
                    is_weak = d.is_weak,
                    is_unowned = d.is_unowned,
                    init = (d.init != null) ? subst_multi_expr (prog, prog.clone_expr_plain (d.init), old_n, new_n, cd, obj_var) : null,
                    line = d.line,
                    column = d.column
                };
                old_n.add (d.name);
                new_n.add (rn);
                return nd;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                var val = subst_multi_expr (prog, prog.clone_expr_plain (a.value), old_n, new_n, cd, obj_var);
                string? rn = lookup_rename (old_n, new_n, a.name);
                if (rn != null) {
                    return new AssignStatement () {
                        name = rn, value = val, line = a.line, column = a.column
                    };
                }
                if (cd != null && obj_var != null && cd_has_field (cd, a.name)) {
                    return new FieldAssignStatement () {
                        target = new VarRef () { name = obj_var, line = a.line, column = a.column },
                        field_name = a.name,
                        op = "=",
                        value = val,
                        line = a.line,
                        column = a.column
                    };
                }
                return new AssignStatement () {
                    name = a.name, value = val, line = a.line, column = a.column
                };
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return new FieldAssignStatement () {
                    target = subst_multi_expr (prog, prog.clone_expr_plain (fa.target), old_n, new_n, cd, obj_var),
                    field_name = fa.field_name,
                    op = fa.op,
                    value = subst_multi_expr (prog, prog.clone_expr_plain (fa.value), old_n, new_n, cd, obj_var),
                    line = fa.line,
                    column = fa.column
                };
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                return new ExprStatement () {
                    expr = subst_multi_expr (prog, prog.clone_expr_plain (es.expr), old_n, new_n, cd, obj_var),
                    line = es.line,
                    column = es.column
                };
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                var nifs = new IfStatement () {
                    condition = subst_multi_expr (prog, prog.clone_expr_plain (ifs.condition), old_n, new_n, cd, obj_var),
                    line = ifs.line,
                    column = ifs.column
                };
                if (ifs.then_body != null)
                    nifs.then_body = clone_subst_stmt (prog, (!) ifs.then_body, seq, old_n, new_n, cd, obj_var, null, false);
                if (ifs.else_body != null)
                    nifs.else_body = clone_subst_stmt (prog, (!) ifs.else_body, seq, old_n, new_n, cd, obj_var, null, false);
                return nifs;
            }
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                var nblk = new BlockStatement () { line = blk.line, column = blk.column };
                int mark = old_n.length;
                for (int i = 0; i < blk.statements.length; i++)
                    nblk.statements.add (clone_subst_stmt (prog, blk.statements[i], seq, old_n, new_n, cd, obj_var, null, false));
                while (old_n.length > mark) old_n.remove_index (old_n.length - 1);
                while (new_n.length > mark) new_n.remove_index (new_n.length - 1);
                return nblk;
            }
            if (s is ReturnStatement) {
                var rs = (ReturnStatement) s;
                if (rs.value == null) {
                    // `value = null` in an initializer list makes valac unref a
                    // literal null and emits C that does not compile.
                    var nr = new ReturnStatement ();
                    nr.line = rs.line;
                    nr.column = rs.column;
                    return nr;
                }
                var rv = subst_multi_expr (prog, prog.clone_expr_plain ((!) rs.value), old_n, new_n, cd, obj_var);
                if (is_ret) {
                    return new ReturnStatement () { value = rv, line = rs.line, column = rs.column };
                }
                if (assign_lhs != null) {
                    return new AssignStatement () { name = assign_lhs, value = rv, line = rs.line, column = rs.column };
                }
                return new ExprStatement () { expr = rv, line = rs.line, column = rs.column };
            }
            return s;
        }

        private static BlockStatement build_multi_inline_block (Program prog, Function fn, int poff,
                                                                GenericArray<Expr> args, ClassDecl? cd, string? obj_var,
                                                                string? assign_lhs, bool is_ret, int line, int col) {
            inline_seq++;
            int seq = inline_seq;
            var blk = new BlockStatement () { line = line, column = col };
            var old_n = new GenericArray<string> ();
            var new_n = new GenericArray<string> ();
            for (int i = 0; i < args.length; i++) {
                var p = fn.params[poff + i];
                string rn = @"__inl_$(seq)_$(p.name)";
                blk.statements.add (new VarDeclStatement () {
                    name = rn,
                    decl_type = p.param_type,
                    decl_type_name = p.type_name,
                    infer_type = false,
                    init = prog.clone_expr_plain (args[i]),
                    line = line,
                    column = col
                });
                old_n.add (p.name);
                new_n.add (rn);
            }
            for (int i = 0; i < fn.body.length; i++) {
                blk.statements.add (clone_subst_stmt (prog, fn.body[i], seq, old_n, new_n, cd, obj_var, assign_lhs, is_ret));
            }
            return blk;
        }

        private static Statement inline_stmt (Program prog, Statement s,
                                              GenericArray<string> vnames, GenericArray<string> vclasses) {
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                int mark = vnames.length;
                for (int i = 0; i < blk.statements.length; i++)
                    blk.statements[i] = inline_stmt (prog, blk.statements[i], vnames, vclasses);
                while (vnames.length > mark) {
                    vnames.remove_index (vnames.length - 1);
                    vclasses.remove_index (vclasses.length - 1);
                }
                return blk;
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.init != null)
                    d.init = inline_expr (prog, d.init, vnames, vclasses);
                string cname = "";
                if (d.decl_type == ValaType.CLASS && d.decl_type_name != "")
                    cname = d.decl_type_name;
                else if (d.infer_type && d.init is ClassNewExpr)
                    cname = ((ClassNewExpr) d.init).class_name;
                if (cname != "") {
                    vnames.add (d.name);
                    vclasses.add (cname);
                }
                return d;
            }
            if (s is ReturnStatement) {
                var rs = (ReturnStatement) s;
                if (rs.value != null) {
                    rs.value = inline_expr (prog, rs.value, vnames, vclasses);
                    if (rs.value is CallExpr) {
                        var c = (CallExpr) rs.value;
                        unowned var fn = prog.find (c.callee);
                        if (fn != null && !fn.is_void && can_inline_multi_fn (prog, fn, c.args.length, 0, null, true, false))
                            return build_multi_inline_block (prog, fn, 0, c.args, null, null, null, true, rs.line, rs.column);
                    } else if (rs.value is MethodCallExpr) {
                        var mc = (MethodCallExpr) rs.value;
                        if (mc.target is VarRef) {
                            string obj = ((VarRef) mc.target).name;
                            string? cname = lookup_var_class (vnames, vclasses, obj);
                            if (cname != null && !class_has_subclasses (prog, cname)) {
                                unowned var cd = prog.find_class (cname);
                                if (cd != null && (cd.base_name == "" || cd.base_name == "Object")) {
                                    unowned var fn = find_class_method_opt (cd, mc.method_name);
                                    int poff = (fn != null && fn.params.length >= 1 && fn.params[0].name == "this") ? 1 : 0;
                                    if (fn != null && !fn.is_static && !fn.is_void
                                        && can_inline_multi_fn (prog, fn, mc.args.length, poff, cd, true, true))
                                        return build_multi_inline_block (prog, fn, poff, mc.args, cd, obj, null, true, rs.line, rs.column);
                                }
                            }
                        }
                    }
                }
                return rs;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                a.value = inline_expr (prog, a.value, vnames, vclasses);
                {
                    if (a.value is CallExpr) {
                        var c = (CallExpr) a.value;
                        unowned var fn = prog.find (c.callee);
                        if (fn != null && !fn.is_void && can_inline_multi_fn (prog, fn, c.args.length, 0, null, true, false))
                            return build_multi_inline_block (prog, fn, 0, c.args, null, null, a.name, false, a.line, a.column);
                    } else if (a.value is MethodCallExpr) {
                        var mc = (MethodCallExpr) a.value;
                        if (mc.target is VarRef) {
                            string obj = ((VarRef) mc.target).name;
                            string? cname = lookup_var_class (vnames, vclasses, obj);
                            if (cname != null && !class_has_subclasses (prog, cname)) {
                                unowned var cd = prog.find_class (cname);
                                if (cd != null && (cd.base_name == "" || cd.base_name == "Object")) {
                                    unowned var fn = find_class_method_opt (cd, mc.method_name);
                                    int poff = (fn != null && fn.params.length >= 1 && fn.params[0].name == "this") ? 1 : 0;
                                    if (fn != null && !fn.is_static && !fn.is_void
                                        && can_inline_multi_fn (prog, fn, mc.args.length, poff, cd, true, true))
                                        return build_multi_inline_block (prog, fn, poff, mc.args, cd, obj, a.name, false, a.line, a.column);
                                }
                            }
                        }
                    }
                }
                return a;
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                fa.target = inline_expr (prog, fa.target, vnames, vclasses);
                fa.value = inline_expr (prog, fa.value, vnames, vclasses);
                return fa;
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                ia.target = inline_expr (prog, ia.target, vnames, vclasses);
                ia.index = inline_expr (prog, ia.index, vnames, vclasses);
                ia.value = inline_expr (prog, ia.value, vnames, vclasses);
                return ia;
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                if (es.expr is MethodCallExpr) {
                    var mc = (MethodCallExpr) es.expr;
                    for (int i = 0; i < mc.args.length; i++)
                        mc.args[i] = inline_expr (prog, mc.args[i], vnames, vclasses);
                    if (mc.target is VarRef) {
                        string obj = ((VarRef) mc.target).name;
                        string? cname = lookup_var_class (vnames, vclasses, obj);
                        if (cname != null && !class_has_subclasses (prog, cname)) {
                            unowned var cd = prog.find_class (cname);
                            if (cd != null && (cd.base_name == "" || cd.base_name == "Object")) {
                                unowned var fn = find_class_method_opt (cd, mc.method_name);
                                int poff = (fn != null && fn.params.length >= 1 && fn.params[0].name == "this") ? 1 : 0;
                                if (fn != null && !fn.is_static && fn.return_type == ValaType.VOID
                                    && fn.body != null && fn.body.length == 1 && fn.body[0] is AssignStatement) {
                                    var asg = (AssignStatement) fn.body[0];
                                    if (cd_has_field (cd, asg.name) && can_inline_fn (fn, mc.args.length, poff, mc.args, asg.value, cd)) {
                                        var pnames = new GenericArray<string> ();
                                        for (int i = poff; i < fn.params.length; i++)
                                            pnames.add (fn.params[i].name);
                                        var cloned = prog.clone_expr_plain (asg.value);
                                        var rhs = subst_inline_expr (prog, cloned, pnames, mc.args, cd, obj);
                                        return new FieldAssignStatement () {
                                            target = new VarRef () { name = obj, line = es.line, column = es.column },
                                            field_name = asg.name,
                                            op = "=",
                                            value = rhs,
                                            line = es.line,
                                            column = es.column
                                        };
                                    }
                                }
                                if (fn != null && !fn.is_static && can_inline_multi_fn (prog, fn, mc.args.length, poff, cd, false, true))
                                    return build_multi_inline_block (prog, fn, poff, mc.args, cd, obj, null, false, es.line, es.column);
                            }
                        }
                    }
                }
                es.expr = inline_expr (prog, es.expr, vnames, vclasses);
                if (es.expr is CallExpr) {
                    var c = (CallExpr) es.expr;
                    unowned var fn = prog.find (c.callee);
                    if (fn != null && can_inline_multi_fn (prog, fn, c.args.length, 0, null, false, false))
                        return build_multi_inline_block (prog, fn, 0, c.args, null, null, null, false, es.line, es.column);
                }
                return es;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                ifs.condition = inline_expr (prog, ifs.condition, vnames, vclasses);
                if (ifs.then_body != null)
                    ifs.then_body = inline_stmt (prog, ifs.then_body, vnames, vclasses);
                if (ifs.else_body != null)
                    ifs.else_body = inline_stmt (prog, ifs.else_body, vnames, vclasses);
                return ifs;
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                ws.condition = inline_expr (prog, ws.condition, vnames, vclasses);
                if (ws.body != null)
                    ws.body = inline_stmt (prog, ws.body, vnames, vclasses);
                return ws;
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                int mark = vnames.length;
                if (fs.init != null)
                    fs.init = inline_stmt (prog, fs.init, vnames, vclasses);
                if (fs.condition != null)
                    fs.condition = inline_expr (prog, fs.condition, vnames, vclasses);
                if (fs.step != null)
                    fs.step = inline_stmt (prog, fs.step, vnames, vclasses);
                if (fs.body != null)
                    fs.body = inline_stmt (prog, fs.body, vnames, vclasses);
                while (vnames.length > mark) {
                    vnames.remove_index (vnames.length - 1);
                    vclasses.remove_index (vclasses.length - 1);
                }
                return fs;
            }
            return s;
        }

        private static int count_self_calls_rec (Expr? e, string fn_name) {
            if (e == null) return 0;
            if (e is CallExpr) {
                var c = (CallExpr) e;
                int n = (c.callee == fn_name) ? 1 : 0;
                for (int i = 0; i < c.args.length; i++)
                    n += count_self_calls_rec (c.args[i], fn_name);
                return n;
            }
            if (e is UnaryExpr) return count_self_calls_rec (((UnaryExpr) e).operand, fn_name);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return count_self_calls_rec (b.left, fn_name) + count_self_calls_rec (b.right, fn_name);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return count_self_calls_rec (te.condition, fn_name)
                    + count_self_calls_rec (te.then_expr, fn_name)
                    + count_self_calls_rec (te.else_expr, fn_name);
            }
            return 0;
        }

        private static bool expr_is_self_rec_pure (Expr? e, Function fn) {
            if (e == null) return false;
            if (e is IntLiteral || e is BoolLiteral) return true;
            if (e is VarRef) {
                string name = ((VarRef) e).name;
                for (int i = 0; i < fn.params.length; i++) {
                    if (fn.params[i].name == name) return true;
                }
                return false;
            }
            if (e is UnaryExpr) return expr_is_self_rec_pure (((UnaryExpr) e).operand, fn);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return expr_is_self_rec_pure (b.left, fn) && expr_is_self_rec_pure (b.right, fn);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return expr_is_self_rec_pure (te.condition, fn)
                    && expr_is_self_rec_pure (te.then_expr, fn)
                    && expr_is_self_rec_pure (te.else_expr, fn);
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                if (c.callee != fn.name || c.args.length != fn.params.length) return false;
                for (int i = 0; i < c.args.length; i++) {
                    if (!expr_is_self_rec_pure (c.args[i], fn)) return false;
                }
                return true;
            }
            return false;
        }

        private static Expr unroll_self_step (Program prog, Expr e, Function fn,
                                              GenericArray<string> pnames, Expr tmpl) {
            if (e is CallExpr) {
                var c = (CallExpr) e;
                if (c.callee == fn.name && c.args.length == pnames.length) {
                    var cloned = prog.clone_expr_plain (tmpl);
                    return subst_inline_expr (prog, cloned, pnames, c.args, null, null);
                }
                return e;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = unroll_self_step (prog, u.operand, fn, pnames, tmpl);
                return u;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = unroll_self_step (prog, b.left, fn, pnames, tmpl);
                b.right = unroll_self_step (prog, b.right, fn, pnames, tmpl);
                return b;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = unroll_self_step (prog, te.condition, fn, pnames, tmpl);
                te.then_expr = unroll_self_step (prog, te.then_expr, fn, pnames, tmpl);
                te.else_expr = unroll_self_step (prog, te.else_expr, fn, pnames, tmpl);
                return te;
            }
            return e;
        }

        private static int cse_seq = 0;

        private static Expr simplify_offset_expr (Expr e) {
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = simplify_offset_expr (u.operand);
                return u;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = simplify_offset_expr (b.left);
                b.right = simplify_offset_expr (b.right);
                if ((b.op == "+" || b.op == "-") && b.right is IntLiteral && b.left is BinaryExpr) {
                    var lb = (BinaryExpr) b.left;
                    if ((lb.op == "+" || lb.op == "-") && lb.right is IntLiteral) {
                        int64 d1 = (lb.op == "+") ? ((IntLiteral) lb.right).value : -((IntLiteral) lb.right).value;
                        int64 d2 = (b.op == "+") ? ((IntLiteral) b.right).value : -((IntLiteral) b.right).value;
                        int64 sum = d1 + d2;
                        if (sum == 0) return lb.left;
                        if (sum > 0)
                            return new BinaryExpr () { op = "+", left = lb.left, right = new IntLiteral () { value = sum, line = e.line, column = e.column }, line = e.line, column = e.column };
                        return new BinaryExpr () { op = "-", left = lb.left, right = new IntLiteral () { value = -sum, line = e.line, column = e.column }, line = e.line, column = e.column };
                    }
                }
                return b;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = simplify_offset_expr (te.condition);
                te.then_expr = simplify_offset_expr (te.then_expr);
                te.else_expr = simplify_offset_expr (te.else_expr);
                return te;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++)
                    c.args[i] = simplify_offset_expr (c.args[i]);
                return c;
            }
            return e;
        }

        private static bool expr_struct_eq (Expr? a, Expr? b) {
            if (a == null || b == null) return a == b;
            if (a is IntLiteral && b is IntLiteral) return ((IntLiteral) a).value == ((IntLiteral) b).value;
            if (a is BoolLiteral && b is BoolLiteral) return ((BoolLiteral) a).value == ((BoolLiteral) b).value;
            if (a is VarRef && b is VarRef) return ((VarRef) a).name == ((VarRef) b).name;
            if (a is UnaryExpr && b is UnaryExpr) {
                var ua = (UnaryExpr) a; var ub = (UnaryExpr) b;
                return ua.op == ub.op && expr_struct_eq (ua.operand, ub.operand);
            }
            if (a is BinaryExpr && b is BinaryExpr) {
                var ba = (BinaryExpr) a; var bb = (BinaryExpr) b;
                return ba.op == bb.op && expr_struct_eq (ba.left, bb.left) && expr_struct_eq (ba.right, bb.right);
            }
            if (a is CallExpr && b is CallExpr) {
                var ca = (CallExpr) a; var cb = (CallExpr) b;
                if (ca.callee != cb.callee || ca.args.length != cb.args.length) return false;
                for (int i = 0; i < ca.args.length; i++) {
                    if (!expr_struct_eq (ca.args[i], cb.args[i])) return false;
                }
                return true;
            }
            return false;
        }

        private static void collect_uncond_calls (Expr? e, GenericArray<CallExpr> out_calls) {
            if (e == null) return;
            if (e is CallExpr) {
                out_calls.add ((CallExpr) e);
                return;
            }
            if (e is UnaryExpr) { collect_uncond_calls (((UnaryExpr) e).operand, out_calls); return; }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                collect_uncond_calls (b.left, out_calls);
                collect_uncond_calls (b.right, out_calls);
            }
        }

        private static Expr replace_call_var (Program prog, Expr e, CallExpr target, string vname) {
            if (e is CallExpr && expr_struct_eq (e, target))
                return new VarRef () { name = vname, line = e.line, column = e.column };
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = replace_call_var (prog, u.operand, target, vname);
                return u;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = replace_call_var (prog, b.left, target, vname);
                b.right = replace_call_var (prog, b.right, target, vname);
                return b;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = replace_call_var (prog, te.condition, target, vname);
                te.then_expr = replace_call_var (prog, te.then_expr, target, vname);
                te.else_expr = replace_call_var (prog, te.else_expr, target, vname);
                return te;
            }
            return e;
        }

        private static void unroll_self_rec_func (Program prog, Function f) {
            if (f.owner_class != "" || f.is_async || f.is_asm_body || f.can_throw || f.is_varargs)
                return;
            if (f.params.length < 1 || f.params.length > 2)
                return;
            if (f.return_type != ValaType.INT && f.return_type != ValaType.BOOL)
                return;
            for (int i = 0; i < f.params.length; i++) {
                if (f.params[i].is_ref || f.params[i].is_out || f.params[i].param_type == ValaType.STRUCT)
                    return;
            }
            if (f.body == null || f.body.length != 2 || !(f.body[0] is IfStatement) || !(f.body[1] is ReturnStatement))
                return;
            var tmpl = try_extract_inline_ret_expr (f);
            if (tmpl == null || count_self_calls_rec (tmpl, f.name) != 2 || !expr_is_self_rec_pure (tmpl, f))
                return;
            var rs = (ReturnStatement) f.body[1];
            if (rs.value == null || count_self_calls_rec (rs.value, f.name) != 2)
                return;
            var pnames = new GenericArray<string> ();
            for (int i = 0; i < f.params.length; i++)
                pnames.add (f.params[i].name);
            var frozen = prog.clone_expr_plain (tmpl);
            Expr cur = unroll_self_step (prog, (Expr) rs.value, f, pnames, frozen);
            cur = simplify_offset_expr (cur);

            // Check if cur is `Ternary(c1, t1, e1) <op> Ternary(c2, t2, e2)` with a shared call in e1 and e2
            if (cur is BinaryExpr) {
                var cb = (BinaryExpr) cur;
                if (cb.left is TernaryExpr && cb.right is TernaryExpr) {
                    var tl = (TernaryExpr) cb.left;
                    var tr = (TernaryExpr) cb.right;
                    var lcalls = new GenericArray<CallExpr> ();
                    var rcalls = new GenericArray<CallExpr> ();
                    collect_uncond_calls (tl.else_expr, lcalls);
                    collect_uncond_calls (tr.else_expr, rcalls);
                    CallExpr? shared = null;
                    for (int i = 0; i < lcalls.length && shared == null; i++) {
                        for (int j = 0; j < rcalls.length; j++) {
                            if (expr_struct_eq (lcalls[i], rcalls[j])) {
                                shared = lcalls[i];
                                break;
                            }
                        }
                    }
                    if (shared != null) {
                        cse_seq++;
                        string vname = @"__cse_$(cse_seq)";
                        var cond_both = new BinaryExpr () {
                            op = "&&",
                            left = new UnaryExpr () { op = "!", operand = prog.clone_expr_plain (tl.condition), line = rs.line, column = rs.column },
                            right = new UnaryExpr () { op = "!", operand = prog.clone_expr_plain (tr.condition), line = rs.line, column = rs.column },
                            line = rs.line,
                            column = rs.column
                        };
                        var cse_decl = new VarDeclStatement () {
                            name = vname,
                            decl_type = f.return_type,
                            decl_type_name = f.return_type_name,
                            infer_type = false,
                            init = prog.clone_expr_plain (shared),
                            line = rs.line,
                            column = rs.column
                        };
                        var fast_ret_expr = new BinaryExpr () {
                            op = cb.op,
                            left = replace_call_var (prog, prog.clone_expr_plain (tl.else_expr), shared, vname),
                            right = replace_call_var (prog, prog.clone_expr_plain (tr.else_expr), shared, vname),
                            line = rs.line,
                            column = rs.column
                        };
                        var fast_blk = new BlockStatement () { line = rs.line, column = rs.column };
                        fast_blk.statements.add (cse_decl);
                        fast_blk.statements.add (new ReturnStatement () { value = fast_ret_expr, line = rs.line, column = rs.column });
                        var guard_if = new IfStatement () {
                            condition = cond_both,
                            then_body = fast_blk,
                            line = rs.line,
                            column = rs.column
                        };
                        rs.value = cur;
                        var s1 = f.body[1];
                        f.body[1] = guard_if;
                        f.body.add (s1);
                        return;
                    }
                }
            }
            cur = unroll_self_step (prog, cur, f, pnames, frozen);
            rs.value = simplify_offset_expr (cur);
        }

        private static void inline_func (Program prog, Function f) {
            if (f.body == null)
                return;
            var vnames = new GenericArray<string> ();
            var vclasses = new GenericArray<string> ();
            for (int i = 0; i < f.params.length; i++) {
                if (f.params[i].param_type == ValaType.CLASS && f.params[i].type_name != "") {
                    vnames.add (f.params[i].name);
                    vclasses.add (f.params[i].type_name);
                }
            }
            for (int i = 0; i < f.body.length; i++)
                f.body[i] = inline_stmt (prog, f.body[i], vnames, vclasses);
            unroll_self_rec_func (prog, f);
        }

        private static void inline_program (Program prog) {
            for (int i = 0; i < prog.functions.length; i++)
                inline_func (prog, prog.functions[i]);
            for (int i = 0; i < prog.classes.length; i++) {
                var cd = prog.classes[i];
                for (int j = 0; j < cd.methods.length; j++)
                    inline_func (prog, cd.methods[j]);
                for (int j = 0; j < cd.named_ctors.length; j++)
                    inline_func (prog, cd.named_ctors[j]);
                if (cd.ctor != null) inline_func (prog, cd.ctor);
            }
        }

        public static void optimize (Program prog, int opt_level) {
            if (opt_level <= 0)
                return;
            if (opt_level >= 2)
                inline_program (prog);
            var funcs = new GenericArray<Function> ();
            var owners = new GenericArray<string> ();
            for (int i = 0; i < prog.functions.length; i++) {
                funcs.add (prog.functions[i]);
                owners.add ("");
            }
            for (int i = 0; i < prog.classes.length; i++) {
                var cd = prog.classes[i];
                for (int j = 0; j < cd.methods.length; j++) {
                    funcs.add (cd.methods[j]);
                    owners.add (cd.name);
                }
                for (int j = 0; j < cd.named_ctors.length; j++) {
                    funcs.add (cd.named_ctors[j]);
                    owners.add (cd.name);
                }
                if (cd.ctor != null) { funcs.add (cd.ctor); owners.add (cd.name); }
                if (cd.dtor != null) { funcs.add (cd.dtor); owners.add (cd.name); }
            }
            for (int i = 0; i < prog.structs.length; i++) {
                var sd = prog.structs[i];
                for (int j = 0; j < sd.methods.length; j++) {
                    funcs.add (sd.methods[j]);
                    owners.add (sd.name);
                }
            }
            for (int i = 0; i < prog.enums.length; i++) {
                var ed = prog.enums[i];
                for (int j = 0; j < ed.methods.length; j++) {
                    funcs.add (ed.methods[j]);
                    owners.add (ed.name);
                }
            }
            int ncpus = Host.cpu_count ();
            if (funcs.length >= 16 && ncpus > 1) {
                int nw = (ncpus < funcs.length) ? ncpus : funcs.length;
                mt_opt_funcs = funcs;
                mt_opt_owners = owners;
                mt_opt_prog = prog;
                mt_opt_level = opt_level;
                mt_opt_next = 0;
                mt_opt_lock = new int[1];
                int64[] handles = new int64[nw];
                for (int wi = 1; wi < nw; wi++)
                    handles[wi] = Host.thread_spawn (mt_opt_worker, wi);
                mt_opt_worker (0);
                for (int wi = 1; wi < nw; wi++)
                    Host.thread_join (handles[wi]);
                return;
            }
            var opt = new Optimizer ();
            opt.level = opt_level;
            opt.cur_prog = prog;
            opt.run (prog);
        }

        private void run (Program prog) {
            cur_owner = "";
            for (int i = 0; i < prog.functions.length; i++)
                opt_func (prog.functions[i]);
            for (int i = 0; i < prog.classes.length; i++) {
                var cd = prog.classes[i];
                cur_owner = cd.name;
                for (int j = 0; j < cd.methods.length; j++)
                    opt_func (cd.methods[j]);
                for (int j = 0; j < cd.named_ctors.length; j++)
                    opt_func (cd.named_ctors[j]);
                if (cd.ctor != null)
                    opt_func (cd.ctor);
                if (cd.dtor != null)
                    opt_func (cd.dtor);
            }
            for (int i = 0; i < prog.structs.length; i++) {
                var sd = prog.structs[i];
                cur_owner = sd.name;
                for (int j = 0; j < sd.methods.length; j++)
                    opt_func (sd.methods[j]);
            }
            for (int i = 0; i < prog.enums.length; i++) {
                var ed = prog.enums[i];
                cur_owner = ed.name;
                for (int j = 0; j < ed.methods.length; j++)
                    opt_func (ed.methods[j]);
            }
            cur_owner = "";
        }

        private static int sra_field_idx (GenericArray<string> fnames, string fn) {
            for (int i = 0; i < fnames.length; i++) {
                if (fnames[i] == fn) return i;
            }
            return -1;
        }

        private bool sra_expr_safe (Expr? e, string vname, ClassDecl cd) {
            if (e == null) return true;
            if (e is IntLiteral || e is BoolLiteral || e is StringLiteral || e is NullLiteral) return true;
            if (e is VarRef) return ((VarRef) e).name != vname;
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                if (ma.target is VarRef && ((VarRef) ma.target).name == vname)
                    return cd_has_field (cd, ma.member);
                return sra_expr_safe (ma.target, vname, cd);
            }
            if (e is UnaryExpr) return sra_expr_safe (((UnaryExpr) e).operand, vname, cd);
            if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                if (inc.target is VarRef && ((VarRef) inc.target).name == vname) return false;
                return sra_expr_safe (inc.target, vname, cd);
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return sra_expr_safe (b.left, vname, cd) && sra_expr_safe (b.right, vname, cd);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return sra_expr_safe (te.condition, vname, cd)
                    && sra_expr_safe (te.then_expr, vname, cd)
                    && sra_expr_safe (te.else_expr, vname, cd);
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return sra_expr_safe (ix.target, vname, cd) && sra_expr_safe (ix.index, vname, cd);
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++) {
                    if (!sra_expr_safe (c.args[i], vname, cd)) return false;
                }
                return true;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (!sra_expr_safe (mc.target, vname, cd)) return false;
                for (int i = 0; i < mc.args.length; i++) {
                    if (!sra_expr_safe (mc.args[i], vname, cd)) return false;
                }
                return true;
            }
            if (e is TemplateExpr) {
                var te = (TemplateExpr) e;
                for (int i = 0; i < te.parts.length; i++) {
                    if (!sra_expr_safe (te.parts[i], vname, cd)) return false;
                }
                return true;
            }
            if (e is ArrayNewExpr) {
                var an = (ArrayNewExpr) e;
                return sra_expr_safe (an.length_expr, vname, cd);
            }
            if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                for (int i = 0; i < cn.args.length; i++) {
                    if (!sra_expr_safe (cn.args[i], vname, cd)) return false;
                }
                return true;
            }
            return false;
        }

        private bool sra_stmt_safe (Statement? s, string vname, ClassDecl cd) {
            if (s == null || s is BreakStatement || s is ContinueStatement) return true;
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.name == vname) return false;
                return sra_expr_safe (d.init, vname, cd);
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                if (a.name == vname) return false;
                return sra_expr_safe (a.value, vname, cd);
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                if (fa.target is VarRef && ((VarRef) fa.target).name == vname)
                    return (fa.op == "=" || fa.op == "+=" || fa.op == "-=")
                        && cd_has_field (cd, fa.field_name) && sra_expr_safe (fa.value, vname, cd);
                return sra_expr_safe (fa.target, vname, cd) && sra_expr_safe (fa.value, vname, cd);
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                return sra_expr_safe (ia.target, vname, cd)
                    && sra_expr_safe (ia.index, vname, cd)
                    && sra_expr_safe (ia.value, vname, cd);
            }
            if (s is ExprStatement) return sra_expr_safe (((ExprStatement) s).expr, vname, cd);
            if (s is ReturnStatement) return sra_expr_safe (((ReturnStatement) s).value, vname, cd);
            if (s is PrintStatement) return sra_expr_safe (((PrintStatement) s).value, vname, cd);
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (!sra_stmt_safe (blk.statements[i], vname, cd)) return false;
                }
                return true;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return sra_expr_safe (ifs.condition, vname, cd)
                    && sra_stmt_safe (ifs.then_body, vname, cd)
                    && sra_stmt_safe (ifs.else_body, vname, cd);
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                return sra_expr_safe (ws.condition, vname, cd) && sra_stmt_safe (ws.body, vname, cd);
            }
            if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                return sra_expr_safe (dw.condition, vname, cd) && sra_stmt_safe (dw.body, vname, cd);
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                return sra_stmt_safe (fs.init, vname, cd)
                    && sra_expr_safe (fs.condition, vname, cd)
                    && sra_stmt_safe (fs.step, vname, cd)
                    && sra_stmt_safe (fs.body, vname, cd);
            }
            return false;
        }

        private Expr? sra_rewrite_expr_opt (Expr? e, string vname, GenericArray<string> fnames, GenericArray<string> sra_names) {
            if (e == null) return null;
            return sra_rewrite_expr (e, vname, fnames, sra_names);
        }

        private Expr sra_rewrite_expr (Expr e, string vname, GenericArray<string> fnames, GenericArray<string> sra_names) {
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                if (ma.target is VarRef && ((VarRef) ma.target).name == vname) {
                    int fi = sra_field_idx (fnames, ma.member);
                    if (fi >= 0)
                        return new VarRef () { name = sra_names[fi], line = ma.line, column = ma.column };
                }
                ma.target = sra_rewrite_expr (ma.target, vname, fnames, sra_names);
                return ma;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = sra_rewrite_expr (u.operand, vname, fnames, sra_names);
                return u;
            }
            if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                inc.target = sra_rewrite_expr (inc.target, vname, fnames, sra_names);
                return inc;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = sra_rewrite_expr (b.left, vname, fnames, sra_names);
                b.right = sra_rewrite_expr (b.right, vname, fnames, sra_names);
                return b;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = sra_rewrite_expr (te.condition, vname, fnames, sra_names);
                te.then_expr = sra_rewrite_expr (te.then_expr, vname, fnames, sra_names);
                te.else_expr = sra_rewrite_expr (te.else_expr, vname, fnames, sra_names);
                return te;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = sra_rewrite_expr (ix.target, vname, fnames, sra_names);
                ix.index = sra_rewrite_expr (ix.index, vname, fnames, sra_names);
                return ix;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++)
                    c.args[i] = sra_rewrite_expr (c.args[i], vname, fnames, sra_names);
                return c;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                mc.target = sra_rewrite_expr_opt (mc.target, vname, fnames, sra_names);
                for (int i = 0; i < mc.args.length; i++)
                    mc.args[i] = sra_rewrite_expr (mc.args[i], vname, fnames, sra_names);
                return mc;
            }
            if (e is TemplateExpr) {
                var te = (TemplateExpr) e;
                for (int i = 0; i < te.parts.length; i++)
                    te.parts[i] = sra_rewrite_expr (te.parts[i], vname, fnames, sra_names);
                return te;
            }
            if (e is ArrayNewExpr) {
                var an = (ArrayNewExpr) e;
                an.length_expr = sra_rewrite_expr (an.length_expr, vname, fnames, sra_names);
                return an;
            }
            if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                for (int i = 0; i < cn.args.length; i++)
                    cn.args[i] = sra_rewrite_expr (cn.args[i], vname, fnames, sra_names);
                return cn;
            }
            return e;
        }

        private Statement? sra_rewrite_stmt_opt (Statement? s, string vname, GenericArray<string> fnames, GenericArray<string> sra_names) {
            if (s == null) return null;
            return sra_rewrite_stmt (s, vname, fnames, sra_names);
        }

        private Statement sra_rewrite_stmt (Statement s, string vname, GenericArray<string> fnames, GenericArray<string> sra_names) {
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                d.init = sra_rewrite_expr_opt (d.init, vname, fnames, sra_names);
                return d;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                a.value = sra_rewrite_expr (a.value, vname, fnames, sra_names);
                return a;
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                fa.value = sra_rewrite_expr (fa.value, vname, fnames, sra_names);
                if (fa.target is VarRef && ((VarRef) fa.target).name == vname) {
                    int fi = sra_field_idx (fnames, fa.field_name);
                    if (fi >= 0) {
                        Expr new_v = fa.value;
                        if (fa.op == "+=" || fa.op == "-=") {
                            new_v = new BinaryExpr () {
                                op = (fa.op == "+=") ? "+" : "-",
                                left = new VarRef () { name = sra_names[fi], line = fa.line, column = fa.column },
                                right = fa.value,
                                line = fa.line,
                                column = fa.column
                            };
                        }
                        return new AssignStatement () {
                            name = sra_names[fi],
                            value = new_v,
                            line = fa.line,
                            column = fa.column
                        };
                    }
                }
                fa.target = sra_rewrite_expr (fa.target, vname, fnames, sra_names);
                return fa;
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                ia.target = sra_rewrite_expr (ia.target, vname, fnames, sra_names);
                ia.index = sra_rewrite_expr (ia.index, vname, fnames, sra_names);
                ia.value = sra_rewrite_expr (ia.value, vname, fnames, sra_names);
                return ia;
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                es.expr = sra_rewrite_expr (es.expr, vname, fnames, sra_names);
                return es;
            }
            if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                r.value = sra_rewrite_expr_opt (r.value, vname, fnames, sra_names);
                return r;
            }
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                p.value = sra_rewrite_expr (p.value, vname, fnames, sra_names);
                return p;
            }
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++)
                    blk.statements[i] = sra_rewrite_stmt (blk.statements[i], vname, fnames, sra_names);
                return blk;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                ifs.condition = sra_rewrite_expr (ifs.condition, vname, fnames, sra_names);
                ifs.then_body = sra_rewrite_stmt (ifs.then_body, vname, fnames, sra_names);
                ifs.else_body = sra_rewrite_stmt_opt (ifs.else_body, vname, fnames, sra_names);
                return ifs;
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                ws.condition = sra_rewrite_expr (ws.condition, vname, fnames, sra_names);
                ws.body = sra_rewrite_stmt (ws.body, vname, fnames, sra_names);
                return ws;
            }
            if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                dw.condition = sra_rewrite_expr (dw.condition, vname, fnames, sra_names);
                dw.body = sra_rewrite_stmt (dw.body, vname, fnames, sra_names);
                return dw;
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                fs.init = sra_rewrite_stmt_opt (fs.init, vname, fnames, sra_names);
                fs.condition = sra_rewrite_expr_opt (fs.condition, vname, fnames, sra_names);
                fs.step = sra_rewrite_stmt_opt (fs.step, vname, fnames, sra_names);
                fs.body = sra_rewrite_stmt (fs.body, vname, fnames, sra_names);
                return fs;
            }
            return s;
        }

        private void sra_recurse_stmt (Statement? s) {
            if (s == null) return;
            if (s is BlockStatement) {
                sra_stmt_list (((BlockStatement) s).statements);
            } else if (s is IfStatement) {
                var ifs = (IfStatement) s;
                sra_recurse_stmt (ifs.then_body);
                sra_recurse_stmt (ifs.else_body);
            } else if (s is WhileStatement) {
                sra_recurse_stmt (((WhileStatement) s).body);
            } else if (s is DoWhileStatement) {
                sra_recurse_stmt (((DoWhileStatement) s).body);
            } else if (s is ForStatement) {
                sra_recurse_stmt (((ForStatement) s).body);
            }
        }

        private void sra_stmt_list (GenericArray<Statement> stmts) {
            var out_stmts = new GenericArray<Statement> ();
            bool changed = false;
            for (int i = 0; i < stmts.length; i++) {
                var s = stmts[i];
                if (s is VarDeclStatement) {
                    var d = (VarDeclStatement) s;
                    if (d.init is ClassNewExpr) {
                        var ne = (ClassNewExpr) d.init;
                        if (ne.ctor_name == "" && ne.args.length <= 6 && ne.init_names.length == 0) {
                            unowned var cd = cur_prog.find_class (ne.class_name);
                            bool ctor_ok = false;
                            int ctor_poff = 0;
                            if (cd != null && (cd.base_name == "" || cd.base_name == "Object") && !cd.is_abstract
                                && cd.dtor == null && cd.fields.length > 0 && cd.fields.length <= 8) {
                                if (cd.ctor == null) {
                                    ctor_ok = (ne.args.length == 0);
                                } else if (cd.ctor.body != null) {
                                    ctor_poff = (cd.ctor.params.length >= 1 && cd.ctor.params[0].name == "this") ? 1 : 0;
                                    if (cd.ctor.params.length == ne.args.length + ctor_poff) {
                                        ctor_ok = true;
                                        for (int ci = 0; ci < cd.ctor.body.length; ci++) {
                                            var cs = cd.ctor.body[ci];
                                            Expr? cval = null;
                                            if (cs is AssignStatement) {
                                                var ca = (AssignStatement) cs;
                                                if (!cd_has_field (cd, ca.name)) { ctor_ok = false; break; }
                                                cval = ca.value;
                                            } else if (cs is FieldAssignStatement) {
                                                var cfa = (FieldAssignStatement) cs;
                                                if (cfa.op != "=" || !(cfa.target is VarRef)
                                                    || ((VarRef) cfa.target).name != "this"
                                                    || !cd_has_field (cd, cfa.field_name)) {
                                                    ctor_ok = false; break;
                                                }
                                                cval = cfa.value;
                                            } else {
                                                ctor_ok = false; break;
                                            }
                                            if (cval == null || !can_inline_fn (cd.ctor, ne.args.length, ctor_poff, ne.args, cval, cd)) {
                                                ctor_ok = false; break;
                                            }
                                        }
                                    }
                                }
                            }
                            if (ctor_ok) {
                                bool fields_ok = true;
                                for (int fi = 0; fi < cd.fields.length; fi++) {
                                    var cf = cd.fields[fi];
                                    if (cf.is_static
                                        || (cf.field_type != ValaType.INT && cf.field_type != ValaType.BOOL)
                                        || (cf.init != null && !(cf.init is IntLiteral) && !(cf.init is BoolLiteral))) {
                                        fields_ok = false;
                                        break;
                                    }
                                }
                                if (fields_ok) {
                                    bool safe = true;
                                    for (int j = i + 1; j < stmts.length; j++) {
                                        if (!sra_stmt_safe (stmts[j], d.name, (ClassDecl) cd)) {
                                            safe = false;
                                            break;
                                        }
                                    }
                                    if (safe) {
                                        int sid = sra_counter++;
                                        var fnames = new GenericArray<string> ();
                                        var sra_names = new GenericArray<string> ();
                                        for (int fi = 0; fi < cd.fields.length; fi++) {
                                            var cf = cd.fields[fi];
                                            string sn = "__sra_" + d.name + "_" + cf.name + "_" + sid.to_string ();
                                            fnames.add (cf.name);
                                            sra_names.add (sn);
                                            Expr init_e = (cf.init != null)
                                                ? cur_prog.clone_expr_plain (cf.init)
                                                : ((cf.field_type == ValaType.BOOL)
                                                    ? (Expr) new BoolLiteral () { value = false, line = d.line, column = d.column }
                                                    : (Expr) new IntLiteral () { value = 0, line = d.line, column = d.column });
                                            out_stmts.add (new VarDeclStatement () {
                                                decl_type = cf.field_type,
                                                decl_type_name = cf.type_name,
                                                name = sn,
                                                init = init_e,
                                                line = d.line,
                                                column = d.column
                                            });
                                        }
                                        if (cd.ctor != null && cd.ctor.body != null) {
                                            var pnames = new GenericArray<string> ();
                                            for (int pi = ctor_poff; pi < cd.ctor.params.length; pi++)
                                                pnames.add (cd.ctor.params[pi].name);
                                            for (int ci = 0; ci < cd.ctor.body.length; ci++) {
                                                var cs = cd.ctor.body[ci];
                                                if (cs is AssignStatement) {
                                                    var ca = (AssignStatement) cs;
                                                    int cfi = sra_field_idx (fnames, ca.name);
                                                    if (cfi >= 0) {
                                                        var cloned = cur_prog.clone_expr_plain (ca.value);
                                                        var sub = subst_inline_expr ((Program) cur_prog, cloned, pnames, ne.args, cd, d.name);
                                                        sub = sra_rewrite_expr (sub, d.name, fnames, sra_names);
                                                        out_stmts.add (new AssignStatement () {
                                                            name = sra_names[cfi],
                                                            value = sub,
                                                            line = d.line,
                                                            column = d.column
                                                        });
                                                    }
                                                } else if (cs is FieldAssignStatement) {
                                                    var cfa = (FieldAssignStatement) cs;
                                                    int cfi = sra_field_idx (fnames, cfa.field_name);
                                                    if (cfi >= 0) {
                                                        var cloned = cur_prog.clone_expr_plain (cfa.value);
                                                        var sub = subst_inline_expr ((Program) cur_prog, cloned, pnames, ne.args, cd, d.name);
                                                        sub = sra_rewrite_expr (sub, d.name, fnames, sra_names);
                                                        out_stmts.add (new AssignStatement () {
                                                            name = sra_names[cfi],
                                                            value = sub,
                                                            line = d.line,
                                                            column = d.column
                                                        });
                                                    }
                                                }
                                            }
                                        }
                                        for (int j = i + 1; j < stmts.length; j++)
                                            stmts[j] = sra_rewrite_stmt (stmts[j], d.name, fnames, sra_names);
                                        changed = true;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }
                sra_recurse_stmt (s);
                out_stmts.add (s);
            }
            if (changed) {
                stmts.length = 0;
                for (int i = 0; i < out_stmts.length; i++)
                    stmts.add (out_stmts[i]);
            }
        }

        private void opt_func (Function f) {
            cur_func = f;
            cur_file = f.file;
            active_locals = new GenericArray<string> ();
            arr_vnames = new GenericArray<string> ();
            for (int pi = 0; pi < f.params.length; pi++) {
                if (f.params[pi].param_type == ValaType.ARRAY)
                    arr_vnames.add (f.params[pi].name);
            }
            if (f.body != null) {
                if (level >= 2 && cur_prog != null)
                    sra_stmt_list (f.body);
                expr_depth = 0;
                opt_stmt_list (f.body);
            }
            cur_func = null;
        }

        private string loc_str (int line, int col) {
            if (cur_file != "")
                return @"$cur_file:$line:$col";
            return @"$line:$col";
        }

        private bool is_local_or_param (string name) {
            for (int i = 0; i < active_locals.length; i++) {
                if (active_locals[i] == name)
                    return true;
            }
            if (cur_func != null) {
                for (int i = 0; i < cur_func.params.length; i++) {
                    if (cur_func.params[i].name == name)
                        return true;
                }
            }
            return false;
        }

        private static bool is_signed_64_int_name (string name) {
            return name == "" || name == "int" || name == "int64"
                || name == "long" || name == "ssize_t"
                || name == "intptr_t" || name == "intptr" || name == "ptrdiff_t";
        }

        private static bool is_unsigned_64_int_name (string name) {
            return name == "uint64" || name == "ulong" || name == "size_t" || name == "uintptr_t" || name == "uintptr";
        }

        private static Expr? const_to_literal (ConstDecl cd, int line, int col) {
            if (cd.const_type == ValaType.INT) {
                if (is_signed_64_int_name (cd.type_name))
                    return new IntLiteral () { value = cd.int_value, line = line, column = col };
                if (is_unsigned_64_int_name (cd.type_name))
                    return new IntLiteral () { value = cd.int_value, is_unsigned = true, is_long = true, line = line, column = col };
                return null;
            }
            if (cd.const_type == ValaType.BOOL)
                return new BoolLiteral () { value = (cd.int_value != 0), line = line, column = col };
            if (cd.const_type == ValaType.STRING)
                return new StringLiteral () { value = cd.str_value, line = line, column = col };
            return null;
        }

        private void opt_block (BlockStatement blk) {
            opt_stmt_list (blk.statements);
        }

        private static void set_const (GenericArray<string> names, GenericArray<Expr?> vals, GenericArray<bool> tracked, string name, Expr? val) {
            for (int i = 0; i < names.length; i++) {
                if (names[i] == name) {
                    vals[i] = val;
                    return;
                }
            }
            names.add (name);
            vals.add (val);
            tracked.add (true);
        }

        private static bool is_tracked_const_var (GenericArray<string> names, string name) {
            for (int i = 0; i < names.length; i++) {
                if (names[i] == name)
                    return true;
            }
            return false;
        }

        private static Expr? get_const (GenericArray<string> names, GenericArray<Expr?> vals, string name) {
            for (int i = 0; i < names.length; i++) {
                if (names[i] == name)
                    return vals[i];
            }
            return null;
        }

        private static void invalidate_var (GenericArray<string> names, GenericArray<Expr?> vals, string name) {
            for (int i = 0; i < names.length; i++) {
                if (names[i] == name) {
                    vals[i] = null;
                    return;
                }
            }
        }

        private static void invalidate_all_consts (GenericArray<Expr?> vals) {
            for (int i = 0; i < vals.length; i++)
                vals[i] = null;
        }

        private static Expr subst_consts_expr (Expr e, GenericArray<string> names, GenericArray<Expr?> vals) {
            if (e is VarRef) {
                var vr = (VarRef) e;
                var c = get_const (names, vals, vr.name);
                if (c != null) {
                    if (c is IntLiteral) {
                        var ic = (IntLiteral) c;
                        return new IntLiteral () { value = ic.value, is_unsigned = ic.is_unsigned, is_long = ic.is_long, line = e.line, column = e.column };
                    }
                    if (c is BoolLiteral)
                        return new BoolLiteral () { value = ((BoolLiteral) c).value, line = e.line, column = e.column };
                }
                return e;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                if (u.op == "&" || u.op == "++" || u.op == "--") {
                    if (u.operand is VarRef)
                        set_const (names, vals, new GenericArray<bool> (), ((VarRef) u.operand).name, null);
                    return e;
                }
                u.operand = subst_consts_expr (u.operand, names, vals);
                return u;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = subst_consts_expr (b.left, names, vals);
                b.right = subst_consts_expr (b.right, names, vals);
                return b;
            }
            if (e is TernaryExpr) {
                var t = (TernaryExpr) e;
                t.condition = subst_consts_expr (t.condition, names, vals);
                t.then_expr = subst_consts_expr (t.then_expr, names, vals);
                t.else_expr = subst_consts_expr (t.else_expr, names, vals);
                return t;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++) {
                    if (c.args[i] is VarRef)
                        invalidate_var (names, vals, ((VarRef) c.args[i]).name);
                    else
                        c.args[i] = subst_consts_expr (c.args[i], names, vals);
                }
                return c;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    mc.target = subst_consts_expr ((Expr) mc.target, names, vals);
                for (int i = 0; i < mc.args.length; i++) {
                    if (mc.args[i] is VarRef)
                        invalidate_var (names, vals, ((VarRef) mc.args[i]).name);
                    else
                        mc.args[i] = subst_consts_expr (mc.args[i], names, vals);
                }
                return mc;
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                ma.target = subst_consts_expr (ma.target, names, vals);
                return ma;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = subst_consts_expr (ix.target, names, vals);
                ix.index = subst_consts_expr (ix.index, names, vals);
                return ix;
            }
            return e;
        }

        private static bool arr_contains_str (GenericArray<string> arr, string s) {
            for (int i = 0; i < arr.length; i++) {
                if (arr[i] == s) return true;
            }
            return false;
        }

        private bool is_licm_pure_arith (Expr? e, GenericArray<string> mod, out bool has_var) {
            has_var = false;
            if (e == null) return false;
            if (e is IntLiteral) return true;
            if (e is VarRef) {
                string name = ((VarRef) e).name;
                if (name == "this" || !is_local_or_param (name) || arr_contains_str (mod, name))
                    return false;
                has_var = true;
                return true;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                if (u.op != "-" && u.op != "~") return false;
                return is_licm_pure_arith (u.operand, mod, out has_var);
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                if (b.op != "+" && b.op != "-" && b.op != "*"
                    && b.op != "&" && b.op != "|" && b.op != "^"
                    && b.op != "<<" && b.op != ">>")
                    return false;
                bool hv1 = false;
                bool hv2 = false;
                if (!is_licm_pure_arith (b.left, mod, out hv1)) return false;
                if (!is_licm_pure_arith (b.right, mod, out hv2)) return false;
                has_var = hv1 || hv2;
                return true;
            }
            return false;
        }

        private Expr licm_rewrite_expr (Expr e, GenericArray<string> mod,
                                        GenericArray<Statement> out_stmts, int line, int col) {
            if (e is BinaryExpr) {
                bool hv = false;
                if (is_licm_pure_arith (e, mod, out hv) && hv) {
                    string tname = @"__licm_$(licm_counter++)";
                    var vd = new VarDeclStatement () {
                        name = tname,
                        infer_type = true,
                        init = e,
                        line = line,
                        column = col
                    };
                    out_stmts.add (vd);
                    active_locals.add (tname);
                    return new VarRef () { name = tname, line = e.line, column = e.column };
                }
                var b = (BinaryExpr) e;
                b.left = licm_rewrite_expr (b.left, mod, out_stmts, line, col);
                b.right = licm_rewrite_expr (b.right, mod, out_stmts, line, col);
                return b;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = licm_rewrite_expr (u.operand, mod, out_stmts, line, col);
                return u;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = licm_rewrite_expr (ix.target, mod, out_stmts, line, col);
                ix.index = licm_rewrite_expr (ix.index, mod, out_stmts, line, col);
                return ix;
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                ma.target = licm_rewrite_expr (ma.target, mod, out_stmts, line, col);
                return ma;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++)
                    c.args[i] = licm_rewrite_expr (c.args[i], mod, out_stmts, line, col);
                return c;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    mc.target = licm_rewrite_expr (mc.target, mod, out_stmts, line, col);
                for (int i = 0; i < mc.args.length; i++)
                    mc.args[i] = licm_rewrite_expr (mc.args[i], mod, out_stmts, line, col);
                return mc;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = licm_rewrite_expr (te.condition, mod, out_stmts, line, col);
                te.then_expr = licm_rewrite_expr (te.then_expr, mod, out_stmts, line, col);
                te.else_expr = licm_rewrite_expr (te.else_expr, mod, out_stmts, line, col);
                return te;
            }
            return e;
        }

        private void licm_rewrite_stmt (Statement? s, GenericArray<string> mod,
                                        GenericArray<Statement> out_stmts, int line, int col) {
            if (s == null) return;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++)
                    licm_rewrite_stmt (blk.statements[i], mod, out_stmts, line, col);
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.init != null) d.init = licm_rewrite_expr (d.init, mod, out_stmts, line, col);
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                a.value = licm_rewrite_expr (a.value, mod, out_stmts, line, col);
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                fa.target = licm_rewrite_expr (fa.target, mod, out_stmts, line, col);
                fa.value = licm_rewrite_expr (fa.value, mod, out_stmts, line, col);
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                ia.target = licm_rewrite_expr (ia.target, mod, out_stmts, line, col);
                ia.index = licm_rewrite_expr (ia.index, mod, out_stmts, line, col);
                ia.value = licm_rewrite_expr (ia.value, mod, out_stmts, line, col);
            } else if (s is ExprStatement) {
                var es = (ExprStatement) s;
                es.expr = licm_rewrite_expr (es.expr, mod, out_stmts, line, col);
            } else if (s is ReturnStatement) {
                var rs = (ReturnStatement) s;
                if (rs.value != null) rs.value = licm_rewrite_expr (rs.value, mod, out_stmts, line, col);
            } else if (s is IfStatement) {
                var ifs = (IfStatement) s;
                ifs.condition = licm_rewrite_expr (ifs.condition, mod, out_stmts, line, col);
                licm_rewrite_stmt (ifs.then_body, mod, out_stmts, line, col);
                licm_rewrite_stmt (ifs.else_body, mod, out_stmts, line, col);
            } else if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                ws.condition = licm_rewrite_expr (ws.condition, mod, out_stmts, line, col);
                licm_rewrite_stmt (ws.body, mod, out_stmts, line, col);
            } else if (s is ForStatement) {
                var fs = (ForStatement) s;
                licm_rewrite_stmt (fs.init, mod, out_stmts, line, col);
                if (fs.condition != null) fs.condition = licm_rewrite_expr (fs.condition, mod, out_stmts, line, col);
                licm_rewrite_stmt (fs.step, mod, out_stmts, line, col);
                licm_rewrite_stmt (fs.body, mod, out_stmts, line, col);
            }
        }

        private void hoist_for_invariants (ForStatement fs, GenericArray<Statement> out_stmts) {
            var mod = new GenericArray<string> ();
            if (!Effects.collect_stmt (fs.init, mod, true)) return;
            if (!Effects.collect_expr (fs.condition, mod, true)) return;
            if (!Effects.collect_stmt (fs.step, mod, true)) return;
            if (!Effects.collect_stmt (fs.body, mod, true)) return;
            if (fs.condition != null)
                fs.condition = licm_rewrite_expr (fs.condition, mod, out_stmts, fs.line, fs.column);
            licm_rewrite_stmt (fs.body, mod, out_stmts, fs.line, fs.column);
        }

        private bool is_arr_var (string name) {
            for (int i = arr_vnames.length - 1; i >= 0; i--) {
                if (arr_vnames[i] == name)
                    return true;
            }
            return false;
        }

        private Statement try_lower_foreach_arr (ForeachStatement fe) {
            if (cur_func != null && (cur_func.is_async || cur_func.from_lambda != null))
                return fe;
            if (!(fe.collection is VarRef))
                return fe;
            string arr_name = ((VarRef) fe.collection).name;
            if (!is_arr_var (arr_name) || fe.var_name == arr_name)
                return fe;
            if (!fe.infer_type && fe.elem_type == ValaType.STRUCT)
                return fe;
            var mod = new GenericArray<string> ();
            if (!Effects.collect_stmt (fe.body, mod, true))
                return fe;
            for (int i = 0; i < mod.length; i++) {
                if (mod[i] == arr_name)
                    return fe;
            }
            fe_counter++;
            string idx_name = @"__fe_i_$(fe_counter)";
            var init_s = new VarDeclStatement () {
                name = idx_name,
                decl_type = ValaType.INT,
                decl_type_name = "",
                infer_type = false,
                init = new IntLiteral () { value = 0, line = fe.line, column = fe.column },
                line = fe.line,
                column = fe.column
            };
            var cond_e = new BinaryExpr () {
                op = "<",
                left = new VarRef () { name = idx_name, line = fe.line, column = fe.column },
                right = new MemberAccessExpr () {
                    target = new VarRef () { name = arr_name, line = fe.line, column = fe.column },
                    member = "length",
                    line = fe.line,
                    column = fe.column
                },
                line = fe.line,
                column = fe.column
            };
            var step_s = new AssignStatement () {
                name = idx_name,
                value = new BinaryExpr () {
                    op = "+",
                    left = new VarRef () { name = idx_name, line = fe.line, column = fe.column },
                    right = new IntLiteral () { value = 1, line = fe.line, column = fe.column },
                    line = fe.line,
                    column = fe.column
                },
                line = fe.line,
                column = fe.column
            };
            var elem_decl = new VarDeclStatement () {
                name = fe.var_name,
                decl_type = fe.elem_type,
                decl_type_name = fe.elem_type_name,
                infer_type = fe.infer_type,
                is_unowned = fe.is_unowned,
                init = new IndexExpr () {
                    target = new VarRef () { name = arr_name, line = fe.line, column = fe.column },
                    index = new VarRef () { name = idx_name, line = fe.line, column = fe.column },
                    line = fe.line,
                    column = fe.column
                },
                line = fe.line,
                column = fe.column
            };
            var body_blk = new BlockStatement () { line = fe.line, column = fe.column };
            body_blk.statements.add (elem_decl);
            if (fe.body is BlockStatement) {
                var fblk = (BlockStatement) fe.body;
                for (int i = 0; i < fblk.statements.length; i++)
                    body_blk.statements.add (fblk.statements[i]);
            } else if (fe.body != null) {
                body_blk.statements.add (fe.body);
            }
            return new ForStatement () {
                init = init_s,
                condition = cond_e,
                step = step_s,
                body = body_blk,
                line = fe.line,
                column = fe.column
            };
        }

        private void opt_stmt_list (GenericArray<Statement> stmts) {
            var out_stmts = new GenericArray<Statement> ();
            var cnames = new GenericArray<string> ();
            var cvals = new GenericArray<Expr?> ();
            var ctracked = new GenericArray<bool> ();
            int arr_mark = arr_vnames.length;
            for (int i = 0; i < stmts.length; i++) {
                var s = stmts[i];
                if (level >= 2 && cnames.length > 0) {
                    if (s is ReturnStatement && ((ReturnStatement) s).value != null)
                        ((ReturnStatement) s).value = subst_consts_expr ((Expr) ((ReturnStatement) s).value, cnames, cvals);
                    else if (s is PrintStatement)
                        ((PrintStatement) s).value = subst_consts_expr (((PrintStatement) s).value, cnames, cvals);
                    else if (s is ExitStatement)
                        ((ExitStatement) s).value = subst_consts_expr (((ExitStatement) s).value, cnames, cvals);
                    else if (s is VarDeclStatement && ((VarDeclStatement) s).init != null)
                        ((VarDeclStatement) s).init = subst_consts_expr ((Expr) ((VarDeclStatement) s).init, cnames, cvals);
                    else if (s is AssignStatement)
                        ((AssignStatement) s).value = subst_consts_expr (((AssignStatement) s).value, cnames, cvals);
                    else if (s is FieldAssignStatement) {
                        ((FieldAssignStatement) s).target = subst_consts_expr (((FieldAssignStatement) s).target, cnames, cvals);
                        ((FieldAssignStatement) s).value = subst_consts_expr (((FieldAssignStatement) s).value, cnames, cvals);
                    } else if (s is IndexAssignStatement) {
                        ((IndexAssignStatement) s).target = subst_consts_expr (((IndexAssignStatement) s).target, cnames, cvals);
                        ((IndexAssignStatement) s).index = subst_consts_expr (((IndexAssignStatement) s).index, cnames, cvals);
                        ((IndexAssignStatement) s).value = subst_consts_expr (((IndexAssignStatement) s).value, cnames, cvals);
                    } else if (s is ExprStatement)
                        ((ExprStatement) s).expr = subst_consts_expr (((ExprStatement) s).expr, cnames, cvals);
                    else if (s is IfStatement)
                        ((IfStatement) s).condition = subst_consts_expr (((IfStatement) s).condition, cnames, cvals);
                }

                var opt_s = opt_stmt (s);

                if (level >= 2 && opt_s != null) {
                    if (opt_s is VarDeclStatement) {
                        var vd = (VarDeclStatement) opt_s;
                        active_locals.add (vd.name);
                        if (vd.decl_type == ValaType.ARRAY || (vd.infer_type && (vd.init is ArrayNewExpr || vd.init is ArrayLiteralExpr)))
                            arr_vnames.add (vd.name);
                        bool track_const = vd.decl_type == ValaType.BOOL || vd.decl_type == ValaType.STRING;
                        if (vd.decl_type == ValaType.INT && is_signed_64_int_name (vd.decl_type_name))
                            track_const = true;
                        else if (vd.infer_type && vd.init != null) {
                            if (vd.init is IntLiteral) {
                                var il = (IntLiteral) vd.init;
                                track_const = !il.is_unsigned && !il.is_long;
                            } else if (vd.init is BoolLiteral || vd.init is StringLiteral) {
                                track_const = true;
                            }
                        }
                        if (track_const) {
                            if (vd.init != null && (vd.init is IntLiteral || vd.init is BoolLiteral || vd.init is StringLiteral)) {
                                if (vd.init is IntLiteral && (((IntLiteral) vd.init).is_unsigned || ((IntLiteral) vd.init).is_long))
                                    set_const (cnames, cvals, ctracked, vd.name, null);
                                else
                                    set_const (cnames, cvals, ctracked, vd.name, vd.init);
                            } else {
                                set_const (cnames, cvals, ctracked, vd.name, null);
                            }
                        }
                    } else if (opt_s is AssignStatement) {
                        var asg = (AssignStatement) opt_s;
                        if (is_tracked_const_var (cnames, asg.name)) {
                            if ((asg.value is IntLiteral && !((IntLiteral) asg.value).is_unsigned && !((IntLiteral) asg.value).is_long)
                                || asg.value is BoolLiteral || asg.value is StringLiteral)
                                set_const (cnames, cvals, ctracked, asg.name, asg.value);
                            else
                                set_const (cnames, cvals, ctracked, asg.name, null);
                        }
                    } else if (opt_s is IfStatement || opt_s is WhileStatement || opt_s is DoWhileStatement
                               || opt_s is ForStatement || opt_s is ForeachStatement || opt_s is SwitchStatement
                               || opt_s is TryStatement || opt_s is BlockStatement) {
                        invalidate_all_consts (cvals);
                    }
                    if (opt_s is ExprStatement && is_pure_atom (((ExprStatement) opt_s).expr))
                        opt_s = null;
                }

                if (opt_s != null) {
                    if (opt_s is BlockStatement) {
                        var inner = (BlockStatement) opt_s;
                        for (int j = 0; j < inner.statements.length; j++)
                            out_stmts.add (inner.statements[j]);
                    } else {
                        if (level >= 2 && opt_s is ForeachStatement)
                            opt_s = try_lower_foreach_arr ((ForeachStatement) opt_s);
                        if (level >= 2 && opt_s is ForStatement) {
                            hoist_for_invariants ((ForStatement) opt_s, out_stmts);
                            if (cur_prog != null)
                                opt_s = try_unroll_for_4x ((ForStatement) opt_s);
                        }
                        out_stmts.add (opt_s);
                    }
                    if (opt_s is ReturnStatement || opt_s is BreakStatement
                        || opt_s is ContinueStatement || opt_s is ThrowStatement) {
                        break; // DCE: unreachable statements after terminator
                    }
                }
            }
            while (arr_vnames.length > arr_mark)
                arr_vnames.remove_index (arr_vnames.length - 1);
            stmts.length = 0;
            for (int i = 0; i < out_stmts.length; i++)
                stmts.add (out_stmts[i]);
        }

        private Expr unroll_subst_iv (Expr e, string iv, int64 off) {
            if (off == 0) return e;
            if (e is VarRef) {
                if (((VarRef) e).name == iv) {
                    return new BinaryExpr () {
                        op = "+",
                        left = e,
                        right = new IntLiteral () { value = off, line = e.line, column = e.column },
                        line = e.line,
                        column = e.column
                    };
                }
                return e;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = unroll_subst_iv (u.operand, iv, off);
                return u;
            }
            if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                inc.target = unroll_subst_iv (inc.target, iv, off);
                return inc;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = unroll_subst_iv (b.left, iv, off);
                b.right = unroll_subst_iv (b.right, iv, off);
                return b;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                te.condition = unroll_subst_iv (te.condition, iv, off);
                te.then_expr = unroll_subst_iv (te.then_expr, iv, off);
                te.else_expr = unroll_subst_iv (te.else_expr, iv, off);
                return te;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = unroll_subst_iv (ix.target, iv, off);
                ix.index = unroll_subst_iv (ix.index, iv, off);
                return ix;
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                ma.target = unroll_subst_iv (ma.target, iv, off);
                return ma;
            }
            if (e is TypeCheckExpr) {
                var tc = (TypeCheckExpr) e;
                tc.operand = unroll_subst_iv (tc.operand, iv, off);
                return tc;
            }
            return e;
        }

        private bool unroll_stmt_ok (Statement? s) {
            if (s == null) return false;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                if (blk.statements.length == 0 || blk.statements.length > 2) return false;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (!unroll_stmt_ok (blk.statements[i])) return false;
                }
                return true;
            }
            if (s is AssignStatement) {
                return expr_is_inline_leaf (((AssignStatement) s).value);
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                return expr_is_inline_leaf (ia.target)
                    && expr_is_inline_leaf (ia.index)
                    && expr_is_inline_leaf (ia.value);
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return expr_is_inline_leaf (fa.target) && expr_is_inline_leaf (fa.value);
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                return (es.expr is IncDecExpr) && expr_is_inline_leaf (((IncDecExpr) es.expr).target);
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return ifs.else_body == null
                    && (ifs.condition is BinaryExpr)
                    && expr_is_inline_leaf (ifs.condition)
                    && unroll_stmt_ok (ifs.then_body);
            }
            return false;
        }

        private Statement unroll_clone_stmt (Statement s, string iv, int64 off) {
            var p = (Program) cur_prog;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                var nb = new BlockStatement () { line = blk.line, column = blk.column };
                for (int i = 0; i < blk.statements.length; i++)
                    nb.statements.add (unroll_clone_stmt (blk.statements[i], iv, off));
                return nb;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                return new AssignStatement () {
                    name = a.name,
                    value = unroll_subst_iv (p.clone_expr_plain (a.value), iv, off),
                    line = a.line,
                    column = a.column
                };
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                return new IndexAssignStatement () {
                    target = unroll_subst_iv (p.clone_expr_plain (ia.target), iv, off),
                    index = unroll_subst_iv (p.clone_expr_plain (ia.index), iv, off),
                    op = ia.op,
                    value = unroll_subst_iv (p.clone_expr_plain (ia.value), iv, off),
                    line = ia.line,
                    column = ia.column
                };
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return new FieldAssignStatement () {
                    target = unroll_subst_iv (p.clone_expr_plain (fa.target), iv, off),
                    field_name = fa.field_name,
                    op = fa.op,
                    value = unroll_subst_iv (p.clone_expr_plain (fa.value), iv, off),
                    line = fa.line,
                    column = fa.column
                };
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                return new ExprStatement () {
                    expr = unroll_subst_iv (p.clone_expr_plain (es.expr), iv, off),
                    line = es.line,
                    column = es.column
                };
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return new IfStatement () {
                    condition = unroll_subst_iv (p.clone_expr_plain (ifs.condition), iv, off),
                    then_body = unroll_clone_stmt ((Statement) ifs.then_body, iv, off),
                    line = ifs.line,
                    column = ifs.column
                };
            }
            return s;
        }

        private Statement try_unroll_for_4x (ForStatement fs) {
            if (!(fs.init is VarDeclStatement) || !(fs.condition is BinaryExpr) || fs.step == null || fs.body == null)
                return fs;
            var vd = (VarDeclStatement) fs.init;
            if (vd.decl_type != ValaType.INT || vd.is_weak || vd.is_unowned || vd.init == null)
                return fs;
            string iv = vd.name;
            var cb = (BinaryExpr) fs.condition;
            if (cb.op != "<" && cb.op != "<=") return fs;
            if (!(cb.left is VarRef) || ((VarRef) cb.left).name != iv) return fs;
            if (!(cb.right is IntLiteral || cb.right is VarRef)) return fs;
            if (cb.right is VarRef && ((VarRef) cb.right).name == iv) return fs;
            if (cb.right is IntLiteral && ((IntLiteral) cb.right).value < int64.MIN + 3) return fs;

            bool step_ok = false;
            if (fs.step is ExprStatement) {
                var ses = (ExprStatement) fs.step;
                if (ses.expr is IncDecExpr) {
                    var inc = (IncDecExpr) ses.expr;
                    if (inc.op == "++" && inc.target is VarRef && ((VarRef) inc.target).name == iv)
                        step_ok = true;
                }
            } else if (fs.step is AssignStatement) {
                var sa = (AssignStatement) fs.step;
                if (sa.name == iv && sa.value is BinaryExpr) {
                    var sb = (BinaryExpr) sa.value;
                    if (sb.op == "+" && sb.left is VarRef && ((VarRef) sb.left).name == iv
                        && sb.right is IntLiteral && ((IntLiteral) sb.right).value == 1)
                        step_ok = true;
                }
            }
            if (!step_ok) return fs;
            if (!unroll_stmt_ok (fs.body)) return fs;

            var mod = new GenericArray<string> ();
            if (!Effects.collect_stmt (fs.body, mod, true)) return fs;
            if (arr_contains_str (mod, iv)) return fs;
            if (cb.right is VarRef && arr_contains_str (mod, ((VarRef) cb.right).name)) return fs;

            var p = (Program) cur_prog;
            Expr end_minus_3 = (cb.right is IntLiteral)
                ? (Expr) new IntLiteral () { value = ((IntLiteral) cb.right).value - 3, line = cb.line, column = cb.column }
                : (Expr) new BinaryExpr () {
                    op = "-",
                    left = p.clone_expr_plain (cb.right),
                    right = new IntLiteral () { value = 3, line = cb.line, column = cb.column },
                    line = cb.line,
                    column = cb.column
                };
            var u_cond = new BinaryExpr () {
                op = cb.op,
                left = new VarRef () { name = iv, line = cb.line, column = cb.column },
                right = end_minus_3,
                line = cb.line,
                column = cb.column
            };
            var u_body = new BlockStatement () { line = fs.line, column = fs.column };
            for (int k = 0; k < 4; k++) {
                var cloned_b = unroll_clone_stmt (fs.body, iv, k);
                if (cloned_b is BlockStatement) {
                    var cbk = (BlockStatement) cloned_b;
                    for (int bi = 0; bi < cbk.statements.length; bi++)
                        u_body.statements.add (cbk.statements[bi]);
                } else {
                    u_body.statements.add (cloned_b);
                }
            }
            u_body.statements.add (new AssignStatement () {
                name = iv,
                value = new BinaryExpr () {
                    op = "+",
                    left = new VarRef () { name = iv, line = fs.line, column = fs.column },
                    right = new IntLiteral () { value = 4, line = fs.line, column = fs.column },
                    line = fs.line,
                    column = fs.column
                },
                line = fs.line,
                column = fs.column
            });

            var r_body = new BlockStatement () { line = fs.line, column = fs.column };
            var cloned_r = unroll_clone_stmt (fs.body, iv, 0);
            if (cloned_r is BlockStatement) {
                var crk = (BlockStatement) cloned_r;
                for (int bi = 0; bi < crk.statements.length; bi++)
                    r_body.statements.add (crk.statements[bi]);
            } else {
                r_body.statements.add (cloned_r);
            }
            r_body.statements.add (new AssignStatement () {
                name = iv,
                value = new BinaryExpr () {
                    op = "+",
                    left = new VarRef () { name = iv, line = fs.line, column = fs.column },
                    right = new IntLiteral () { value = 1, line = fs.line, column = fs.column },
                    line = fs.line,
                    column = fs.column
                },
                line = fs.line,
                column = fs.column
            });

            var outer = new BlockStatement () { line = fs.line, column = fs.column };
            outer.statements.add ((Statement) fs.init);
            outer.statements.add (new WhileStatement () { condition = u_cond, body = u_body, line = fs.line, column = fs.column });
            outer.statements.add (new WhileStatement () { condition = p.clone_expr_plain ((Expr) fs.condition), body = r_body, line = fs.line, column = fs.column });
            return outer;
        }

        private Statement? opt_stmt (Statement s) {
            if (s is BlockStatement) {
                opt_block ((BlockStatement) s);
                return s;
            }
            if (s is ReturnStatement) {
                var rs = (ReturnStatement) s;
                if (rs.value != null)
                    rs.value = opt_expr (rs.value);
                return s;
            }
            if (s is PrintStatement) {
                var ps = (PrintStatement) s;
                ps.value = opt_expr (ps.value);
                return s;
            }
            if (s is ExitStatement) {
                var es = (ExitStatement) s;
                es.value = opt_expr (es.value);
                return s;
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.init != null)
                    d.init = opt_expr (d.init);
                return s;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                a.value = opt_expr (a.value);
                return s;
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                fa.target = opt_expr (fa.target);
                fa.value = opt_expr (fa.value);
                return s;
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                ia.target = opt_expr (ia.target);
                ia.index = opt_expr (ia.index);
                ia.value = opt_expr (ia.value);
                return s;
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                es.expr = opt_expr (es.expr);
                return s;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                ifs.condition = opt_expr (ifs.condition);
                if (ifs.then_body != null) {
                    var tb = opt_stmt (ifs.then_body);
                    ifs.then_body = tb != null ? tb : new BlockStatement ();
                }
                if (ifs.else_body != null)
                    ifs.else_body = opt_stmt (ifs.else_body);
                if (ifs.condition is BoolLiteral) {
                    bool cond_val = ((BoolLiteral) ifs.condition).value;
                    if (cond_val)
                        return ifs.then_body;
                    return ifs.else_body; // null if no else
                }
                return s;
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                ws.condition = opt_expr (ws.condition);
                if (ws.body != null) {
                    var wb = opt_stmt (ws.body);
                    ws.body = wb != null ? wb : new BlockStatement ();
                }
                if (ws.condition is BoolLiteral && !((BoolLiteral) ws.condition).value)
                    return null; // DCE: while (false)
                return s;
            }
            if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                if (dw.body != null) {
                    var dwb = opt_stmt (dw.body);
                    dw.body = dwb != null ? dwb : new BlockStatement ();
                }
                dw.condition = opt_expr (dw.condition);
                return s;
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                if (fs.init != null)
                    fs.init = opt_stmt (fs.init);
                if (fs.condition != null)
                    fs.condition = opt_expr (fs.condition);
                if (fs.step != null)
                    fs.step = opt_stmt (fs.step);
                if (fs.body != null) {
                    var fb = opt_stmt (fs.body);
                    fs.body = fb != null ? fb : new BlockStatement ();
                }
                return s;
            }
            if (s is ForeachStatement) {
                var fe = (ForeachStatement) s;
                fe.collection = opt_expr (fe.collection);
                if (fe.body != null) {
                    var feb = opt_stmt (fe.body);
                    fe.body = feb != null ? feb : new BlockStatement ();
                }
                return s;
            }
            if (s is SwitchStatement) {
                var sw = (SwitchStatement) s;
                sw.target = opt_expr (sw.target);
                for (int i = 0; i < sw.cases.length; i++) {
                    var sc = sw.cases[i];
                    for (int j = 0; j < sc.values.length; j++)
                        sc.values[j] = opt_expr (sc.values[j]);
                    if (sc.body != null)
                        opt_stmt_list (sc.body);
                }
                if (sw.default_body != null)
                    opt_stmt_list (sw.default_body);
                return s;
            }
            if (s is TryStatement) {
                var ts = (TryStatement) s;
                if (ts.try_body != null)
                    opt_stmt_list (ts.try_body);
                for (int i = 0; i < ts.catches.length; i++) {
                    if (ts.catches[i].body != null)
                        opt_stmt_list (ts.catches[i].body);
                }
                if (ts.finally_body != null)
                    opt_stmt_list (ts.finally_body);
                return s;
            }
            return s;
        }

        private static int pow2_shift (int64 v) {
            if (v <= 1)
                return -1;
            if ((v & (v - 1)) != 0)
                return -1;
            int sh = 0;
            int64 cur = v;
            while (cur > 1) {
                cur = cur >> 1;
                sh++;
            }
            return sh;
        }

        private static bool is_pure_atom (Expr e) {
            return (e is IntLiteral || e is BoolLiteral || e is StringLiteral || e is VarRef);
        }

        // AST recursion budget shared by the optimizer passes: subtrees beyond
        // the limit are left untouched instead of blowing the stack.
        private const int MAX_EXPR_DEPTH = 600;
        private int expr_depth = 0;

        private Expr opt_expr (Expr e) {
            if (expr_depth >= MAX_EXPR_DEPTH)
                return e;
            expr_depth++;
            try {
                return opt_expr_node (e);
            } finally {
                expr_depth--;
            }
        }

        private Expr opt_expr_node (Expr e) {
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                u.operand = opt_expr (u.operand);
                if (u.operand is IntLiteral) {
                    var il = (IntLiteral) u.operand;
                    int64 v = il.value;
                    if (il.is_unsigned) {
                        bool is64 = il.is_long || ((uint64) v) > (uint64) 0xFFFFFFFFu;
                        if (u.op == "-") {
                            int64 nv = is64 ? (int64) (-(uint64) v) : (int64) ((uint64) (uint32) (-(uint32) (uint64) v));
                            return new IntLiteral () { value = nv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (u.op == "~") {
                            int64 nv = is64 ? ~v : (int64) ((uint64) (uint32) (~(uint32) (uint64) v));
                            return new IntLiteral () { value = nv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                    } else {
                        if (u.op == "-") {
                            if (v == int64.MIN) {
                                Host.eprintln (@"planc: warning: integer overflow in unary '-' at $(loc_str (e.line, e.column))");
                                return u;
                            }
                            return new IntLiteral () { value = -v, is_long = il.is_long, line = e.line, column = e.column };
                        }
                        if (u.op == "~")
                            return new IntLiteral () { value = ~v, is_long = il.is_long, line = e.line, column = e.column };
                    }
                }
                if (u.operand is BoolLiteral && u.op == "!") {
                    bool bv = ((BoolLiteral) u.operand).value;
                    return new BoolLiteral () { value = !bv, line = e.line, column = e.column };
                }
                if (level >= 2 && u.op == "!") {
                    if (u.operand is BinaryExpr) {
                        var cb = (BinaryExpr) u.operand;
                        if (cb.op == "==") { cb.op = "!="; return cb; }
                        if (cb.op == "!=") { cb.op = "=="; return cb; }
                        if (cb.op == "<")  { cb.op = ">="; return cb; }
                        if (cb.op == "<=") { cb.op = ">";  return cb; }
                        if (cb.op == ">")  { cb.op = "<="; return cb; }
                        if (cb.op == ">=") { cb.op = "<";  return cb; }
                    }
                    if (u.operand is UnaryExpr && ((UnaryExpr) u.operand).op == "!") {
                        var inner = ((UnaryExpr) u.operand).operand;
                        if (inner is BoolLiteral || inner is UnaryExpr && ((UnaryExpr) inner).op == "!"
                            || (inner is BinaryExpr && (((BinaryExpr) inner).op == "==" || ((BinaryExpr) inner).op == "!="
                                || ((BinaryExpr) inner).op == "<" || ((BinaryExpr) inner).op == "<="
                                || ((BinaryExpr) inner).op == ">" || ((BinaryExpr) inner).op == ">="
                                || ((BinaryExpr) inner).op == "&&" || ((BinaryExpr) inner).op == "||"))) {
                            return inner;
                        }
                    }
                }
                return u;
            }

            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                b.left = opt_expr (b.left);
                b.right = opt_expr (b.right);

                if (b.left is IntLiteral && b.right is IntLiteral) {
                    var ll = (IntLiteral) b.left;
                    var rl = (IntLiteral) b.right;
                    int64 l = ll.value;
                    int64 r = rl.value;
                    if (ll.is_unsigned && rl.is_unsigned) {
                        bool is64 = ll.is_long || rl.is_long
                            || ((uint64) l) > (uint64) 0xFFFFFFFFu
                            || ((uint64) r) > (uint64) 0xFFFFFFFFu;
                        uint64 ul = is64 ? (uint64) l : (uint64) (uint32) (uint64) l;
                        uint64 ur = is64 ? (uint64) r : (uint64) (uint32) (uint64) r;
                        int bits = is64 ? 64 : 32;
                        if (b.op == "+") {
                            uint64 res = ul + ur;
                            int64 fv = is64 ? (int64) res : (int64) (uint64) (uint32) res;
                            return new IntLiteral () { value = fv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (b.op == "-") {
                            uint64 res = ul - ur;
                            int64 fv = is64 ? (int64) res : (int64) (uint64) (uint32) res;
                            return new IntLiteral () { value = fv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (b.op == "*") {
                            uint64 res = ul * ur;
                            int64 fv = is64 ? (int64) res : (int64) (uint64) (uint32) res;
                            return new IntLiteral () { value = fv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (b.op == "/") {
                            if (ur == 0) {
                                Host.eprintln (@"planc: warning: division by zero at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            uint64 res = ul / ur;
                            int64 fv = is64 ? (int64) res : (int64) (uint64) (uint32) res;
                            return new IntLiteral () { value = fv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (b.op == "%") {
                            if (ur == 0) {
                                Host.eprintln (@"planc: warning: modulo by zero at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            uint64 res = ul % ur;
                            int64 fv = is64 ? (int64) res : (int64) (uint64) (uint32) res;
                            return new IntLiteral () { value = fv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (b.op == "&") return new IntLiteral () { value = (int64) (ul & ur), is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        if (b.op == "|") return new IntLiteral () { value = (int64) (ul | ur), is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        if (b.op == "^") return new IntLiteral () { value = (int64) (ul ^ ur), is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        if (b.op == "<<") {
                            if (ur >= (uint64) bits) {
                                Host.eprintln (@"planc: warning: shift count out of range in '<<' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            uint64 res = ul << (int) ur;
                            int64 fv = is64 ? (int64) res : (int64) (uint64) (uint32) res;
                            return new IntLiteral () { value = fv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (b.op == ">>") {
                            if (ur >= (uint64) bits) {
                                Host.eprintln (@"planc: warning: shift count out of range in '>>' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            uint64 res = ul >> (int) ur;
                            int64 fv = is64 ? (int64) res : (int64) (uint64) (uint32) res;
                            return new IntLiteral () { value = fv, is_unsigned = true, is_long = is64, line = e.line, column = e.column };
                        }
                        if (b.op == "==") return new BoolLiteral () { value = (ul == ur), line = e.line, column = e.column };
                        if (b.op == "!=") return new BoolLiteral () { value = (ul != ur), line = e.line, column = e.column };
                        if (b.op == "<")  return new BoolLiteral () { value = (ul < ur),  line = e.line, column = e.column };
                        if (b.op == "<=") return new BoolLiteral () { value = (ul <= ur), line = e.line, column = e.column };
                        if (b.op == ">")  return new BoolLiteral () { value = (ul > ur),  line = e.line, column = e.column };
                        if (b.op == ">=") return new BoolLiteral () { value = (ul >= ur), line = e.line, column = e.column };
                    } else if (!ll.is_unsigned && !rl.is_unsigned) {
                        if (b.op == "+") {
                            if ((r > 0 && l > int64.MAX - r) || (r < 0 && l < int64.MIN - r)) {
                                Host.eprintln (@"planc: warning: integer overflow in '+' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            return new IntLiteral () { value = l + r, line = e.line, column = e.column };
                        }
                        if (b.op == "-") {
                            if ((r < 0 && l > int64.MAX + r) || (r > 0 && l < int64.MIN + r)) {
                                Host.eprintln (@"planc: warning: integer overflow in '-' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            return new IntLiteral () { value = l - r, line = e.line, column = e.column };
                        }
                        if (b.op == "*") {
                            bool ov = false;
                            if (l > 0 && r > 0 && l > int64.MAX / r) ov = true;
                            else if (l > 0 && r < 0 && r < int64.MIN / l) ov = true;
                            else if (l < 0 && r > 0 && l < int64.MIN / r) ov = true;
                            else if (l < 0 && r < 0 && l < int64.MAX / r) ov = true;
                            if (ov) {
                                Host.eprintln (@"planc: warning: integer overflow in '*' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            return new IntLiteral () { value = l * r, line = e.line, column = e.column };
                        }
                        if (b.op == "/") {
                            if (r == 0) {
                                Host.eprintln (@"planc: warning: division by zero at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            if (l == int64.MIN && r == -1) {
                                Host.eprintln (@"planc: warning: integer overflow in '/' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            return new IntLiteral () { value = l / r, line = e.line, column = e.column };
                        }
                        if (b.op == "%") {
                            if (r == 0) {
                                Host.eprintln (@"planc: warning: modulo by zero at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            if (l == int64.MIN && r == -1) {
                                Host.eprintln (@"planc: warning: integer overflow in '%' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            return new IntLiteral () { value = l % r, line = e.line, column = e.column };
                        }
                        if (b.op == "&") return new IntLiteral () { value = l & r, line = e.line, column = e.column };
                        if (b.op == "|") return new IntLiteral () { value = l | r, line = e.line, column = e.column };
                        if (b.op == "^") return new IntLiteral () { value = l ^ r, line = e.line, column = e.column };
                        if (b.op == "<<") {
                            if (r < 0 || r >= 64) {
                                Host.eprintln (@"planc: warning: shift count out of range in '<<' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            return new IntLiteral () { value = l << r, line = e.line, column = e.column };
                        }
                        if (b.op == ">>") {
                            if (r < 0 || r >= 64) {
                                Host.eprintln (@"planc: warning: shift count out of range in '>>' at $(loc_str (e.line, e.column))");
                                return b;
                            }
                            return new IntLiteral () { value = l >> r, line = e.line, column = e.column };
                        }
                        if (b.op == "==") return new BoolLiteral () { value = (l == r), line = e.line, column = e.column };
                        if (b.op == "!=") return new BoolLiteral () { value = (l != r), line = e.line, column = e.column };
                        if (b.op == "<")  return new BoolLiteral () { value = (l < r),  line = e.line, column = e.column };
                        if (b.op == "<=") return new BoolLiteral () { value = (l <= r), line = e.line, column = e.column };
                        if (b.op == ">")  return new BoolLiteral () { value = (l > r),  line = e.line, column = e.column };
                        if (b.op == ">=") return new BoolLiteral () { value = (l >= r), line = e.line, column = e.column };
                    } else if (ll.is_unsigned && !rl.is_unsigned && (b.op == "<<" || b.op == ">>")) {
                        int bits = ll.is_long ? 64 : 32;
                        if (r < 0 || r >= bits) {
                            Host.eprintln (@"planc: warning: shift count out of range in '$(b.op)' at $(loc_str (e.line, e.column))");
                            return b;
                        }
                        uint64 ul = (uint64) l;
                        uint64 res = (b.op == "<<") ? (ul << (int) r) : (ul >> (int) r);
                        int64 fv = ll.is_long ? (int64) res : (int64) (uint64) (uint32) res;
                        return new IntLiteral () { value = fv, is_unsigned = true, is_long = ll.is_long, line = e.line, column = e.column };
                    }
                }

                if (b.left is BoolLiteral && b.right is BoolLiteral) {
                    bool l = ((BoolLiteral) b.left).value;
                    bool r = ((BoolLiteral) b.right).value;
                    if (b.op == "&&") return new BoolLiteral () { value = (l && r), line = e.line, column = e.column };
                    if (b.op == "||") return new BoolLiteral () { value = (l || r), line = e.line, column = e.column };
                    if (b.op == "==") return new BoolLiteral () { value = (l == r), line = e.line, column = e.column };
                    if (b.op == "!=") return new BoolLiteral () { value = (l != r), line = e.line, column = e.column };
                }

                if (b.left is StringLiteral && b.right is StringLiteral && b.op == "+") {
                    string ls = ((StringLiteral) b.left).value;
                    string rs = ((StringLiteral) b.right).value;
                    return new StringLiteral () { value = ls + rs, line = e.line, column = e.column };
                }

                // Algebraic identities & strength reduction
                if (b.right is IntLiteral) {
                    int64 r = ((IntLiteral) b.right).value;
                    if ((b.op == "+" || b.op == "-" || b.op == "|" || b.op == "^" || b.op == "<<" || b.op == ">>") && r == 0)
                        return b.left;
                    if ((b.op == "+" || b.op == "-") && b.left is BinaryExpr) {
                        var lb = (BinaryExpr) b.left;
                        if ((lb.op == "+" || lb.op == "-") && lb.right is IntLiteral) {
                            int64 c1 = ((IntLiteral) lb.right).value;
                            int64 d1 = (lb.op == "+") ? c1 : -c1;
                            int64 d2 = (b.op == "+") ? r : -r;
                            int64 sum = d1 + d2;
                            if (sum == 0) return lb.left;
                            if (sum > 0)
                                return new BinaryExpr () { op = "+", left = lb.left, right = new IntLiteral () { value = sum, line = e.line, column = e.column }, line = e.line, column = e.column };
                            return new BinaryExpr () { op = "-", left = lb.left, right = new IntLiteral () { value = -sum, line = e.line, column = e.column }, line = e.line, column = e.column };
                        }
                    }
                    if ((b.op == "*" || b.op == "/") && r == 1)
                        return b.left;
                    if (b.op == "*" && r == 0 && is_pure_atom (b.left))
                        return new IntLiteral () { value = 0, line = e.line, column = e.column };
                    if (b.op == "&" && r == 0 && is_pure_atom (b.left))
                        return new IntLiteral () { value = 0, line = e.line, column = e.column };
                    if (b.op == "&" && r == -1)
                        return b.left;
                    if (b.op == "|" && r == -1 && is_pure_atom (b.left))
                        return new IntLiteral () { value = -1, line = e.line, column = e.column };
                    if (b.op == "*") {
                        int sh = pow2_shift (r);
                        if (sh > 0) {
                            b.op = "<<";
                            b.right = new IntLiteral () { value = sh, line = b.right.line, column = b.right.column };
                        }
                    }
                }
                if (b.left is IntLiteral) {
                    int64 l = ((IntLiteral) b.left).value;
                    if ((b.op == "+" || b.op == "|" || b.op == "^") && l == 0)
                        return b.right;
                    if (b.op == "*" && l == 1)
                        return b.right;
                    if (b.op == "*" && l == 0 && is_pure_atom (b.right))
                        return new IntLiteral () { value = 0, line = e.line, column = e.column };
                    if (b.op == "*") {
                        int sh = pow2_shift (l);
                        if (sh > 0) {
                            b.op = "<<";
                            b.left = b.right;
                            b.right = new IntLiteral () { value = sh, line = b.left.line, column = b.left.column };
                        }
                    }
                }
                if (b.left is BoolLiteral) {
                    bool lv = ((BoolLiteral) b.left).value;
                    if ((b.op == "&&" && lv) || (b.op == "||" && !lv)) {
                        bool rb = (b.right is BoolLiteral)
                            || (b.right is UnaryExpr && ((UnaryExpr) b.right).op == "!");
                        if (!rb && b.right is BinaryExpr) {
                            string rop = ((BinaryExpr) b.right).op;
                            rb = (rop == "==" || rop == "!=" || rop == "<" || rop == "<="
                                  || rop == ">" || rop == ">=" || rop == "&&" || rop == "||");
                        }
                        if (rb) return b.right;
                        return new BinaryExpr () {
                            op = "!=",
                            left = b.right,
                            right = new IntLiteral () { value = 0, line = b.right.line, column = b.right.column },
                            line = e.line,
                            column = e.column
                        };
                    }
                    if (b.op == "&&" && !lv) return new BoolLiteral () { value = false, line = e.line, column = e.column };
                    if (b.op == "||" && lv) return new BoolLiteral () { value = true, line = e.line, column = e.column };
                    if (level >= 2) {
                        if ((b.op == "==" && lv) || (b.op == "!=" && !lv)) return b.right;
                        if ((b.op == "==" && !lv) || (b.op == "!=" && lv))
                            return new UnaryExpr () { op = "!", operand = b.right, line = e.line, column = e.column };
                    }
                }
                if (level >= 2 && b.right is BoolLiteral) {
                    bool rv = ((BoolLiteral) b.right).value;
                    if ((b.op == "==" && rv) || (b.op == "!=" && !rv)) return b.left;
                    if ((b.op == "==" && !rv) || (b.op == "!=" && rv))
                        return new UnaryExpr () { op = "!", operand = b.left, line = e.line, column = e.column };
                }
                if (level >= 2 && b.right is IntLiteral && !((IntLiteral) b.right).is_unsigned && b.left is BinaryExpr) {
                    var lb = (BinaryExpr) b.left;
                    if (lb.right is IntLiteral && !((IntLiteral) lb.right).is_unsigned) {
                        int64 c1 = ((IntLiteral) lb.right).value;
                        int64 c2 = ((IntLiteral) b.right).value;
                        if (b.op == "+" && lb.op == "+") {
                            lb.right = new IntLiteral () { value = c1 + c2, line = lb.right.line, column = lb.right.column };
                            return lb;
                        }
                        if (b.op == "+" && lb.op == "-") {
                            lb.op = "+";
                            lb.right = new IntLiteral () { value = c2 - c1, line = lb.right.line, column = lb.right.column };
                            return lb;
                        }
                        if (b.op == "*" && lb.op == "*") {
                            lb.right = new IntLiteral () { value = c1 * c2, line = lb.right.line, column = lb.right.column };
                            return lb;
                        }
                    }
                }
                return b;
            }

            if (e is TernaryExpr) {
                var t = (TernaryExpr) e;
                t.condition = opt_expr (t.condition);
                t.then_expr = opt_expr (t.then_expr);
                t.else_expr = opt_expr (t.else_expr);
                if (t.condition is BoolLiteral)
                    return ((BoolLiteral) t.condition).value ? t.then_expr : t.else_expr;
                return t;
            }

            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++)
                    c.args[i] = opt_expr (c.args[i]);
                return c;
            }

            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    mc.target = opt_expr ((Expr) mc.target);
                for (int i = 0; i < mc.args.length; i++)
                    mc.args[i] = opt_expr (mc.args[i]);
                return mc;
            }

            if (e is VarRef && cur_prog != null) {
                var vr = (VarRef) e;
                if (!is_local_or_param (vr.name)) {
                    unowned var cd = (cur_owner != "") ? cur_prog.find_const (cur_owner, vr.name) : null;
                    if (cd == null)
                        cd = cur_prog.find_const ("", vr.name);
                    if (cd != null) {
                        var lit = const_to_literal (cd, e.line, e.column);
                        if (lit != null)
                            return lit;
                    }
                }
                return e;
            }

            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                ma.target = opt_expr (ma.target);
                if (ma.member == "length" && ma.target is StringLiteral) {
                    string sv = ((StringLiteral) ma.target).value;
                    return new IntLiteral () { value = sv.length, line = e.line, column = e.column };
                }
                if (cur_prog != null && ma.target is VarRef) {
                    unowned var cd = cur_prog.find_const (((VarRef) ma.target).name, ma.member);
                    if (cd != null) {
                        var lit = const_to_literal (cd, e.line, e.column);
                        if (lit != null)
                            return lit;
                    }
                }
                return ma;
            }

            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                ix.target = opt_expr (ix.target);
                ix.index = opt_expr (ix.index);
                return ix;
            }

            if (e is TypeCheckExpr) {
                var tc = (TypeCheckExpr) e;
                tc.operand = opt_expr (tc.operand);
                return tc;
            }

            if (e is ArrayNewExpr) {
                var an = (ArrayNewExpr) e;
                an.length_expr = opt_expr (an.length_expr);
                if (an.length_expr is IntLiteral) {
                    int64 len_v = ((IntLiteral) an.length_expr).value;
                    if (len_v < 0)
                        Host.eprintln (@"planc: warning: negative array size $(len_v) in 'new' at $(loc_str (an.line, an.column))");
                }
                return an;
            }

            return e;
        }
    }
}
