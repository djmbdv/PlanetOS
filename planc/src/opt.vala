// AST optimization pass for planc (-O1 / -O2):
// - Constant folding (int/bool/string arithmetic, bitwise, comparisons, ternary)
// - Algebraic identities & strength reduction (x * 2^k -> x << k, x + 0 -> x)
// - Dead-code elimination (if(true/false), while(false), unreachable after return/break/continue)

namespace Planc {

    public sealed class Optimizer : Object {
        private int level = 0;
        private Program? cur_prog = null;
        private string cur_owner = "";
        private string cur_file = "";
        private Function? cur_func = null;
        private GenericArray<string> active_locals = new GenericArray<string> ();

        public static void optimize (Program prog, int opt_level) {
            if (opt_level <= 0)
                return;
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

        private void opt_func (Function f) {
            cur_func = f;
            cur_file = f.file;
            active_locals = new GenericArray<string> ();
            if (f.body != null)
                opt_stmt_list (f.body);
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

        private static Expr? const_to_literal (ConstDecl cd, int line, int col) {
            if (cd.const_type == ValaType.INT)
                return new IntLiteral () { value = cd.int_value, line = line, column = col };
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
                    if (c is IntLiteral)
                        return new IntLiteral () { value = ((IntLiteral) c).value, line = e.line, column = e.column };
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
                        if (vd.infer_type || vd.decl_type == ValaType.INT || vd.decl_type == ValaType.BOOL || vd.decl_type == ValaType.STRING) {
                            if (vd.init != null && (vd.init is IntLiteral || vd.init is BoolLiteral || vd.init is StringLiteral))
                                set_const (cnames, cvals, ctracked, vd.name, vd.init);
                            else
                                set_const (cnames, cvals, ctracked, vd.name, null);
                        }
                    } else if (opt_s is AssignStatement) {
                        var asg = (AssignStatement) opt_s;
                        if (is_tracked_const_var (cnames, asg.name)) {
                            if (asg.value is IntLiteral || asg.value is BoolLiteral || asg.value is StringLiteral)
                                set_const (cnames, cvals, ctracked, asg.name, asg.value);
                            else
                                set_const (cnames, cvals, ctracked, asg.name, null);
                        }
                    } else if (opt_s is IfStatement || opt_s is WhileStatement || opt_s is ForStatement
                               || opt_s is ForeachStatement || opt_s is SwitchStatement
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
                    int64 v = ((IntLiteral) u.operand).value;
                    if (u.op == "-") {
                        if (v == int64.MIN) {
                            Host.eprintln (@"planc: warning: integer overflow in unary '-' at $(loc_str (e.line, e.column))");
                            return u;
                        }
                        return new IntLiteral () { value = -v, line = e.line, column = e.column };
                    }
                    if (u.op == "~")
                        return new IntLiteral () { value = ~v, line = e.line, column = e.column };
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
                    int64 l = ((IntLiteral) b.left).value;
                    int64 r = ((IntLiteral) b.right).value;
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
                if (level >= 2 && b.right is IntLiteral && b.left is BinaryExpr) {
                    var lb = (BinaryExpr) b.left;
                    if (lb.right is IntLiteral) {
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
