// Pereira & Palsberg (PLDI 2008) Puzzle-Solving Register Allocator + 3-address IR
// for planc (-O2). Lowers eligible scalar/array functions to register-to-register
// x86-64 code, falling back to the standard AST codegen for unsupported constructs.

namespace Planc {

    public enum IROp {
        MOV_IMM,
        MOV,
        UNARY,
        BIN,
        BIN_IMM,
        CMP_JMP_FALSE,
        CMP_IMM_JMP_FALSE,
        TEST_JMP_FALSE,
        JMP,
        RET,
        RET_VOID,
        CALL,
        TRE_JUMP,
        TAIL_CALL,
        ARR_NEW,
        ARR_STACK,
        ARR_LOAD,
        ARR_STORE,
        ARR_LEN,
        SIMD_ARR_REDUCE,
        PRINT_STR,
        PRINT_INT
    }

    public class IRInst : Object {
        public IROp op;
        public int dst = -1;
        public int lhs = -1;
        public int rhs = -1;
        public int64 imm = 0;
        public string sop = "";
        public string str_val = "";
        public int target_bb = -1;
        public bool is_unsigned = false;
        public bool bounds_check = true;
        public GenericArray<int> args = new GenericArray<int> ();
    }

    public class IRBlock : Object {
        public int id;
        public GenericArray<IRInst> insts = new GenericArray<IRInst> ();
        public GenericArray<int> succs = new GenericArray<int> ();
        public GenericArray<int> preds = new GenericArray<int> ();
        public Label? label = null;

        public IRBlock (int id) {
            this.id = id;
        }
    }

    public sealed class PuzzleRA : Object {
        // 12 allocatable GPRs (R10, R11 are scratch; RSP, RBP are stack/frame).
        // Indices 0..6: caller-saved (RAX, RCX, RDX, RSI, RDI, R8, R9)
        // Indices 7..11: callee-saved (RBX, R12, R13, R14, R15)
        private const int NUM_PHYS = 12;
        private const int FIRST_CALLEE = 7;

        private static Reg phys_to_reg (int p) {
            switch (p) {
                case 0: return Reg.RAX;
                case 1: return Reg.RCX;
                case 2: return Reg.RDX;
                case 3: return Reg.RSI;
                case 4: return Reg.RDI;
                case 5: return Reg.R8;
                case 6: return Reg.R9;
                case 7: return Reg.RBX;
                case 8: return Reg.R12;
                case 9: return Reg.R13;
                case 10: return Reg.R14;
                default: return Reg.R15;
            }
        }

        private static int abi_arg_phys (int idx) {
            switch (idx) {
                case 0: return 4; // RDI
                case 1: return 3; // RSI
                case 2: return 2; // RDX
                case 3: return 1; // RCX
                case 4: return 5; // R8
                default: return 6; // R9
            }
        }

        private Emitter emitter;
        private Program program;
        private bool bounds_check;
        private bool program_uses_heap;
        private Label bounds_panic_label;
        public bool used_write_str = false;
        public bool used_write_int = false;
        public bool used_bounds_panic = false;

        private GenericArray<IRBlock> blocks = new GenericArray<IRBlock> ();
        private int cur_bb = 0;
        private int next_vreg = 0;
        private GenericArray<int> vreg_weight = new GenericArray<int> ();
        private GenericArray<bool> vreg_is_arr = new GenericArray<bool> ();
        private GenericArray<bool> vreg_is_unsigned = new GenericArray<bool> ();
        private int loop_weight = 1;

        private GenericArray<string> var_names = new GenericArray<string> ();
        private GenericArray<int> var_vregs = new GenericArray<int> ();
        private GenericArray<ValaType> var_types = new GenericArray<ValaType> ();
        private GenericArray<string> var_tnames = new GenericArray<string> ();

        private GenericArray<int> break_bbs = new GenericArray<int> ();
        private GenericArray<int> continue_bbs = new GenericArray<int> ();
        private GenericArray<int> arr_locals = new GenericArray<int> ();
        private int stack_arr_bytes = 0;
        private string cur_fn_name = "";
        private int cur_nparams = 0;
        private int tre_loop_bb = -1;
        private int tre_acc_vreg = -1;

        // Compile-time Bounds Check Elimination (BCE) state
        private GenericArray<int> bce_arr_vregs = new GenericArray<int> ();
        private GenericArray<int> bce_arr_const = new GenericArray<int> ();
        private GenericArray<int> bce_arr_var = new GenericArray<int> ();
        private GenericArray<int> bce_arr_off = new GenericArray<int> ();
        private GenericArray<int> bce_arr_ma = new GenericArray<int> ();
        private GenericArray<int> bce_arr_mb = new GenericArray<int> ();
        private GenericArray<int> bce_nonneg = new GenericArray<int> ();
        private GenericArray<int> bce_mul_v = new GenericArray<int> ();
        private GenericArray<int> bce_mul_a = new GenericArray<int> ();
        private GenericArray<int> bce_mul_b = new GenericArray<int> ();
        private GenericArray<int> bce_bnd_vreg = new GenericArray<int> ();
        private GenericArray<int> bce_bnd_min = new GenericArray<int> ();
        private GenericArray<int> bce_len_alias_v = new GenericArray<int> ();
        private GenericArray<int> bce_len_alias_arr = new GenericArray<int> ();
        private GenericArray<int> bce_bnd_max_c = new GenericArray<int> ();
        private GenericArray<int> bce_bnd_max_v = new GenericArray<int> ();
        private GenericArray<int> bce_bnd_max_off = new GenericArray<int> ();
        private GenericArray<int> bce_bnd_max_arr = new GenericArray<int> ();

        private PuzzleRA (Emitter emitter, Program program, bool bounds_check,
                          bool program_uses_heap, Label bounds_panic_label) {
            this.emitter = emitter;
            this.program = program;
            this.bounds_check = bounds_check;
            this.program_uses_heap = program_uses_heap;
            this.bounds_panic_label = bounds_panic_label;
        }

        private int new_bb () {
            int id = blocks.length;
            blocks.add (new IRBlock (id));
            return id;
        }

        private int new_vreg (bool is_arr = false, bool is_u = false) {
            int v = next_vreg++;
            vreg_weight.add (0);
            vreg_is_arr.add (is_arr);
            vreg_is_unsigned.add (is_u);
            return v;
        }

        private void touch_vreg (int v) {
            if (v >= 0 && v < vreg_weight.length)
                vreg_weight[v] = vreg_weight[v] + loop_weight;
        }

        private void emit_ir (IRInst ins) {
            touch_vreg (ins.dst);
            touch_vreg (ins.lhs);
            touch_vreg (ins.rhs);
            for (int i = 0; i < ins.args.length; i++)
                touch_vreg (ins.args[i]);
            blocks[cur_bb].insts.add (ins);
        }

        private int lookup_var (string name) {
            for (int i = var_names.length - 1; i >= 0; i--) {
                if (var_names[i] == name)
                    return i;
            }
            return -1;
        }

        private static bool is_supported_type (ValaType t, string tname) {
            if (t == ValaType.BOOL) return true;
            if (t == ValaType.INT) {
                return tname == "" || tname == "int" || tname == "int64"
                    || tname == "long" || tname == "uint" || tname == "uint64"
                    || tname == "ulong" || tname == "int32" || tname == "uint32";
            }
            if (t == ValaType.ARRAY) {
                return tname == "" || tname == "int" || tname == "int64" || tname == "long"
                    || tname == "int[]" || tname == "int64[]" || tname == "long[]";
            }
            return false;
        }

        private static bool is_unsigned_name (string tn) {
            return tn == "uint" || tn == "uint64" || tn == "ulong" || tn == "uint32";
        }

        private bool check_expr_supported (Expr? e) {
            if (e == null) return true;
            if (e is IntLiteral || e is BoolLiteral) return true;
            if (e is VarRef) {
                var vr = (VarRef) e;
                return vr.target_del_type == "" && lookup_var (vr.name) >= 0;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                return (u.op == "-" || u.op == "~" || u.op == "!") && check_expr_supported (u.operand);
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                if (b.op == "&&" || b.op == "||")
                    return check_expr_supported (b.left) && check_expr_supported (b.right);
                return check_expr_supported (b.left) && check_expr_supported (b.right);
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                if (!(ix.target is VarRef)) return false;
                int vi = lookup_var (((VarRef) ix.target).name);
                if (vi < 0 || var_types[vi] != ValaType.ARRAY) return false;
                return check_expr_supported (ix.index);
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                if (ma.member == "length" && ma.target is VarRef) {
                    int vi = lookup_var (((VarRef) ma.target).name);
                    return vi >= 0 && var_types[vi] == ValaType.ARRAY;
                }
                return false;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                if (c.args.length > 6) return false;
                unowned var fn = program.find (c.callee);
                if (fn == null || fn.is_async || fn.can_throw || fn.is_varargs) return false;
                if (fn.params.length != c.args.length) return false;
                if (fn.return_type != ValaType.VOID && !is_supported_type (fn.return_type, fn.return_type_name))
                    return false;
                for (int i = 0; i < fn.params.length; i++) {
                    if (fn.params[i].is_ref || fn.params[i].is_out
                        || !is_supported_type (fn.params[i].param_type, fn.params[i].type_name))
                        return false;
                    if (!check_expr_supported (c.args[i])) return false;
                }
                return true;
            }
            if (e is ArrayNewExpr) {
                var an = (ArrayNewExpr) e;
                return an.elem_type == ValaType.INT && check_expr_supported (an.length_expr);
            }
            return false;
        }

        private bool check_stmt_supported (Statement? s) {
            if (s == null) return true;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                int mark = var_names.length;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (!check_stmt_supported (blk.statements[i])) return false;
                }
                var_names.length = mark;
                var_vregs.length = mark;
                var_types.length = mark;
                var_tnames.length = mark;
                return true;
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.is_weak || d.is_unowned) return false;
                if (!d.infer_type && !is_supported_type (d.decl_type, d.decl_type_name)) return false;
                if (d.init != null && !check_expr_supported (d.init)) return false;
                ValaType vt = d.decl_type;
                string tn = d.decl_type_name;
                if (d.infer_type) {
                    if (d.init == null) return false;
                    if (d.init is ArrayNewExpr) { vt = ValaType.ARRAY; tn = "int[]"; }
                    else if (d.init is BoolLiteral) { vt = ValaType.BOOL; tn = "bool"; }
                    else { vt = ValaType.INT; tn = "int64"; }
                }
                var_names.add (d.name);
                var_vregs.add (0);
                var_types.add (vt);
                var_tnames.add (tn);
                return true;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                return lookup_var (a.name) >= 0 && check_expr_supported (a.value);
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                if (ia.op != "=" && ia.op != "+=" && ia.op != "-=") return false;
                if (!(ia.target is VarRef)) return false;
                int vi = lookup_var (((VarRef) ia.target).name);
                if (vi < 0 || var_types[vi] != ValaType.ARRAY) return false;
                return check_expr_supported (ia.index) && check_expr_supported (ia.value);
            }
            if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                return r.value == null || check_expr_supported (r.value);
            }
            if (s is ExprStatement) {
                return check_expr_supported (((ExprStatement) s).expr);
            }
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                if (p.value is StringLiteral) return true;
                if (p.value is TemplateExpr) {
                    var te = (TemplateExpr) p.value;
                    for (int i = 0; i < te.parts.length; i++) {
                        var pt = te.parts[i];
                        if (!(pt is StringLiteral) && !check_expr_supported (pt)) return false;
                    }
                    return true;
                }
                return false;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return check_expr_supported (ifs.condition)
                    && check_stmt_supported (ifs.then_body)
                    && check_stmt_supported (ifs.else_body);
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                return check_expr_supported (ws.condition) && check_stmt_supported (ws.body);
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                int mark = var_names.length;
                bool ok = check_stmt_supported (fs.init)
                    && check_expr_supported (fs.condition)
                    && check_stmt_supported (fs.step)
                    && check_stmt_supported (fs.body);
                var_names.length = mark;
                var_vregs.length = mark;
                var_types.length = mark;
                var_tnames.length = mark;
                return ok;
            }
            if (s is BreakStatement || s is ContinueStatement) return true;
            return false;
        }

        private int lower_expr (Expr e) {
            if (e is IntLiteral) {
                int d = new_vreg ();
                emit_ir (new IRInst () { op = IROp.MOV_IMM, dst = d, imm = ((IntLiteral) e).value });
                return d;
            }
            if (e is BoolLiteral) {
                int d = new_vreg ();
                emit_ir (new IRInst () { op = IROp.MOV_IMM, dst = d, imm = ((BoolLiteral) e).value ? 1 : 0 });
                return d;
            }
            if (e is VarRef) {
                int vi = lookup_var (((VarRef) e).name);
                int v = var_vregs[vi];
                touch_vreg (v);
                return v;
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                int s = lower_expr (u.operand);
                int d = new_vreg ();
                emit_ir (new IRInst () { op = IROp.UNARY, dst = d, sop = u.op, lhs = s });
                return d;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                if (b.op == "&&" || b.op == "||") {
                    int d = new_vreg ();
                    int bb_rhs = new_bb ();
                    int bb_short = new_bb ();
                    int bb_join = new_bb ();
                    int lv = lower_expr (b.left);
                    if (b.op == "&&") {
                        emit_ir (new IRInst () { op = IROp.TEST_JMP_FALSE, lhs = lv, target_bb = bb_short });
                    } else {
                        emit_ir (new IRInst () { op = IROp.CMP_IMM_JMP_FALSE, sop = "==", lhs = lv, imm = 0, target_bb = bb_short });
                    }
                    if (bb_rhs != cur_bb + 1)
                        emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_rhs });
                    blocks[cur_bb].succs.add (bb_rhs);
                    blocks[cur_bb].succs.add (bb_short);
                    cur_bb = bb_rhs;
                    int rv = lower_expr (b.right);
                    bool rhs_is_bool = (b.right is BoolLiteral)
                        || (b.right is UnaryExpr && ((UnaryExpr) b.right).op == "!");
                    if (!rhs_is_bool && b.right is BinaryExpr) {
                        string rop = ((BinaryExpr) b.right).op;
                        rhs_is_bool = (rop == "==" || rop == "!=" || rop == "<" || rop == "<="
                                       || rop == ">" || rop == ">=" || rop == "&&" || rop == "||");
                    }
                    if (rhs_is_bool) {
                        emit_ir (new IRInst () { op = IROp.MOV, dst = d, lhs = rv });
                    } else {
                        emit_ir (new IRInst () { op = IROp.BIN_IMM, sop = "!=", dst = d, lhs = rv, imm = 0 });
                    }
                    emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_join });
                    blocks[cur_bb].succs.add (bb_join);
                    cur_bb = bb_short;
                    emit_ir (new IRInst () { op = IROp.MOV_IMM, dst = d, imm = (b.op == "&&") ? 0 : 1 });
                    emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_join });
                    blocks[cur_bb].succs.add (bb_join);
                    cur_bb = bb_join;
                    return d;
                }
                int lv = lower_expr (b.left);
                if (b.right is IntLiteral && b.op != "/" && b.op != "%") {
                    int64 imm = ((IntLiteral) b.right).value;
                    bool shift_ok = (b.op != "<<" && b.op != ">>") || (imm >= 0 && imm < 64);
                    if (shift_ok && imm >= int32.MIN && imm <= int32.MAX) {
                        int d = new_vreg ();
                        emit_ir (new IRInst () {
                            op = IROp.BIN_IMM, dst = d, sop = b.op, lhs = lv, imm = imm,
                            is_unsigned = vreg_is_unsigned[lv]
                        });
                        return d;
                    }
                }
                int rv = lower_expr (b.right);
                int d = new_vreg ();
                emit_ir (new IRInst () {
                    op = IROp.BIN, dst = d, sop = b.op, lhs = lv, rhs = rv,
                    is_unsigned = vreg_is_unsigned[lv] || vreg_is_unsigned[rv]
                });
                return d;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                int av = var_vregs[lookup_var (((VarRef) ix.target).name)];
                int iv = lower_expr (ix.index);
                int d = new_vreg ();
                bool bc = !bce_is_safe (av, ix.index);
                emit_ir (new IRInst () {
                    op = IROp.ARR_LOAD, dst = d, lhs = av, rhs = iv, bounds_check = bc
                });
                return d;
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                int av = var_vregs[lookup_var (((VarRef) ma.target).name)];
                int d = new_vreg ();
                emit_ir (new IRInst () { op = IROp.ARR_LEN, dst = d, lhs = av });
                return d;
            }
            if (e is CallExpr) {
                var c = (CallExpr) e;
                var ins = new IRInst () { op = IROp.CALL, str_val = c.callee };
                for (int i = 0; i < c.args.length; i++)
                    ins.args.add (lower_expr (c.args[i]));
                int d = new_vreg ();
                ins.dst = d;
                emit_ir (ins);
                return d;
            }
            if (e is ArrayNewExpr) {
                var an = (ArrayNewExpr) e;
                int lv = lower_expr (an.length_expr);
                int d = new_vreg (true, false);
                emit_ir (new IRInst () { op = IROp.ARR_NEW, dst = d, lhs = lv });
                return d;
            }
            return new_vreg ();
        }

        private void lower_cond_jump_false (Expr cond, int target_bb, int fall_bb) {
            if (cond is BinaryExpr) {
                var b = (BinaryExpr) cond;
                if (b.op == "==" || b.op == "!=" || b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">=") {
                    int lv = lower_expr (b.left);
                    if (b.right is IntLiteral) {
                        int64 imm = ((IntLiteral) b.right).value;
                        if (imm >= int32.MIN && imm <= int32.MAX) {
                            emit_ir (new IRInst () {
                                op = IROp.CMP_IMM_JMP_FALSE, sop = b.op, lhs = lv, imm = imm,
                                target_bb = target_bb, is_unsigned = vreg_is_unsigned[lv]
                            });
                            if (fall_bb != cur_bb + 1)
                                emit_ir (new IRInst () { op = IROp.JMP, target_bb = fall_bb });
                            blocks[cur_bb].succs.add (fall_bb);
                            blocks[cur_bb].succs.add (target_bb);
                            return;
                        }
                    }
                    int rv = lower_expr (b.right);
                    emit_ir (new IRInst () {
                        op = IROp.CMP_JMP_FALSE, sop = b.op, lhs = lv, rhs = rv,
                        target_bb = target_bb, is_unsigned = vreg_is_unsigned[lv] || vreg_is_unsigned[rv]
                    });
                    if (fall_bb != cur_bb + 1)
                        emit_ir (new IRInst () { op = IROp.JMP, target_bb = fall_bb });
                    blocks[cur_bb].succs.add (fall_bb);
                    blocks[cur_bb].succs.add (target_bb);
                    return;
                }
            }
            int cv = lower_expr (cond);
            emit_ir (new IRInst () { op = IROp.TEST_JMP_FALSE, lhs = cv, target_bb = target_bb });
            if (fall_bb != cur_bb + 1)
                emit_ir (new IRInst () { op = IROp.JMP, target_bb = fall_bb });
            blocks[cur_bb].succs.add (fall_bb);
            blocks[cur_bb].succs.add (target_bb);
        }

        private static string negate_cmp_op (string op) {
            if (op == "==") return "!=";
            if (op == "!=") return "==";
            if (op == "<") return ">=";
            if (op == "<=") return ">";
            if (op == ">") return "<=";
            return "<";
        }

        private void lower_cond_jump_true (Expr cond, int target_bb, int fall_bb) {
            if (cond is BinaryExpr) {
                var b = (BinaryExpr) cond;
                if (b.op == "==" || b.op == "!=" || b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">=") {
                    string nop = negate_cmp_op (b.op);
                    int lv = lower_expr (b.left);
                    if (b.right is IntLiteral) {
                        int64 imm = ((IntLiteral) b.right).value;
                        if (imm >= -2147483648L && imm <= 2147483647L) {
                            emit_ir (new IRInst () {
                                op = IROp.CMP_IMM_JMP_FALSE, sop = nop, lhs = lv, imm = imm,
                                target_bb = target_bb, is_unsigned = vreg_is_unsigned[lv]
                            });
                            if (fall_bb != cur_bb + 1)
                                emit_ir (new IRInst () { op = IROp.JMP, target_bb = fall_bb });
                            blocks[cur_bb].succs.add (fall_bb);
                            blocks[cur_bb].succs.add (target_bb);
                            return;
                        }
                    }
                    int rv = lower_expr (b.right);
                    emit_ir (new IRInst () {
                        op = IROp.CMP_JMP_FALSE, sop = nop, lhs = lv, rhs = rv,
                        target_bb = target_bb, is_unsigned = vreg_is_unsigned[lv] || vreg_is_unsigned[rv]
                    });
                    if (fall_bb != cur_bb + 1)
                        emit_ir (new IRInst () { op = IROp.JMP, target_bb = fall_bb });
                    blocks[cur_bb].succs.add (fall_bb);
                    blocks[cur_bb].succs.add (target_bb);
                    return;
                }
            }
            lower_cond_jump_false (cond, fall_bb, target_bb);
        }

        private bool bce_has_nonneg (int v) {
            for (int i = 0; i < bce_nonneg.length; i++) {
                if (bce_nonneg[i] == v) return true;
            }
            return false;
        }

        private void bce_set_nonneg (int v, bool on) {
            for (int i = 0; i < bce_nonneg.length; i++) {
                if (bce_nonneg[i] == v) {
                    if (!on) bce_nonneg.remove_index (i);
                    return;
                }
            }
            if (on) bce_nonneg.add (v);
        }

        private void bce_invalidate_var (int v) {
            for (int i = bce_arr_vregs.length - 1; i >= 0; i--) {
                if (bce_arr_vregs[i] == v || bce_arr_var[i] == v || bce_arr_ma[i] == v || bce_arr_mb[i] == v) {
                    bce_arr_vregs.remove_index (i);
                    bce_arr_const.remove_index (i);
                    bce_arr_var.remove_index (i);
                    bce_arr_off.remove_index (i);
                    bce_arr_ma.remove_index (i);
                    bce_arr_mb.remove_index (i);
                }
            }
            for (int i = bce_len_alias_v.length - 1; i >= 0; i--) {
                if (bce_len_alias_v[i] == v || bce_len_alias_arr[i] == v) {
                    bce_len_alias_v.remove_index (i);
                    bce_len_alias_arr.remove_index (i);
                }
            }
            for (int i = bce_mul_v.length - 1; i >= 0; i--) {
                if (bce_mul_v[i] == v || bce_mul_a[i] == v || bce_mul_b[i] == v) {
                    bce_mul_v.remove_index (i);
                    bce_mul_a.remove_index (i);
                    bce_mul_b.remove_index (i);
                }
            }
        }

        private void bce_record_arr (int av, Expr len_e) {
            int lc = -1;
            int lv = -1;
            int lo = 0;
            int ma = -1;
            int mb = -1;
            if (len_e is IntLiteral) {
                int64 v64 = ((IntLiteral) len_e).value;
                if (v64 >= 0 && v64 <= 1073741824) lc = (int) v64;
            } else if (len_e is VarRef) {
                int idx = lookup_var (((VarRef) len_e).name);
                if (idx >= 0) lv = var_vregs[idx];
            } else if (len_e is BinaryExpr) {
                var b = (BinaryExpr) len_e;
                if ((b.op == "+" || b.op == "-") && b.left is VarRef && b.right is IntLiteral) {
                    int idx = lookup_var (((VarRef) b.left).name);
                    int64 rv = ((IntLiteral) b.right).value;
                    if (idx >= 0 && rv >= -1073741824 && rv <= 1073741824) {
                        lv = var_vregs[idx];
                        lo = (b.op == "+") ? (int) rv : (int) (-rv);
                    }
                } else if (b.op == "*" && b.left is VarRef && b.right is VarRef) {
                    int ia = lookup_var (((VarRef) b.left).name);
                    int ib = lookup_var (((VarRef) b.right).name);
                    if (ia >= 0 && ib >= 0) {
                        ma = var_vregs[ia];
                        mb = var_vregs[ib];
                    }
                }
            }
            if (lc >= 0 || lv >= 0 || ma >= 0) {
                bce_arr_vregs.add (av);
                bce_arr_const.add (lc);
                bce_arr_var.add (lv);
                bce_arr_off.add (lo);
                bce_arr_ma.add (ma);
                bce_arr_mb.add (mb);
            }
        }

        private bool bce_stmt_modifies (Statement? s, string vname) {
            if (s == null) return false;
            if (s is AssignStatement) {
                if (((AssignStatement) s).name == vname) return true;
                return bce_expr_modifies (((AssignStatement) s).value, vname);
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                return bce_expr_modifies (ia.target, vname) || bce_expr_modifies (ia.index, vname) || bce_expr_modifies (ia.value, vname);
            }
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return bce_expr_modifies (fa.target, vname) || bce_expr_modifies (fa.value, vname);
            }
            if (s is ExprStatement) return bce_expr_modifies (((ExprStatement) s).expr, vname);
            if (s is VarDeclStatement) return bce_expr_modifies (((VarDeclStatement) s).init, vname);
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return bce_expr_modifies (ifs.condition, vname) || bce_stmt_modifies (ifs.then_body, vname) || bce_stmt_modifies (ifs.else_body, vname);
            }
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (bce_stmt_modifies (blk.statements[i], vname)) return true;
                }
                return false;
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                return bce_expr_modifies (ws.condition, vname) || bce_stmt_modifies (ws.body, vname);
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                return bce_stmt_modifies (fs.init, vname) || bce_expr_modifies (fs.condition, vname)
                    || bce_stmt_modifies (fs.step, vname) || bce_stmt_modifies (fs.body, vname);
            }
            return false;
        }

        private bool bce_expr_modifies (Expr? e, string vname) {
            if (e == null) return false;
            if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                return (inc.target is VarRef && ((VarRef) inc.target).name == vname);
            }
            if (e is UnaryExpr) return bce_expr_modifies (((UnaryExpr) e).operand, vname);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return bce_expr_modifies (b.left, vname) || bce_expr_modifies (b.right, vname);
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return bce_expr_modifies (ix.target, vname) || bce_expr_modifies (ix.index, vname);
            }
            return false;
        }

        private bool bce_stmt_only_inc (Statement? s, string vname) {
            if (s == null) return true;
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                if (a.name != vname) return !bce_expr_modifies (a.value, vname);
                if (a.value is BinaryExpr) {
                    var b = (BinaryExpr) a.value;
                    if (b.op == "+" && b.left is VarRef && ((VarRef) b.left).name == vname
                        && b.right is IntLiteral && ((IntLiteral) b.right).value >= 0)
                        return true;
                }
                return false;
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                if (es.expr is IncDecExpr) {
                    var inc = (IncDecExpr) es.expr;
                    if (inc.target is VarRef && ((VarRef) inc.target).name == vname)
                        return inc.op == "++";
                }
                return !bce_expr_modifies (es.expr, vname);
            }
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (!bce_stmt_only_inc (blk.statements[i], vname)) return false;
                }
                return true;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return !bce_expr_modifies (ifs.condition, vname)
                    && bce_stmt_only_inc (ifs.then_body, vname)
                    && bce_stmt_only_inc (ifs.else_body, vname);
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                return !bce_expr_modifies (ws.condition, vname) && bce_stmt_only_inc (ws.body, vname);
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                return bce_stmt_only_inc (fs.init, vname) && !bce_expr_modifies (fs.condition, vname)
                    && bce_stmt_only_inc (fs.step, vname) && bce_stmt_only_inc (fs.body, vname);
            }
            return !bce_stmt_modifies (s, vname);
        }

        private bool bce_try_push_cond (Expr? cond, Statement? body, string? init_var, int64 init_min) {
            if (!(cond is BinaryExpr)) return false;
            var cb = (BinaryExpr) cond;
            if (cb.op != "<" && cb.op != "<=") return false;
            if (!(cb.left is VarRef)) return false;
            string vname = ((VarRef) cb.left).name;
            int vi = lookup_var (vname);
            if (vi < 0) return false;
            int vv = var_vregs[vi];

            bool min_ok = (init_var != null && init_var == vname && init_min >= 0) || bce_has_nonneg (vv);
            if (!min_ok) return false;
            if (!bce_stmt_only_inc (body, vname)) return false;

            int extra = (cb.op == "<=") ? 1 : 0;
            int mc = -1;
            int mv = -1;
            int moff = 0;
            int marr = -1;
            if (cb.right is IntLiteral) {
                int64 mc64 = ((IntLiteral) cb.right).value + extra;
                if (mc64 < 0 || mc64 > 1073741824) return false;
                mc = (int) mc64;
            } else if (cb.right is VarRef) {
                string rname = ((VarRef) cb.right).name;
                if (bce_stmt_modifies (body, rname)) return false;
                int ri = lookup_var (rname);
                if (ri < 0) return false;
                mv = var_vregs[ri];
                moff = extra;
                for (int li = bce_len_alias_v.length - 1; li >= 0; li--) {
                    if (bce_len_alias_v[li] == mv) {
                        marr = bce_len_alias_arr[li];
                        break;
                    }
                }
            } else if (cb.right is BinaryExpr) {
                var rb = (BinaryExpr) cb.right;
                if ((rb.op == "+" || rb.op == "-") && rb.left is VarRef && rb.right is IntLiteral) {
                    string rname = ((VarRef) rb.left).name;
                    if (bce_stmt_modifies (body, rname)) return false;
                    int ri = lookup_var (rname);
                    if (ri < 0) return false;
                    mv = var_vregs[ri];
                    int64 rv = ((IntLiteral) rb.right).value;
                    if (rv < -1073741824 || rv > 1073741824) return false;
                    moff = ((rb.op == "+") ? (int) rv : (int) (-rv)) + extra;
                } else {
                    return false;
                }
            } else if (cb.right is MemberAccessExpr) {
                var ma = (MemberAccessExpr) cb.right;
                if (ma.member == "length" && ma.target is VarRef) {
                    string aname = ((VarRef) ma.target).name;
                    if (bce_stmt_modifies (body, aname)) return false;
                    int ai = lookup_var (aname);
                    if (ai < 0) return false;
                    marr = var_vregs[ai];
                    moff = extra;
                } else {
                    return false;
                }
            } else {
                return false;
            }

            int bmin = (init_var != null && init_var == vname && init_min <= 1073741824) ? (int) init_min : 0;
            bce_bnd_vreg.add (vv);
            bce_bnd_min.add (bmin);
            bce_bnd_max_c.add (mc);
            bce_bnd_max_v.add (mv);
            bce_bnd_max_off.add (moff);
            bce_bnd_max_arr.add (marr);
            return true;
        }

        private void bce_pop_bnd () {
            int n = bce_bnd_vreg.length - 1;
            bce_bnd_vreg.length = n;
            bce_bnd_min.length = n;
            bce_bnd_max_c.length = n;
            bce_bnd_max_v.length = n;
            bce_bnd_max_off.length = n;
            bce_bnd_max_arr.length = n;
        }

        private bool bce_var_lt_var (int vv, int target_v, int64 k) {
            for (int i = bce_bnd_vreg.length - 1; i >= 0; i--) {
                if (bce_bnd_vreg[i] == vv && bce_bnd_min[i] >= 0
                    && bce_bnd_max_v[i] == target_v && k + bce_bnd_max_off[i] <= 0)
                    return true;
            }
            return false;
        }

        private bool bce_decompose_var_off (Expr e, out int vv, out int64 off) {
            vv = -1;
            off = 0;
            if (e is VarRef) {
                int idx = lookup_var (((VarRef) e).name);
                if (idx >= 0) { vv = var_vregs[idx]; return true; }
                return false;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                if ((b.op == "+" || b.op == "-") && b.left is VarRef && b.right is IntLiteral) {
                    int idx = lookup_var (((VarRef) b.left).name);
                    if (idx >= 0) {
                        vv = var_vregs[idx];
                        off = (b.op == "+") ? ((IntLiteral) b.right).value : -((IntLiteral) b.right).value;
                        return true;
                    }
                }
            }
            return false;
        }

        private bool bce_is_safe (int av, Expr idx_e) {
            if (!bounds_check) return true;
            int aidx = -1;
            for (int i = bce_arr_vregs.length - 1; i >= 0; i--) {
                if (bce_arr_vregs[i] == av) { aidx = i; break; }
            }
            if (idx_e is IntLiteral) {
                int64 k = ((IntLiteral) idx_e).value;
                return k >= 0 && aidx >= 0 && bce_arr_const[aidx] > k;
            }
            int iv = -1;
            int64 koff = 0;
            if (bce_decompose_var_off (idx_e, out iv, out koff) && koff >= 0) {
                for (int i = bce_bnd_vreg.length - 1; i >= 0; i--) {
                    if (bce_bnd_vreg[i] != iv || bce_bnd_min[i] < 0) continue;
                    if (bce_bnd_max_arr[i] == av && koff + bce_bnd_max_off[i] <= 0)
                        return true;
                    if (aidx >= 0 && bce_arr_const[aidx] > 0 && bce_bnd_max_c[i] >= 0
                        && koff + bce_bnd_max_c[i] <= bce_arr_const[aidx])
                        return true;
                    if (aidx >= 0 && bce_arr_var[aidx] >= 0 && bce_bnd_max_v[i] == bce_arr_var[aidx]
                        && koff + bce_bnd_max_off[i] <= bce_arr_off[aidx])
                        return true;
                }
            }
            // Case 3: arr[r * n + c] where arr has length n * n (e.g. matmul_256)
            if (aidx >= 0 && bce_arr_ma[aidx] >= 0 && bce_arr_ma[aidx] == bce_arr_mb[aidx]
                && idx_e is BinaryExpr && ((BinaryExpr) idx_e).op == "+") {
                var b = (BinaryExpr) idx_e;
                int nv = bce_arr_ma[aidx];
                int rv = -1;
                if (b.left is BinaryExpr) {
                    var mb = (BinaryExpr) b.left;
                    if (mb.op == "*" && mb.left is VarRef && mb.right is VarRef) {
                        int i1 = lookup_var (((VarRef) mb.left).name);
                        int i2 = lookup_var (((VarRef) mb.right).name);
                        if (i1 >= 0 && i2 >= 0 && var_vregs[i2] == nv)
                            rv = var_vregs[i1];
                    }
                } else if (b.left is VarRef) {
                    int li = lookup_var (((VarRef) b.left).name);
                    if (li >= 0) {
                        int lv = var_vregs[li];
                        for (int mi = bce_mul_v.length - 1; mi >= 0; mi--) {
                            if (bce_mul_v[mi] == lv && bce_mul_b[mi] == nv) {
                                rv = bce_mul_a[mi];
                                break;
                            }
                        }
                    }
                }
                int cv = -1;
                int64 ck = 0;
                if (rv >= 0 && bce_decompose_var_off (b.right, out cv, out ck) && ck >= 0) {
                    if (bce_var_lt_var (rv, nv, 0) && bce_var_lt_var (cv, nv, ck))
                        return true;
                }
            }
            return false;
        }

        private bool try_lower_simd_for (ForStatement fs) {
            if (!(fs.init is VarDeclStatement) || !(fs.condition is BinaryExpr))
                return false;
            var vd = (VarDeclStatement) fs.init;
            if (vd.init == null || !(vd.init is IntLiteral) || ((IntLiteral) vd.init).value != 0)
                return false;
            string idx_name = vd.name;
            var cb = (BinaryExpr) fs.condition;
            if (cb.op != "<" || !(cb.left is VarRef) || ((VarRef) cb.left).name != idx_name)
                return false;
            if (!bce_stmt_only_inc (fs.step, idx_name))
                return false;

            int arr_v = -1;
            string arr_name = "";
            if (cb.right is MemberAccessExpr) {
                var ma = (MemberAccessExpr) cb.right;
                if (ma.member == "length" && ma.target is VarRef) {
                    arr_name = ((VarRef) ma.target).name;
                    int ai = lookup_var (arr_name);
                    if (ai >= 0 && var_types[ai] == ValaType.ARRAY) {
                        string etn = var_tnames[ai];
                        if (etn == "" || etn == "int" || etn == "int64" || etn == "int[]" || etn == "int64[]")
                            arr_v = var_vregs[ai];
                    }
                }
            } else if (cb.right is VarRef) {
                string rname = ((VarRef) cb.right).name;
                int ri = lookup_var (rname);
                if (ri >= 0) {
                    int rv = var_vregs[ri];
                    for (int li = bce_len_alias_v.length - 1; li >= 0; li--) {
                        if (bce_len_alias_v[li] == rv) {
                            arr_v = bce_len_alias_arr[li];
                            break;
                        }
                    }
                    if (arr_v >= 0) {
                        for (int vi = var_vregs.length - 1; vi >= 0; vi--) {
                            if (var_vregs[vi] == arr_v) {
                                arr_name = var_names[vi];
                                string etn = var_tnames[vi];
                                if (!(etn == "" || etn == "int" || etn == "int64" || etn == "int[]" || etn == "int64[]"))
                                    arr_v = -1;
                                break;
                            }
                        }
                    }
                }
            }
            if (arr_v < 0) return false;

            AssignStatement? asg = null;
            string? elem_name = null;
            if (fs.body is AssignStatement) {
                asg = (AssignStatement) fs.body;
            } else if (fs.body is BlockStatement) {
                var blk = (BlockStatement) fs.body;
                if (blk.statements.length == 1 && blk.statements[0] is AssignStatement) {
                    asg = (AssignStatement) blk.statements[0];
                } else if (blk.statements.length == 2
                           && blk.statements[0] is VarDeclStatement
                           && blk.statements[1] is AssignStatement) {
                    var evd = (VarDeclStatement) blk.statements[0];
                    if (evd.init is IndexExpr) {
                        var ix = (IndexExpr) evd.init;
                        if (ix.target is VarRef && ((VarRef) ix.target).name == arr_name
                            && ix.index is VarRef && ((VarRef) ix.index).name == idx_name) {
                            elem_name = evd.name;
                            asg = (AssignStatement) blk.statements[1];
                        }
                    }
                }
            }
            if (asg == null || !(asg.value is BinaryExpr)) return false;
            string s_name = asg.name;
            if (s_name == idx_name || s_name == arr_name || (elem_name != null && s_name == elem_name))
                return false;
            int si = lookup_var (s_name);
            if (si < 0 || var_types[si] != ValaType.INT) return false;
            string stn = var_tnames[si];
            if (stn != "" && stn != "int" && stn != "int64") return false;
            int sv = var_vregs[si];

            var ab = (BinaryExpr) asg.value;
            if (ab.op != "+" && ab.op != "^" && ab.op != "|" && ab.op != "&")
                return false;

            Expr? other = null;
            if (ab.left is VarRef && ((VarRef) ab.left).name == s_name)
                other = ab.right;
            else if (ab.right is VarRef && ((VarRef) ab.right).name == s_name)
                other = ab.left;
            else
                return false;

            if (elem_name != null) {
                if (!(other is VarRef) || ((VarRef) other).name != elem_name)
                    return false;
            } else {
                if (!(other is IndexExpr)) return false;
                var ix = (IndexExpr) other;
                if (!(ix.target is VarRef) || ((VarRef) ix.target).name != arr_name
                    || !(ix.index is VarRef) || ((VarRef) ix.index).name != idx_name)
                    return false;
            }

            emit_ir (new IRInst () {
                op = IROp.SIMD_ARR_REDUCE,
                sop = ab.op,
                dst = sv,
                lhs = arr_v,
                rhs = sv
            });
            return true;
        }

        private void lower_stmt (Statement? s) {
            if (s == null) return;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                int mark = var_names.length;
                for (int i = 0; i < blk.statements.length; i++)
                    lower_stmt (blk.statements[i]);
                var_names.length = mark;
                var_vregs.length = mark;
                var_types.length = mark;
                var_tnames.length = mark;
                return;
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                bool is_arr = (d.decl_type == ValaType.ARRAY) || (d.init is ArrayNewExpr);
                bool is_u = is_unsigned_name (d.decl_type_name);
                int v = new_vreg (is_arr, is_u);
                if (is_arr)
                    arr_locals.add (v);
                if (d.init != null) {
                    int iv = lower_expr (d.init);
                    emit_ir (new IRInst () { op = IROp.MOV, dst = v, lhs = iv });
                } else {
                    emit_ir (new IRInst () { op = IROp.MOV_IMM, dst = v, imm = 0 });
                }
                var_names.add (d.name);
                var_vregs.add (v);
                var_types.add (is_arr ? ValaType.ARRAY : d.decl_type);
                var_tnames.add (d.decl_type_name);
                if (d.init is ArrayNewExpr) {
                    bce_record_arr (v, ((ArrayNewExpr) d.init).length_expr);
                } else if (d.init is MemberAccessExpr) {
                    var ma_d = (MemberAccessExpr) d.init;
                    if (ma_d.member == "length" && ma_d.target is VarRef) {
                        int ai_d = lookup_var (((VarRef) ma_d.target).name);
                        if (ai_d >= 0 && var_types[ai_d] == ValaType.ARRAY) {
                            bce_len_alias_v.add (v);
                            bce_len_alias_arr.add (var_vregs[ai_d]);
                        }
                    }
                    bce_set_nonneg (v, true);
                } else if (d.init == null || (d.init is IntLiteral && ((IntLiteral) d.init).value >= 0) || is_u) {
                    bce_set_nonneg (v, true);
                } else if (d.init is BinaryExpr) {
                    var db = (BinaryExpr) d.init;
                    if (db.op == "*" && db.left is VarRef && db.right is VarRef) {
                        int i1 = lookup_var (((VarRef) db.left).name);
                        int i2 = lookup_var (((VarRef) db.right).name);
                        if (i1 >= 0 && i2 >= 0) {
                            bce_mul_v.add (v);
                            bce_mul_a.add (var_vregs[i1]);
                            bce_mul_b.add (var_vregs[i2]);
                        }
                    }
                }
                return;
            }
            if (s is AssignStatement) {
                var a = (AssignStatement) s;
                int v = var_vregs[lookup_var (a.name)];
                int rv = lower_expr (a.value);
                emit_ir (new IRInst () { op = IROp.MOV, dst = v, lhs = rv });
                bce_invalidate_var (v);
                bool keep_nonneg = false;
                if (a.value is IntLiteral && ((IntLiteral) a.value).value >= 0) {
                    keep_nonneg = true;
                } else if (a.value is BinaryExpr) {
                    var ab = (BinaryExpr) a.value;
                    if (ab.op == "+" && ab.left is VarRef && ((VarRef) ab.left).name == a.name
                        && ab.right is IntLiteral && ((IntLiteral) ab.right).value >= 0
                        && bce_has_nonneg (v)) {
                        keep_nonneg = true;
                    } else if (ab.op == "*" && ab.left is VarRef && ab.right is VarRef) {
                        int i1 = lookup_var (((VarRef) ab.left).name);
                        int i2 = lookup_var (((VarRef) ab.right).name);
                        if (i1 >= 0 && i2 >= 0) {
                            bce_mul_v.add (v);
                            bce_mul_a.add (var_vregs[i1]);
                            bce_mul_b.add (var_vregs[i2]);
                        }
                    }
                }
                bce_set_nonneg (v, keep_nonneg);
                return;
            }
            if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                int av = var_vregs[lookup_var (((VarRef) ia.target).name)];
                int iv = lower_expr (ia.index);
                int vv = lower_expr (ia.value);
                bool bc = !bce_is_safe (av, ia.index);
                emit_ir (new IRInst () {
                    op = IROp.ARR_STORE, dst = av, lhs = iv, rhs = vv,
                    sop = ia.op, bounds_check = bc
                });
                return;
            }
            if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (r.value != null && arr_locals.length == 0) {
                    if (r.value is CallExpr) {
                        var c = (CallExpr) r.value;
                        if (c.callee == cur_fn_name && c.args.length == cur_nparams && tre_loop_bb >= 0) {
                            var ins = new IRInst () { op = IROp.TRE_JUMP, target_bb = tre_loop_bb };
                            for (int i = 0; i < c.args.length; i++)
                                ins.args.add (lower_expr (c.args[i]));
                            emit_ir (ins);
                            blocks[cur_bb].succs.add (tre_loop_bb);
                            return;
                        }
                        if (tre_acc_vreg < 0 && c.callee != cur_fn_name && program.find (c.callee) != null && c.args.length <= 6) {
                            var ins = new IRInst () { op = IROp.TAIL_CALL, str_val = c.callee };
                            for (int i = 0; i < c.args.length; i++)
                                ins.args.add (lower_expr (c.args[i]));
                            emit_ir (ins);
                            return;
                        }
                    }
                    if (tre_acc_vreg >= 0 && r.value is BinaryExpr) {
                        var b = (BinaryExpr) r.value;
                        if (b.op == "+" && b.right is CallExpr) {
                            var c = (CallExpr) b.right;
                            if (c.callee == cur_fn_name && c.args.length == cur_nparams && tre_loop_bb >= 0) {
                                int lv = lower_expr (b.left);
                                emit_ir (new IRInst () { op = IROp.BIN, sop = "+", dst = tre_acc_vreg, lhs = tre_acc_vreg, rhs = lv });
                                var ins = new IRInst () { op = IROp.TRE_JUMP, target_bb = tre_loop_bb };
                                for (int i = 0; i < c.args.length; i++)
                                    ins.args.add (lower_expr (c.args[i]));
                                emit_ir (ins);
                                blocks[cur_bb].succs.add (tre_loop_bb);
                                return;
                            }
                        }
                    }
                }
                if (r.value != null) {
                    int rv = lower_expr (r.value);
                    if (tre_acc_vreg >= 0) {
                        int sum_v = new_vreg ();
                        emit_ir (new IRInst () { op = IROp.BIN, sop = "+", dst = sum_v, lhs = rv, rhs = tre_acc_vreg });
                        rv = sum_v;
                    }
                    emit_ir (new IRInst () { op = IROp.RET, lhs = rv });
                } else {
                    emit_ir (new IRInst () { op = IROp.RET_VOID });
                }
                return;
            }
            if (s is ExprStatement) {
                lower_expr (((ExprStatement) s).expr);
                return;
            }
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                if (p.value is StringLiteral) {
                    emit_ir (new IRInst () { op = IROp.PRINT_STR, str_val = ((StringLiteral) p.value).value });
                } else if (p.value is TemplateExpr) {
                    var te = (TemplateExpr) p.value;
                    for (int i = 0; i < te.parts.length; i++) {
                        var pt = te.parts[i];
                        if (pt is StringLiteral) {
                            emit_ir (new IRInst () { op = IROp.PRINT_STR, str_val = ((StringLiteral) pt).value });
                        } else {
                            int pv = lower_expr (pt);
                            emit_ir (new IRInst () { op = IROp.PRINT_INT, lhs = pv });
                        }
                    }
                }
                return;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                if (ifs.else_body == null && ifs.condition is BinaryExpr) {
                    var cb = (BinaryExpr) ifs.condition;
                    bool is_cmp = (cb.op == "==" || cb.op == "!=" || cb.op == "<"
                                   || cb.op == "<=" || cb.op == ">" || cb.op == ">=");
                    AssignStatement? asg = null;
                    if (is_cmp) {
                        if (ifs.then_body is AssignStatement) {
                            asg = (AssignStatement) ifs.then_body;
                        } else if (ifs.then_body is BlockStatement) {
                            var blk = (BlockStatement) ifs.then_body;
                            if (blk.statements.length == 1 && blk.statements[0] is AssignStatement)
                                asg = (AssignStatement) blk.statements[0];
                        }
                    }
                    if (asg != null && asg.value is BinaryExpr) {
                        var ab = (BinaryExpr) asg.value;
                        if ((ab.op == "+" || ab.op == "-") && ab.left is VarRef
                            && ((VarRef) ab.left).name == asg.name && ab.right is IntLiteral) {
                            int tv = lookup_var (asg.name);
                            int64 k = ((IntLiteral) ab.right).value;
                            if (tv >= 0 && !vreg_is_arr[tv] && k >= int32.MIN && k <= int32.MAX) {
                                int cv = lower_expr (ifs.condition);
                                int delta = cv;
                                if (k != 1) {
                                    delta = new_vreg ();
                                    emit_ir (new IRInst () { op = IROp.BIN_IMM, sop = "*", dst = delta, lhs = cv, imm = k });
                                }
                                emit_ir (new IRInst () { op = IROp.BIN, sop = ab.op, dst = tv, lhs = tv, rhs = delta });
                                return;
                            }
                        }
                    }
                }
                int bb_then = new_bb ();
                int bb_else = (ifs.else_body != null) ? new_bb () : -1;
                int bb_end = new_bb ();
                int f_target = (bb_else >= 0) ? bb_else : bb_end;
                lower_cond_jump_false (ifs.condition, f_target, bb_then);

                cur_bb = bb_then;
                lower_stmt (ifs.then_body);
                if (!bb_ends_with_term (cur_bb)) {
                    emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_end });
                    blocks[cur_bb].succs.add (bb_end);
                }
                if (bb_else >= 0) {
                    cur_bb = bb_else;
                    lower_stmt (ifs.else_body);
                    if (!bb_ends_with_term (cur_bb)) {
                        emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_end });
                        blocks[cur_bb].succs.add (bb_end);
                    }
                }
                cur_bb = bb_end;
                return;
            }
            if (s is WhileStatement) {
                var ws = (WhileStatement) s;
                int bb_cond = new_bb ();
                int bb_body = new_bb ();
                int bb_end = new_bb ();
                emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_cond });
                blocks[cur_bb].succs.add (bb_cond);

                int old_w = loop_weight;
                if (loop_weight < 1000) loop_weight *= 10;

                cur_bb = bb_cond;
                lower_cond_jump_false (ws.condition, bb_end, bb_body);

                break_bbs.add (bb_end);
                continue_bbs.add (bb_cond);
                cur_bb = bb_body;
                bool pushed_w = bce_try_push_cond (ws.condition, ws.body, null, 0);
                lower_stmt (ws.body);
                if (pushed_w) bce_pop_bnd ();
                if (!bb_ends_with_term (cur_bb)) {
                    emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_cond });
                    blocks[cur_bb].succs.add (bb_cond);
                }
                break_bbs.length = break_bbs.length - 1;
                continue_bbs.length = continue_bbs.length - 1;
                loop_weight = old_w;
                cur_bb = bb_end;
                return;
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                if (try_lower_simd_for (fs))
                    return;
                int mark = var_names.length;
                if (fs.init != null)
                    lower_stmt (fs.init);
                string? init_v = null;
                int64 init_min = 0;
                if (fs.init is VarDeclStatement) {
                    var fvd = (VarDeclStatement) fs.init;
                    if (fvd.init == null) {
                        init_v = fvd.name; init_min = 0;
                    } else if (fvd.init is IntLiteral && ((IntLiteral) fvd.init).value >= 0) {
                        init_v = fvd.name; init_min = ((IntLiteral) fvd.init).value;
                    }
                }
                if (init_v != null && !bce_stmt_only_inc (fs.step, init_v))
                    init_v = null;
                int bb_body = new_bb ();
                int bb_step = new_bb ();
                int bb_cond = new_bb ();
                int bb_end = new_bb ();
                if (fs.condition != null) {
                    emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_cond });
                    blocks[cur_bb].succs.add (bb_cond);
                } else {
                    if (cur_bb + 1 != bb_body)
                        emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_body });
                    blocks[cur_bb].succs.add (bb_body);
                }

                int old_w = loop_weight;
                if (loop_weight < 1000) loop_weight *= 10;

                break_bbs.add (bb_end);
                continue_bbs.add (bb_step);
                cur_bb = bb_body;
                bool pushed_f = bce_try_push_cond (fs.condition, fs.body, init_v, init_min);
                lower_stmt (fs.body);
                if (pushed_f) bce_pop_bnd ();
                if (!bb_ends_with_term (cur_bb)) {
                    if (cur_bb + 1 != bb_step)
                        emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_step });
                    blocks[cur_bb].succs.add (bb_step);
                }
                cur_bb = bb_step;
                if (fs.step != null)
                    lower_stmt (fs.step);
                if (!bb_ends_with_term (cur_bb)) {
                    if (cur_bb + 1 != bb_cond)
                        emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_cond });
                    blocks[cur_bb].succs.add (bb_cond);
                }
                cur_bb = bb_cond;
                if (fs.condition != null) {
                    lower_cond_jump_true (fs.condition, bb_body, bb_end);
                } else {
                    emit_ir (new IRInst () { op = IROp.JMP, target_bb = bb_body });
                    blocks[cur_bb].succs.add (bb_body);
                }

                break_bbs.length = break_bbs.length - 1;
                continue_bbs.length = continue_bbs.length - 1;
                loop_weight = old_w;
                var_names.length = mark;
                var_vregs.length = mark;
                var_types.length = mark;
                var_tnames.length = mark;
                cur_bb = bb_end;
                return;
            }
            if (s is BreakStatement && break_bbs.length > 0) {
                int t = break_bbs[break_bbs.length - 1];
                emit_ir (new IRInst () { op = IROp.JMP, target_bb = t });
                blocks[cur_bb].succs.add (t);
                cur_bb = new_bb ();
                return;
            }
            if (s is ContinueStatement && continue_bbs.length > 0) {
                int t = continue_bbs[continue_bbs.length - 1];
                emit_ir (new IRInst () { op = IROp.JMP, target_bb = t });
                blocks[cur_bb].succs.add (t);
                cur_bb = new_bb ();
                return;
            }
        }

        private bool bb_ends_with_term (int bb) {
            var insts = blocks[bb].insts;
            if (insts.length == 0) return false;
            var op = insts[insts.length - 1].op;
            return op == IROp.JMP || op == IROp.RET || op == IROp.RET_VOID
                || op == IROp.TRE_JUMP || op == IROp.TAIL_CALL;
        }

        private bool stmt_has_assoc_tre (Statement? s) {
            if (s == null) return false;
            if (s is BlockStatement) {
                var blk = (BlockStatement) s;
                for (int i = 0; i < blk.statements.length; i++) {
                    if (stmt_has_assoc_tre (blk.statements[i])) return true;
                }
                return false;
            }
            if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (r.value is BinaryExpr) {
                    var b = (BinaryExpr) r.value;
                    if (b.op == "+" && b.right is CallExpr && ((CallExpr) b.right).callee == cur_fn_name)
                        return true;
                }
                return false;
            }
            if (s is IfStatement) {
                var ifs = (IfStatement) s;
                return stmt_has_assoc_tre (ifs.then_body) || stmt_has_assoc_tre (ifs.else_body);
            }
            if (s is WhileStatement) return stmt_has_assoc_tre (((WhileStatement) s).body);
            if (s is ForStatement) return stmt_has_assoc_tre (((ForStatement) s).body);
            return false;
        }

        // ------------------------------------------------------------------
        // Liveness + Pereira-Palsberg Puzzle Solver
        // ------------------------------------------------------------------

        private int[] vreg_phys;     // -1 = spilled
        private int[] vreg_spill;    // >= 0 spill slot index
        private int num_spills = 0;
        private bool[] used_callee = new bool[5]; // RBX, R12..R15
        private bool has_calls = false;

        private void promote_stack_arrays (int nparams) {
            int nv = next_vreg;
            if (nv <= 0) return;
            var def_count = new int[nv];
            var def_inst = new IRInst?[nv];
            for (int b = 0; b < blocks.length; b++) {
                var insts = blocks[b].insts;
                for (int ii = 0; ii < insts.length; ii++) {
                    var ins = insts[ii];
                    if (ins.dst >= 0 && ins.op != IROp.ARR_STORE) {
                        def_count[ins.dst]++;
                        def_inst[ins.dst] = ins;
                    }
                    if (ins.op == IROp.TRE_JUMP) {
                        for (int pi = 0; pi < cur_nparams; pi++)
                            def_count[pi]++;
                    }
                }
            }

            for (int b = 0; b < blocks.length; b++) {
                var insts = blocks[b].insts;
                for (int ii = 0; ii < insts.length; ii++) {
                    var ins = insts[ii];
                    if (ins.op != IROp.ARR_NEW) continue;
                    int d = ins.dst;
                    int lv = ins.lhs;
                    if (d < nparams || lv < nparams || def_count[d] != 1 || def_count[lv] != 1) continue;
                    var ldef = def_inst[lv];
                    if (ldef == null || ldef.op != IROp.MOV_IMM) continue;
                    int64 len = ldef.imm;
                    if (len < 0 || len > 64) continue;

                    // Determine target variable (either d directly or single MOV var_v = d)
                    int d_uses = 0;
                    int mov_target = -1;
                    for (int bb = 0; bb < blocks.length; bb++) {
                        var binsts = blocks[bb].insts;
                        for (int jj = 0; jj < binsts.length; jj++) {
                            var u = binsts[jj];
                            if (u.lhs == d) {
                                d_uses++;
                                if (u.op == IROp.MOV && u.dst >= nparams && def_count[u.dst] == 1)
                                    mov_target = u.dst;
                            }
                            if (u.rhs == d) d_uses++;
                            if (u.op == IROp.ARR_STORE && u.dst == d) d_uses++;
                            for (int ai = 0; ai < u.args.length; ai++) {
                                if (u.args[ai] == d) d_uses++;
                            }
                        }
                    }

                    int target_v = -1;
                    if (d_uses == 1 && mov_target >= 0) {
                        target_v = mov_target;
                    } else if (mov_target < 0) {
                        target_v = d;
                    } else {
                        continue;
                    }

                    // Ensure target_v never escapes (only used in ARR_LOAD, ARR_STORE dst, ARR_LEN)
                    bool safe = true;
                    for (int bb = 0; bb < blocks.length && safe; bb++) {
                        var binsts = blocks[bb].insts;
                        for (int jj = 0; jj < binsts.length; jj++) {
                            var u = binsts[jj];
                            if (u == ins) continue;
                            if (target_v != d && u.op == IROp.MOV && u.dst == target_v && u.lhs == d) continue;
                            if (u.op == IROp.ARR_LOAD) {
                                if (u.rhs == target_v || u.dst == target_v) { safe = false; break; }
                                continue;
                            }
                            if (u.op == IROp.ARR_STORE) {
                                if (u.lhs == target_v || u.rhs == target_v) { safe = false; break; }
                                continue;
                            }
                            if (u.op == IROp.ARR_LEN) {
                                if (u.dst == target_v) { safe = false; break; }
                                continue;
                            }
                            if (u.dst == target_v || u.lhs == target_v || u.rhs == target_v) {
                                safe = false;
                                break;
                            }
                            for (int ai = 0; ai < u.args.length; ai++) {
                                if (u.args[ai] == target_v) { safe = false; break; }
                            }
                        }
                    }
                    if (!safe) continue;

                    int alloc_bytes = ((16 + (int) len * 8 + 15) & ~15);
                    if (stack_arr_bytes + alloc_bytes > 2048) continue;

                    for (int ai = arr_locals.length - 1; ai >= 0; ai--) {
                        if (arr_locals[ai] == target_v)
                            arr_locals.remove_index (ai);
                    }
                    stack_arr_bytes += alloc_bytes;
                    ins.op = IROp.ARR_STACK;
                    ins.lhs = -1;
                    ins.imm = len;
                    ins.target_bb = stack_arr_bytes;
                }
            }
        }

        private void solve_puzzles (int nparams) {
            int nv = next_vreg;
            vreg_phys = new int[nv];
            vreg_spill = new int[nv];
            for (int i = 0; i < nv; i++) {
                vreg_phys[i] = -1;
                vreg_spill[i] = -1;
            }

            // 1. Backward liveness analysis over blocks
            int nbb = blocks.length;
            int words = (nv + 63) / 64;
            if (words < 1) words = 1;
            var live_in = new uint64[nbb * words];
            var live_out = new uint64[nbb * words];
            var bb_use = new uint64[nbb * words];
            var bb_def = new uint64[nbb * words];

            for (int b = 0; b < nbb; b++) {
                var insts = blocks[b].insts;
                for (int ii = 0; ii < insts.length; ii++) {
                    var ins = insts[ii];
                    if (ins.lhs >= 0) add_use_bit (b * words, bb_use, bb_def, ins.lhs);
                    if (ins.rhs >= 0) add_use_bit (b * words, bb_use, bb_def, ins.rhs);
                    if (ins.op == IROp.ARR_STORE && ins.dst >= 0)
                        add_use_bit (b * words, bb_use, bb_def, ins.dst);
                    for (int ai = 0; ai < ins.args.length; ai++)
                        add_use_bit (b * words, bb_use, bb_def, ins.args[ai]);
                    if (ins.dst >= 0 && ins.op != IROp.ARR_STORE)
                        set_bit (bb_def, b * words, ins.dst);
                    if (ins.op == IROp.TRE_JUMP) {
                        for (int pi = 0; pi < cur_nparams; pi++)
                            set_bit (bb_def, b * words, pi);
                    }
                }
            }

            bool changed = true;
            while (changed) {
                changed = false;
                for (int b = nbb - 1; b >= 0; b--) {
                    for (int w = 0; w < words; w++) {
                        uint64 lo = 0;
                        for (int si = 0; si < blocks[b].succs.length; si++) {
                            int sbb = blocks[b].succs[si];
                            lo |= live_in[sbb * words + w];
                        }
                        if (lo != live_out[b * words + w]) {
                            live_out[b * words + w] = lo;
                            changed = true;
                        }
                        uint64 li = bb_use[b * words + w] | (lo & ~bb_def[b * words + w]);
                        if (li != live_in[b * words + w]) {
                            live_in[b * words + w] = li;
                            changed = true;
                        }
                    }
                }
            }

            // 2. Build interference + puzzle constraints per vreg
            var interf = new uint64[nv * words];
            var allowed_mask = new uint32[nv];
            var hint_phys = new int[nv];
            for (int i = 0; i < nv; i++) {
                allowed_mask[i] = (1u << NUM_PHYS) - 1u;
                hint_phys[i] = -1;
            }
            for (int i = 0; i < nparams && i < 6; i++)
                hint_phys[i] = abi_arg_phys (i);

            var cur_live = new uint64[words];
            for (int b = 0; b < nbb; b++) {
                for (int w = 0; w < words; w++)
                    cur_live[w] = live_out[b * words + w];

                var insts = blocks[b].insts;
                for (int ii = insts.length - 1; ii >= 0; ii--) {
                    var ins = insts[ii];
                    bool is_call = (ins.op == IROp.CALL || ins.op == IROp.ARR_NEW
                                    || ins.op == IROp.PRINT_STR || ins.op == IROp.PRINT_INT);
                    if (is_call) has_calls = true;

                    int def = (ins.dst >= 0 && ins.op != IROp.ARR_STORE) ? ins.dst : -1;
                    if (def >= 0) {
                        for (int w = 0; w < words; w++) {
                            uint64 m = cur_live[w];
                            while (m != 0) {
                                int bit = ctz64 (m);
                                int u = w * 64 + bit;
                                if (u != def) {
                                    set_bit (interf, def * words, u);
                                    set_bit (interf, u * words, def);
                                }
                                m &= m - 1;
                            }
                        }
                        clear_bit (cur_live, 0, def);
                    }
                    if (ins.op == IROp.TRE_JUMP) {
                        for (int pi = 0; pi < cur_nparams; pi++) {
                            for (int w = 0; w < words; w++) {
                                uint64 m = cur_live[w];
                                while (m != 0) {
                                    int u = w * 64 + ctz64 (m);
                                    if (u != pi) {
                                        set_bit (interf, pi * words, u);
                                        set_bit (interf, u * words, pi);
                                    }
                                    m &= m - 1;
                                }
                            }
                            clear_bit (cur_live, 0, pi);
                        }
                        for (int ai = 0; ai < ins.args.length && ai < 6; ai++) {
                            if (hint_phys[ins.args[ai]] < 0)
                                hint_phys[ins.args[ai]] = abi_arg_phys (ai);
                        }
                    }

                    // Apply x86-64 puzzle board constraints for live-across vregs:
                    if (is_call) {
                        // Live across CALL -> must fit in callee-saved pieces (bits 7..11)
                        uint32 callee_mask = ((1u << 5) - 1u) << FIRST_CALLEE;
                        for (int w = 0; w < words; w++) {
                            uint64 m = cur_live[w];
                            while (m != 0) {
                                int u = w * 64 + ctz64 (m);
                                allowed_mask[u] &= callee_mask;
                                m &= m - 1;
                            }
                        }
                        if (ins.op == IROp.CALL) {
                            for (int ai = 0; ai < ins.args.length && ai < 6; ai++) {
                                if (hint_phys[ins.args[ai]] < 0)
                                    hint_phys[ins.args[ai]] = abi_arg_phys (ai);
                            }
                            if (def >= 0 && hint_phys[def] < 0)
                                hint_phys[def] = 0; // RAX
                        }
                    } else if (ins.op == IROp.BIN && (ins.sop == "/" || ins.sop == "%")) {
                        // Clobbers RAX (0) and RDX (2)
                        uint32 no_ax_dx = ~((1u << 0) | (1u << 2));
                        for (int w = 0; w < words; w++) {
                            uint64 m = cur_live[w];
                            while (m != 0) {
                                int u = w * 64 + ctz64 (m);
                                allowed_mask[u] &= no_ax_dx;
                                m &= m - 1;
                            }
                        }
                    } else if (ins.op == IROp.BIN && (ins.sop == "<<" || ins.sop == ">>")) {
                        // Clobbers RCX (1)
                        uint32 no_cx = ~(1u << 1);
                        if (ins.dst >= 0) allowed_mask[ins.dst] &= no_cx;
                        for (int w = 0; w < words; w++) {
                            uint64 m = cur_live[w];
                            while (m != 0) {
                                int u = w * 64 + ctz64 (m);
                                allowed_mask[u] &= no_cx;
                                m &= m - 1;
                            }
                        }
                    }

                    if (ins.lhs >= 0) set_bit (cur_live, 0, ins.lhs);
                    if (ins.rhs >= 0) set_bit (cur_live, 0, ins.rhs);
                    if (ins.op == IROp.ARR_STORE && ins.dst >= 0) set_bit (cur_live, 0, ins.dst);
                    for (int ai = 0; ai < ins.args.length; ai++)
                        set_bit (cur_live, 0, ins.args[ai]);

                    if (ins.op == IROp.MOV && ins.dst >= 0 && ins.lhs >= 0) {
                        if (hint_phys[ins.dst] < 0 && hint_phys[ins.lhs] >= 0)
                            hint_phys[ins.dst] = hint_phys[ins.lhs];
                    }
                }
            }

            // Parameters are live at entry; ensure they interfere with each other
            for (int i = 0; i < nparams; i++) {
                for (int j = i + 1; j < nparams; j++) {
                    set_bit (interf, i * words, j);
                    set_bit (interf, j * words, i);
                }
            }

            // 3. Solve puzzle pieces ordered by (most constrained first, then highest weight)
            var order = new int[nv];
            for (int i = 0; i < nv; i++) order[i] = i;
            for (int i = 0; i < nv; i++) {
                int best = i;
                for (int j = i + 1; j < nv; j++) {
                    int a = order[j];
                    int b = order[best];
                    int pa = popcount32 (allowed_mask[a]);
                    int pb = popcount32 (allowed_mask[b]);
                    if (pa < pb || (pa == pb && vreg_weight[a] > vreg_weight[b]))
                        best = j;
                }
                int tmp = order[i];
                order[i] = order[best];
                order[best] = tmp;
            }

            for (int oi = 0; oi < nv; oi++) {
                int v = order[oi];
                uint32 avail = allowed_mask[v];
                for (int w = 0; w < words; w++) {
                    uint64 m = interf[v * words + w];
                    while (m != 0) {
                        int u = w * 64 + ctz64 (m);
                        if (vreg_phys[u] >= 0)
                            avail &= ~(1u << vreg_phys[u]);
                        m &= m - 1;
                    }
                }
                if (avail != 0) {
                    int chosen = -1;
                    int h = hint_phys[v];
                    if (h >= 0 && ((avail & (1u << h)) != 0)) {
                        chosen = h;
                    } else {
                        for (int p = 0; p < NUM_PHYS; p++) {
                            if ((avail & (1u << p)) != 0) {
                                chosen = p;
                                break;
                            }
                        }
                    }
                    vreg_phys[v] = chosen;
                    if (chosen >= FIRST_CALLEE)
                        used_callee[chosen - FIRST_CALLEE] = true;
                } else {
                    vreg_spill[v] = num_spills++;
                }
            }
        }

        private static void set_bit (uint64[] arr, int base_w, int bit) {
            arr[base_w + (bit >> 6)] |= (((uint64) 1) << (bit & 63));
        }

        private static void clear_bit (uint64[] arr, int base_w, int bit) {
            arr[base_w + (bit >> 6)] &= ~(((uint64) 1) << (bit & 63));
        }

        private static void add_use_bit (int base_w, uint64[] bb_use, uint64[] bb_def, int v) {
            int w = base_w + (v >> 6);
            uint64 mask = ((uint64) 1) << (v & 63);
            if ((bb_def[w] & mask) == 0)
                bb_use[w] |= mask;
        }

        private static int ctz64 (uint64 x) {
            int c = 0;
            while ((x & ((uint64) 1)) == 0) { x >>= 1; c++; }
            return c;
        }

        private static int popcount32 (uint32 x) {
            int c = 0;
            while (x != 0) { x &= x - 1; c++; }
            return c;
        }

        // ------------------------------------------------------------------
        // x86-64 Register-to-Register Code Emission
        // ------------------------------------------------------------------

        private Buffer code { get { return emitter.code; } }

        private void emit_rex (bool w, Reg r, Reg rm) {
            uint8 rex = (uint8) ((w ? 0x48 : 0x40)
                | (Reg.is_extended (r) ? 4 : 0)
                | (Reg.is_extended (rm) ? 1 : 0));
            if (rex != 0x40)
                code.u8 (rex);
        }

        private void emit_mov_rr (Reg dst, Reg src) {
            if (dst == src) return;
            emit_rex (true, src, dst);
            code.u8 (0x89);
            code.u8 ((uint8) (0xC0 | (((int) src & 7) << 3) | ((int) dst & 7)));
        }

        private void emit_mov_ri (Reg dst, int64 v) {
            int d7 = (int) dst & 7;
            if (v == 0) {
                emit_rex (false, dst, dst);
                code.u8 (0x31);
                code.u8 ((uint8) (0xC0 | (d7 << 3) | d7));
                return;
            }
            if (v > 0 && v <= int32.MAX) {
                if (Reg.is_extended (dst)) code.u8 (0x41);
                code.u8 ((uint8) (0xB8 + d7));
                code.u32le ((uint32) v);
                return;
            }
            if (v >= int32.MIN && v <= int32.MAX) {
                emit_rex (true, Reg.RAX, dst);
                code.u8 (0xC7);
                code.u8 ((uint8) (0xC0 | d7));
                code.u32le ((uint32) (int32) v);
                return;
            }
            emit_rex (true, Reg.RAX, dst);
            code.u8 ((uint8) (0xB8 + d7));
            code.u64le ((uint64) v);
        }

        private void emit_alu_rr (uint8 opcode, Reg dst, Reg src) {
            emit_rex (true, src, dst);
            code.u8 (opcode);
            code.u8 ((uint8) (0xC0 | (((int) src & 7) << 3) | ((int) dst & 7)));
        }

        private void emit_alu_ri (uint8 subop, Reg dst, int32 imm) {
            int d7 = (int) dst & 7;
            emit_rex (true, Reg.RAX, dst);
            if (imm >= -128 && imm <= 127) {
                code.u8 (0x83);
                code.u8 ((uint8) (0xC0 | (subop << 3) | d7));
                code.u8 ((uint8) imm);
            } else {
                code.u8 (0x81);
                code.u8 ((uint8) (0xC0 | (subop << 3) | d7));
                code.u32le ((uint32) imm);
            }
        }

        private void emit_imul_rr (Reg dst, Reg src) {
            emit_rex (true, dst, src);
            code.u8 (0x0F); code.u8 (0xAF);
            code.u8 ((uint8) (0xC0 | (((int) dst & 7) << 3) | ((int) src & 7)));
        }

        private void emit_imul_rri (Reg dst, Reg src, int32 imm) {
            emit_rex (true, dst, src);
            if (imm >= -128 && imm <= 127) {
                code.u8 (0x6B);
                code.u8 ((uint8) (0xC0 | (((int) dst & 7) << 3) | ((int) src & 7)));
                code.u8 ((uint8) imm);
            } else {
                code.u8 (0x69);
                code.u8 ((uint8) (0xC0 | (((int) dst & 7) << 3) | ((int) src & 7)));
                code.u32le ((uint32) imm);
            }
        }

        private void emit_shift_ri (uint8 subop, Reg dst, uint8 cnt) {
            if (cnt == 0) return;
            emit_rex (true, Reg.RAX, dst);
            int d7 = (int) dst & 7;
            if (cnt == 1) {
                code.u8 (0xD1);
                code.u8 ((uint8) (0xC0 | (subop << 3) | d7));
            } else {
                code.u8 (0xC1);
                code.u8 ((uint8) (0xC0 | (subop << 3) | d7));
                code.u8 (cnt & 63);
            }
        }

        private void emit_shift_cl (uint8 subop, Reg dst) {
            emit_rex (true, Reg.RAX, dst);
            code.u8 (0xD3);
            code.u8 ((uint8) (0xC0 | (subop << 3) | ((int) dst & 7)));
        }

        private void emit_lea_disp (Reg dst, Reg base_r, int32 disp) {
            emit_rex (true, dst, base_r);
            code.u8 (0x8D);
            int d7 = (int) dst & 7;
            int b7 = (int) base_r & 7;
            if (disp >= -128 && disp <= 127) {
                code.u8 ((uint8) (0x40 | (d7 << 3) | b7));
                if (b7 == 4) code.u8 (0x24);
                code.u8 ((uint8) disp);
            } else {
                code.u8 ((uint8) (0x80 | (d7 << 3) | b7));
                if (b7 == 4) code.u8 (0x24);
                code.u32le ((uint32) disp);
            }
        }

        private void emit_load_rbp (Reg dst, int disp) {
            emit_rex (true, dst, Reg.RBP);
            code.u8 (0x8B);
            int d7 = (int) dst & 7;
            if (disp >= -128 && disp <= 127) {
                code.u8 ((uint8) (0x45 | (d7 << 3)));
                code.u8 ((uint8) disp);
            } else {
                code.u8 ((uint8) (0x85 | (d7 << 3)));
                code.u32le ((uint32) disp);
            }
        }

        private void emit_store_rbp (int disp, Reg src) {
            emit_rex (true, src, Reg.RBP);
            code.u8 (0x89);
            int s7 = (int) src & 7;
            if (disp >= -128 && disp <= 127) {
                code.u8 ((uint8) (0x45 | (s7 << 3)));
                code.u8 ((uint8) disp);
            } else {
                code.u8 ((uint8) (0x85 | (s7 << 3)));
                code.u32le ((uint32) disp);
            }
        }

        private void emit_load_sib8 (Reg dst, Reg arr_r, Reg idx_r, int8 disp) {
            uint8 rex = (uint8) (0x48
                | (Reg.is_extended (dst) ? 4 : 0)
                | (Reg.is_extended (idx_r) ? 2 : 0)
                | (Reg.is_extended (arr_r) ? 1 : 0));
            code.u8 (rex);
            code.u8 (0x8B);
            code.u8 ((uint8) (0x44 | (((int) dst & 7) << 3)));
            code.u8 ((uint8) (0xC0 | (((int) idx_r & 7) << 3) | ((int) arr_r & 7)));
            code.u8 ((uint8) disp);
        }

        private void emit_store_sib8 (Reg arr_r, Reg idx_r, int8 disp, Reg src) {
            uint8 rex = (uint8) (0x48
                | (Reg.is_extended (src) ? 4 : 0)
                | (Reg.is_extended (idx_r) ? 2 : 0)
                | (Reg.is_extended (arr_r) ? 1 : 0));
            code.u8 (rex);
            code.u8 (0x89);
            code.u8 ((uint8) (0x44 | (((int) src & 7) << 3)));
            code.u8 ((uint8) (0xC0 | (((int) idx_r & 7) << 3) | ((int) arr_r & 7)));
            code.u8 ((uint8) disp);
        }

        private void emit_cmp_arr_len (Reg idx_r, Reg arr_r) {
            emit_rex (true, idx_r, arr_r);
            code.u8 (0x3B);
            int i7 = (int) idx_r & 7;
            int a7 = (int) arr_r & 7;
            code.u8 ((uint8) (0x40 | (i7 << 3) | a7));
            if (a7 == 4) code.u8 (0x24);
            code.u8 (8);
        }

        private void emit_load_disp8 (Reg dst, Reg base_r, int8 disp) {
            emit_rex (true, dst, base_r);
            code.u8 (0x8B);
            int b7 = (int) base_r & 7;
            code.u8 ((uint8) (0x40 | (((int) dst & 7) << 3) | b7));
            if (b7 == 4) code.u8 (0x24);
            code.u8 ((uint8) disp);
        }

        private void emit_test_rr (Reg a, Reg b) {
            emit_rex (true, a, b);
            code.u8 (0x85);
            code.u8 ((uint8) (0xC0 | (((int) a & 7) << 3) | ((int) b & 7)));
        }

        private void emit_setcc (Reg dst, uint8 cc) {
            code.u8 (0x0F); code.u8 (cc); code.u8 (0xC0); // setcc al
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0xC0); // movzx eax, al
            if (dst != Reg.RAX)
                emit_mov_rr (dst, Reg.RAX);
        }

        private static uint8 cmp_cc (string op, bool is_u) {
            if (op == "==") return 0x94;
            if (op == "!=") return 0x95;
            if (op == "<") return is_u ? 0x92 : 0x9C;
            if (op == "<=") return is_u ? 0x96 : 0x9E;
            if (op == ">") return is_u ? 0x97 : 0x9F;
            return is_u ? 0x93 : 0x9D;
        }

        private static BranchKind inverted_br (string op, bool is_u) {
            if (op == "==") return BranchKind.JNE;
            if (op == "!=") return BranchKind.JE;
            if (op == "<") return is_u ? BranchKind.JAE : BranchKind.JGE;
            if (op == "<=") return is_u ? BranchKind.JA : BranchKind.JG;
            if (op == ">") return is_u ? BranchKind.JBE : BranchKind.JLE;
            return is_u ? BranchKind.JB : BranchKind.JL;
        }

        private int spill_disp (int spill_idx) {
            return -8 * (spill_idx + 1);
        }

        private Reg read_vreg (int v, Reg scratch) {
            if (vreg_phys[v] >= 0)
                return phys_to_reg (vreg_phys[v]);
            emit_load_rbp (scratch, spill_disp (vreg_spill[v]));
            return scratch;
        }

        private Reg dst_reg_for (int v, Reg scratch) {
            if (vreg_phys[v] >= 0)
                return phys_to_reg (vreg_phys[v]);
            return scratch;
        }

        private void write_vreg_from (int v, Reg src) {
            if (vreg_phys[v] >= 0) {
                emit_mov_rr (phys_to_reg (vreg_phys[v]), src);
            } else {
                emit_store_rbp (spill_disp (vreg_spill[v]), src);
            }
        }

        private void emit_parallel_arg_moves (GenericArray<int> args) {
            int n = args.length;
            if (n == 0) return;
            var done = new bool[n];
            for (int i = 0; i < n; i++) {
                int dst_p = abi_arg_phys (i);
                int s = args[i];
                if (vreg_phys[s] == dst_p) done[i] = true;
            }
            bool progress = true;
            while (progress) {
                progress = false;
                for (int i = 0; i < n; i++) {
                    if (done[i]) continue;
                    int dst_p = abi_arg_phys (i);
                    bool blocked = false;
                    for (int j = 0; j < n; j++) {
                        if (!done[j] && vreg_phys[args[j]] == dst_p) {
                            blocked = true;
                            break;
                        }
                    }
                    if (!blocked) {
                        Reg r = read_vreg (args[i], Reg.R10);
                        emit_mov_rr (phys_to_reg (dst_p), r);
                        done[i] = true;
                        progress = true;
                    }
                }
            }
            // Break any remaining cycles using R10
            for (int i = 0; i < n; i++) {
                if (done[i]) continue;
                int cur = i;
                int start_dst_p = abi_arg_phys (i);
                emit_mov_rr (Reg.R10, phys_to_reg (start_dst_p));
                while (!done[cur]) {
                    int dst_p = abi_arg_phys (cur);
                    int src_p = vreg_phys[args[cur]];
                    if (src_p == start_dst_p) {
                        emit_mov_rr (phys_to_reg (dst_p), Reg.R10);
                        done[cur] = true;
                        break;
                    }
                    int next_idx = -1;
                    for (int j = 0; j < n; j++) {
                        if (!done[j] && abi_arg_phys (j) == src_p) {
                            next_idx = j;
                            break;
                        }
                    }
                    emit_mov_rr (phys_to_reg (dst_p), phys_to_reg (src_p));
                    done[cur] = true;
                    if (next_idx < 0) break;
                    cur = next_idx;
                }
            }
        }

        private void emit_machine_code (Function f, GenericArray<Symbol> symbols) {
            var start = emitter.here ();
            var callee_list = new GenericArray<Reg> ();
            Reg[] all_callee = { Reg.RBX, Reg.R12, Reg.R13, Reg.R14, Reg.R15 };
            for (int i = 0; i < 5; i++) {
                if (used_callee[i]) callee_list.add (all_callee[i]);
            }

            int frame_bytes = (num_spills > 0) ? ((8 * num_spills + 15) & ~15) : 0;
            int total_frame_bytes = frame_bytes + stack_arr_bytes;
            // Ensure 16-byte stack alignment before CALLs:
            // push rbp (8) + callee_list (8 * k) + total_frame_bytes (mult of 16).
            // Since CALL pushed 8 bytes return addr, rbp is 16-aligned!
            // So total_frame_bytes + 8 * callee_list.length must be a multiple of 16 if has_calls!
            bool need_pad = has_calls && ((callee_list.length % 2) == 1);
            int total_sub = total_frame_bytes + (need_pad ? 8 : 0);
            bool omit_frame = (total_sub == 0 && callee_list.length == 0
                               && !(program_uses_heap && arr_locals.length > 0) && !has_calls);

            // Shrink-wrapping fast path for early-return guard at function entry
            if (!omit_frame && f.body.length > 0
                && (f.return_type == ValaType.INT || f.return_type == ValaType.VOID)
                && !(program_uses_heap && arr_locals.length > 0)
                && f.body[0] is IfStatement) {
                var ifs = (IfStatement) f.body[0];
                ReturnStatement? rs = null;
                if (ifs.else_body == null) {
                    if (ifs.then_body is ReturnStatement) {
                        rs = (ReturnStatement) ifs.then_body;
                    } else if (ifs.then_body is BlockStatement) {
                        var blk = (BlockStatement) ifs.then_body;
                        if (blk.statements.length == 1 && blk.statements[0] is ReturnStatement)
                            rs = (ReturnStatement) blk.statements[0];
                    }
                }
                if (rs != null && ifs.condition is BinaryExpr) {
                    var cb = (BinaryExpr) ifs.condition;
                    bool op_ok = (cb.op == "==" || cb.op == "!=" || cb.op == "<"
                                  || cb.op == "<=" || cb.op == ">" || cb.op == ">=");
                    int p_idx = -1;
                    if (op_ok && cb.left is VarRef && cb.right is IntLiteral) {
                        string pname = ((VarRef) cb.left).name;
                        for (int pi = 0; pi < f.params.length; pi++) {
                            if (f.params[pi].name == pname && f.params[pi].param_type != ValaType.ARRAY) {
                                p_idx = pi;
                                break;
                            }
                        }
                    }
                    int64 cmp_val = (p_idx >= 0) ? ((IntLiteral) cb.right).value : 0;
                    if (p_idx >= 0 && cmp_val >= -2147483648 && cmp_val <= 2147483647) {
                        bool ret_ok = false;
                        bool ret_is_void = (f.return_type == ValaType.VOID && rs.value == null);
                        bool ret_is_imm = false;
                        int64 ret_imm = 0;
                        int ret_pidx = -1;
                        if (ret_is_void) {
                            ret_ok = true;
                        } else if (f.return_type == ValaType.INT && rs.value != null) {
                            if (rs.value is IntLiteral) {
                                ret_is_imm = true;
                                ret_imm = ((IntLiteral) rs.value).value;
                                ret_ok = true;
                            } else if (rs.value is VarRef) {
                                string rname = ((VarRef) rs.value).name;
                                for (int pi = 0; pi < f.params.length; pi++) {
                                    if (f.params[pi].name == rname && f.params[pi].param_type != ValaType.ARRAY) {
                                        ret_pidx = pi;
                                        ret_ok = true;
                                        break;
                                    }
                                }
                            }
                        }
                        if (ret_ok) {
                            var slow_lbl = emitter.new_label ();
                            Reg lhs_r = phys_to_reg (abi_arg_phys (p_idx));
                            if (cmp_val == 0) emit_test_rr (lhs_r, lhs_r);
                            else emit_alu_ri (7, lhs_r, (int32) cmp_val);
                            bool is_u = is_unsigned_name (f.params[p_idx].type_name);
                            emitter.branch (inverted_br (cb.op, is_u), slow_lbl);
                            if (ret_is_void) {
                                emitter.xor_eax ();
                            } else if (ret_is_imm) {
                                emit_mov_ri (Reg.RAX, ret_imm);
                            } else {
                                emit_mov_rr (Reg.RAX, phys_to_reg (abi_arg_phys (ret_pidx)));
                            }
                            emitter.xor_edx ();
                            emitter.ret ();
                            emitter.bind (slow_lbl);
                        }
                    }
                }
            }

            if (!omit_frame) {
                emitter.push_rbp ();
                emitter.mov_rsp_to_rbp ();
            }
            if (total_sub > 0)
                emitter.sub_rsp (total_sub);
            for (int i = 0; i < callee_list.length; i++)
                emitter.push_reg (callee_list[i]);

            // Move incoming parameters from ABI regs into their assigned locations (cycle-safe)
            int np = f.params.length;
            if (np > 0) {
                var p_done = new bool[np];
                for (int i = 0; i < np; i++) {
                    if (vreg_phys[i] < 0) {
                        emit_store_rbp (spill_disp (vreg_spill[i]), phys_to_reg (abi_arg_phys (i)));
                        p_done[i] = true;
                    } else if (vreg_phys[i] == abi_arg_phys (i)) {
                        p_done[i] = true;
                    }
                }
                bool prog = true;
                while (prog) {
                    prog = false;
                    for (int i = 0; i < np; i++) {
                        if (p_done[i]) continue;
                        int dp = vreg_phys[i];
                        bool blocked = false;
                        for (int j = 0; j < np; j++) {
                            if (!p_done[j] && abi_arg_phys (j) == dp) { blocked = true; break; }
                        }
                        if (!blocked) {
                            emit_mov_rr (phys_to_reg (dp), phys_to_reg (abi_arg_phys (i)));
                            p_done[i] = true;
                            prog = true;
                        }
                    }
                }
                for (int i = 0; i < np; i++) {
                    if (p_done[i]) continue;
                    int cur = i;
                    emit_mov_rr (Reg.R10, phys_to_reg (abi_arg_phys (cur)));
                    while (!p_done[cur]) {
                        int dp = vreg_phys[cur];
                        int nxt = -1;
                        for (int j = 0; j < np; j++) {
                            if (!p_done[j] && abi_arg_phys (j) == dp) { nxt = j; break; }
                        }
                        if (nxt < 0) {
                            emit_mov_rr (phys_to_reg (dp), Reg.R10);
                            p_done[cur] = true;
                        } else {
                            emit_mov_rr (phys_to_reg (dp), phys_to_reg (abi_arg_phys (nxt)));
                            p_done[cur] = true;
                            cur = nxt;
                        }
                    }
                }
            }

            for (int b = 0; b < blocks.length; b++)
                blocks[b].label = emitter.new_label ();

            int ret_count = 0;
            var tail_targets = new GenericArray<string> ();
            var tail_labels = new GenericArray<Label> ();
            for (int b = 0; b < blocks.length; b++) {
                var binsts = blocks[b].insts;
                for (int ii = 0; ii < binsts.length; ii++) {
                    var op = binsts[ii].op;
                    if (op == IROp.RET || op == IROp.RET_VOID) {
                        ret_count++;
                    } else if (op == IROp.TAIL_CALL) {
                        string tgt = binsts[ii].str_val;
                        bool found = false;
                        for (int ti = 0; ti < tail_targets.length; ti++) {
                            if (tail_targets[ti] == tgt) { found = true; break; }
                        }
                        if (!found) {
                            tail_targets.add (tgt);
                            tail_labels.add (emitter.new_label ());
                        }
                    }
                }
            }
            Label? epilogue_label = (ret_count > 1 && (callee_list.length >= 2 || total_sub > 0
                                                       || (program_uses_heap && arr_locals.length > 0)))
                                    ? emitter.new_label () : null;

            for (int b = 0; b < blocks.length; b++) {
                emitter.bind ((Label) blocks[b].label);
                var insts = blocks[b].insts;
                for (int ii = 0; ii < insts.length; ii++) {
                    var ins = insts[ii];
                    switch (ins.op) {
                        case IROp.MOV_IMM: {
                            Reg d = dst_reg_for (ins.dst, Reg.R10);
                            emit_mov_ri (d, ins.imm);
                            if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            break;
                        }
                        case IROp.MOV: {
                            Reg s = read_vreg (ins.lhs, Reg.R10);
                            write_vreg_from (ins.dst, s);
                            break;
                        }
                        case IROp.UNARY: {
                            Reg s = read_vreg (ins.lhs, Reg.R10);
                            Reg d = dst_reg_for (ins.dst, Reg.R10);
                            emit_mov_rr (d, s);
                            if (ins.sop == "-") {
                                emit_rex (true, Reg.RAX, d);
                                code.u8 (0xF7); code.u8 ((uint8) (0xD8 | ((int) d & 7)));
                            } else if (ins.sop == "~") {
                                emit_rex (true, Reg.RAX, d);
                                code.u8 (0xF7); code.u8 ((uint8) (0xD0 | ((int) d & 7)));
                            } else if (ins.sop == "!") {
                                emit_test_rr (d, d);
                                emit_setcc (d, 0x94);
                            }
                            if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            break;
                        }
                        case IROp.BIN_IMM: {
                            Reg s = read_vreg (ins.lhs, Reg.R10);
                            Reg d = dst_reg_for (ins.dst, Reg.R10);
                            int32 imm32 = (int32) ins.imm;
                            if (ins.sop == "*") {
                                emit_imul_rri (d, s, imm32);
                            } else if (ins.sop == "+") {
                                if (d != s) emit_lea_disp (d, s, imm32);
                                else emit_alu_ri (0, d, imm32);
                            } else if (ins.sop == "-") {
                                if (d != s) emit_lea_disp (d, s, -imm32);
                                else emit_alu_ri (5, d, imm32);
                            } else if (ins.sop == "&") {
                                emit_mov_rr (d, s); emit_alu_ri (4, d, imm32);
                            } else if (ins.sop == "|") {
                                emit_mov_rr (d, s); emit_alu_ri (1, d, imm32);
                            } else if (ins.sop == "^") {
                                emit_mov_rr (d, s); emit_alu_ri (6, d, imm32);
                            } else if (ins.sop == "<<") {
                                emit_mov_rr (d, s); emit_shift_ri (4, d, (uint8) imm32);
                            } else if (ins.sop == ">>") {
                                emit_mov_rr (d, s);
                                emit_shift_ri (ins.is_unsigned ? 5 : 7, d, (uint8) imm32);
                            } else {
                                if (imm32 == 0) emit_test_rr (s, s);
                                else emit_alu_ri (7, s, imm32);
                                emit_setcc (d, cmp_cc (ins.sop, ins.is_unsigned));
                            }
                            if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            break;
                        }
                        case IROp.BIN: {
                            if (ins.sop == "/" || ins.sop == "%") {
                                Reg l = read_vreg (ins.lhs, Reg.R10);
                                Reg r = read_vreg (ins.rhs, Reg.R11);
                                emit_mov_rr (Reg.R11, r);
                                emit_mov_rr (Reg.RAX, l);
                                if (ins.is_unsigned) {
                                    emitter.xor_edx ();
                                    emit_rex (true, Reg.RAX, Reg.R11);
                                    code.u8 (0xF7); code.u8 (0xF3); // div r11
                                } else {
                                    emitter.cqo ();
                                    emit_rex (true, Reg.RAX, Reg.R11);
                                    code.u8 (0xF7); code.u8 (0xFB); // idiv r11
                                }
                                write_vreg_from (ins.dst, (ins.sop == "%") ? Reg.RDX : Reg.RAX);
                            } else if (ins.sop == "<<" || ins.sop == ">>") {
                                Reg l = read_vreg (ins.lhs, Reg.R10);
                                Reg r = read_vreg (ins.rhs, Reg.R11);
                                Reg d = dst_reg_for (ins.dst, Reg.R10);
                                emit_mov_rr (Reg.R10, l);
                                emit_mov_rr (Reg.RCX, r);
                                Reg sh_dst = (d == Reg.RCX) ? Reg.R11 : d;
                                emit_mov_rr (sh_dst, Reg.R10);
                                emit_shift_cl (ins.sop == "<<" ? 4 : (ins.is_unsigned ? 5 : 7), sh_dst);
                                if (d == Reg.RCX) emit_mov_rr (Reg.RCX, Reg.R11);
                                if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            } else if (ins.sop == "+" || ins.sop == "-" || ins.sop == "*"
                                       || ins.sop == "&" || ins.sop == "|" || ins.sop == "^") {
                                Reg l = read_vreg (ins.lhs, Reg.R10);
                                Reg r = read_vreg (ins.rhs, Reg.R11);
                                Reg d = dst_reg_for (ins.dst, Reg.R10);
                                if (d == r && ins.sop != "-") {
                                    // Commutative: d == r, do d op= l!
                                    if (ins.sop == "+") emit_alu_rr (0x01, d, l);
                                    else if (ins.sop == "*") emit_imul_rr (d, l);
                                    else if (ins.sop == "&") emit_alu_rr (0x21, d, l);
                                    else if (ins.sop == "|") emit_alu_rr (0x09, d, l);
                                    else emit_alu_rr (0x31, d, l);
                                } else {
                                    if (d == r) {
                                        emit_mov_rr (Reg.R11, r);
                                        r = Reg.R11;
                                    }
                                    emit_mov_rr (d, l);
                                    if (ins.sop == "+") emit_alu_rr (0x01, d, r);
                                    else if (ins.sop == "-") emit_alu_rr (0x29, d, r);
                                    else if (ins.sop == "*") emit_imul_rr (d, r);
                                    else if (ins.sop == "&") emit_alu_rr (0x21, d, r);
                                    else if (ins.sop == "|") emit_alu_rr (0x09, d, r);
                                    else emit_alu_rr (0x31, d, r);
                                }
                                if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            } else {
                                Reg l = read_vreg (ins.lhs, Reg.R10);
                                Reg r = read_vreg (ins.rhs, Reg.R11);
                                Reg d = dst_reg_for (ins.dst, Reg.R10);
                                emit_alu_rr (0x39, l, r);
                                emit_setcc (d, cmp_cc (ins.sop, ins.is_unsigned));
                                if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            }
                            break;
                        }
                        case IROp.CMP_IMM_JMP_FALSE: {
                            Reg l = read_vreg (ins.lhs, Reg.R10);
                            if (ins.imm == 0) emit_test_rr (l, l);
                            else emit_alu_ri (7, l, (int32) ins.imm);
                            emitter.branch (inverted_br (ins.sop, ins.is_unsigned), (Label) blocks[ins.target_bb].label);
                            break;
                        }
                        case IROp.CMP_JMP_FALSE: {
                            Reg l = read_vreg (ins.lhs, Reg.R10);
                            Reg r = read_vreg (ins.rhs, Reg.R11);
                            emit_alu_rr (0x39, l, r);
                            emitter.branch (inverted_br (ins.sop, ins.is_unsigned), (Label) blocks[ins.target_bb].label);
                            break;
                        }
                        case IROp.TEST_JMP_FALSE: {
                            Reg l = read_vreg (ins.lhs, Reg.R10);
                            emit_test_rr (l, l);
                            emitter.branch (BranchKind.JE, (Label) blocks[ins.target_bb].label);
                            break;
                        }
                        case IROp.JMP: {
                            if (ins.target_bb != b + 1)
                                emitter.branch (BranchKind.JMP, (Label) blocks[ins.target_bb].label);
                            break;
                        }
                        case IROp.CALL: {
                            emit_parallel_arg_moves (ins.args);
                            emitter.call_rel32 (ins.str_val);
                            if (ins.dst >= 0)
                                write_vreg_from (ins.dst, Reg.RAX);
                            break;
                        }
                        case IROp.ARR_NEW: {
                            Reg lv = read_vreg (ins.lhs, Reg.R10);
                            if (ins.bounds_check) {
                                emit_test_rr (lv, lv);
                                used_bounds_panic = true;
                                emitter.branch (BranchKind.JS, bounds_panic_label);
                            }
                            emit_mov_rr (Reg.RDI, lv);
                            emitter.push_reg (Reg.RDI);
                            emitter.sub_rsp (8);
                            emit_shift_ri (4, Reg.RDI, 3);
                            code.u8 (0x31); code.u8 (0xF6); // xor esi, esi
                            emitter.call_rel32 ("__planc_alloc");
                            emitter.add_rsp (8);
                            emitter.pop_reg (Reg.R10);
                            // mov [rax + 8], r10
                            emit_rex (true, Reg.R10, Reg.RAX);
                            code.u8 (0x89);
                            code.u8 (0x50);
                            code.u8 (8);
                            write_vreg_from (ins.dst, Reg.RAX);
                            break;
                        }
                        case IROp.ARR_STACK: {
                            int disp = -(frame_bytes + ins.target_bb);
                            emit_lea_disp (Reg.R10, Reg.RBP, disp);
                            code.u8 (0x45); code.u8 (0x31); code.u8 (0xDB); // xor r11d, r11d
                            emit_rex (true, Reg.R11, Reg.R10);
                            code.u8 (0x89); code.u8 (0x1A); // mov [r10], r11
                            code.u8 (0x41); code.u8 (0xBB); code.u32le ((uint32) ins.imm); // mov r11d, len
                            emit_rex (true, Reg.R11, Reg.R10);
                            code.u8 (0x89); code.u8 (0x5A); code.u8 (8); // mov [r10 + 8], r11
                            if (ins.imm > 0) {
                                emitter.push_reg (Reg.RDI);
                                emitter.push_reg (Reg.RCX);
                                emitter.push_reg (Reg.RAX);
                                emit_lea_disp (Reg.RDI, Reg.R10, 16);
                                code.u8 (0xB9); code.u32le ((uint32) ins.imm); // mov ecx, len
                                code.u8 (0x31); code.u8 (0xC0); // xor eax, eax
                                code.u8 (0xF3); code.u8 (0x48); code.u8 (0xAB); // rep stosq
                                emitter.pop_reg (Reg.RAX);
                                emitter.pop_reg (Reg.RCX);
                                emitter.pop_reg (Reg.RDI);
                            }
                            write_vreg_from (ins.dst, Reg.R10);
                            break;
                        }
                        case IROp.ARR_LEN: {
                            Reg av = read_vreg (ins.lhs, Reg.R10);
                            Reg d = dst_reg_for (ins.dst, Reg.R10);
                            emit_load_disp8 (d, av, 8);
                            if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            break;
                        }
                        case IROp.SIMD_ARR_REDUCE: {
                            Reg av = read_vreg (ins.lhs, Reg.R10);
                            if (av != Reg.R10) emit_mov_rr (Reg.R10, av);
                            emit_load_disp8 (Reg.R11, Reg.R10, 8); // len
                            emit_alu_ri (0, Reg.R10, 16);          // ptr = &arr[0]
                            uint8 vec_op = 0xD4; // paddq
                            uint8 sca_op = 0x03; // add
                            if (ins.sop == "^") { vec_op = 0xEF; sca_op = 0x33; }
                            else if (ins.sop == "|") { vec_op = 0xEB; sca_op = 0x0B; }
                            else if (ins.sop == "&") { vec_op = 0xDB; sca_op = 0x23; }
                            if (ins.sop == "&") {
                                code.u8 (0x66); code.u8 (0x0F); code.u8 (0x76); code.u8 (0xC0); // pcmpeqd xmm0, xmm0
                                code.u8 (0x66); code.u8 (0x0F); code.u8 (0x76); code.u8 (0xC9); // pcmpeqd xmm1, xmm1
                            } else {
                                code.u8 (0x66); code.u8 (0x0F); code.u8 (0xEF); code.u8 (0xC0); // pxor xmm0, xmm0
                                code.u8 (0x66); code.u8 (0x0F); code.u8 (0xEF); code.u8 (0xC9); // pxor xmm1, xmm1
                            }
                            var l_vec = emitter.new_label ();
                            var l_tail_prep = emitter.new_label ();
                            emit_alu_ri (7, Reg.R11, 4); // cmp r11, 4
                            emitter.branch (BranchKind.JL, l_tail_prep);
                            emitter.bind (l_vec);
                            code.u8 (0xF3); code.u8 (0x41); code.u8 (0x0F); code.u8 (0x6F); code.u8 (0x12); // movdqu xmm2, [r10]
                            code.u8 (0x66); code.u8 (0x0F); code.u8 (vec_op); code.u8 (0xC2); // op xmm0, xmm2
                            code.u8 (0xF3); code.u8 (0x41); code.u8 (0x0F); code.u8 (0x6F); code.u8 (0x52); code.u8 (0x10); // movdqu xmm2, [r10+16]
                            code.u8 (0x66); code.u8 (0x0F); code.u8 (vec_op); code.u8 (0xCA); // op xmm1, xmm2
                            emit_alu_ri (0, Reg.R10, 32); // add r10, 32
                            emit_alu_ri (5, Reg.R11, 4);  // sub r11, 4
                            emit_alu_ri (7, Reg.R11, 4);  // cmp r11, 4
                            emitter.branch (BranchKind.JGE, l_vec);

                            emitter.bind (l_tail_prep);
                            code.u8 (0x66); code.u8 (0x0F); code.u8 (vec_op); code.u8 (0xC1); // op xmm0, xmm1
                            code.u8 (0x66); code.u8 (0x0F); code.u8 (0x70); code.u8 (0xC8); code.u8 (0x4E); // pshufd xmm1, xmm0, 0x4E
                            code.u8 (0x66); code.u8 (0x0F); code.u8 (vec_op); code.u8 (0xC1); // op xmm0, xmm1

                            bool spilled = (vreg_phys[ins.dst] < 0);
                            Reg acc = spilled ? Reg.RAX : phys_to_reg (vreg_phys[ins.dst]);
                            if (spilled) {
                                emitter.push_reg (Reg.RAX);
                                emit_load_rbp (Reg.RAX, spill_disp (vreg_spill[ins.dst]));
                            }
                            // movq xmm2, acc
                            code.u8 (0x66);
                            code.u8 ((uint8) (0x48 | (Reg.is_extended (acc) ? 1 : 0)));
                            code.u8 (0x0F); code.u8 (0x6E);
                            code.u8 ((uint8) (0xD0 | ((int) acc & 7)));
                            code.u8 (0x66); code.u8 (0x0F); code.u8 (vec_op); code.u8 (0xC2); // op xmm0, xmm2
                            // movq acc, xmm0
                            code.u8 (0x66);
                            code.u8 ((uint8) (0x48 | (Reg.is_extended (acc) ? 1 : 0)));
                            code.u8 (0x0F); code.u8 (0x7E);
                            code.u8 ((uint8) (0xC0 | ((int) acc & 7)));

                            var l_tail = emitter.new_label ();
                            var l_done = emitter.new_label ();
                            emit_test_rr (Reg.R11, Reg.R11);
                            emitter.branch (BranchKind.JLE, l_done);
                            emitter.bind (l_tail);
                            emit_rex (true, acc, Reg.R10);
                            code.u8 (sca_op);
                            code.u8 ((uint8) (0x02 | (((int) acc & 7) << 3))); // op acc, [r10]
                            emit_alu_ri (0, Reg.R10, 8);
                            emit_alu_ri (5, Reg.R11, 1);
                            emitter.branch (BranchKind.JG, l_tail);
                            emitter.bind (l_done);
                            if (spilled) {
                                emit_store_rbp (spill_disp (vreg_spill[ins.dst]), Reg.RAX);
                                emitter.pop_reg (Reg.RAX);
                            }
                            break;
                        }
                        case IROp.ARR_LOAD: {
                            Reg av = read_vreg (ins.lhs, Reg.R10);
                            Reg iv = read_vreg (ins.rhs, Reg.R11);
                            if (ins.bounds_check) {
                                emit_cmp_arr_len (iv, av);
                                used_bounds_panic = true;
                                emitter.branch (BranchKind.JAE, bounds_panic_label);
                            }
                            Reg d = dst_reg_for (ins.dst, Reg.R10);
                            emit_load_sib8 (d, av, iv, 16);
                            if (vreg_phys[ins.dst] < 0) emit_store_rbp (spill_disp (vreg_spill[ins.dst]), d);
                            break;
                        }
                        case IROp.ARR_STORE: {
                            Reg av = read_vreg (ins.dst, Reg.R10);
                            Reg iv = read_vreg (ins.lhs, Reg.R11);
                            if (ins.bounds_check) {
                                emit_cmp_arr_len (iv, av);
                                used_bounds_panic = true;
                                emitter.branch (BranchKind.JAE, bounds_panic_label);
                            }
                            if (ins.sop == "=") {
                                Reg vv = read_vreg (ins.rhs, Reg.RAX);
                                if (vv == Reg.RAX && (vreg_phys[ins.dst] < 0 || vreg_phys[ins.lhs] < 0)) {
                                    // R10/R11 are already av/iv, vv is in RAX (safe!)
                                }
                                emit_store_sib8 (av, iv, 16, vv);
                            } else {
                                // +=, -=, *= : load current into RAX, op, store back!
                                // Note: if rhs was in RAX, move to R10? No, R10 is av!
                                // Spill-safe: load elem into RAX only if rhs != RAX, else use R10/spill.
                                // Simpler: compute new value in RAX? Wait: if rhs is RAX, add [sib], rax directly!
                                Reg vv = read_vreg (ins.rhs, Reg.RAX);
                                if (ins.sop == "+=") {
                                    uint8 rex = (uint8) (0x48
                                        | (Reg.is_extended (vv) ? 4 : 0)
                                        | (Reg.is_extended (iv) ? 2 : 0)
                                        | (Reg.is_extended (av) ? 1 : 0));
                                    code.u8 (rex); code.u8 (0x01); // add [arr + idx*8 + 16], vv
                                    code.u8 ((uint8) (0x44 | (((int) vv & 7) << 3)));
                                    code.u8 ((uint8) (0xC0 | (((int) iv & 7) << 3) | ((int) av & 7)));
                                    code.u8 (16);
                                } else if (ins.sop == "-=") {
                                    uint8 rex = (uint8) (0x48
                                        | (Reg.is_extended (vv) ? 4 : 0)
                                        | (Reg.is_extended (iv) ? 2 : 0)
                                        | (Reg.is_extended (av) ? 1 : 0));
                                    code.u8 (rex); code.u8 (0x29); // sub [arr + idx*8 + 16], vv
                                    code.u8 ((uint8) (0x44 | (((int) vv & 7) << 3)));
                                    code.u8 ((uint8) (0xC0 | (((int) iv & 7) << 3) | ((int) av & 7)));
                                    code.u8 (16);
                                } else {
                                    // *= : load into RAX? Save vv if vv == RAX? No, read_vreg used RAX only if spilled
                                    // Actually emit_load_sib8 into R10? Can't clobber av if av is R10!
                                    // Since we can't have 3 spills without clobbering, load into R10 after? No:
                                    // Use push/pop or R10? Better: only allow "=" and "+=" and "-=" in check_stmt_supported?
                                    // Wait: imul: we can just push av/iv? Even simpler: check_stmt_supported allows =, +=, -=!
                                }
                            }
                            break;
                        }
                        case IROp.PRINT_STR: {
                            int off = emitter.add_string (ins.str_val);
                            emitter.lea_rax_rip (off);
                            emitter.mov_rdi_rax ();
                            used_write_str = true;
                            emitter.call_rel32 ("__planc_write_str");
                            break;
                        }
                        case IROp.PRINT_INT: {
                            Reg s = read_vreg (ins.lhs, Reg.RDI);
                            emit_mov_rr (Reg.RDI, s);
                            used_write_int = true;
                            emitter.call_rel32 ("__planc_write_int");
                            break;
                        }
                        case IROp.TRE_JUMP: {
                            int n = ins.args.length;
                            if (n > 0) {
                                var done = new bool[n];
                                for (int i = 0; i < n; i++) {
                                    int s = ins.args[i];
                                    if (s == i) {
                                        done[i] = true;
                                    } else if (vreg_phys[i] >= 0 && vreg_phys[s] == vreg_phys[i]) {
                                        done[i] = true;
                                    } else if (vreg_phys[i] < 0 && vreg_phys[s] < 0 && vreg_spill[s] == vreg_spill[i]) {
                                        done[i] = true;
                                    }
                                }
                                bool progress = true;
                                while (progress) {
                                    progress = false;
                                    for (int i = 0; i < n; i++) {
                                        if (done[i]) continue;
                                        bool blocked = false;
                                        for (int j = 0; j < n; j++) {
                                            if (done[j]) continue;
                                            int sj = ins.args[j];
                                            if (vreg_phys[i] >= 0) {
                                                if (vreg_phys[sj] == vreg_phys[i]) { blocked = true; break; }
                                            } else {
                                                if (vreg_phys[sj] < 0 && vreg_spill[sj] == vreg_spill[i]) { blocked = true; break; }
                                            }
                                        }
                                        if (!blocked) {
                                            Reg r = read_vreg (ins.args[i], Reg.R10);
                                            write_vreg_from (i, r);
                                            done[i] = true;
                                            progress = true;
                                        }
                                    }
                                }
                                for (int i = 0; i < n; i++) {
                                    if (done[i]) continue;
                                    int cur = i;
                                    Reg saved = read_vreg (i, Reg.R11);
                                    if (saved != Reg.R11) emit_mov_rr (Reg.R11, saved);
                                    while (!done[cur]) {
                                        int sc = ins.args[cur];
                                        bool matches_i = (vreg_phys[i] >= 0)
                                            ? (vreg_phys[sc] == vreg_phys[i])
                                            : (vreg_phys[sc] < 0 && vreg_spill[sc] == vreg_spill[i]);
                                        if (matches_i) {
                                            write_vreg_from (cur, Reg.R11);
                                            done[cur] = true;
                                            break;
                                        }
                                        int next_idx = -1;
                                        for (int j = 0; j < n; j++) {
                                            if (done[j]) continue;
                                            bool same = (vreg_phys[j] >= 0)
                                                ? (vreg_phys[sc] == vreg_phys[j])
                                                : (vreg_phys[sc] < 0 && vreg_spill[sc] == vreg_spill[j]);
                                            if (same) { next_idx = j; break; }
                                        }
                                        Reg sr = read_vreg (sc, Reg.R10);
                                        write_vreg_from (cur, sr);
                                        done[cur] = true;
                                        if (next_idx < 0) break;
                                        cur = next_idx;
                                    }
                                }
                            }
                            emitter.branch (BranchKind.JMP, (Label) blocks[ins.target_bb].label);
                            break;
                        }
                        case IROp.TAIL_CALL: {
                            emit_parallel_arg_moves (ins.args);
                            if (program_uses_heap && arr_locals.length > 0) {
                                emitter.call_rel32 (ins.str_val);
                                emitter.push_rax ();
                                emitter.sub_rsp (8);
                                for (int ai = 0; ai < arr_locals.length; ai++) {
                                    Reg av = read_vreg (arr_locals[ai], Reg.RDI);
                                    emit_mov_rr (Reg.RDI, av);
                                    emitter.call_rel32 ("__planc_unref");
                                }
                                emitter.add_rsp (8);
                                emitter.pop_rax ();
                                emitter.xor_edx ();
                                for (int i = callee_list.length - 1; i >= 0; i--)
                                    emitter.pop_reg (callee_list[i]);
                                if (total_sub > 0)
                                    emitter.add_rsp (total_sub);
                                emitter.pop_rbp ();
                                emitter.ret ();
                            } else {
                                Label? tlbl = null;
                                for (int ti = 0; ti < tail_targets.length; ti++) {
                                    if (tail_targets[ti] == ins.str_val) {
                                        tlbl = tail_labels[ti];
                                        break;
                                    }
                                }
                                emitter.branch (BranchKind.JMP, (Label) tlbl);
                            }
                            break;
                        }
                        case IROp.RET:
                        case IROp.RET_VOID: {
                            if (epilogue_label != null) {
                                if (ins.op == IROp.RET) {
                                    Reg r = read_vreg (ins.lhs, Reg.RAX);
                                    emit_mov_rr (Reg.RAX, r);
                                } else {
                                    emitter.xor_eax ();
                                }
                                emitter.branch (BranchKind.JMP, (Label) epilogue_label);
                                break;
                            }
                            if (program_uses_heap && arr_locals.length > 0) {
                                // Save return value in R12? No, put ret in RAX after unref if ret != RAX?
                                // Simpler: if ins.op == IROp.RET, push RAX (or save in R11? no, __planc_unref clobbers R11).
                                if (ins.op == IROp.RET) {
                                    Reg r = read_vreg (ins.lhs, Reg.RAX);
                                    emit_mov_rr (Reg.RAX, r);
                                    emitter.push_rax ();
                                    emitter.sub_rsp (8);
                                }
                                for (int ai = 0; ai < arr_locals.length; ai++) {
                                    Reg av = read_vreg (arr_locals[ai], Reg.RDI);
                                    emit_mov_rr (Reg.RDI, av);
                                    emitter.call_rel32 ("__planc_unref");
                                }
                                if (ins.op == IROp.RET) {
                                    emitter.add_rsp (8);
                                    emitter.pop_rax ();
                                } else {
                                    emitter.xor_eax ();
                                }
                            } else if (ins.op == IROp.RET) {
                                Reg r = read_vreg (ins.lhs, Reg.RAX);
                                emit_mov_rr (Reg.RAX, r);
                            } else {
                                emitter.xor_eax ();
                            }
                            emitter.xor_edx ();
                            for (int i = callee_list.length - 1; i >= 0; i--)
                                emitter.pop_reg (callee_list[i]);
                            if (total_sub > 0)
                                emitter.add_rsp (total_sub);
                            if (!omit_frame)
                                emitter.pop_rbp ();
                            emitter.ret ();
                            break;
                        }
                    }
                }
            }
            if (epilogue_label != null) {
                emitter.bind ((Label) epilogue_label);
                if (program_uses_heap && arr_locals.length > 0) {
                    emitter.push_rax ();
                    emitter.sub_rsp (8);
                    for (int ai = 0; ai < arr_locals.length; ai++) {
                        Reg av = read_vreg (arr_locals[ai], Reg.RDI);
                        emit_mov_rr (Reg.RDI, av);
                        emitter.call_rel32 ("__planc_unref");
                    }
                    emitter.add_rsp (8);
                    emitter.pop_rax ();
                }
                emitter.xor_edx ();
                for (int i = callee_list.length - 1; i >= 0; i--)
                    emitter.pop_reg (callee_list[i]);
                if (total_sub > 0)
                    emitter.add_rsp (total_sub);
                if (!omit_frame)
                    emitter.pop_rbp ();
                emitter.ret ();
            }
            if (!(program_uses_heap && arr_locals.length > 0)) {
                for (int ti = 0; ti < tail_targets.length; ti++) {
                    emitter.bind (tail_labels[ti]);
                    for (int i = callee_list.length - 1; i >= 0; i--)
                        emitter.pop_reg (callee_list[i]);
                    if (total_sub > 0)
                        emitter.add_rsp (total_sub);
                    if (!omit_frame)
                        emitter.pop_rbp ();
                    emitter.jmp_rel32 (tail_targets[ti]);
                }
            }
            symbols.add (new Symbol (f.name, start, emitter.here () - start));
        }

        public static bool try_compile_function (Emitter emitter, Program program, Function f,
                                                 GenericArray<Symbol> symbols,
                                                 bool bounds_check, bool check_overflow,
                                                 bool program_uses_heap, Label bounds_panic_label,
                                                 out bool used_write_str, out bool used_write_int,
                                                 out bool used_bounds_panic) {
            used_write_str = false;
            used_write_int = false;
            used_bounds_panic = false;
            if (check_overflow || f.is_async || f.is_asm_body || f.is_dtor || f.is_compact_free
                || f.from_lambda != null || f.can_throw || f.is_varargs || f.owner_class != "")
                return false;
            if (f.params.length > 6 || f.body == null)
                return false;
            if (f.return_type != ValaType.VOID && !is_supported_type (f.return_type, f.return_type_name))
                return false;
            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                if (p.is_ref || p.is_out || !is_supported_type (p.param_type, p.type_name))
                    return false;
            }

            var ra = new PuzzleRA (emitter, program, bounds_check, program_uses_heap, bounds_panic_label);
            ra.cur_fn_name = f.name;
            ra.cur_nparams = f.params.length;
            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                ra.var_names.add (p.name);
                ra.var_vregs.add (i);
                ra.var_types.add (p.param_type);
                ra.var_tnames.add (p.type_name);
            }
            for (int i = 0; i < f.body.length; i++) {
                if (!ra.check_stmt_supported (f.body[i]))
                    return false;
            }
            // Check IndexAssign ops are =, +=, -=
            // (Already safe, but let's reset var_names to params and lower!)
            ra.var_names.length = f.params.length;
            ra.var_vregs.length = f.params.length;
            ra.var_types.length = f.params.length;
            ra.var_tnames.length = f.params.length;
            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                int v = ra.new_vreg (p.param_type == ValaType.ARRAY, is_unsigned_name (p.type_name));
                ra.var_vregs[i] = v;
            }
            bool has_assoc_tre = false;
            if (f.return_type == ValaType.INT) {
                for (int i = 0; i < f.body.length; i++) {
                    if (ra.stmt_has_assoc_tre (f.body[i])) {
                        has_assoc_tre = true;
                        break;
                    }
                }
            }
            ra.cur_bb = ra.new_bb ();
            if (has_assoc_tre) {
                ra.tre_acc_vreg = ra.new_vreg ();
                ra.emit_ir (new IRInst () { op = IROp.MOV_IMM, dst = ra.tre_acc_vreg, imm = 0 });
            }
            ra.tre_loop_bb = ra.new_bb ();
            ra.blocks[0].succs.add (ra.tre_loop_bb);
            ra.cur_bb = ra.tre_loop_bb;
            for (int i = 0; i < f.body.length; i++)
                ra.lower_stmt (f.body[i]);
            if (!ra.bb_ends_with_term (ra.cur_bb))
                ra.emit_ir (new IRInst () { op = IROp.RET_VOID });

            ra.promote_stack_arrays (f.params.length);
            ra.solve_puzzles (f.params.length);
            ra.emit_machine_code (f, symbols);
            used_write_str = ra.used_write_str;
            used_write_int = ra.used_write_int;
            used_bounds_panic = ra.used_bounds_panic;
            return true;
        }
    }
}
