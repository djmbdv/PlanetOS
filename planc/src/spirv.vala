// Deterministic SPIR-V 1.0 Fragment Shader backend for planc (--target=spirv, GX-01/GX-02/GX-04).

namespace Planc {

    public class SpirvBackend : Object {

        // SPIR-V 1.0 opcodes
        private const uint16 OP_CAPABILITY          = 17;
        private const uint16 OP_MEMORY_MODEL        = 14;
        private const uint16 OP_ENTRY_POINT         = 15;
        private const uint16 OP_EXECUTION_MODE      = 16;
        private const uint16 OP_DECORATE            = 71;
        private const uint16 OP_TYPE_VOID           = 19;
        private const uint16 OP_TYPE_FLOAT          = 22;
        private const uint16 OP_TYPE_INT            = 21;
        private const uint16 OP_TYPE_VECTOR         = 23;
        private const uint16 OP_TYPE_POINTER        = 32;
        private const uint16 OP_TYPE_FUNCTION       = 33;
        private const uint16 OP_CONSTANT            = 43;
        private const uint16 OP_FUNCTION            = 54;
        private const uint16 OP_FUNCTION_END        = 56;
        private const uint16 OP_VARIABLE            = 59;
        private const uint16 OP_LOAD                = 61;
        private const uint16 OP_STORE               = 62;
        private const uint16 OP_COMPOSITE_CONSTRUCT = 80;
        private const uint16 OP_CONVERT_S_TO_F      = 111;
        private const uint16 OP_S_NEGATE            = 126;
        private const uint16 OP_F_NEGATE            = 127;
        private const uint16 OP_I_ADD               = 128;
        private const uint16 OP_F_ADD               = 129;
        private const uint16 OP_I_SUB               = 130;
        private const uint16 OP_F_SUB               = 131;
        private const uint16 OP_I_MUL               = 132;
        private const uint16 OP_F_MUL               = 133;
        private const uint16 OP_S_DIV               = 135;
        private const uint16 OP_F_DIV               = 136;
        private const uint16 OP_LABEL               = 248;
        private const uint16 OP_RETURN              = 253;

        private uint32 next_id = 1;
        private GenericArray<uint32> type_words;
        private GenericArray<uint32> fn_words;
        private GenericArray<uint32> var_words;
        private GenericArray<uint32> const_keys;
        private GenericArray<uint32> const_types;
        private GenericArray<uint32> const_ids;

        private GenericArray<string> local_names;
        private GenericArray<uint32> local_ptr_ids;
        private GenericArray<uint32> local_ty_ids;

        private uint32 ty_void = 0;
        private uint32 ty_fn_void = 0;
        private uint32 ty_f32 = 0;
        private uint32 ty_i32 = 0;
        private uint32 ty_v4f32 = 0;
        private uint32 ty_ptr_out_v4 = 0;
        private uint32 ty_ptr_fn_f32 = 0;
        private uint32 ty_ptr_fn_i32 = 0;
        private uint32 ty_ptr_fn_v4 = 0;
        private uint32 out_color_id = 0;
        private uint32 main_fn_id = 0;

        private uint32 alloc_id () {
            uint32 id = next_id;
            next_id = next_id + 1;
            return id;
        }

        private static void emit_op (GenericArray<uint32> dst, uint16 opcode, uint32[] args) {
            uint32 wc = (uint32) (1 + args.length);
            dst.add ((wc << 16) | (uint32) opcode);
            for (int i = 0; i < args.length; i++)
                dst.add (args[i]);
        }

        private static void emit_str_words (GenericArray<uint32> dst, string s) {
            int n = s.length + 1; // include NUL
            int words = (n + 3) / 4;
            for (int w = 0; w < words; w++) {
                uint32 v = 0;
                for (int b = 0; b < 4; b++) {
                    int idx = w * 4 + b;
                    uint32 ch = (idx < s.length) ? (uint32) s[idx] : 0;
                    v = v | (ch << (b * 8));
                }
                dst.add (v);
            }
        }

        private uint32 get_const (uint32 ty_id, uint32 bits) {
            for (int i = 0; i < const_keys.length; i++) {
                if (const_types[i] == ty_id && const_keys[i] == bits)
                    return const_ids[i];
            }
            uint32 id = alloc_id ();
            const_types.add (ty_id);
            const_keys.add (bits);
            const_ids.add (id);
            emit_op (type_words, OP_CONSTANT, new uint32[] { ty_id, id, bits });
            return id;
        }

        private static uint32 f64_to_f32_bits (uint64 b64) {
            uint32 sign = (uint32) ((b64 >> 63) & 1) << 31;
            int exp64 = (int) ((b64 >> 52) & 0x7FF);
            uint64 mant64 = b64 & 0xFFFFFFFFFFFFFu;
            if (exp64 == 0)
                return sign;
            if (exp64 == 0x7FF)
                return sign | 0x7F800000u | (uint32) (mant64 >> 29);
            int exp32 = exp64 - 1023 + 127;
            if (exp32 <= 0)
                return sign;
            if (exp32 >= 255)
                return sign | 0x7F800000u;
            uint32 mant32 = (uint32) (mant64 >> 29);
            return sign | ((uint32) exp32 << 23) | mant32;
        }

        private uint32 to_f32 (uint32 val_id, uint32 val_ty) {
            if (val_ty == ty_f32)
                return val_id;
            uint32 id = alloc_id ();
            emit_op (fn_words, OP_CONVERT_S_TO_F, new uint32[] { ty_f32, id, val_id });
            return id;
        }

        private uint32 gen_expr (Expr e, out uint32 out_ty) throws SemanticError {
            if (e is IntLiteral) {
                var il = (IntLiteral) e;
                out_ty = ty_i32;
                return get_const (ty_i32, (uint32) (int32) il.value);
            }
            if (e is FloatLiteral) {
                var fl = (FloatLiteral) e;
                out_ty = ty_f32;
                uint32 bits = fl.is_float32 ? (uint32) fl.bits : f64_to_f32_bits (fl.bits);
                return get_const (ty_f32, bits);
            }
            if (e is VarRef) {
                var vr = (VarRef) e;
                for (int i = local_names.length - 1; i >= 0; i--) {
                    if (local_names[i] == vr.name) {
                        uint32 res = alloc_id ();
                        out_ty = local_ty_ids[i];
                        emit_op (fn_words, OP_LOAD, new uint32[] { out_ty, res, local_ptr_ids[i] });
                        return res;
                    }
                }
                throw new SemanticError.UNKNOWN_VARIABLE (@"[spirv] unknown variable '$(vr.name)' at $(vr.line):$(vr.column)");
            }
            if (e is UnaryExpr) {
                var ue = (UnaryExpr) e;
                uint32 ot = 0;
                uint32 ov = gen_expr (ue.operand, out ot);
                if (ue.op == "-") {
                    uint32 res = alloc_id ();
                    out_ty = ot;
                    uint16 opc = (ot == ty_f32) ? OP_F_NEGATE : OP_S_NEGATE;
                    emit_op (fn_words, opc, new uint32[] { ot, res, ov });
                    return res;
                }
                throw new SemanticError.TYPE_MISMATCH (@"[spirv] unsupported unary op '$(ue.op)' at $(ue.line):$(ue.column)");
            }
            if (e is BinaryExpr) {
                var be = (BinaryExpr) e;
                uint32 lt = 0;
                uint32 rt = 0;
                uint32 lv = gen_expr (be.left, out lt);
                uint32 rv = gen_expr (be.right, out rt);
                if (lt != rt && (lt == ty_f32 || rt == ty_f32)) {
                    lv = to_f32 (lv, lt);
                    rv = to_f32 (rv, rt);
                    lt = ty_f32;
                    rt = ty_f32;
                }
                if (lt != rt || (lt != ty_f32 && lt != ty_i32))
                    throw new SemanticError.TYPE_MISMATCH (@"[spirv] incompatible binary operands at $(be.line):$(be.column)");
                uint16 opc = 0;
                bool is_f = (lt == ty_f32);
                if (be.op == "+") opc = is_f ? OP_F_ADD : OP_I_ADD;
                else if (be.op == "-") opc = is_f ? OP_F_SUB : OP_I_SUB;
                else if (be.op == "*") opc = is_f ? OP_F_MUL : OP_I_MUL;
                else if (be.op == "/") opc = is_f ? OP_F_DIV : OP_S_DIV;
                else throw new SemanticError.TYPE_MISMATCH (@"[spirv] unsupported binary op '$(be.op)' at $(be.line):$(be.column)");
                uint32 res = alloc_id ();
                out_ty = lt;
                emit_op (fn_words, opc, new uint32[] { lt, res, lv, rv });
                return res;
            }
            if (e is CallExpr) {
                var ce = (CallExpr) e;
                if (ce.callee == "vec4" && ce.args.length == 4) {
                    var comps = new uint32[4];
                    for (int k = 0; k < 4; k++) {
                        uint32 at = 0;
                        uint32 av = gen_expr (ce.args[k], out at);
                        comps[k] = to_f32 (av, at);
                    }
                    uint32 res = alloc_id ();
                    out_ty = ty_v4f32;
                    emit_op (fn_words, OP_COMPOSITE_CONSTRUCT,
                        new uint32[] { ty_v4f32, res, comps[0], comps[1], comps[2], comps[3] });
                    return res;
                }
                throw new SemanticError.UNKNOWN_FUNCTION (@"[spirv] unsupported call '$(ce.callee)' at $(ce.line):$(ce.column)");
            }
            throw new SemanticError.TYPE_MISMATCH (@"[spirv] non-shader expression at $(e.line):$(e.column)");
        }

        private void gen_stmt (Statement s) throws SemanticError {
            if (s is VarDeclStatement) {
                var vd = (VarDeclStatement) s;
                uint32 vty = ty_f32;
                uint32 pty = ty_ptr_fn_f32;
                if (vd.decl_type_name == "int" || vd.decl_type_name == "int32") {
                    vty = ty_i32;
                    pty = ty_ptr_fn_i32;
                } else if (vd.decl_type_name == "vec4") {
                    vty = ty_v4f32;
                    pty = ty_ptr_fn_v4;
                }
                uint32 init_id = 0;
                if (vd.init != null) {
                    uint32 it = 0;
                    init_id = gen_expr (vd.init, out it);
                    if (vd.infer_type) {
                        vty = it;
                        pty = (it == ty_i32) ? ty_ptr_fn_i32 : ((it == ty_v4f32) ? ty_ptr_fn_v4 : ty_ptr_fn_f32);
                    } else if (vty == ty_f32 && it == ty_i32) {
                        init_id = to_f32 (init_id, it);
                    }
                }
                uint32 pid = alloc_id ();
                emit_op (var_words, OP_VARIABLE, new uint32[] { pty, pid, 7 }); // Function storage class = 7
                local_names.add (vd.name);
                local_ptr_ids.add (pid);
                local_ty_ids.add (vty);
                if (init_id != 0)
                    emit_op (fn_words, OP_STORE, new uint32[] { pid, init_id });
                return;
            }
            if (s is AssignStatement) {
                var asg = (AssignStatement) s;
                uint32 it = 0;
                uint32 val_id = gen_expr (asg.value, out it);
                for (int i = local_names.length - 1; i >= 0; i--) {
                    if (local_names[i] == asg.name) {
                        if (local_ty_ids[i] == ty_f32 && it == ty_i32)
                            val_id = to_f32 (val_id, it);
                        emit_op (fn_words, OP_STORE, new uint32[] { local_ptr_ids[i], val_id });
                        return;
                    }
                }
                throw new SemanticError.UNKNOWN_VARIABLE (@"[spirv] unknown variable '$(asg.name)' at $(asg.line):$(asg.column)");
            }
            if (s is ExprStatement) {
                var es = (ExprStatement) s;
                if (es.expr is CallExpr) {
                    var ce = (CallExpr) es.expr;
                    if (ce.callee == "frag_color" && ce.args.length == 4) {
                        var comps = new uint32[4];
                        for (int k = 0; k < 4; k++) {
                            uint32 at = 0;
                            uint32 av = gen_expr (ce.args[k], out at);
                            comps[k] = to_f32 (av, at);
                        }
                        uint32 vec = alloc_id ();
                        emit_op (fn_words, OP_COMPOSITE_CONSTRUCT,
                            new uint32[] { ty_v4f32, vec, comps[0], comps[1], comps[2], comps[3] });
                        emit_op (fn_words, OP_STORE, new uint32[] { out_color_id, vec });
                        return;
                    }
                }
                uint32 dt = 0;
                gen_expr (es.expr, out dt);
                return;
            }
            if (s is ReturnStatement) {
                var rs = (ReturnStatement) s;
                if (rs.value != null) {
                    uint32 rt = 0;
                    uint32 rv = gen_expr (rs.value, out rt);
                    if (rt == ty_v4f32)
                        emit_op (fn_words, OP_STORE, new uint32[] { out_color_id, rv });
                }
                emit_op (fn_words, OP_RETURN, new uint32[0]);
                return;
            }
            throw new SemanticError.TYPE_MISMATCH (@"[spirv] unsupported statement in shader at $(s.line):$(s.column)");
        }

        public uint8[] generate (Program prog) throws SemanticError {
            if (prog.classes.length > 0 || prog.interfaces.length > 0 || prog.structs.length > 0)
                throw new SemanticError.TYPE_MISMATCH ("[spirv] classes/structs/interfaces are not supported in shader target");
            var main_fn = prog.find ("main");
            if (main_fn == null)
                throw new SemanticError.TYPE_MISMATCH ("[spirv] shader must define main()");

            next_id = 1;
            type_words = new GenericArray<uint32> ();
            fn_words = new GenericArray<uint32> ();
            var_words = new GenericArray<uint32> ();
            const_keys = new GenericArray<uint32> ();
            const_types = new GenericArray<uint32> ();
            const_ids = new GenericArray<uint32> ();
            local_names = new GenericArray<string> ();
            local_ptr_ids = new GenericArray<uint32> ();
            local_ty_ids = new GenericArray<uint32> ();

            ty_void = alloc_id ();
            ty_fn_void = alloc_id ();
            ty_f32 = alloc_id ();
            ty_i32 = alloc_id ();
            ty_v4f32 = alloc_id ();
            ty_ptr_out_v4 = alloc_id ();
            ty_ptr_fn_f32 = alloc_id ();
            ty_ptr_fn_i32 = alloc_id ();
            ty_ptr_fn_v4 = alloc_id ();
            out_color_id = alloc_id ();
            main_fn_id = alloc_id ();
            uint32 entry_lbl = alloc_id ();

            emit_op (type_words, OP_TYPE_VOID, new uint32[] { ty_void });
            emit_op (type_words, OP_TYPE_FUNCTION, new uint32[] { ty_fn_void, ty_void });
            emit_op (type_words, OP_TYPE_FLOAT, new uint32[] { ty_f32, 32 });
            emit_op (type_words, OP_TYPE_INT, new uint32[] { ty_i32, 32, 1 });
            emit_op (type_words, OP_TYPE_VECTOR, new uint32[] { ty_v4f32, ty_f32, 4 });
            emit_op (type_words, OP_TYPE_POINTER, new uint32[] { ty_ptr_out_v4, 3, ty_v4f32 });  // Output=3
            emit_op (type_words, OP_TYPE_POINTER, new uint32[] { ty_ptr_fn_f32, 7, ty_f32 });   // Function=7
            emit_op (type_words, OP_TYPE_POINTER, new uint32[] { ty_ptr_fn_i32, 7, ty_i32 });
            emit_op (type_words, OP_TYPE_POINTER, new uint32[] { ty_ptr_fn_v4, 7, ty_v4f32 });
            emit_op (type_words, OP_VARIABLE, new uint32[] { ty_ptr_out_v4, out_color_id, 3 });

            bool has_ret = false;
            for (int i = 0; i < main_fn.body.length; i++) {
                if (main_fn.body[i] is ReturnStatement)
                    has_ret = true;
                gen_stmt (main_fn.body[i]);
            }
            if (!has_ret)
                emit_op (fn_words, OP_RETURN, new uint32[0]);

            var words = new GenericArray<uint32> ();
            // 5-word SPIR-V 1.0 header
            words.add (0x07230203u);
            words.add (0x00010000u);
            words.add (0x00000000u);
            words.add (next_id);
            words.add (0x00000000u);

            emit_op (words, OP_CAPABILITY, new uint32[] { 1 }); // Shader
            emit_op (words, OP_MEMORY_MODEL, new uint32[] { 0, 1 }); // Logical, GLSL450

            // OpEntryPoint Fragment %main "main" %out_color
            var ep_str_words = new GenericArray<uint32> ();
            emit_str_words (ep_str_words, "main");
            uint32 ep_wc = (uint32) (4 + ep_str_words.length);
            words.add ((ep_wc << 16) | (uint32) OP_ENTRY_POINT);
            words.add (4); // Fragment
            words.add (main_fn_id);
            for (int i = 0; i < ep_str_words.length; i++)
                words.add (ep_str_words[i]);
            words.add (out_color_id);

            emit_op (words, OP_EXECUTION_MODE, new uint32[] { main_fn_id, 7 }); // OriginUpperLeft
            emit_op (words, OP_DECORATE, new uint32[] { out_color_id, 30, 0 }); // Location 0

            for (int i = 0; i < type_words.length; i++)
                words.add (type_words[i]);

            emit_op (words, OP_FUNCTION, new uint32[] { ty_void, main_fn_id, 0, ty_fn_void });
            emit_op (words, OP_LABEL, new uint32[] { entry_lbl });
            for (int i = 0; i < var_words.length; i++)
                words.add (var_words[i]);
            for (int i = 0; i < fn_words.length; i++)
                words.add (fn_words[i]);
            emit_op (words, OP_FUNCTION_END, new uint32[0]);

            var out_bytes = new uint8[words.length * 4];
            for (int i = 0; i < words.length; i++) {
                uint32 w = words[i];
                out_bytes[i * 4 + 0] = (uint8) (w & 0xFF);
                out_bytes[i * 4 + 1] = (uint8) ((w >> 8) & 0xFF);
                out_bytes[i * 4 + 2] = (uint8) ((w >> 16) & 0xFF);
                out_bytes[i * 4 + 3] = (uint8) ((w >> 24) & 0xFF);
            }
            return out_bytes;
        }
    }
}
