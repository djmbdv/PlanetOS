// One implementation of "which variables does this code write".
//
// Three passes ask the same question: the bounds-check elimination of each
// backend and the loop-invariant hoisting of the optimizer. Keeping three
// traversals meant the same hole could be fixed in one and left in the others,
// so the traversal lives here and the passes only pick a policy.
//
// Over-approximating is always safe: counting a write that does not happen only
// costs an optimisation. Constructs the traversal cannot analyse (lambda bodies,
// `&expr`) are reported as not analysable, and the callers treat that as a write.

namespace Planc {

    public class Effects : Object {
        // `ref_out_writes` says whether a call may write through its arguments.
        // True for the AST backend and the optimizer, where `ref`/`out` exist;
        // false for the register-allocating backend, which refuses them and would
        // otherwise lose bounds-check elimination on every loop that calls a
        // function with the induction variable as an argument.
        public static bool collect_expr (Expr? e, GenericArray<string> mod, bool ref_out_writes) {
            if (e == null) return true;
            if (e is LambdaExpr || e is AddrOfExpr) return false;
            if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                if (inc.target is VarRef) add (mod, ((VarRef) inc.target).name);
                return collect_expr (inc.target, mod, ref_out_writes);
            }
            if (e is UnaryExpr) return collect_expr (((UnaryExpr) e).operand, mod, ref_out_writes);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return collect_expr (b.left, mod, ref_out_writes)
                    && collect_expr (b.right, mod, ref_out_writes);
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return collect_expr (te.condition, mod, ref_out_writes)
                    && collect_expr (te.then_expr, mod, ref_out_writes)
                    && collect_expr (te.else_expr, mod, ref_out_writes);
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return collect_expr (ix.target, mod, ref_out_writes)
                    && collect_expr (ix.index, mod, ref_out_writes);
            }
            if (e is MemberAccessExpr) return collect_expr (((MemberAccessExpr) e).target, mod, ref_out_writes);
            if (e is DerefExpr) return collect_expr (((DerefExpr) e).target, mod, ref_out_writes);
            if (e is SliceExpr) {
                var se = (SliceExpr) e;
                return collect_expr (se.target, mod, ref_out_writes)
                    && collect_expr (se.start, mod, ref_out_writes)
                    && collect_expr (se.end, mod, ref_out_writes);
            }
            if (e is ArrayNew2Expr) {
                var an2 = (ArrayNew2Expr) e;
                return collect_expr (an2.dim0, mod, ref_out_writes)
                    && collect_expr (an2.dim1, mod, ref_out_writes);
            }
            if (e is LengthDimExpr) {
                var ld = (LengthDimExpr) e;
                return collect_expr (ld.target, mod, ref_out_writes)
                    && collect_expr (ld.dim, mod, ref_out_writes);
            }
            if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                return collect_expr (ce.left, mod, ref_out_writes)
                    && collect_expr (ce.right, mod, ref_out_writes);
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                for (int i = 0; i < c.args.length; i++) {
                    if (ref_out_writes && c.args[i] is VarRef)
                        add (mod, ((VarRef) c.args[i]).name);
                    if (!collect_expr (c.args[i], mod, ref_out_writes)) return false;
                }
                return true;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                // A method on a variable can rebind or mutate it: `resize`/`move`
                // rewrite the receiver's slot, the rest may touch the payload.
                if (mc.target is VarRef) {
                    add (mod, ((VarRef) mc.target).name);
                } else if (!collect_expr (mc.target, mod, ref_out_writes)) {
                    return false;
                }
                for (int i = 0; i < mc.args.length; i++) {
                    if (ref_out_writes && mc.args[i] is VarRef)
                        add (mod, ((VarRef) mc.args[i]).name);
                    if (!collect_expr (mc.args[i], mod, ref_out_writes)) return false;
                }
                return true;
            }
            return true;
        }

        public static bool collect_stmt (Statement? s, GenericArray<string> mod, bool ref_out_writes) {
            if (s == null) return true;
            if (s is TryStatement || s is ForeachStatement || s is SwitchStatement) return false;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (!collect_stmt (blk.statements[i], mod, ref_out_writes)) return false;
                }
                return true;
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                add (mod, d.name);
                return collect_expr (d.init, mod, ref_out_writes);
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                add (mod, a.name);
                return collect_expr (a.value, mod, ref_out_writes);
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return collect_expr (fa.target, mod, ref_out_writes)
                    && collect_expr (fa.value, mod, ref_out_writes);
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                return collect_expr (ia.target, mod, ref_out_writes)
                    && collect_expr (ia.index, mod, ref_out_writes)
                    && collect_expr (ia.value, mod, ref_out_writes);
            }
            if (s is ReturnStatement) return collect_expr (((ReturnStatement) s).value, mod, ref_out_writes);
            if (s is ExitStatement) return collect_expr (((ExitStatement) s).value, mod, ref_out_writes);
            if (s is PrintStatement) return collect_expr (((PrintStatement) s).value, mod, ref_out_writes);
            if (s is ExprStatement) return collect_expr (((ExprStatement) s).expr, mod, ref_out_writes);
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return collect_expr (ifs.condition, mod, ref_out_writes)
                    && collect_stmt (ifs.then_body, mod, ref_out_writes)
                    && collect_stmt (ifs.else_body, mod, ref_out_writes);
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                return collect_expr (ws.condition, mod, ref_out_writes)
                    && collect_stmt (ws.body, mod, ref_out_writes);
            }
            if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                return collect_stmt (dw.body, mod, ref_out_writes)
                    && collect_expr (dw.condition, mod, ref_out_writes);
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                return collect_stmt (fs.init, mod, ref_out_writes)
                    && collect_expr (fs.condition, mod, ref_out_writes)
                    && collect_stmt (fs.step, mod, ref_out_writes)
                    && collect_stmt (fs.body, mod, ref_out_writes);
            }
            return true;
        }

        // True when `e` may write `vname`. Anything the traversal cannot analyse
        // counts as a write.
        public static bool modifies_expr (Expr? e, string vname, bool ref_out_writes) {
            var mod = new GenericArray<string> ();
            if (!collect_expr (e, mod, ref_out_writes)) return true;
            return holds (mod, vname);
        }

        // True when `s` may write `vname`. Anything the traversal cannot analyse
        // counts as a write.
        public static bool modifies_stmt (Statement? s, string vname, bool ref_out_writes) {
            var mod = new GenericArray<string> ();
            if (!collect_stmt (s, mod, ref_out_writes)) return true;
            return holds (mod, vname);
        }

        private static void add (GenericArray<string> mod, string name) {
            for (int i = 0; i < mod.length; i++) {
                if (mod[i] == name) return;
            }
            mod.add (name);
        }

        public static bool holds (GenericArray<string> mod, string name) {
            for (int i = 0; i < mod.length; i++) {
                if (mod[i] == name) return true;
            }
            return false;
        }
    }
}
