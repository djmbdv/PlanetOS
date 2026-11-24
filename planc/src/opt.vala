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
        private int licm_counter = 0;
        private int sra_counter = 0;

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

        private static bool can_inline_fn (Function fn, int arg_count, int param_offset, GenericArray<Expr> args, Expr body_expr, ClassDecl? cd = null) {
            if (fn.is_async || fn.is_asm_body || fn.can_throw || fn.is_varargs || fn.is_virtual || fn.is_override || fn.is_abstract)
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
                if (fn != null && fn.body != null && fn.body.length == 1 && fn.body[0] is ReturnStatement) {
                    var rs = (ReturnStatement) fn.body[0];
                    if (rs.value != null && can_inline_fn (fn, c.args.length, 0, c.args, rs.value)) {
                        var pnames = new GenericArray<string> ();
                        for (int i = 0; i < fn.params.length; i++)
                            pnames.add (fn.params[i].name);
                        var cloned = prog.clone_expr_plain (rs.value);
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
                            if (fn != null && !fn.is_static
                                && fn.body != null && fn.body.length == 1 && fn.body[0] is ReturnStatement) {
                                var rs = (ReturnStatement) fn.body[0];
                                if (rs.value != null && can_inline_fn (fn, mc.args.length, poff, mc.args, rs.value, cd)) {
                                    var pnames = new GenericArray<string> ();
                                    for (int i = poff; i < fn.params.length; i++)
                                        pnames.add (fn.params[i].name);
                                    var cloned = prog.clone_expr_plain (rs.value);
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
                if (rs.value != null)
                    rs.value = inline_expr (prog, rs.value, vnames, vclasses);
                return rs;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                a.value = inline_expr (prog, a.value, vnames, vclasses);
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
                            }
                        }
                    }
                }
                es.expr = inline_expr (prog, es.expr, vnames, vclasses);
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
            if (f.body != null) {
                if (level >= 2 && cur_prog != null)
                    sra_stmt_list (f.body);
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

        private static void add_unique_str (GenericArray<string> arr, string s) {
            if (s != "" && !arr_contains_str (arr, s))
                arr.add (s);
        }

        private bool collect_mod_expr (Expr? e, GenericArray<string> mod) {
            if (e == null) return true;
            if (e is LambdaExpr || e is AddrOfExpr) return false;
            if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                if (inc.target is VarRef) add_unique_str (mod, ((VarRef) inc.target).name);
                return true;
            }
            if (e is UnaryExpr) return collect_mod_expr (((UnaryExpr) e).operand, mod);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return collect_mod_expr (b.left, mod) && collect_mod_expr (b.right, mod);
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return collect_mod_expr (ix.target, mod) && collect_mod_expr (ix.index, mod);
            }
            if (e is MemberAccessExpr) return collect_mod_expr (((MemberAccessExpr) e).target, mod);
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++) {
                    if (c.args[i] is VarRef) add_unique_str (mod, ((VarRef) c.args[i]).name);
                    if (!collect_mod_expr (c.args[i], mod)) return false;
                }
                return true;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (!collect_mod_expr (mc.target, mod)) return false;
                for (int i = 0; i < mc.args.length; i++) {
                    if (mc.args[i] is VarRef) add_unique_str (mod, ((VarRef) mc.args[i]).name);
                    if (!collect_mod_expr (mc.args[i], mod)) return false;
                }
                return true;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return collect_mod_expr (te.condition, mod)
                    && collect_mod_expr (te.then_expr, mod)
                    && collect_mod_expr (te.else_expr, mod);
            }
            return true;
        }

        private bool collect_mod_stmt (Statement? s, GenericArray<string> mod) {
            if (s == null) return true;
            if (s is TryStatement || s is ForeachStatement || s is SwitchStatement) return false;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (!collect_mod_stmt (blk.statements[i], mod)) return false;
                }
                return true;
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                add_unique_str (mod, d.name);
                return collect_mod_expr (d.init, mod);
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                add_unique_str (mod, a.name);
                return collect_mod_expr (a.value, mod);
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return collect_mod_expr (fa.target, mod) && collect_mod_expr (fa.value, mod);
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                return collect_mod_expr (ia.target, mod)
                    && collect_mod_expr (ia.index, mod)
                    && collect_mod_expr (ia.value, mod);
            }
            if (s is ReturnStatement) return collect_mod_expr (((ReturnStatement) s).value, mod);
            if (s is ExprStatement) return collect_mod_expr (((ExprStatement) s).expr, mod);
            if (s is PrintStatement) return collect_mod_expr (((PrintStatement) s).value, mod);
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return collect_mod_expr (ifs.condition, mod)
                    && collect_mod_stmt (ifs.then_body, mod)
                    && collect_mod_stmt (ifs.else_body, mod);
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                return collect_mod_expr (ws.condition, mod) && collect_mod_stmt (ws.body, mod);
            }
            if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                return collect_mod_stmt (dw.body, mod) && collect_mod_expr (dw.condition, mod);
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                return collect_mod_stmt (fs.init, mod)
                    && collect_mod_expr (fs.condition, mod)
                    && collect_mod_stmt (fs.step, mod)
                    && collect_mod_stmt (fs.body, mod);
            }
            return true;
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
            if (!collect_mod_stmt (fs.init, mod)) return;
            if (!collect_mod_expr (fs.condition, mod)) return;
            if (!collect_mod_stmt (fs.step, mod)) return;
            if (!collect_mod_stmt (fs.body, mod)) return;
            if (fs.condition != null)
                fs.condition = licm_rewrite_expr (fs.condition, mod, out_stmts, fs.line, fs.column);
            licm_rewrite_stmt (fs.body, mod, out_stmts, fs.line, fs.column);
        }

        private void opt_stmt_list (GenericArray<Statement> stmts) {
            var out_stmts = new GenericArray<Statement> ();
            var cnames = new GenericArray<string> ();
            var cvals = new GenericArray<Expr?> ();
            var ctracked = new GenericArray<bool> ();
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
                        if (level >= 2 && opt_s is ForStatement)
                            hoist_for_invariants ((ForStatement) opt_s, out_stmts);
                        out_stmts.add (opt_s);
                    }
                    if (opt_s is ReturnStatement || opt_s is BreakStatement
                        || opt_s is ContinueStatement || opt_s is ThrowStatement) {
                        break; // DCE: unreachable statements after terminator
                    }
                }
            }
            stmts.length = 0;
            for (int i = 0; i < out_stmts.length; i++)
                stmts.add (out_stmts[i]);
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

        private Expr opt_expr (Expr e) {
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
                    if (b.op == "&&" && lv) return b.right;
                    if (b.op == "&&" && !lv) return new BoolLiteral () { value = false, line = e.line, column = e.column };
                    if (b.op == "||" && !lv) return b.right;
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

            return e;
        }
    }
}
