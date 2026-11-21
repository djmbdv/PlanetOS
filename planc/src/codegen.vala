// Code generation, type checking, and automatic reference counting.
//
// Slice 6 adds: classes (`class`), inheritance, virtual/override/abstract,
// constructors/destructors, unified 16B header + `.rodata` vtables,
// compile-time non-null (`T`) + guarded nullable (`T?` via Option B),
// `is`, `as`, casts `(Sub) x`, and `--no-null-check`.

namespace Planc {

    public errordomain SemanticError {
        UNKNOWN_VARIABLE,
        DUPLICATE_VARIABLE,
        UNUSED_VARIABLE,
        UNKNOWN_FUNCTION,
        UNKNOWN_MEMBER,
        WRONG_ARG_COUNT,
        VOID_IN_EXPRESSION,
        RETURN_MISMATCH,
        TYPE_MISMATCH,
        BAD_LOOP_CONTROL,
        BAD_MAIN
    }

    public sealed class Codegen : Object {

        public Emitter emitter { get; private set; }
        public GenericArray<Symbol> symbols { get; private set; }
        public GenericArray<DebugLineEntry> debug_lines { get; private set; }
        public GenericArray<DebugFunc> debug_funcs { get; private set; }
        public bool bounds_check { get; set; default = true; }
        public bool null_check { get; set; default = true; }
        public bool strict_null { get; set; default = false; }
        public bool strict_unused { get; set; default = false; }
        public bool warn_unused { get; set; default = true; }
        public bool allow_asm { get; set; default = true; }
        public int opt_level { get; set; default = 0; }
        public bool check_leaks { get; set; default = false; }
        public bool check_overflow { get; set; default = false; }
        public string current_file { get; private set; default = ""; }
        public bool freestanding { get; set; default = false; }
        public bool target_planetos { get; set; default = false; }

        private const uint32 SYS_EXIT = 60;

        private const int NUM_ARG_REGS = 6;

        private static Reg arg_reg (int i) {
            switch (i) {
                case 0: return Reg.RDI;
                case 1: return Reg.RSI;
                case 2: return Reg.RDX;
                case 3: return Reg.RCX;
                case 4: return Reg.R8;
                default: return Reg.R9;
            }
        }

        private Program program;
        private Function current;
        private ClassDecl? current_class = null;
        private StructDecl? current_struct = null;
        private EnumDecl? current_enum = null;
        private bool program_uses_heap = false;
        private int alloc_bss_offset = -1;
        private int async_bss_offset = -1;
        private int sig_bss_offset = -1;
        private int freestanding_heap_off = -1;
        private bool in_async_resume = false;
        private GenericArray<Label> async_resume_labels;
        private GenericArray<string> non_null_vars;

        // Per-function local symbol table.
        private GenericArray<string> locals;
        private GenericArray<ValaType> local_types;
        private GenericArray<string> local_type_names;
        private GenericArray<int> local_slots;
        private GenericArray<bool> local_active;
        private GenericArray<bool> local_by_ref;
        private GenericArray<bool> local_is_weak;
        private GenericArray<bool> local_is_compact;
        private GenericArray<bool> local_used;
        private GenericArray<bool> local_is_user;
        private GenericArray<int> local_decl_line;
        private GenericArray<int> local_decl_col;
        private bool in_check_pass = false;
        private int next_var_slot;
        private GenericArray<Expr> pending_struct_exprs;
        private GenericArray<int> pending_struct_rel_slots;
        private GenericArray<Expr> pending_ref_exprs;
        private int cur_ref_temp_start;
        private int cur_total_slots;
        private int err_prop_slot;
        private Label cur_func_throw_label;
        private bool need_func_throw;
        private GenericArray<string> active_catch_domains;
        private GenericArray<Label> unwind_labels;
        private GenericArray<int> unwind_marks;
        private GenericArray<Label> finally_labels;
        private GenericArray<int> finally_mode_slots;
        private GenericArray<int> finally_ret_slots;
        private GenericArray<int> finally_marks;
        private GenericArray<int> live_stmt_ref_slots;
        private int push_depth;

        // Loop target and cleanup scope stacks for `break` / `continue`.
        private GenericArray<Label> break_labels;
        private GenericArray<Label> continue_labels;
        private GenericArray<int> break_scope_marks;
        private GenericArray<int> continue_scope_marks;

        // Globals.
        private GenericArray<string> global_names;
        private GenericArray<ValaType> global_types;
        private GenericArray<string> global_type_names;
        private GenericArray<int> global_offsets;
        private GenericArray<PatchSpace> global_spaces;

        private int struct_ret_bss_offset = -1;
        private int null_delegate_bss_offset = -1;

        // Runtime intrinsics emitted on demand at the end of .text.
        private bool need_write_str = false;
        private bool need_str_eq = false;
        private bool need_write_int = false;
        private bool need_write_uint = false;
        private bool need_bounds_panic = false;
        private bool need_alloc = false;
        private bool need_ref = false;
        private bool need_unref = false;
        private bool need_str_concat = false;
        private bool need_str_slice = false;
        private bool need_int_to_str = false;
        private bool need_uint_to_str = false;
        private bool need_is_instance = false;
        private bool need_mem_panic = false;
        private bool need_null_panic = false;
        private bool need_cast_panic = false;
        private bool need_leak_panic = false;
        private bool need_overflow_panic = false;
        private Label overflow_panic_label = new Label ();
        private bool need_iface_lookup = false;
        private bool need_build_args = false;
        private bool need_str_has_prefix = false;
        private bool need_str_has_suffix = false;
        private bool need_utf8_char_count = false;
        private bool need_utf8_get_char = false;
        private bool need_lock = false;
        private bool need_compact_free = false;
        private int lock_bss_offset = -1;
        private bool need_utf8_validate = false;
        // True when any function returns or takes a string, or any global is a
        // string: `may_be_string` used to rescan the whole program per `+`.
        private bool program_has_string_slots = false;
        private bool need_str_index_of = false;
        private bool need_async = false;
        private bool need_signal = false;
        private bool need_sync = false;
        private bool need_str_to_int = false;
        private bool need_double_to_str = false;
        private bool need_str_to_double = false;
        private bool need_bytes_to_str = false;
        private bool need_eprint = false;
        private bool need_chmod = false;
        private bool need_read_file = false;
        private bool need_write_file = false;
        private bool main_takes_args = false;
        private int lambda_counter = 0;
        private GenericArray<LambdaExpr> pending_lambdas;

        private Label bounds_panic_label;
        private Label mem_panic_label;
        private Label null_panic_label;
        private Label cast_panic_label;
        private Label leak_panic_label;

        public Codegen () {
            emitter = new Emitter ();
            emitter.opt_level = opt_level;
            symbols = new GenericArray<Symbol> ();
            debug_lines = new GenericArray<DebugLineEntry> ();
            debug_funcs = new GenericArray<DebugFunc> ();
            non_null_vars = new GenericArray<string> ();
            locals = new GenericArray<string> ();
            local_types = new GenericArray<ValaType> ();
            local_type_names = new GenericArray<string> ();
            local_slots = new GenericArray<int> ();
            local_active = new GenericArray<bool> ();
            local_is_weak = new GenericArray<bool> ();
            local_is_compact = new GenericArray<bool> ();
            break_labels = new GenericArray<Label> ();
            continue_labels = new GenericArray<Label> ();
            break_scope_marks = new GenericArray<int> ();
            continue_scope_marks = new GenericArray<int> ();
            global_names = new GenericArray<string> ();
            global_types = new GenericArray<ValaType> ();
            global_type_names = new GenericArray<string> ();
            global_offsets = new GenericArray<int> ();
            global_spaces = new GenericArray<PatchSpace> ();
            pending_lambdas = new GenericArray<LambdaExpr> ();
            del_thunk_keys = new GenericArray<string> ();
            del_thunk_syms = new GenericArray<string> ();
            bounds_panic_label = emitter.new_label ();
            mem_panic_label = emitter.new_label ();
            null_panic_label = emitter.new_label ();
            cast_panic_label = emitter.new_label ();
            leak_panic_label = emitter.new_label ();
        }

        // ------------------------------------------------------------------
        // Program & heap-usage pre-scan.
        // ------------------------------------------------------------------

        public void generate (Program p) throws SemanticError {
            program = p;

            check_struct_cycles ();
            prepare_value_methods ();
            prepare_interfaces ();
            prepare_classes ();

            var main = program.find ("main");
            if (main == null) {
                Host.panic ("no main function");
                return;
            }
            if (main.params.length == 0) {
                main_takes_args = false;
            } else if (main.params.length == 1
                       && main.params[0].param_type == ValaType.ARRAY
                       && main.params[0].type_name == "string"
                       && !main.params[0].is_ref && !main.params[0].is_out) {
                main_takes_args = true;
            } else {
                throw new SemanticError.BAD_MAIN (
                    @"main takes no parameters or (string[] args) at $(main.line):$(main.column)");
            }
            if (main.return_type != ValaType.INT
                && main.return_type != ValaType.VOID
                && main.return_type != ValaType.BOOL) {
                throw new SemanticError.BAD_MAIN (
                    @"main cannot return '$(type_label (main.return_type, main.return_type_name))' at $(main.line):$(main.column)");
            }
            if (main.can_throw) {
                throw new SemanticError.BAD_MAIN (
                    @"main cannot declare 'throws' at $(main.line):$(main.column)");
            }

            program_uses_heap = check_leaks || main_takes_args || scan_program_heap ();
            if (main_takes_args)
                need_build_args = true;
            if (program_uses_heap) {
                alloc_bss_offset = emitter.add_bss_bytes (104);
                async_bss_offset = emitter.add_bss_bytes (64);
                sig_bss_offset = emitter.add_bss_bytes (8);
                if (freestanding)
                    freestanding_heap_off = emitter.add_bss_bytes (262144);
                need_alloc = true;
                need_ref = true;
                need_unref = true;
                need_mem_panic = true;
            }
            lock_bss_offset = emitter.add_bss_bytes (emitter.lock_table_bytes ());

            int max_ret_slots = 0;
            foreach (var f in program.functions) {
                if (f.return_type == ValaType.STRUCT) {
                    var n = type_slots (ValaType.STRUCT, f.return_type_name);
                    if (n > max_ret_slots)
                        max_ret_slots = n;
                }
            }
            if (max_ret_slots > 0)
                struct_ret_bss_offset = emitter.add_bss_bytes (8 * max_ret_slots);
            null_delegate_bss_offset = emitter.add_bss_bytes (16);

            synthesize_static_field_globals ();
            register_globals ();
            if (freestanding) {
                for (int fi = 0; fi < program.functions.length; fi++) {
                    if (program.functions[fi].name == "_kstart32")
                        generate_function (program.functions[fi]);
                }
            }
            for (int fi = 0; fi < program.functions.length; fi++) {
                if (freestanding && program.functions[fi].name == "_kstart32")
                    continue;
                generate_function (program.functions[fi]);
            }

            emit_start ();
            emit_runtime ();
        }

        private bool scan_program_heap () {
            program_has_string_slots = false;
            foreach (var f in program.functions) {
                if (f.return_type == ValaType.STRING) {
                    program_has_string_slots = true;
                    break;
                }
                foreach (var p in f.params) {
                    if (p.param_type == ValaType.STRING) {
                        program_has_string_slots = true;
                        break;
                    }
                }
                if (program_has_string_slots)
                    break;
            }
            if (!program_has_string_slots) {
                foreach (var g in program.globals) {
                    if (g.var_type == ValaType.STRING) {
                        program_has_string_slots = true;
                        break;
                    }
                }
            }
            if (program.classes.length > 0 || program.delegates.length > 0)
                return true;
            foreach (var g in program.globals) {
                if (g.var_type == ValaType.ARRAY || g.var_type == ValaType.CLASS || g.var_type == ValaType.ERROR)
                    return true;
            }
            foreach (var f in program.functions) {
                if (f.can_throw || f.is_async || f.return_type == ValaType.ARRAY || f.return_type == ValaType.ERROR)
                    return true;
                foreach (var p in f.params) {
                    if (p.param_type == ValaType.ARRAY || p.param_type == ValaType.ERROR)
                        return true;
                }
                foreach (var s in f.body) {
                    if (scan_stmt_heap (s))
                        return true;
                }
            }
            return false;
        }

        private bool scan_stmt_heap (Statement s) {
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                if (p.value is TemplateExpr) {
                    foreach (var part in ((TemplateExpr) p.value).parts) {
                        if (scan_expr_heap (part))
                            return true;
                    }
                    return false;
                }
                return scan_expr_heap (p.value);
            }
            if (s is ExitStatement)
                return scan_expr_heap (((ExitStatement) s).value);
            if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                return r.value != null && scan_expr_heap (r.value);
            }
            if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.decl_type == ValaType.ARRAY)
                    return true;
                return d.init != null && scan_expr_heap (d.init);
            }
            if (s is AssignStatement)
                return scan_expr_heap (((AssignStatement) s).value);
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return scan_expr_heap (fa.target) || scan_expr_heap (fa.value);
            }
            if (s is IndexAssignStatement)
                return true;
            if (s is ExprStatement)
                return scan_expr_heap (((ExprStatement) s).expr);
            if (s is BlockStatement) {
                foreach (var inner in ((BlockStatement) s).statements) {
                    if (scan_stmt_heap (inner))
                        return true;
                }
                return false;
            }
            if (s is IfStatement) {
                var i = (IfStatement) s;
                return scan_expr_heap (i.condition)
                    || scan_stmt_heap (i.then_body)
                    || (i.else_body != null && scan_stmt_heap (i.else_body));
            }
            if (s is WhileStatement) {
                var w = (WhileStatement) s;
                return scan_expr_heap (w.condition) || scan_stmt_heap (w.body);
            }
            if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                return scan_stmt_heap (dw.body) || scan_expr_heap (dw.condition);
            }
            if (s is ForStatement) {
                var fs = (ForStatement) s;
                return (fs.init != null && scan_stmt_heap (fs.init))
                    || (fs.condition != null && scan_expr_heap (fs.condition))
                    || (fs.step != null && scan_stmt_heap (fs.step))
                    || scan_stmt_heap (fs.body);
            }
            if (s is ForeachStatement) {
                var fe = (ForeachStatement) s;
                return scan_expr_heap (fe.collection) || scan_stmt_heap (fe.body);
            }
            if (s is SwitchStatement) {
                var sw = (SwitchStatement) s;
                if (scan_expr_heap (sw.target))
                    return true;
                foreach (var sc in sw.cases) {
                    foreach (var v in sc.values) {
                        if (scan_expr_heap (v))
                            return true;
                    }
                    foreach (var bs in sc.body) {
                        if (scan_stmt_heap (bs))
                            return true;
                    }
                }
                foreach (var ds in sw.default_body) {
                    if (scan_stmt_heap (ds))
                        return true;
                }
                return false;
            }
            if (s is ThrowStatement)
                return true;
            if (s is TryStatement) {
                var tr = (TryStatement) s;
                foreach (var ts in tr.try_body) {
                    if (scan_stmt_heap (ts))
                        return true;
                }
                foreach (var cc in tr.catches) {
                    foreach (var cs in cc.body) {
                        if (scan_stmt_heap (cs))
                            return true;
                    }
                }
                foreach (var fs in tr.finally_body) {
                    if (scan_stmt_heap (fs))
                        return true;
                }
                return false;
            }
            return false;
        }

        private bool scan_expr_heap (Expr e) {
            if (e is ArrayNewExpr || e is ArrayLiteralExpr || e is ClassNewExpr || e is SliceExpr || e is LambdaExpr || e is YieldExpr)
                return true;
            if (e is NullLiteral)
                return false;
            if (e is TemplateExpr)
                return !is_static_template ((TemplateExpr) e);
            if (e is UnaryExpr)
                return scan_expr_heap (((UnaryExpr) e).operand);
            if (e is IncDecExpr)
                return scan_expr_heap (((IncDecExpr) e).target);
            if (e is TypeCheckExpr)
                return scan_expr_heap (((TypeCheckExpr) e).operand);
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                return scan_expr_heap (te.condition) || scan_expr_heap (te.then_expr) || scan_expr_heap (te.else_expr);
            }
            if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                return scan_expr_heap (ce.left) || scan_expr_heap (ce.right);
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.method_name == "to_string" || mc.method_name == "substring" || mc.method_name == "begin")
                    return true;
                if (mc.target is VarRef && ((VarRef) mc.target).name == "Async")
                    return true;
                if (mc.target != null && scan_expr_heap (mc.target))
                    return true;
                foreach (var a in mc.args) {
                    if (scan_expr_heap (a))
                        return true;
                }
                return false;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                if (b.op == "+" && may_be_string (b.left))
                    return true;
                return scan_expr_heap (b.left) || scan_expr_heap (b.right);
            }
            if (e is MemberAccessExpr)
                return scan_expr_heap (((MemberAccessExpr) e).target);
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                return scan_expr_heap (ix.target) || scan_expr_heap (ix.index);
            }
            if (e is StructLiteral) {
                foreach (var fv in ((StructLiteral) e).field_values) {
                    if (scan_expr_heap (fv))
                        return true;
                }
                return false;
            }
            if (e is CallExpr) {
                var ce = (CallExpr) e;
                if (ce.callee == "__planc_host_bytes_to_str"
                    || ce.callee == "__planc_host_read_file"
                    || ce.callee == "__planc_host_write_file")
                    return true;
                foreach (var a in ce.args) {
                    if (scan_expr_heap (a))
                        return true;
                }
                return false;
            }
            return false;
        }

        private bool may_be_string (Expr e) {
            if (e is StringLiteral || e is TemplateExpr)
                return true;
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return b.op == "+" && (may_be_string (b.left) || may_be_string (b.right));
            }
            if (e is VarRef || e is IndexExpr || e is MemberAccessExpr || e is CallExpr) {
                // Conservative: any string-typed function or variable in program.
                // That is a property of the program, computed once.
                return program_has_string_slots || (e is VarRef);
            }
            return false;
        }

        private void check_struct_cycles () throws SemanticError {
            var visiting = new GenericArray<string> ();
            var visited = new GenericArray<string> ();
            foreach (var sd in program.structs) {
                if (sd.is_generic_template)
                    continue;
                visit_struct_cycle (sd, visiting, visited);
            }
        }

        private static bool list_contains (GenericArray<string> list, string name) {
            for (int i = 0; i < list.length; i++) {
                if (list[i] == name)
                    return true;
            }
            return false;
        }

        private void visit_struct_cycle (StructDecl sd,
                                         GenericArray<string> visiting,
                                         GenericArray<string> visited) throws SemanticError {
            if (list_contains (visited, sd.name))
                return;
            if (list_contains (visiting, sd.name))
                throw new SemanticError.TYPE_MISMATCH (
                    @"cyclic struct definition '$(sd.name)' at $(sd.line):$(sd.column)");
            visiting.add (sd.name);
            foreach (var fld in sd.fields) {
                if (sd.is_union && is_ref_type (fld.field_type)) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"union '$(sd.name)' cannot contain reference-counted field '$(fld.name)' at $(fld.line):$(fld.column)");
                }
                if (fld.field_type == ValaType.STRUCT) {
                    unowned var sub = program.find_struct (fld.type_name);
                    if (sub != null) {
                        if (sd.is_union && struct_has_string (sub)) {
                            throw new SemanticError.TYPE_MISMATCH (
                                @"union '$(sd.name)' cannot contain struct with reference-counted fields '$(fld.name)' at $(fld.line):$(fld.column)");
                        }
                        visit_struct_cycle (sub, visiting, visited);
                    }
                }
            }
            visited.add (sd.name);
        }

        private int type_slots (ValaType t, string tname) {
            if (t == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tname);
                if (sd == null)
                    return 1;
                if (sd.is_union) {
                    int max_s = 1;
                    foreach (var fld in sd.fields) {
                        int fs = type_slots (fld.field_type, fld.type_name);
                        if (fs > max_s)
                            max_s = fs;
                    }
                    return max_s;
                }
                int total = 0;
                foreach (var fld in sd.fields)
                    total += type_slots (fld.field_type, fld.type_name);
                return total > 0 ? total : 1;
            }
            return 1;
        }

        // sizeof: every scalar and reference occupies one 8-byte slot in this
        // ABI, and a struct occupies `type_slots` of them.
        private int sizeof_bytes (ValaType t, string tname) {
            if (t == ValaType.VOID)
                return 0;
            if (t == ValaType.STRUCT)
                return 8 * type_slots (ValaType.STRUCT, strip_null (tname));
            return 8;
        }

        private int struct_field_offset_slots (StructDecl sd, string fname, out unowned StructField? found) {            int slot_off = 0;
            foreach (unowned var fld in sd.fields) {
                if (fld.name == fname) {
                    found = fld;
                    return sd.is_union ? 0 : slot_off;
                }
                slot_off += type_slots (fld.field_type, fld.type_name);
            }
            found = null;
            return -1;
        }

        private bool struct_has_string (StructDecl sd) {
            foreach (var fld in sd.fields) {
                if (is_ref_type (fld.field_type))
                    return true;
                if (fld.field_type == ValaType.STRUCT) {
                    unowned var sub = program.find_struct (fld.type_name);
                    if (sub != null && struct_has_string (sub))
                        return true;
                }
            }
            return false;
        }

        private bool struct_has_ref_name (string sname) {
            unowned var sd = program.find_struct (sname);
            return sd != null && struct_has_string (sd);
        }

        private void prepare_value_methods () {
            foreach (var ed in program.enums) {
                foreach (var m in ed.methods) {
                    m.method_name = m.name;
                    m.name = @"$(ed.name)__$(m.name)";
                    if (!m.is_static)
                        prepend_this_param_typed (m, ValaType.ENUM, ed.name, false);
                    program.functions.add (m);
                }
            }
            foreach (var sd in program.structs) {
                if (sd.is_generic_template || sd.is_delegate)
                    continue;
                foreach (var m in sd.methods) {
                    m.method_name = m.name;
                    m.name = @"$(sd.name)__$(m.name)";
                    if (!m.is_static)
                        prepend_this_param_typed (m, ValaType.STRUCT, sd.name, false);
                    program.functions.add (m);
                }
            }
        }

        private void visit_iface_order (InterfaceDecl itf,
                                        GenericArray<string> visiting,
                                        GenericArray<string> visited,
                                        GenericArray<InterfaceDecl> ordered) throws SemanticError {
            if (list_contains (visited, itf.name))
                return;
            if (list_contains (visiting, itf.name))
                throw new SemanticError.TYPE_MISMATCH (
                    @"cyclic interface inheritance involving '$(itf.name)' at $(itf.line):$(itf.column)");
            visiting.add (itf.name);
            foreach (var pname in itf.prereq_names) {
                unowned var p = program.find_interface (pname);
                if (p == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown prerequisite interface '$pname' for '$(itf.name)' at $(itf.line):$(itf.column)");
                visit_iface_order (p, visiting, visited, ordered);
            }
            visited.add (itf.name);
            ordered.add (itf);
        }

        private void prepare_interfaces () throws SemanticError {
            var ordered = new GenericArray<InterfaceDecl> ();
            var visiting = new GenericArray<string> ();
            var visited = new GenericArray<string> ();
            foreach (var itf in program.interfaces) {
                if (itf.is_generic_template)
                    continue;
                visit_iface_order (itf, visiting, visited, ordered);
            }

            foreach (var itf in ordered) {
                for (int mi = 0; mi < itf.methods.length; mi++) {
                    var m = itf.methods[mi];
                    if (m.is_static) {
                        m.name = @"$(itf.name)__$(m.method_name)";
                        program.functions.add (m);
                        continue;
                    }
                    m.iface_id = itf.iface_id;
                    m.iface_slot = mi;
                    m.method_name = m.name;
                    prepend_this_param_typed (m, ValaType.INTERFACE, itf.name, false);
                    if (m.has_body) {
                        m.name = @"$(itf.name)__$(m.method_name)";
                        program.functions.add (m);
                    }
                }
                foreach (var sd in itf.signals) {
                    sd.iface_id = itf.iface_id;
                    sd.iface_name = itf.name;
                    unowned var acc = itf.find_own_method (@"__sigslot_$(sd.name)");
                    if (acc != null)
                        sd.iface_slot = acc.iface_slot;
                }
            }
        }

        // `class P : HasName` with `public string name { get; set; }` stores a
        // plain field, so `get_name`/`set_name` are synthesized to satisfy the
        // interface property.
        private Function? synthesize_iface_property_accessor (ClassDecl cd, Function im) {
            string prop = "";
            bool is_set = false;
            if (im.method_name.has_prefix ("get_") && im.method_name.length > 4) {
                prop = im.method_name.substring (4);
            } else if (im.method_name.has_prefix ("set_") && im.method_name.length > 4) {
                prop = im.method_name.substring (4);
                is_set = true;
            } else {
                return null;
            }
            unowned ClassField? cf = null;
            if (class_field_offset_slots (cd, prop, out cf) < 0 || cf == null)
                return null;

            var f = new Function () {
                name = @"$(cd.name)__$(im.method_name)",
                method_name = im.method_name,
                return_type = is_set ? ValaType.VOID : cf.field_type,
                return_type_name = is_set ? "" : cf.type_name,
                owner_class = cd.name,
                has_body = true,
                line = cd.line,
                column = cd.column
            };
            var this_p = new Param () {
                param_type = ValaType.CLASS,
                type_name = cd.name,
                name = "this",
                unmanaged = true,
                line = cd.line,
                column = cd.column
            };
            f.params.add (this_p);
            if (is_set) {
                f.params.add (new Param () {
                    param_type = cf.field_type,
                    type_name = cf.type_name,
                    name = "value",
                    line = cd.line,
                    column = cd.column
                });
                f.body.add (new AssignStatement () {
                    name = prop,
                    value = new VarRef () { name = "value", line = cd.line, column = cd.column },
                    line = cd.line,
                    column = cd.column
                });
            } else {
                f.body.add (new ReturnStatement () {
                    value = new VarRef () { name = prop, line = cd.line, column = cd.column },
                    line = cd.line,
                    column = cd.column
                });
            }
            cd.methods.add (f);
            program.functions.add (f);
            return f;
        }

        // An interface signal's slot depends on the concrete class, so each
        // implementor answers `__sigslot_<name> ()` with its own index.
        private Function synthesize_signal_slot_accessor (ClassDecl cd, Function iface_m, int slot) {
            var f = new Function () {
                name = @"$(cd.name)____ifacesig_$(iface_m.method_name)",
                method_name = iface_m.method_name,
                return_type = ValaType.INT,
                owner_class = cd.name,
                has_body = true,
                line = iface_m.line,
                column = iface_m.column
            };
            f.params.add (new Param () {
                param_type = ValaType.CLASS,
                type_name = cd.name,
                name = "this",
                unmanaged = true,
                line = iface_m.line,
                column = iface_m.column
            });
            f.body.add (new ReturnStatement () {
                value = new IntLiteral () { value = slot },
                line = iface_m.line,
                column = iface_m.column
            });
            cd.methods.add (f);
            program.functions.add (f);
            return f;
        }

        private void collect_iface_closure (string iname, GenericArray<string> dst) {            if (list_contains (dst, iname))
                return;
            unowned var itf = program.find_interface (iname);
            if (itf == null)
                return;
            foreach (var pn in itf.prereq_names)
                collect_iface_closure (pn, dst);
            dst.add (iname);
        }

        private void collect_class_interfaces (ClassDecl cd, GenericArray<string> dst) {
            if (cd.base_name != "") {
                unowned var b = program.find_class (cd.base_name);
                if (b != null)
                    collect_class_interfaces (b, dst);
            }
            foreach (var iname in cd.iface_names)
                collect_iface_closure (iname, dst);
        }

        private unowned Function? find_interface_method (InterfaceDecl itf, string mname) {
            unowned var own = itf.find_own_method (mname);
            if (own != null)
                return own;
            foreach (var pn in itf.prereq_names) {
                unowned var p = program.find_interface (pn);
                if (p != null) {
                    unowned var res = find_interface_method (p, mname);
                    if (res != null)
                        return res;
                }
            }
            return null;
        }

        private bool class_implements_iface (ClassDecl cd, string iface_name) {
            var all = new GenericArray<string> ();
            collect_class_interfaces (cd, all);
            return list_contains (all, iface_name);
        }

        private bool iface_inherits_from (InterfaceDecl sub, string target_iface) {
            if (sub.name == target_iface)
                return true;
            foreach (var pn in sub.prereq_names) {
                unowned var p = program.find_interface (pn);
                if (p != null && iface_inherits_from (p, target_iface))
                    return true;
            }
            return false;
        }

        private void check_iface_impl_signature (ClassDecl cd, Function impl, Function iface_m)
                throws SemanticError {
            if (impl.is_static)
                throw new SemanticError.TYPE_MISMATCH (
                    @"static method '$(cd.name).$(impl.method_name)' cannot implement interface method at $(impl.line):$(impl.column)");
            if (impl.params.length != iface_m.params.length)
                throw new SemanticError.WRONG_ARG_COUNT (
                    @"method '$(cd.name).$(impl.method_name)' parameter count does not match interface '$(iface_m.owner_class).$(iface_m.method_name)' at $(impl.line):$(impl.column)");
            if (impl.return_type != iface_m.return_type || impl.return_type_name != iface_m.return_type_name)
                throw new SemanticError.TYPE_MISMATCH (
                    @"method '$(cd.name).$(impl.method_name)' return type does not match interface '$(iface_m.owner_class).$(iface_m.method_name)' at $(impl.line):$(impl.column)");
            for (int i = 1; i < impl.params.length; i++) {
                var ip = impl.params[i];
                var fp = iface_m.params[i];
                if (ip.param_type != fp.param_type || ip.type_name != fp.type_name
                    || ip.is_ref != fp.is_ref || ip.is_out != fp.is_out) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"method '$(cd.name).$(impl.method_name)' parameter $i does not match interface at $(ip.line):$(ip.column)");
                }
            }
            foreach (var ddom in impl.throws_domains) {
                bool found = false;
                foreach (var bdom in iface_m.throws_domains) {
                    if (ddom == bdom || bdom == "Error") {
                        found = true;
                        break;
                    }
                }
                if (!found)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"method '$(cd.name).$(impl.method_name)' throws '$(ddom)' not declared on interface method at $(impl.line):$(impl.column)");
            }
        }

        private void prepare_classes () throws SemanticError {
            if (program.classes.length == 0)
                return;

            var ordered = new GenericArray<ClassDecl> ();
            var visiting = new GenericArray<string> ();
            var visited = new GenericArray<string> ();
            foreach (var cd in program.classes) {
                if (cd.is_generic_template)
                    continue;
                visit_class_order (cd, visiting, visited, ordered);
            }

            foreach (var cd in ordered) {
                unowned ClassDecl? base_cd = (cd.base_name != "") ? program.find_class (cd.base_name) : null;
                cd.needs_finalizer = true;

                foreach (var fld in cd.fields) {
                    if (fld.is_static)
                        continue;
                    if (base_cd != null) {
                        unowned ClassField? dummy = null;
                        if (class_field_offset_slots (base_cd, fld.name, out dummy) >= 0)
                            throw new SemanticError.DUPLICATE_VARIABLE (
                                @"field '$(cd.name).$(fld.name)' shadows inherited field at $(fld.line):$(fld.column)");
                    }
                    if (is_ref_type (fld.field_type)
                        || (fld.field_type == ValaType.STRUCT && struct_has_ref_name (fld.type_name))) {
                        cd.needs_finalizer = true;
                    }
                }
                // A compact object has no vtable, so it cannot be finalized:
                // `free ()` releases its fields instead.
                if (cd.is_compact)
                    cd.needs_finalizer = false;

                // Signals declared on an implemented interface get a hidden slot
                // field on this class, like a signal declared here.
                var sig_ifaces = new GenericArray<string> ();
                collect_class_interfaces (cd, sig_ifaces);
                foreach (var iname in sig_ifaces) {
                    unowned var sitf = program.find_interface (iname);
                    if (sitf == null || sitf.signals.length == 0)
                        continue;
                    foreach (var isd in sitf.signals) {
                        if (find_class_signal (cd, isd.name) != null)
                            continue;
                        var nsd = new SignalDecl () {
                            name = isd.name,
                            return_type = isd.return_type,
                            return_type_name = isd.return_type_name,
                            handler_delegate_name = isd.handler_delegate_name,
                            iface_name = iname,
                            iface_id = isd.iface_id,
                            iface_slot = isd.iface_slot,
                            line = isd.line,
                            column = isd.column
                        };
                        foreach (var p in isd.params)
                            nsd.params.add (p);
                        cd.signals.add (nsd);
                    }
                }

                foreach (var sd in cd.signals) {
                    if (base_cd != null && find_class_signal (base_cd, sd.name) != null)
                        throw new SemanticError.DUPLICATE_VARIABLE (
                            @"signal '$(cd.name).$(sd.name)' shadows inherited signal at $(sd.line):$(sd.column)");
                    cd.needs_finalizer = true;
                    need_signal = true;
                    var sf = new ClassField () {
                        field_type = ValaType.INT,
                        type_name = "",
                        name = @"#sig_$(sd.name)",
                        line = sd.line,
                        column = sd.column
                    };
                    cd.fields.add (sf);
                    unowned ClassField? dummy_sf = null;
                    sd.slot_index = class_field_offset_slots (cd, sf.name, out dummy_sf);
                    if (sd.default_handler != null)
                        program.functions.add (sd.default_handler);
                }

                if (base_cd != null) {
                    for (int i = 0; i < base_cd.vtable_method_names.length; i++) {
                        cd.vtable_method_names.add (base_cd.vtable_method_names[i]);
                        cd.vtable_impl_symbols.add (base_cd.vtable_impl_symbols[i]);
                    }
                }

                foreach (var m in cd.methods) {
                    unowned Function? base_m = (!m.is_static && base_cd != null) ? find_class_method (base_cd, m.name) : null;
                    var impl_sym = @"$(cd.name)__$(m.name)";
                    if (m.is_static) {
                        if (base_m != null)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"static method '$(cd.name).$(m.name)' hides inherited member at $(m.line):$(m.column)");
                        m.method_name = m.name;
                        m.name = impl_sym;
                        program.functions.add (m);
                        continue;
                    }
                    if (m.is_override) {
                        if (base_m == null || base_m.vtable_slot < 0)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"method '$(cd.name).$(m.name)' does not override a virtual or abstract method at $(m.line):$(m.column)");
                        check_override_signature (cd.name, m, base_m);
                        m.vtable_slot = base_m.vtable_slot;
                        cd.vtable_impl_symbols[m.vtable_slot] = impl_sym;
                    } else {
                        if (base_m != null)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"method '$(cd.name).$(m.name)' hides inherited method without 'override' at $(m.line):$(m.column)");
                        if (m.is_virtual || m.is_abstract) {
                            int slot = cd.vtable_method_names.length;
                            cd.vtable_method_names.add (m.name);
                            cd.vtable_impl_symbols.add (m.is_abstract ? "" : impl_sym);
                            m.vtable_slot = slot;
                        }
                    }

                    m.method_name = m.name;
                    m.name = impl_sym;
                    prepend_this_param (m, cd.name, false);
                    if (!m.is_abstract)
                        program.functions.add (m);
                }

                if (!cd.is_abstract) {
                    for (int s = 0; s < cd.vtable_method_names.length; s++) {
                        if (cd.vtable_impl_symbols[s] == "")
                            throw new SemanticError.TYPE_MISMATCH (
                                @"class '$(cd.name)' must implement abstract method '$(cd.vtable_method_names[s])' at $(cd.line):$(cd.column)");
                    }
                }

                // Constructor validation and synthesis.
                unowned Function? anc_ctor = (base_cd != null) ? find_class_ctor (base_cd) : null;
                if (cd.ctor == null) {
                    if (anc_ctor != null) {
                        int anc_user_params = anc_ctor.params.length - 1;
                        if (anc_user_params > 0 && !cd.is_abstract)
                            throw new SemanticError.WRONG_ARG_COUNT (
                                @"class '$(cd.name)' must define a constructor calling 'base(...)' at $(cd.line):$(cd.column)");
                        if (anc_user_params == 0) {
                            var syn = new Function () {
                                name = @"$(cd.name)____ctor",
                                return_type = ValaType.VOID,
                                is_ctor = true,
                                has_base_call = true,
                                owner_class = cd.name,
                                line = cd.line,
                                column = cd.column
                            };
                            prepend_this_param (syn, cd.name, true);
                            cd.ctor = syn;
                            program.functions.add (syn);
                        }
                    }
                } else {
                    if (anc_ctor != null && !cd.ctor.has_this_call) {
                        int anc_user_params = anc_ctor.params.length - 1;
                        if (!cd.ctor.has_base_call) {
                            if (anc_user_params == 0)
                                cd.ctor.has_base_call = true;
                            else
                                throw new SemanticError.WRONG_ARG_COUNT (
                                    @"constructor '$(cd.name)' must call ': base(...)' with $(anc_user_params) argument(s) at $(cd.ctor.line):$(cd.ctor.column)");
                        }
                    } else if (!cd.ctor.has_this_call && cd.ctor.has_base_call && cd.ctor.base_args.length > 0) {
                        throw new SemanticError.WRONG_ARG_COUNT (
                            @"base class of '$(cd.name)' has no constructor taking $(cd.ctor.base_args.length) argument(s) at $(cd.ctor.line):$(cd.ctor.column)");
                    }
                    cd.ctor.name = @"$(cd.name)____ctor";
                    prepend_this_param (cd.ctor, cd.name, true);
                    program.functions.add (cd.ctor);
                }

                foreach (var nc in cd.named_ctors) {
                    if (anc_ctor != null && !nc.has_this_call) {
                        int anc_user_params = anc_ctor.params.length - 1;
                        if (!nc.has_base_call) {
                            if (anc_user_params == 0)
                                nc.has_base_call = true;
                            else
                                throw new SemanticError.WRONG_ARG_COUNT (
                                    @"constructor '$(cd.name).$(nc.ctor_subname)' must call ': base(...)' with $(anc_user_params) argument(s) at $(nc.line):$(nc.column)");
                        }
                    } else if (!nc.has_this_call && nc.has_base_call && nc.base_args.length > 0) {
                        throw new SemanticError.WRONG_ARG_COUNT (
                            @"base class of '$(cd.name)' has no constructor taking $(nc.base_args.length) argument(s) at $(nc.line):$(nc.column)");
                    }
                    nc.name = @"$(cd.name)____ctor_$(nc.ctor_subname)";
                    prepend_this_param (nc, cd.name, true);
                    program.functions.add (nc);
                }

                // Interface method resolution and .rodata itable emission.
                var all_ifaces = new GenericArray<string> ();
                collect_class_interfaces (cd, all_ifaces);
                if (all_ifaces.length > 0) {
                    var iface_ids = new GenericArray<int> ();
                    var mtable_offs = new GenericArray<int> ();
                    foreach (var iname in all_ifaces) {
                        unowned var itf = program.find_interface (iname);
                        if (itf == null)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"unknown interface '$iname' on class '$(cd.name)' at $(cd.line):$(cd.column)");
                        var impl_syms = new GenericArray<string> ();
                        foreach (var im in itf.methods) {
                            if (im.is_static) {
                                impl_syms.add ("");
                                continue;
                            }
                            unowned var impl_m = find_class_method (cd, im.method_name);
                            if (impl_m == null) {
                                if (im.has_body) {
                                    impl_syms.add (im.name);
                                } else if (!cd.is_abstract) {
                                    if (im.method_name.has_prefix ("__sigslot_")) {
                                        unowned var isig = find_class_signal (cd, im.method_name.substring (10));
                                        if (isig != null && isig.slot_index >= 0) {
                                            impl_syms.add (synthesize_signal_slot_accessor (cd, im, isig.slot_index).name);
                                            continue;
                                        }
                                    }
                                    // An auto-property is a plain field, so the
                                    // interface accessors are synthesized on demand.
                                    var syn_acc = synthesize_iface_property_accessor (cd, im);
                                    if (syn_acc != null) {
                                        impl_syms.add (syn_acc.name);
                                    } else {
                                        throw new SemanticError.TYPE_MISMATCH (
                                            @"class '$(cd.name)' does not implement interface method '$(itf.name).$(im.method_name)' at $(cd.line):$(cd.column)");
                                    }
                                } else {
                                    impl_syms.add ("");
                                }
                            } else if (impl_m.is_abstract) {
                                if (!cd.is_abstract)
                                    throw new SemanticError.TYPE_MISMATCH (
                                        @"class '$(cd.name)' must implement abstract method '$(impl_m.method_name)' at $(cd.line):$(cd.column)");
                                impl_syms.add ("");
                            } else {
                                check_iface_impl_signature (cd, impl_m, im);
                                impl_syms.add (impl_m.name);
                            }
                        }
                        int mt_off = emitter.align_rodata_8 ();
                        for (int mi = 0; mi < impl_syms.length; mi++) {
                            if (impl_syms[mi] != "")
                                emitter.add_rodata_text_ptr (impl_syms[mi]);
                            else
                                emitter.add_rodata_u64 (0);
                        }
                        if (impl_syms.length == 0)
                            emitter.add_rodata_u64 (0);
                        iface_ids.add (itf.iface_id);
                        mtable_offs.add (mt_off);
                    }
                    cd.itable_rodata_offset = emitter.align_rodata_8 ();
                    for (int ii = 0; ii < iface_ids.length; ii++) {
                        emitter.add_rodata_u64 ((uint64) iface_ids[ii]);
                        emitter.add_rodata_rodata_ptr (mtable_offs[ii]);
                    }
                    emitter.add_rodata_u64 (0);
                    emitter.add_rodata_u64 (0);
                }

                // Emit .rodata vtable: [ +0 finalizer, +8 parent_vtable, +16 itable, +24+8k methods ].
                cd.vtable_rodata_offset = emitter.align_rodata_8 ();
                if (cd.needs_finalizer)
                    emitter.add_rodata_text_ptr (@"__planc_dtor_$(cd.name)");
                else
                    emitter.add_rodata_u64 (0);
                if (base_cd != null)
                    emitter.add_rodata_rodata_ptr (base_cd.vtable_rodata_offset);
                else
                    emitter.add_rodata_u64 (0);
                if (cd.itable_rodata_offset >= 0)
                    emitter.add_rodata_rodata_ptr (cd.itable_rodata_offset);
                else
                    emitter.add_rodata_u64 (0);
                for (int s = 0; s < cd.vtable_impl_symbols.length; s++) {
                    if (cd.vtable_impl_symbols[s] != "")
                        emitter.add_rodata_text_ptr (cd.vtable_impl_symbols[s]);
                    else
                        emitter.add_rodata_u64 (0);
                }

                // Synthesize field initializer function __planc_init_<Class>.
                var init_fn = new Function () {
                    name = @"__planc_init_$(cd.name)",
                    return_type = ValaType.VOID,
                    is_ctor = true,
                    owner_class = cd.name,
                    line = cd.line,
                    column = cd.column
                };
                prepend_this_param (init_fn, cd.name, true);
                // The builtin root has nothing to initialize, so chaining into
                // it would be one wasted call per constructed object.
                bool base_init_needed = base_cd != null && !is_bare_object (base_cd);
                if (base_init_needed) {
                    var bc = new CallExpr () { callee = @"__planc_init_$(base_cd.name)" };
                    var tv = new VarRef () { name = "this", line = cd.line, column = cd.column };
                    bc.args.add (tv);
                    bc.line = cd.line;
                    bc.column = cd.column;
                    var es = new ExprStatement () { expr = bc, line = cd.line, column = cd.column };
                    init_fn.body.add (es);
                }
                foreach (var fld in cd.fields) {
                    if (fld.is_static)
                        continue;
                    Expr? fval = fld.init;
                    if (fval == null && fld.field_type == ValaType.STRING && !is_nullable_type (fld.field_type, fld.type_name)) {
                        fval = new StringLiteral () { value = "", line = fld.line, column = fld.column };
                    } else if (fval == null && fld.field_type == ValaType.STRUCT) {
                        fval = new StructLiteral () { struct_name = fld.type_name, line = fld.line, column = fld.column };
                    }
                    if (fval != null) {
                        var tv = new VarRef () { name = "this", line = fld.line, column = fld.column };
                        var fa = new FieldAssignStatement () {
                            target = tv,
                            field_name = fld.name,
                            op = "=",
                            value = fval,
                            line = fld.line,
                            column = fld.column
                        };
                        init_fn.body.add (fa);
                    }
                }
                program.functions.add (init_fn);

                if (cd.dtor != null) {
                    cd.dtor.name = @"$(cd.name)____dtor";
                    prepend_this_param (cd.dtor, cd.name, true);
                    program.functions.add (cd.dtor);
                }
                if (cd.needs_finalizer) {
                    var dtor_wrap = new Function () {
                        name = @"__planc_dtor_$(cd.name)",
                        return_type = ValaType.VOID,
                        is_dtor = true,
                        owner_class = cd.name,
                        line = cd.line,
                        column = cd.column
                    };
                    prepend_this_param (dtor_wrap, cd.name, true);
                    program.functions.add (dtor_wrap);
                }
                if (cd.is_compact && cd.find_own_method ("free") == null) {
                    // Manual lifetime: `free ()` releases the fields and hands
                    // the block back to the allocator.
                    var fr = new Function () {
                        name = @"$(cd.name)____free",
                        method_name = "free",
                        return_type = ValaType.VOID,
                        owner_class = cd.name,
                        is_compact_free = true,
                        line = cd.line,
                        column = cd.column
                    };
                    prepend_this_param (fr, cd.name, true);
                    cd.methods.add (fr);
                    program.functions.add (fr);
                }
            }
        }

        private void visit_class_order (ClassDecl cd,
                                        GenericArray<string> visiting,
                                        GenericArray<string> visited,
                                        GenericArray<ClassDecl> ordered) throws SemanticError {
            if (list_contains (visited, cd.name))
                return;
            if (list_contains (visiting, cd.name))
                throw new SemanticError.TYPE_MISMATCH (
                    @"cyclic class inheritance involving '$(cd.name)' at $(cd.line):$(cd.column)");
            visiting.add (cd.name);
            if (cd.base_name != "") {
                unowned var b = program.find_class (cd.base_name);
                if (b == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown base class '$(cd.base_name)' for '$(cd.name)' at $(cd.line):$(cd.column)");
                if (b.is_sealed)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"cannot inherit from sealed class '$(b.name)' at $(cd.line):$(cd.column)");
                visit_class_order (b, visiting, visited, ordered);
            }
            visited.add (cd.name);
            ordered.add (cd);
        }

        private static void prepend_this_param (Function f, string cname, bool unmanaged) {
            prepend_this_param_typed (f, ValaType.CLASS, cname, unmanaged);
        }

        private static void prepend_this_param_typed (Function f, ValaType ptype, string tname, bool unmanaged) {
            var orig = new GenericArray<Param> ();
            foreach (var p in f.params)
                orig.add (p);
            while (f.params.length > 0)
                f.params.remove_index (f.params.length - 1);
            f.params.add (new Param () {
                param_type = ptype,
                type_name = tname,
                name = "this",
                unmanaged = unmanaged,
                line = f.line,
                column = f.column
            });
            foreach (var p in orig)
                f.params.add (p);
        }

        private void check_override_signature (string cname, Function derived, Function base_m)
                throws SemanticError {
            int base_user_params = base_m.params.length - 1;
            if (derived.params.length != base_user_params)
                throw new SemanticError.TYPE_MISMATCH (
                    @"override '$(cname).$(derived.name)' parameter count does not match base at $(derived.line):$(derived.column)");
            if (derived.return_type != base_m.return_type || derived.return_type_name != base_m.return_type_name)
                throw new SemanticError.TYPE_MISMATCH (
                    @"override '$(cname).$(derived.name)' return type does not match base at $(derived.line):$(derived.column)");
            for (int i = 0; i < derived.params.length; i++) {
                var dp = derived.params[i];
                var bp = base_m.params[i + 1];
                if (dp.param_type != bp.param_type || dp.type_name != bp.type_name
                    || dp.is_ref != bp.is_ref || dp.is_out != bp.is_out) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"override '$(cname).$(derived.name)' parameter $(i + 1) type mismatch at $(dp.line):$(dp.column)");
                }
            }
            foreach (var ddom in derived.throws_domains) {
                bool found = false;
                foreach (var bdom in base_m.throws_domains) {
                    if (ddom == bdom || bdom == "Error") {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"override '$(cname).$(derived.name)' throws '$(ddom)' not thrown by base at $(derived.line):$(derived.column)");
                }
            }
        }

        private unowned Function? find_class_ctor (ClassDecl? cd) {
            unowned ClassDecl? cur = cd;
            while (cur != null) {
                if (cur.ctor != null)
                    return cur.ctor;
                cur = (cur.base_name != "") ? program.find_class (cur.base_name) : null;
            }
            return null;
        }

        private unowned Function? find_class_method (ClassDecl? cd, string mname) {
            if (cd == null)
                return null;
            unowned ClassDecl? cur = cd;
            while (cur != null) {
                unowned var m2 = cur.find_own_method (mname);
                if (m2 != null)
                    return m2;
                cur = (cur.base_name != "") ? program.find_class (cur.base_name) : null;
            }
            return null;
        }

        // The builtin root: `Object` with no fields, no signals and no user
        // destructor. Chaining into it costs a call and does nothing.
        private static bool is_bare_object (ClassDecl cd) {
            return cd.name == "Object" && cd.base_name == ""
                && cd.fields.length == 0 && cd.signals.length == 0 && cd.dtor == null;
        }

        private static bool has_weak_slot (ClassDecl cd) {
            if (cd.is_compact)
                return false;
            return !cd.name.has_prefix ("GenericArray__") && !cd.name.has_prefix ("Channel__");
        }

        // Compact instances have no vtable and no refcount, so their fields
        // start right after the 8-byte allocator word instead of after the
        // 16-byte object header.
        private static int class_field_base (ClassDecl? cd) {
            if (cd == null)
                return 16;
            return cd.is_compact ? 8 : 16;
        }

        private int class_total_field_slots (ClassDecl cd) {
            int n = has_weak_slot (cd) ? 1 : 0; // slot 0 on root class is reserved for __planc_weak_box
            if (cd.base_name != "") {
                unowned var b = program.find_class (cd.base_name);
                if (b != null)
                    n = class_total_field_slots (b);
            }
            foreach (var fld in cd.fields)
                if (!fld.is_static)
                    n += type_slots (fld.field_type, fld.type_name);
            return n;
        }

        private int class_field_offset_slots (ClassDecl cd, string fname, out unowned ClassField? found) {
            int base_off = has_weak_slot (cd) ? 1 : 0; // slot 0 on root class is reserved for __planc_weak_box
            if (cd.base_name != "") {
                unowned var b = program.find_class (cd.base_name);
                if (b != null) {
                    var res = class_field_offset_slots (b, fname, out found);
                    if (res >= 0)
                        return res;
                    base_off = class_total_field_slots (b);
                }
            }
            int off = base_off;
            foreach (unowned var fld in cd.fields) {
                if (fld.is_static)
                    continue;
                if (fld.name == fname) {
                    found = fld;
                    return off;
                }
                off += type_slots (fld.field_type, fld.type_name);
            }
            found = null;
            return -1;
        }

        // The class that declares the static field `fname` in this hierarchy.
        private unowned ClassDecl? static_field_owner (ClassDecl cd, string fname) {
            unowned ClassDecl? cur = cd;
            while (cur != null) {
                unowned var fld = cur.find_own_field (fname);
                if (fld != null && fld.is_static)
                    return cur;
                cur = (cur.base_name != "") ? program.find_class (cur.base_name) : null;
            }
            return null;
        }

        private int static_field_global_of_type (string tname, string fname) {
            unowned var cd = program.find_class (strip_null (tname));
            if (cd == null)
                return -1;
            unowned var owner = static_field_owner (cd, fname);
            if (owner == null)
                return -1;
            return lookup_global (@"$(owner.name).$(fname)");
        }

        private int static_field_global_of_this_class (string fname) {
            if (current_class == null)
                return -1;
            unowned var owner = static_field_owner (current_class, fname);
            if (owner == null)
                return -1;
            return lookup_global (@"$(owner.name).$(fname)");
        }

        private bool is_subclass_of (string child_name, string ancestor_name) {            unowned ClassDecl? cur = program.find_class (child_name);
            while (cur != null) {
                if (cur.name == ancestor_name)
                    return true;
                cur = (cur.base_name != "") ? program.find_class (cur.base_name) : null;
            }
            return false;
        }

        private unowned ClassDecl? common_ancestor_class (string a_name, string b_name) {
            unowned ClassDecl? cur = program.find_class (a_name);
            while (cur != null) {
                if (is_subclass_of (b_name, cur.name))
                    return cur;
                cur = (cur.base_name != "") ? program.find_class (cur.base_name) : null;
            }
            return null;
        }

        private void patch_struct_strings_in_data (StructDecl sd, int base_offset, int empty_str_off) {
            int off = 0;
            foreach (var fld in sd.fields) {
                if (fld.field_type == ValaType.STRING) {
                    emitter.add_data_patch (base_offset + off, empty_str_off);
                    off += 8;
                } else if (fld.field_type == ValaType.STRUCT) {
                    unowned var sub = program.find_struct (fld.type_name);
                    if (sub != null)
                        patch_struct_strings_in_data (sub, base_offset + off, empty_str_off);
                    off += 8 * type_slots (fld.field_type, fld.type_name);
                } else {
                    off += 8;
                }
            }
        }

        // A `static` class field is one variable per class, so it is stored as a
        // global named `Class.field` and every access resolves through the
        // ordinary global machinery.
        private void synthesize_static_field_globals () throws SemanticError {
            foreach (var cd in program.classes) {
                foreach (var fld in cd.fields) {
                    if (!fld.is_static)
                        continue;
                    var gname = @"$(cd.name).$(fld.name)";
                    bool exists = false;
                    foreach (var gv in program.globals) {
                        if (gv.name == gname) {
                            exists = true;
                            break;
                        }
                    }
                    if (exists)
                        continue;
                    var g = new GlobalVar () {
                        var_type = fld.field_type,
                        var_type_name = fld.type_name,
                        name = gname,
                        line = fld.line,
                        column = fld.column
                    };
                    var init = fld.init;
                    if (init != null) {
                        if (init is IntLiteral) {
                            g.value = ((IntLiteral) init).value;
                            g.initialized = true;
                        } else if (init is FloatLiteral) {
                            g.value = (int64) ((FloatLiteral) init).bits;
                            g.initialized = true;
                        } else if (init is BoolLiteral) {
                            g.value = ((BoolLiteral) init).value ? 1 : 0;
                            g.initialized = true;
                        } else if (init is StringLiteral) {
                            g.str_value = ((StringLiteral) init).value;
                            g.initialized = true;
                        } else {
                            throw new SemanticError.TYPE_MISMATCH (
                                @"static field '$(cd.name).$(fld.name)' must be initialized with a literal at $(fld.line):$(fld.column)");
                        }
                    }
                    program.globals.add (g);
                }
            }
        }

        private void register_globals () {
            foreach (var g in program.globals) {
                global_names.add (g.name);
                global_types.add (g.var_type);
                global_type_names.add (g.var_type_name);
                if (g.var_type == ValaType.STRING) {
                    var str_off = emitter.add_string (g.initialized ? g.str_value : "");
                    var offset = emitter.add_string_global (str_off);
                    global_offsets.add (offset);
                    global_spaces.add (PatchSpace.DATA);
                } else if (g.var_type == ValaType.STRUCT) {
                    unowned var sd = program.find_struct (g.var_type_name);
                    var nbytes = 8 * type_slots (ValaType.STRUCT, g.var_type_name);
                    if (sd != null && struct_has_string (sd)) {
                        var offset = emitter.add_data_bytes (nbytes);
                        patch_struct_strings_in_data (sd, offset, emitter.add_string (""));
                        global_offsets.add (offset);
                        global_spaces.add (PatchSpace.DATA);
                    } else {
                        var offset = emitter.add_bss_bytes (nbytes);
                        global_offsets.add (offset);
                        global_spaces.add (PatchSpace.BSS);
                    }
                } else {
                    int64 gval = g.value;
                    if (g.var_type == ValaType.INT && g.initialized)
                        gval = narrow_const_int (g.var_type_name, gval);
                    var offset = emitter.add_global (gval, g.initialized);
                    global_offsets.add (offset);
                    global_spaces.add (g.initialized ? PatchSpace.DATA : PatchSpace.BSS);
                }
            }
        }

        private void emit_runtime () {
            if (need_str_concat || need_int_to_str || need_uint_to_str || need_double_to_str || need_str_slice
                || need_bytes_to_str || need_read_file || need_write_file) {
                need_alloc = true;
                need_mem_panic = true;
            }
            if (need_read_file)
                need_unref = true;
            if (need_str_slice && bounds_check)
                need_bounds_panic = true;
            if (need_alloc || need_ref || need_unref || need_compact_free)
                need_mem_panic = true;

            int io_err_msg_off = -1;
            int file_err_dom = 1;
            if (need_read_file || need_write_file) {
                io_err_msg_off = emitter.add_string ("io error");
                unowned var fed = program.find_error_domain ("FileError");
                if (fed != null)
                    file_err_dom = fed.domain_id;
            }

            if (need_write_str) {
                var start = emitter.here ();
                emitter.emit_rt_write_str (freestanding, target_planetos);
                symbols.add (new Symbol ("__planc_write_str", start, emitter.here () - start));
            }
            if (need_str_eq) {
                var start = emitter.here ();
                emitter.emit_rt_str_eq ();
                symbols.add (new Symbol ("__planc_str_eq", start, emitter.here () - start));
            }
            if (need_write_int) {
                var start = emitter.here ();
                emitter.emit_rt_write_int (freestanding, target_planetos);
                symbols.add (new Symbol ("__planc_write_int", start, emitter.here () - start));
            }
            if (need_write_uint) {
                var start = emitter.here ();
                emitter.emit_rt_write_uint (freestanding, target_planetos);
                symbols.add (new Symbol ("__planc_write_uint", start, emitter.here () - start));
            }
            if (need_alloc || need_ref || need_unref) {
                var start_alloc = emitter.here ();
                emitter.emit_rt_alloc (alloc_bss_offset, mem_panic_label, freestanding_heap_off, target_planetos);
                symbols.add (new Symbol ("__planc_alloc", start_alloc, emitter.here () - start_alloc));

                var start_ref = emitter.here ();
                emitter.emit_rt_ref (mem_panic_label);
                symbols.add (new Symbol ("__planc_ref", start_ref, emitter.here () - start_ref));

                var start_unref = emitter.here ();
                emitter.emit_rt_unref (alloc_bss_offset, mem_panic_label);
                symbols.add (new Symbol ("__planc_unref", start_unref, emitter.here () - start_unref));

                emitter.emit_rt_weak (symbols);
            }
            if (need_async) {
                emitter.emit_rt_async (async_bss_offset, symbols);
            }
            if (need_signal) {
                emitter.emit_rt_signal (sig_bss_offset, symbols);
            }
            if (need_sync) {
                emitter.emit_rt_sync (symbols);
            }
            if (need_str_concat) {
                var start = emitter.here ();
                emitter.emit_rt_str_concat ();
                symbols.add (new Symbol ("__planc_str_concat", start, emitter.here () - start));
            }
            if (need_str_slice) {
                var start = emitter.here ();
                emitter.emit_rt_str_slice (emitter.add_string (""), bounds_check, bounds_panic_label);
                symbols.add (new Symbol ("__planc_str_slice", start, emitter.here () - start));
            }
            if (need_int_to_str) {
                var start = emitter.here ();
                emitter.emit_rt_int_to_str ();
                symbols.add (new Symbol ("__planc_int_to_str", start, emitter.here () - start));
            }
            if (need_uint_to_str) {
                var start = emitter.here ();
                emitter.emit_rt_uint_to_str ();
                symbols.add (new Symbol ("__planc_uint_to_str", start, emitter.here () - start));
            }
            if (need_is_instance) {
                var start = emitter.here ();
                emitter.emit_rt_is_instance ();
                symbols.add (new Symbol ("__planc_is_instance", start, emitter.here () - start));
            }
            if (need_iface_lookup) {
                var start = emitter.here ();
                emitter.emit_rt_iface_lookup ();
                symbols.add (new Symbol ("__planc_iface_lookup", start, emitter.here () - start));
            }
            if (need_lock) {
                var s_slot = emitter.here ();
                emitter.emit_rt_lock_slot (lock_bss_offset);
                symbols.add (new Symbol ("__planc_lock_slot", s_slot, emitter.here () - s_slot));
                var s_acq = emitter.here ();
                emitter.emit_rt_lock_acquire (lock_bss_offset);
                symbols.add (new Symbol ("__planc_lock_acquire", s_acq, emitter.here () - s_acq));
                var s_rel = emitter.here ();
                emitter.emit_rt_lock_release (lock_bss_offset);
                symbols.add (new Symbol ("__planc_lock_release", s_rel, emitter.here () - s_rel));
            }
            if (need_compact_free) {
                var s_cf = emitter.here ();
                emitter.emit_rt_compact_free (mem_panic_label);
                symbols.add (new Symbol ("__planc_compact_free", s_cf, emitter.here () - s_cf));
            }
            if (need_build_args) {
                var start = emitter.here ();
                emitter.emit_rt_build_args ();
                symbols.add (new Symbol ("__planc_build_args", start, emitter.here () - start));
            }
            if (need_str_has_prefix) {
                var start = emitter.here ();
                emitter.emit_rt_str_has_prefix ();
                symbols.add (new Symbol ("__planc_str_has_prefix", start, emitter.here () - start));
            }
            if (need_str_has_suffix) {
                var start = emitter.here ();
                emitter.emit_rt_str_has_suffix ();
                symbols.add (new Symbol ("__planc_str_has_suffix", start, emitter.here () - start));
            }
            if (need_utf8_char_count) {
                var start = emitter.here ();
                emitter.emit_rt_utf8_char_count ();
                symbols.add (new Symbol ("__planc_utf8_char_count", start, emitter.here () - start));
            }
            if (need_utf8_get_char) {
                var start = emitter.here ();
                emitter.emit_rt_utf8_get_char ();
                symbols.add (new Symbol ("__planc_utf8_get_char", start, emitter.here () - start));
            }
            if (need_utf8_validate) {
                var start = emitter.here ();
                emitter.emit_rt_utf8_validate ();
                symbols.add (new Symbol ("__planc_utf8_validate", start, emitter.here () - start));
            }
            if (need_str_index_of) {
                var start = emitter.here ();
                emitter.emit_rt_str_index_of ();
                symbols.add (new Symbol ("__planc_str_index_of", start, emitter.here () - start));
            }
            if (need_str_to_int) {
                var start = emitter.here ();
                emitter.emit_rt_str_to_int ();
                symbols.add (new Symbol ("__planc_str_to_int", start, emitter.here () - start));
            }
            if (need_double_to_str) {
                var start = emitter.here ();
                emitter.emit_rt_double_to_str ();
                symbols.add (new Symbol ("__planc_double_to_str", start, emitter.here () - start));
            }
            if (need_str_to_double) {
                var start = emitter.here ();
                emitter.emit_rt_str_to_double ();
                symbols.add (new Symbol ("__planc_str_to_double", start, emitter.here () - start));
            }
            if (need_bytes_to_str) {
                var start = emitter.here ();
                emitter.emit_rt_bytes_to_str ();
                symbols.add (new Symbol ("__planc_bytes_to_str", start, emitter.here () - start));
            }
            if (need_eprint) {
                var start = emitter.here ();
                emitter.emit_rt_eprint ();
                symbols.add (new Symbol ("__planc_eprint", start, emitter.here () - start));
            }
            if (need_chmod) {
                var start = emitter.here ();
                emitter.emit_rt_chmod ();
                symbols.add (new Symbol ("__planc_chmod", start, emitter.here () - start));
            }
            if (need_read_file) {
                var start = emitter.here ();
                emitter.emit_rt_read_file (io_err_msg_off, file_err_dom);
                symbols.add (new Symbol ("__planc_read_file", start, emitter.here () - start));
            }
            if (need_write_file) {
                var start = emitter.here ();
                emitter.emit_rt_write_file (io_err_msg_off, file_err_dom);
                symbols.add (new Symbol ("__planc_write_file", start, emitter.here () - start));
            }
            emit_panic_sym (need_bounds_panic, bounds_panic_label, "__planc_bounds_panic",
                            "planc: panic: index out of bounds\n");
            emit_panic_sym (need_mem_panic, mem_panic_label, "__planc_mem_panic",
                            "planc: panic: memory error (double free or corrupted block)\n");
            emit_panic_sym (need_null_panic, null_panic_label, "__planc_null_panic",
                            "planc: panic: null pointer dereference\n");
            emit_panic_sym (need_cast_panic, cast_panic_label, "__planc_cast_panic",
                            "planc: panic: invalid class cast\n");
            emit_panic_sym (need_leak_panic, leak_panic_label, "__planc_leak_panic",
                            "planc: panic: memory leak detected\n");
            emit_panic_sym (need_overflow_panic, overflow_panic_label, "__planc_overflow_panic",
                            "planc: panic: integer overflow\n");
        }

        private void emit_panic_sym (bool needed, Label lbl, string sym_name, string msg) {
            if (!needed)
                return;
            var msg_off = emitter.add_string (msg);
            var start = emitter.here ();
            emitter.bind (lbl);
            emitter.emit_rt_panic (msg_off, msg.length, freestanding, target_planetos);
            symbols.add (new Symbol (sym_name, start, emitter.here () - start));
        }

        private void emit_start () {
            var start = emitter.here ();

            if (main_takes_args) {
                // Save argc ([rsp]) and argv (&[rsp + 8]) before aligning rsp.
                // mov rdi, [rsp]              48 8B 3C 24
                emitter.code.u8 (0x48); emitter.code.u8 (0x8B);
                emitter.code.u8 (0x3C); emitter.code.u8 (0x24);
                // lea rsi, [rsp + 8]          48 8D 74 24 08
                emitter.code.u8 (0x48); emitter.code.u8 (0x8D);
                emitter.code.u8 (0x74); emitter.code.u8 (0x24); emitter.code.u8 (0x08);
            }
            // xor ebp, ebp                    31 ED
            emitter.code.u8 (0x31); emitter.code.u8 (0xED);
            // and rsp, -16                    48 83 E4 F0
            emitter.code.u8 (0x48); emitter.code.u8 (0x83);
            emitter.code.u8 (0xE4); emitter.code.u8 (0xF0);
            if (main_takes_args) {
                emitter.call_rel32 ("__planc_build_args");
                // mov r13, rax                49 89 C5
                emitter.code.u8 (0x49); emitter.code.u8 (0x89); emitter.code.u8 (0xC5);
                // mov rdi, r13                4C 89 EF
                emitter.code.u8 (0x4C); emitter.code.u8 (0x89); emitter.code.u8 (0xEF);
            }
            emitter.call_rel32 ("main");

            if (freestanding) {
                emitter.code.u8 (0xFA); emitter.code.u8 (0xF4); // cli; hlt
                emitter.code.u8 (0xEB); emitter.code.u8 (0xFD); // jmp -3
                symbols.add (new Symbol ("_start", start, emitter.here () - start));
                return;
            }

            if (program_uses_heap) {
                emitter.mov_r12d_eax ();
                if (main_takes_args) {
                    // mov rdi, r13            4C 89 EF
                    emitter.code.u8 (0x4C); emitter.code.u8 (0x89); emitter.code.u8 (0xEF);
                    emitter.call_rel32 ("__planc_unref");
                }
                for (int gi = 0; gi < global_names.length; gi++) {
                    var gt = global_types[gi];
                    if (is_ref_type (gt)) {
                        emitter.load_global (global_offsets[gi], global_spaces[gi]);
                        emitter.mov_rdi_rax ();
                        emitter.call_rel32 ("__planc_unref");
                        emitter.xor_eax ();
                        emitter.store_global (global_offsets[gi], global_spaces[gi]);
                    } else if (gt == ValaType.STRUCT) {
                        unowned var sd = program.find_struct (global_type_names[gi]);
                        if (sd != null && struct_has_string (sd)) {
                            emitter.lea_rax_space (global_offsets[gi], global_spaces[gi]);
                            emitter.mov_rcx_rax ();
                            unref_struct_at_rcx (sd, 0);
                        }
                    }
                }
                if (check_leaks) {
                    need_leak_panic = true;
                    emitter.emit_check_leaks (alloc_bss_offset, leak_panic_label);
                }
                emitter.mov_edi_r12d ();
            } else {
                emitter.mov_edi_eax ();
            }
            if (target_planetos) {
                emitter.mov_eax (11);
                emitter.int80 ();
            } else {
                emitter.mov_eax (SYS_EXIT);
                emitter.syscall ();
            }

            symbols.add (new Symbol ("_start", start, emitter.here () - start));
        }

        // ------------------------------------------------------------------
        // Functions, frame partitioning, and temporary tracking.
        // ------------------------------------------------------------------

        private static int align16 (int v) {
            return (v % 16 == 0) ? v : v + (16 - v % 16);
        }

        private static int struct_base_disp (int first_slot, int slot_count) {
            return Emitter.slot_offset (first_slot + slot_count - 1);
        }

        private GenericArray<bool> local_unmanaged;

        private void reset_locals () {
            locals = new GenericArray<string> ();
            local_types = new GenericArray<ValaType> ();
            local_type_names = new GenericArray<string> ();
            local_slots = new GenericArray<int> ();
            local_active = new GenericArray<bool> ();
            local_is_weak = new GenericArray<bool> ();
            local_is_compact = new GenericArray<bool> ();
            local_unmanaged = new GenericArray<bool> ();
            local_by_ref = new GenericArray<bool> ();
            local_used = new GenericArray<bool> ();
            local_is_user = new GenericArray<bool> ();
            local_decl_line = new GenericArray<int> ();
            local_decl_col = new GenericArray<int> ();
        }

        private void deactivate_from (int saved_len) throws SemanticError {
            for (int i = saved_len; i < local_active.length; i++) {
                if (in_check_pass && local_active[i] && local_is_user[i] && !local_used[i]) {
                    string loc = (current_file != "")
                        ? @"$current_file:$(local_decl_line[i]):$(local_decl_col[i])"
                        : @"$(local_decl_line[i]):$(local_decl_col[i])";
                    if (strict_unused)
                        throw new SemanticError.UNUSED_VARIABLE (
                            @"unused local variable '$(locals[i])' at $loc");
                    else if (warn_unused)
                        Host.eprintln (
                            @"planc: warning: unused variable '$(locals[i])' at $loc");
                }
                local_active[i] = false;
            }
        }

        private GenericArray<string> clone_non_null () {
            var copy = new GenericArray<string> ();
            foreach (var s in non_null_vars)
                copy.add (s);
            return copy;
        }

        private void restore_non_null (GenericArray<string> snap) {
            non_null_vars = new GenericArray<string> ();
            foreach (var s in snap)
                non_null_vars.add (s);
        }

        private bool is_non_null_narrowed (string name) {
            foreach (var s in non_null_vars) {
                if (s == name)
                    return true;
            }
            return false;
        }

        private void add_non_null (string name) {
            if (!is_non_null_narrowed (name))
                non_null_vars.add (name);
        }

        private void add_all_non_null (GenericArray<string> keys) {
            foreach (var k in keys)
                add_non_null (k);
        }

        private void remove_non_null (string name) {
            for (int i = non_null_vars.length - 1; i >= 0; i--) {
                if (non_null_vars[i] == name)
                    non_null_vars.remove_index (i);
            }
        }

        private void invalidate_non_null_prefix (string name) {
            var pfx = name + ".";
            for (int i = non_null_vars.length - 1; i >= 0; i--) {
                var k = non_null_vars[i];
                if (k == name || k.has_prefix (pfx))
                    non_null_vars.remove_index (i);
            }
        }

        private static string? member_narrow_key (MemberAccessExpr m) {
            if (!(m.target is VarRef))
                return null;
            var vn = ((VarRef) m.target).name;
            return (vn == "this") ? m.member : @"$(vn).$(m.member)";
        }

        private static string? null_cmp_expr_key (Expr e) {
            if (e is VarRef)
                return ((VarRef) e).name;
            if (e is MemberAccessExpr)
                return member_narrow_key ((MemberAccessExpr) e);
            return null;
        }

        private static void collect_non_null_when (Expr cond, bool when_true, GenericArray<string> out_keys) {
            if (cond is UnaryExpr) {
                var u = (UnaryExpr) cond;
                if (u.op == "!")
                    collect_non_null_when (u.operand, !when_true, out_keys);
                return;
            }
            if (!(cond is BinaryExpr))
                return;
            var b = (BinaryExpr) cond;
            if ((b.op == "&&" && when_true) || (b.op == "||" && !when_true)) {
                collect_non_null_when (b.left, when_true, out_keys);
                collect_non_null_when (b.right, when_true, out_keys);
                return;
            }
            var want_op = when_true ? "!=" : "==";
            if (b.op != want_op)
                return;
            string? k = null;
            if (b.right is NullLiteral)
                k = null_cmp_expr_key (b.left);
            else if (b.left is NullLiteral)
                k = null_cmp_expr_key (b.right);
            if (k != null)
                out_keys.add (k);
        }

        private static bool stmt_always_exits (Statement s) {
            if (s is ReturnStatement || s is ExitStatement
                || s is BreakStatement || s is ContinueStatement
                || s is ThrowStatement) {
                return true;
            }
            if (s is BlockStatement) {
                foreach (var inner in ((BlockStatement) s).statements) {
                    if (stmt_always_exits (inner))
                        return true;
                }
                return false;
            }
            if (s is IfStatement) {
                var i = (IfStatement) s;
                return i.else_body != null
                    && stmt_always_exits (i.then_body)
                    && stmt_always_exits (i.else_body);
            }
            return false;
        }

        private static bool stmt_list_exits (GenericArray<Statement> list) {
            foreach (var s in list) {
                if (stmt_always_exits (s))
                    return true;
            }
            return false;
        }

        // ------------------------------------------------------------------
        // Definite-assignment analysis.
        //
        // The dialect allows a local of non-nullable class/interface/error
        // type to be declared without an initializer and assigned later
        // (`Expr atom;` ... `atom = ...;`). The compiler's own sources rely
        // on it. This pass is the authority that makes that sound: it walks
        // the body once and rejects (a) a read that can be reached while the
        // variable is still unassigned and (b) a declaration that is still
        // unassigned when its scope ends. prepare_stmt and gen_statement no
        // longer reject the declaration itself; they zero the slot (null),
        // which is safe precisely because this pass guarantees no read of
        // the null. Every flow fork merges by intersection: only an
        // assignment that happens on *all* paths counts.
        // ------------------------------------------------------------------

        // Tracked locals currently in scope, parallel arrays. An entry is
        // appended on declaration and removed when its scope ends.
        private GenericArray<string> da_names;
        private GenericArray<string> da_positions;   // decl "line:column"
        private GenericArray<string> da_labels;      // type label for messages
        private GenericArray<int> da_flags;          // 1: definitely assigned

        private void da_reset () {
            da_names = new GenericArray<string> ();
            da_positions = new GenericArray<string> ();
            da_labels = new GenericArray<string> ();
            da_flags = new GenericArray<int> ();
        }

        private static bool da_needs_tracking (ValaType t, string tname) {
            return (t == ValaType.CLASS || t == ValaType.INTERFACE || t == ValaType.ERROR)
                && !is_nullable_type (t, tname);
        }

        private GenericArray<int> da_state_copy () {
            var c = new GenericArray<int> ();
            for (int i = 0; i < da_flags.length; i++)
                c.add (da_flags[i]);
            return c;
        }

        private void da_state_restore (GenericArray<int>? st) {
            if (st == null)
                return;
            for (int i = 0; i < da_flags.length; i++)
                da_flags[i] = st[i];
        }

        private void da_scope_exit (int mark) throws SemanticError {
            for (int i = da_names.length - 1; i >= mark; i--) {
                if (da_flags[i] == 0)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"non-nullable $(da_labels[i]) variable '$(da_names[i])' must be initialized at $(da_positions[i])");
            }
            while (da_names.length > mark) {
                var k = da_names.length - 1;
                da_names.remove_index (k);
                da_positions.remove_index (k);
                da_labels.remove_index (k);
                da_flags.remove_index (k);
            }
        }

        private void da_use (string name, int line, int col) throws SemanticError {
            for (int i = 0; i < da_names.length; i++) {
                if (da_names[i] == name && da_flags[i] == 0)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"non-nullable $(da_labels[i]) variable '$name' used before assignment at $(line):$(col)");
            }
        }

        private void da_assign (string name) {
            for (int i = da_names.length - 1; i >= 0; i--) {
                if (da_names[i] == name) {
                    da_flags[i] = 1;
                    return;
                }
            }
        }

        private void da_stmt (Statement s) throws SemanticError {
            if (s is PrintStatement) {
                da_expr (((PrintStatement) s).value);
            } else if (s is ExitStatement) {
                da_expr (((ExitStatement) s).value);
            } else if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (r.value != null)
                    da_expr (r.value);
            } else if (s is ThrowStatement) {
                da_expr (((ThrowStatement) s).message);
            } else if (s is BreakStatement || s is ContinueStatement) {
                // Exits unconditionally; nothing to track.
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.init != null)
                    da_expr (d.init);
                if (d.init == null && da_needs_tracking (d.decl_type, d.decl_type_name)) {
                    da_names.add (d.name);
                    da_positions.add (@"$(d.line):$(d.column)");
                    da_labels.add (type_label (d.decl_type, d.decl_type_name));
                    da_flags.add (0);
                }
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                // The right-hand side is read first: `x = x + 1` on an
                // unassigned x is a use, not an assignment.
                da_expr (a.value);
                da_assign (a.name);
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                da_expr (fa.target);
                da_expr (fa.value);
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                da_expr (ia.target);
                da_expr (ia.index);
                da_expr (ia.value);
            } else if (s is ExprStatement) {
                da_expr (((ExprStatement) s).expr);
            } else if (s is BlockStatement) {
                var mark = da_names.length;
                foreach (var inner in ((BlockStatement) s).statements)
                    da_stmt (inner);
                da_scope_exit (mark);
            } else if (s is IfStatement) {
                var i = (IfStatement) s;
                var pre = da_state_copy ();
                var pre_len = da_names.length;
                da_expr (i.condition);
                bool then_exits = stmt_always_exits (i.then_body);
                var mark_then = da_names.length;
                da_stmt (i.then_body);
                da_scope_exit (mark_then);
                GenericArray<int>? then_state = then_exits ? null : da_state_copy ();
                da_state_restore (pre);

                bool else_exits = (i.else_body != null) && stmt_always_exits (i.else_body);
                GenericArray<int>? else_state = null;
                if (i.else_body != null) {
                    var mark_else = da_names.length;
                    da_stmt (i.else_body);
                    da_scope_exit (mark_else);
                    if (!else_exits)
                        else_state = da_state_copy ();
                    da_state_restore (pre);
                }
                // Merge at the join point: a branch that always exits
                // contributes nothing; an absent else falls through with `pre`.
                if (then_state == null && else_state == null)
                    da_state_restore (pre);
                else if (then_state == null)
                    da_state_restore (else_state);
                else if (else_state == null)
                    da_state_restore (else_exits ? then_state : pre);
                else {
                    for (int k = 0; k < pre_len; k++)
                        da_flags[k] = (then_state[k] != 0 && else_state[k] != 0) ? 1 : 0;
                }
            } else if (s is WhileStatement) {
                var w = (WhileStatement) s;
                da_expr (w.condition);
                var pre = da_state_copy ();
                var mark = da_names.length;
                da_stmt (w.body);
                da_scope_exit (mark);
                // The body may run zero times: its assignments do not count.
                da_state_restore (pre);
            } else if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                var pre = da_state_copy ();
                var mark = da_names.length;
                da_stmt (dw.body);
                da_scope_exit (mark);
                da_expr (dw.condition);
                da_state_restore (pre);
            } else if (s is ForStatement) {
                var fs = (ForStatement) s;
                if (fs.init != null)
                    da_stmt (fs.init);
                if (fs.condition != null)
                    da_expr (fs.condition);
                var pre = da_state_copy ();
                var mark = da_names.length;
                da_stmt (fs.body);
                da_scope_exit (mark);
                if (fs.step != null)
                    da_stmt (fs.step);
                da_state_restore (pre);
            } else if (s is ForeachStatement) {
                var fe = (ForeachStatement) s;
                da_expr (fe.collection);
                var pre = da_state_copy ();
                var mark = da_names.length;
                da_stmt (fe.body);
                da_scope_exit (mark);
                da_state_restore (pre);
            } else if (s is SwitchStatement) {
                var sw = (SwitchStatement) s;
                da_expr (sw.target);
                var pre = da_state_copy ();
                var pre_len = da_names.length;
                // Without a default, control can reach past the switch
                // without entering any case: the pre-state participates.
                GenericArray<int>? acc = sw.has_default ? null : da_state_copy ();
                foreach (var sc in sw.cases) {
                    da_state_restore (pre);
                    var mark = da_names.length;
                    foreach (var bs in sc.body)
                        da_stmt (bs);
                    da_scope_exit (mark);
                    if (!stmt_list_exits (sc.body)) {
                        var cur = da_state_copy ();
                        if (acc == null)
                            acc = cur;
                        else {
                            for (int k = 0; k < pre_len; k++)
                                if (cur[k] == 0)
                                    acc[k] = 0;
                        }
                    }
                }
                da_state_restore (acc != null ? acc : pre);
            } else if (s is TryStatement) {
                var t = (TryStatement) s;
                var pre = da_state_copy ();
                var pre_len = da_names.length;
                bool try_exits = stmt_list_exits (t.try_body);
                GenericArray<int>? try_state = null;
                if (!try_exits) {
                    var mark = da_names.length;
                    foreach (var ts in t.try_body)
                        da_stmt (ts);
                    da_scope_exit (mark);
                    try_state = da_state_copy ();
                    da_state_restore (pre);
                }
                // Catches run with the pre-state: when an exception unwinds
                // into them, nothing assigned inside try is guaranteed.
                // A variable is definite afterwards only if the try path and
                // every live catch path assigned it.
                var acc = try_state;
                foreach (var cc in t.catches) {
                    da_state_restore (pre);
                    var mark = da_names.length;
                    foreach (var cs in cc.body)
                        da_stmt (cs);
                    da_scope_exit (mark);
                    if (!stmt_list_exits (cc.body)) {
                        var cur = da_state_copy ();
                        if (acc == null)
                            acc = cur;
                        else {
                            for (int k = 0; k < pre_len; k++)
                                if (cur[k] == 0)
                                    acc[k] = 0;
                        }
                    }
                }
                da_state_restore (acc != null ? acc : pre);
                if (t.has_finally) {
                    // Finally always runs; its assignments persist.
                    var mark = da_names.length;
                    foreach (var fst in t.finally_body)
                        da_stmt (fst);
                    da_scope_exit (mark);
                }
            }
        }

        private void da_expr (Expr e) throws SemanticError {
            if (e is VarRef) {
                var v = (VarRef) e;
                if (v.name != "this")
                    da_use (v.name, v.line, v.column);
                return;
            }
            if (e is TemplateExpr) {
                foreach (var p in ((TemplateExpr) e).parts)
                    da_expr (p);
            } else if (e is MemberAccessExpr) {
                da_expr (((MemberAccessExpr) e).target);
            } else if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                da_expr (ix.target);
                da_expr (ix.index);
            } else if (e is ArrayNewExpr) {
                da_expr (((ArrayNewExpr) e).length_expr);
            } else if (e is ArrayLiteralExpr) {
                foreach (var el in ((ArrayLiteralExpr) e).elements)
                    da_expr (el);
            } else if (e is StructLiteral) {
                foreach (var fv in ((StructLiteral) e).field_values)
                    da_expr (fv);
            } else if (e is UnaryExpr) {
                da_expr (((UnaryExpr) e).operand);
            } else if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                da_expr (b.left);
                da_expr (b.right);
            } else if (e is CallExpr) {
                var c = (CallExpr) e;
                // A delegate local invoked by name reads the variable.
                da_use (c.callee, c.line, c.column);
                foreach (var a in c.args)
                    da_expr (a);
            } else if (e is ClassNewExpr) {
                var n = (ClassNewExpr) e;
                foreach (var a in n.args)
                    da_expr (a);
                foreach (var iv in n.init_values)
                    da_expr (iv);
            } else if (e is MethodCallExpr) {
                var m = (MethodCallExpr) e;
                if (m.target != null)
                    da_expr (m.target);
                foreach (var a in m.args)
                    da_expr (a);
            } else if (e is TypeCheckExpr) {
                da_expr (((TypeCheckExpr) e).operand);
            } else if (e is SliceExpr) {
                var sl = (SliceExpr) e;
                da_expr (sl.target);
                da_expr (sl.start);
                da_expr (sl.end);
            } else if (e is TernaryExpr) {
                var t = (TernaryExpr) e;
                da_expr (t.condition);
                da_expr (t.then_expr);
                da_expr (t.else_expr);
            } else if (e is CoalesceExpr) {
                var c = (CoalesceExpr) e;
                da_expr (c.left);
                da_expr (c.right);
            } else if (e is IncDecExpr) {
                da_expr (((IncDecExpr) e).target);
            } else if (e is YieldExpr) {
                var ye = (YieldExpr) e;
                if (ye.value != null)
                    da_expr (ye.value);
            } else if (e is LambdaExpr) {
                var lam = (LambdaExpr) e;
                // A lambda is its own scope: its captures were assigned in
                // the enclosing scope, so the analysis restarts there.
                var s_names = da_names;
                var s_pos = da_positions;
                var s_lab = da_labels;
                var s_flags = da_flags;
                da_reset ();
                if (lam.expr_body != null)
                    da_expr (lam.expr_body);
                foreach (var st in lam.body)
                    da_stmt (st);
                da_scope_exit (0);
                da_names = s_names;
                da_positions = s_pos;
                da_labels = s_lab;
                da_flags = s_flags;
            }
        }

        private void finalize_if_narrowing (IfStatement i,
                                            GenericArray<string> snap,
                                            GenericArray<string> after_then,
                                            GenericArray<string>? after_else,
                                            GenericArray<string> nn_then,
                                            GenericArray<string> nn_else) {
            bool then_exits = stmt_always_exits (i.then_body);
            bool else_exits = (i.else_body != null) && stmt_always_exits (i.else_body);
            if (then_exits && i.else_body == null) {
                restore_non_null (snap);
                add_all_non_null (nn_else);
                return;
            }
            if (then_exits && after_else != null && !else_exits) {
                restore_non_null (after_else);
                add_all_non_null (nn_else);
                return;
            }
            if (else_exits && !then_exits) {
                restore_non_null (after_then);
                add_all_non_null (nn_then);
                return;
            }
            var other = snap;
            if (i.else_body != null && after_else != null)
                other = after_else;
            non_null_vars = new GenericArray<string> ();
            foreach (var v in after_then) {
                if (list_contains (other, v) && (list_contains (snap, v) || !list_contains (nn_then, v)))
                    add_non_null (v);
            }
        }

        private string maybe_narrow_var (string name, string raw_tname) {
            return is_non_null_narrowed (name) ? strip_null (raw_tname) : raw_tname;
        }

        private string maybe_narrow_member (MemberAccessExpr m, string raw_tname) {
            var mkey = member_narrow_key (m);
            if (mkey != null && is_non_null_narrowed (mkey))
                return strip_null (raw_tname);
            return raw_tname;
        }

        private void update_non_null_on_assign (string key, ValaType rhs_t, string rhs_tname) {
            invalidate_non_null_prefix (key);
            if (rhs_t != ValaType.NULL
                && (is_ref_type (rhs_t) || is_delegate_type (program, rhs_t, rhs_tname))
                && !is_nullable_type (rhs_t, rhs_tname))
                add_non_null (key);
        }

        private bool is_compact_type (ValaType t, string tname) {
            if (t != ValaType.CLASS)
                return false;
            unowned var ccd = program.find_class (strip_null (tname));
            return ccd != null && ccd.is_compact;
        }

        private void push_local (string name, ValaType t, string tname, int slot,
                                 bool unmanaged, bool by_ref = false, bool is_weak = false) {
            locals.add (name);
            local_types.add (t);
            local_type_names.add (tname);
            local_slots.add (slot);
            local_active.add (true);
            local_unmanaged.add (unmanaged);
            local_by_ref.add (by_ref);
            local_is_weak.add (is_weak);
            local_is_compact.add (is_compact_type (t, tname));
            local_used.add (false);
            local_is_user.add (false);
            local_decl_line.add (0);
            local_decl_col.add (0);
        }

        private void emit_convert_to_weak () {
            // Input: rax = obj_ptr (+1 strong ref, or 0).
            // Output: rax = weak_box (+1 ref, or 0), and unrefs the strong temp obj_ptr.
            emitter.push_rax ();
            push_depth++;
            emitter.mov_rdi_rax ();
            call_aligned ("__planc_weak_make");
            emitter.pop_reg (Reg.RDI);
            push_depth--;
            emitter.push_rax ();
            push_depth++;
            call_aligned ("__planc_unref");
            emitter.pop_rax ();
            push_depth--;
        }

        private void emit_load_weak (int ref_temp_slot) {
            // Input: rax = weak_box (or 0).
            // Output: rax = obj_ptr (+1 strong ref, or 0), registered in ref_temp_slot.
            emitter.mov_rdi_rax ();
            call_aligned ("__planc_weak_load");
            if (ref_temp_slot >= 0) {
                emitter.store_local (ref_temp_slot);
                add_live_ref_slot (ref_temp_slot);
            }
        }

        private void add_live_ref_slot (int slot) {
            if (slot < 0)
                return;
            for (int i = 0; i < live_stmt_ref_slots.length; i++) {
                if (live_stmt_ref_slots[i] == slot)
                    return;
            }
            live_stmt_ref_slots.add (slot);
        }

        private void check_domain_exists (string dom, int line, int col) throws SemanticError {
            if (dom != "Error" && program.find_error_domain (dom) == null)
                throw new SemanticError.TYPE_MISMATCH (
                    @"unknown error domain '$(dom)' at $line:$col");
        }

        private void check_domains_handled (GenericArray<string> domains, int line, int col)
                throws SemanticError {
            foreach (var dom in domains) {
                check_domain_exists (dom, line, col);
                bool ok = false;
                foreach (var ad in active_catch_domains) {
                    if (ad == dom || ad == "Error") {
                        ok = true;
                        break;
                    }
                }
                if (!ok && current != null) {
                    foreach (var td in current.throws_domains) {
                        if (td == dom || td == "Error") {
                            ok = true;
                            break;
                        }
                    }
                }
                if (!ok) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unhandled error '$(dom)' at $line:$col");
                }
            }
        }

        private unowned Function? find_prop_getter (ValaType tt, string tt_name, string prop) {
            if (tt == ValaType.CLASS) {
                unowned var cd = program.find_class (strip_null (tt_name));
                unowned var gm = (cd != null) ? find_class_method (cd, @"get_$(prop)") : null;
                if (gm != null && !gm.is_static && gm.params.length == 1)
                    return gm;
            } else if (tt == ValaType.INTERFACE) {
                unowned var itf = program.find_interface (strip_null (tt_name));
                unowned var gm = (itf != null) ? find_interface_method (itf, @"get_$(prop)") : null;
                if (gm != null && gm.params.length == 1)
                    return gm;
            } else if (tt == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tt_name);
                unowned var gm = (sd != null) ? sd.find_method (@"get_$(prop)") : null;
                if (gm != null && !gm.is_static && gm.params.length == 1)
                    return gm;
            }
            return null;
        }

        private unowned Function? find_prop_setter (ValaType tt, string tt_name, string prop) {
            if (tt == ValaType.CLASS) {
                unowned var cd = program.find_class (strip_null (tt_name));
                unowned var sm = (cd != null) ? find_class_method (cd, @"set_$(prop)") : null;
                if (sm != null && !sm.is_static && sm.params.length == 2)
                    return sm;
            } else if (tt == ValaType.INTERFACE) {
                unowned var itf = program.find_interface (strip_null (tt_name));
                unowned var sm = (itf != null) ? find_interface_method (itf, @"set_$(prop)") : null;
                if (sm != null && sm.params.length == 2)
                    return sm;
            } else if (tt == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tt_name);
                unowned var sm = (sd != null) ? sd.find_method (@"set_$(prop)") : null;
                if (sm != null && !sm.is_static && sm.params.length == 2)
                    return sm;
            }
            return null;
        }

        private bool has_real_member (ValaType tt, string tt_name, string member) {
            if (tt == ValaType.CLASS) {
                unowned var cd = program.find_class (strip_null (tt_name));
                unowned ClassField? cf = null;
                if (cd != null && class_field_offset_slots (cd, member, out cf) >= 0)
                    return true;
            } else if (tt == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tt_name);
                unowned StructField? sf = null;
                if (sd != null && struct_field_offset_slots (sd, member, out sf) >= 0)
                    return true;
            } else if (tt == ValaType.STRING || tt == ValaType.ARRAY) {
                if (member == "length")
                    return true;
            } else if (tt == ValaType.ERROR) {
                if (member == "message" || member == "domain" || member == "code")
                    return true;
            }
            return find_prop_getter (tt, tt_name, member) != null;
        }

        private unowned Function? resolve_member_delegate_fn (ValaType tt, string tt_name, string member) {
            if (tt == ValaType.CLASS) {
                unowned var cd = program.find_class (strip_null (tt_name));
                return (cd != null) ? find_class_method (cd, member) : null;
            } else if (tt == ValaType.INTERFACE) {
                unowned var itf = program.find_interface (strip_null (tt_name));
                return (itf != null) ? find_interface_method (itf, member) : null;
            } else if (tt == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tt_name);
                return (sd != null) ? sd.find_method (member) : null;
            } else if (tt == ValaType.ENUM) {
                unowned var ed = program.find_enum (tt_name);
                return (ed != null) ? ed.find_method (member) : null;
            }
            return null;
        }

        private bool find_generic_array_elem (string tt_name, out ValaType et, out string et_name) {
            et = ValaType.INT;
            et_name = "";
            var cname = strip_null (tt_name);
            if (!cname.has_prefix ("GenericArray__"))
                return false;
            unowned var cd = program.find_class (cname);
            unowned ClassField? df = (cd != null) ? cd.find_own_field ("data") : null;
            if (df == null)
                return false;
            parse_array_elem (df.type_name, out et, out et_name);
            return true;
        }

        private bool find_channel_elem (string tt_name, out ValaType et, out string et_name) {
            et = ValaType.INT;
            et_name = "";
            var cname = strip_null (tt_name);
            if (!cname.has_prefix ("Channel__"))
                return false;
            unowned var cd = program.find_class (cname);
            unowned ClassField? ef = (cd != null) ? cd.find_own_field ("elem") : null;
            if (ef == null)
                return false;
            et = ef.field_type;
            et_name = ef.type_name;
            return true;
        }

        private unowned DelegateDecl? resolve_delegate_callee (string name) {
            var slot = lookup (name);
            if (slot >= 0) {
                if (local_types[slot] == ValaType.STRUCT)
                    return program.find_delegate (local_type_names[slot]);
                return null;
            }
            var gi = lookup_global (name);
            if (gi >= 0) {
                if (global_types[gi] == ValaType.STRUCT)
                    return program.find_delegate (global_type_names[gi]);
                return null;
            }
            if (current_class != null && current != null && !current.is_static) {
                unowned ClassField? cf = null;
                if (class_field_offset_slots (current_class, name, out cf) >= 0 && cf != null) {
                    if (cf.field_type == ValaType.STRUCT)
                        return program.find_delegate (cf.type_name);
                    return null;
                }
            }
            if (current_struct != null && current != null && !current.is_static) {
                unowned StructField? sf = null;
                if (struct_field_offset_slots (current_struct, name, out sf) >= 0 && sf != null) {
                    if (sf.field_type == ValaType.STRUCT)
                        return program.find_delegate (sf.type_name);
                    return null;
                }
            }
            unowned var gm = find_this_prop_getter (name);
            if (gm != null && gm.return_type == ValaType.STRUCT)
                return program.find_delegate (gm.return_type_name);
            return null;
        }

        private unowned DelegateDecl? resolve_member_delegate (Expr target, string member) throws SemanticError {
            if (target is VarRef && is_type_name (((VarRef) target).name))
                return null;
            string tt_name = "";
            var tt = expr_type_full (target, out tt_name);
            if (member == "") {
                if (tt == ValaType.STRUCT)
                    return program.find_delegate (tt_name);
                return null;
            }
            if (tt == ValaType.CLASS) {
                unowned var cd = program.find_class (strip_null (tt_name));
                unowned ClassField? cf = null;
                if (cd != null && class_field_offset_slots (cd, member, out cf) >= 0 && cf != null) {
                    if (cf.field_type == ValaType.STRUCT)
                        return program.find_delegate (cf.type_name);
                    return null;
                }
            } else if (tt == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tt_name);
                unowned StructField? sf = null;
                if (sd != null && struct_field_offset_slots (sd, member, out sf) >= 0 && sf != null) {
                    if (sf.field_type == ValaType.STRUCT)
                        return program.find_delegate (sf.type_name);
                    return null;
                }
            }
            unowned var gm = find_prop_getter (tt, tt_name, member);
            if (gm != null && gm.return_type == ValaType.STRUCT)
                return program.find_delegate (gm.return_type_name);
            return null;
        }

        private unowned Function? find_this_prop_getter (string prop) {
            if (current_class != null && current != null && !current.is_static)
                return find_prop_getter (ValaType.CLASS, current_class.name, prop);
            if (current_struct != null && current != null && !current.is_static)
                return find_prop_getter (ValaType.STRUCT, current_struct.name, prop);
            return null;
        }

        private unowned Function? find_this_prop_setter (string prop) {
            if (current_class != null && current != null && !current.is_static)
                return find_prop_setter (ValaType.CLASS, current_class.name, prop);
            if (current_struct != null && current != null && !current.is_static)
                return find_prop_setter (ValaType.STRUCT, current_struct.name, prop);
            return null;
        }

        private GenericArray<string> del_thunk_keys;
        private GenericArray<string> del_thunk_syms;

        private void emit_error_jump () {
            if (push_depth > 0)
                emitter.add_rsp (8 * push_depth);
            int saved_pd = push_depth;
            push_depth = 0;

            if (program_uses_heap && live_stmt_ref_slots.length > 0) {
                for (int k = live_stmt_ref_slots.length - 1; k >= 0; k--) {
                    int rslot = live_stmt_ref_slots[k];
                    emitter.load_local (rslot);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_unref");
                    emitter.zero_local (rslot);
                }
            }

            Label target;
            int tmark = 0;
            if (unwind_labels.length > 0) {
                target = unwind_labels[unwind_labels.length - 1];
                tmark = unwind_marks[unwind_marks.length - 1];
            } else {
                need_func_throw = true;
                target = cur_func_throw_label;
                tmark = 0;
            }

            if (program_uses_heap)
                unref_locals_from (tmark);
            emitter.branch (BranchKind.JMP, target);
            push_depth = saved_pd;
        }

        private void emit_post_call_error_check_flag (bool can_throw) {
            if (!can_throw)
                return;
            emitter.test_rdx_rdx ();
            var l_ok = emitter.new_label ();
            emitter.branch (BranchKind.JE, l_ok);
            emitter.store_local_reg (err_prop_slot, Reg.RDX);
            emit_error_jump ();
            emitter.bind (l_ok);
        }

        private void emit_post_call_error_check (Function callee) {
            emit_post_call_error_check_flag (callee.can_throw);
        }

        private void load_this_slot () {
            var ts = lookup ("this");
            // lookup() returns the locals-table index; the physical slot
            // lives in local_slots. They coincide only by accident when no
            // capture slot was allocated out of order before the entry.
            emitter.load_local (ts >= 0 ? local_slots[ts] : 0);
        }

        private static bool is_delegate_type (Program prog, ValaType t, string tname) {
            return t == ValaType.STRUCT && prog.find_delegate (strip_null (tname)) != null;
        }

        private void fill_default_args (Function fn, int param_offset, GenericArray<Expr> args) {
            int avail = fn.params.length - param_offset;
            if (args.length >= avail)
                return;
            for (int i = param_offset + args.length; i < fn.params.length; i++) {
                if (fn.params[i].default_value == null)
                    return;
            }
            for (int i = param_offset + args.length; i < fn.params.length; i++) {
                var dv = fn.params[i].default_value;
                if (dv == null)
                    return;
                args.add (program.clone_expr_plain (dv));
            }
        }

        private void bind_delegate_target (Expr? e, ValaType expected_t, string expected_tname) {
            if (e == null || !is_delegate_type (program, expected_t, expected_tname))
                return;
            var dname = strip_null (expected_tname);
            if (e is LambdaExpr) {
                ((LambdaExpr) e).delegate_type_name = dname;
            } else if (e is VarRef) {
                var vr = (VarRef) e;
                if (lookup (vr.name) < 0 && lookup_global (vr.name) < 0
                    && (program.find (vr.name) != null
                        || (current_class != null && find_class_method (current_class, vr.name) != null))) {
                    vr.target_del_type = dname;
                }
            } else if (e is MemberAccessExpr) {
                ((MemberAccessExpr) e).target_del_type = dname;
            } else if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                bind_delegate_target (te.then_expr, expected_t, expected_tname);
                bind_delegate_target (te.else_expr, expected_t, expected_tname);
            } else if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                bind_delegate_target (ce.left, expected_t, expected_tname);
                bind_delegate_target (ce.right, expected_t, expected_tname);
            }
        }

        private void collect_stmt_free_vars (Statement s,
                                             GenericArray<string> bound,
                                             GenericArray<string> free_vars) {
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                if (p.value is TemplateExpr) {
                    foreach (var pt in ((TemplateExpr) p.value).parts)
                        collect_expr_free_vars (pt, bound, free_vars);
                } else {
                    collect_expr_free_vars (p.value, bound, free_vars);
                }
            } else if (s is ExitStatement) {
                collect_expr_free_vars (((ExitStatement) s).value, bound, free_vars);
            } else if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (r.value != null)
                    collect_expr_free_vars (r.value, bound, free_vars);
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.init != null)
                    collect_expr_free_vars (d.init, bound, free_vars);
                bound.add (d.name);
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                collect_expr_free_vars (a.value, bound, free_vars);
                add_free_var_if_needed (a.name, bound, free_vars);
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                collect_expr_free_vars (fa.target, bound, free_vars);
                collect_expr_free_vars (fa.value, bound, free_vars);
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                collect_expr_free_vars (ia.target, bound, free_vars);
                collect_expr_free_vars (ia.index, bound, free_vars);
                collect_expr_free_vars (ia.value, bound, free_vars);
            } else if (s is ExprStatement) {
                collect_expr_free_vars (((ExprStatement) s).expr, bound, free_vars);
            } else if (s is BlockStatement) {
                int saved = bound.length;
                foreach (var inner in ((BlockStatement) s).statements)
                    collect_stmt_free_vars (inner, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
            } else if (s is IfStatement) {
                var i = (IfStatement) s;
                collect_expr_free_vars (i.condition, bound, free_vars);
                int saved = bound.length;
                collect_stmt_free_vars (i.then_body, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
                if (i.else_body != null) {
                    collect_stmt_free_vars (i.else_body, bound, free_vars);
                    while (bound.length > saved)
                        bound.remove_index (bound.length - 1);
                }
            } else if (s is WhileStatement) {
                var w = (WhileStatement) s;
                collect_expr_free_vars (w.condition, bound, free_vars);
                int saved = bound.length;
                collect_stmt_free_vars (w.body, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
            } else if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                int saved = bound.length;
                collect_stmt_free_vars (dw.body, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
                collect_expr_free_vars (dw.condition, bound, free_vars);
            } else if (s is ForStatement) {
                var fs = (ForStatement) s;
                int saved = bound.length;
                if (fs.init != null)
                    collect_stmt_free_vars (fs.init, bound, free_vars);
                if (fs.condition != null)
                    collect_expr_free_vars (fs.condition, bound, free_vars);
                if (fs.step != null)
                    collect_stmt_free_vars (fs.step, bound, free_vars);
                collect_stmt_free_vars (fs.body, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
            } else if (s is ForeachStatement) {
                var fe = (ForeachStatement) s;
                collect_expr_free_vars (fe.collection, bound, free_vars);
                int saved = bound.length;
                bound.add (fe.var_name);
                collect_stmt_free_vars (fe.body, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
            } else if (s is SwitchStatement) {
                var sw = (SwitchStatement) s;
                collect_expr_free_vars (sw.target, bound, free_vars);
                foreach (var sc in sw.cases) {
                    foreach (var v in sc.values)
                        collect_expr_free_vars (v, bound, free_vars);
                    int saved = bound.length;
                    foreach (var bs in sc.body)
                        collect_stmt_free_vars (bs, bound, free_vars);
                    while (bound.length > saved)
                        bound.remove_index (bound.length - 1);
                }
                int saved = bound.length;
                foreach (var ds in sw.default_body)
                    collect_stmt_free_vars (ds, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
            } else if (s is ThrowStatement) {
                collect_expr_free_vars (((ThrowStatement) s).message, bound, free_vars);
            } else if (s is TryStatement) {
                var tr = (TryStatement) s;
                int saved = bound.length;
                foreach (var st in tr.try_body)
                    collect_stmt_free_vars (st, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
                foreach (var cc in tr.catches) {
                    bound.add (cc.var_name);
                    foreach (var bs in cc.body)
                        collect_stmt_free_vars (bs, bound, free_vars);
                    while (bound.length > saved)
                        bound.remove_index (bound.length - 1);
                }
                foreach (var fs in tr.finally_body)
                    collect_stmt_free_vars (fs, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
            }
        }

        private void add_free_var_if_needed (string name,
                                             GenericArray<string> bound,
                                             GenericArray<string> free_vars) {
            if (list_contains (bound, name))
                return;
            if (name == "this") {
                if (current_class != null && current != null && !current.is_static
                    && !list_contains (free_vars, "this")) {
                    free_vars.add ("this");
                }
                return;
            }
            if (lookup (name) >= 0) {
                if (!list_contains (free_vars, name))
                    free_vars.add (name);
                return;
            }
            if (lookup_global (name) < 0 && current_class != null && current != null && !current.is_static) {
                unowned ClassField? cf = null;
                if (class_field_offset_slots (current_class, name, out cf) >= 0
                    || find_this_prop_getter (name) != null
                    || find_this_prop_setter (name) != null) {
                    if (!list_contains (free_vars, "this"))
                        free_vars.add ("this");
                }
            }
        }

        private void collect_expr_free_vars (Expr? e,
                                             GenericArray<string> bound,
                                             GenericArray<string> free_vars) {
            if (e == null)
                return;
            if (e is VarRef) {
                add_free_var_if_needed (((VarRef) e).name, bound, free_vars);
            } else if (e is CallExpr) {
                var ce = (CallExpr) e;
                add_free_var_if_needed (ce.callee, bound, free_vars);
                if (lookup (ce.callee) < 0 && current_class != null && current != null && !current.is_static) {
                    unowned var m = find_class_method (current_class, ce.callee);
                    if (m != null && !m.is_static && !list_contains (free_vars, "this"))
                        free_vars.add ("this");
                }
                foreach (var a in ce.args)
                    collect_expr_free_vars (a, bound, free_vars);
            } else if (e is LambdaExpr) {
                var inner = (LambdaExpr) e;
                int saved = bound.length;
                foreach (var pn in inner.param_names)
                    bound.add (pn);
                if (inner.expr_body != null)
                    collect_expr_free_vars (inner.expr_body, bound, free_vars);
                foreach (var st in inner.body)
                    collect_stmt_free_vars (st, bound, free_vars);
                while (bound.length > saved)
                    bound.remove_index (bound.length - 1);
            } else {
                walk_expr_children (e, (ch) => {
                    collect_expr_free_vars (ch, bound, free_vars);
                });
            }
        }

        private string ensure_free_delegate_thunk (Function fn, DelegateDecl dd,
                                                   bool has_env_receiver, int param_off)
                throws SemanticError {
            var key = @"$(fn.name)|$((has_env_receiver ? 1 : 0))|$(dd.name)";
            for (int i = 0; i < del_thunk_keys.length; i++) {
                if (del_thunk_keys[i] == key)
                    return del_thunk_syms[i];
            }
            var sym = @"__planc_delthunk_$(lambda_counter++)";
            del_thunk_keys.add (key);
            del_thunk_syms.add (sym);

            var th = new Function () {
                name = sym,
                return_type = dd.return_type,
                return_type_name = dd.return_type_name,
                line = fn.line,
                column = fn.column
            };
            if (has_env_receiver) {
                th.params.add (new Param () {
                    param_type = (fn.iface_slot >= 0) ? ValaType.INTERFACE : ValaType.CLASS,
                    type_name = fn.owner_class,
                    name = "#env",
                    unmanaged = true
                });
            } else {
                th.params.add (new Param () {
                    param_type = ValaType.STRING,
                    type_name = "string?",
                    name = "#env",
                    unmanaged = true
                });
            }
            var fwd_args = new GenericArray<Expr> ();
            for (int i = 0; i < dd.params.length; i++) {
                var dp = dd.params[i];
                var pname = @"#p$i";
                th.params.add (new Param () {
                    param_type = dp.param_type,
                    type_name = dp.type_name,
                    name = pname,
                    is_ref = dp.is_ref,
                    is_out = dp.is_out
                });
                fwd_args.add (new VarRef () { name = pname, line = fn.line, column = fn.column });
            }
            foreach (var td in dd.throws_domains)
                th.throws_domains.add (td);

            Expr call_expr;
            if (has_env_receiver) {
                var mc = new MethodCallExpr () {
                    target = new VarRef () { name = "#env", line = fn.line, column = fn.column },
                    method_name = fn.method_name,
                    line = fn.line,
                    column = fn.column
                };
                foreach (var a in fwd_args)
                    mc.args.add (a);
                call_expr = mc;
            } else if (fn.owner_class != "") {
                var mc = new MethodCallExpr () {
                    target = new VarRef () { name = fn.owner_class, line = fn.line, column = fn.column },
                    method_name = fn.method_name,
                    line = fn.line,
                    column = fn.column
                };
                foreach (var a in fwd_args)
                    mc.args.add (a);
                call_expr = mc;
            } else {
                var ce = new CallExpr () { callee = fn.name, line = fn.line, column = fn.column };
                foreach (var a in fwd_args)
                    ce.args.add (a);
                call_expr = ce;
            }
            if (dd.return_type == ValaType.VOID) {
                th.body.add (new ExprStatement () { expr = call_expr, line = fn.line, column = fn.column });
            } else {
                th.body.add (new ReturnStatement () { value = call_expr, line = fn.line, column = fn.column });
            }
            program.functions.add (th);
            return sym;
        }

        private void check_delegate_target_fn (DelegateDecl dd, Function fn, int param_off,
                                               int line, int col) throws SemanticError {
            int avail = fn.params.length - param_off;
            if (avail != dd.params.length) {
                throw new SemanticError.TYPE_MISMATCH (
                    @"delegate '$(dd.name)' expects $(dd.params.length) parameter(s), target '$(fn.name)' has $(avail) at $line:$col");
            }
            if (fn.return_type != dd.return_type || fn.return_type_name != dd.return_type_name) {
                throw new SemanticError.TYPE_MISMATCH (
                    @"delegate '$(dd.name)' return type mismatch for '$(fn.name)' at $line:$col");
            }
            for (int i = 0; i < dd.params.length; i++) {
                var dp = dd.params[i];
                var fp = fn.params[param_off + i];
                if (dp.param_type != fp.param_type || dp.type_name != fp.type_name
                    || dp.is_ref != fp.is_ref || dp.is_out != fp.is_out) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"delegate '$(dd.name)' parameter $(i + 1) mismatch for '$(fn.name)' at $line:$col");
                }
            }
            foreach (var fdom in fn.throws_domains) {
                bool ok = false;
                foreach (var ddom in dd.throws_domains) {
                    if (fdom == ddom || ddom == "Error") {
                        ok = true;
                        break;
                    }
                }
                if (!ok) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"target '$(fn.name)' throws '$(fdom)' not declared by delegate '$(dd.name)' at $line:$col");
                }
            }
        }

        private int prepare_function (Function f, out int ref_temp_start) throws SemanticError {
            current = f;
            current_file = f.file;
            // Definite-assignment analysis runs first: it decides whether
            // locals without an initializer are legal in this body.
            da_reset ();
            foreach (var s in f.body)
                da_stmt (s);
            da_scope_exit (0);
            current_class = (f.owner_class != "") ? program.find_class (f.owner_class) : null;
            current_struct = (f.owner_class != "") ? program.find_struct (f.owner_class) : null;
            current_enum = (f.owner_class != "") ? program.find_enum (f.owner_class) : null;
            foreach (var d in f.throws_domains)
                check_domain_exists (d, f.line, f.column);
            pending_struct_exprs = new GenericArray<Expr> ();
            pending_struct_rel_slots = new GenericArray<int> ();
            pending_ref_exprs = new GenericArray<Expr> ();
            active_catch_domains = new GenericArray<string> ();
            non_null_vars = new GenericArray<string> ();
            reset_locals ();
            next_var_slot = 0;

            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                var raw_slot = next_var_slot++;
                int var_slot = raw_slot;
                bool by_ref = p.is_ref || p.is_out;
                if (p.param_type == ValaType.STRUCT && !by_ref) {
                    var n = type_slots (ValaType.STRUCT, p.type_name);
                    var_slot = next_var_slot;
                    next_var_slot += n;
                }
                push_local (p.name, p.param_type, p.type_name, var_slot, p.unmanaged || by_ref, by_ref);
            }
            if (f.from_lambda != null) {
                var lam = f.from_lambda;
                for (int ci = 0; ci < lam.captured_names.length; ci++) {
                    var cslot = next_var_slot++;
                    push_local (lam.captured_names[ci], lam.captured_types[ci],
                                lam.captured_type_names[ci], cslot, false);
                }
            }
            err_prop_slot = next_var_slot++;

            int struct_temp_slots = 0;
            int ref_temp_slots = 0;
            if (f.is_ctor && (f.has_base_call || f.has_this_call) && current_class != null) {
                unowned Function? target_ctor = null;
                if (f.has_this_call) {
                    target_ctor = (f.this_ctor_subname == "")
                        ? current_class.ctor
                        : current_class.find_own_named_ctor (f.this_ctor_subname);
                } else if (current_class.base_name != "") {
                    target_ctor = find_class_ctor (program.find_class (current_class.base_name));
                }
                if (target_ctor != null) {
                    fill_default_args (target_ctor, 1, f.base_args);
                    for (int bi = 0; bi < f.base_args.length && (1 + bi) < target_ctor.params.length; bi++) {
                        var bp = target_ctor.params[1 + bi];
                        bind_delegate_target (f.base_args[bi], bp.param_type, bp.type_name);
                    }
                }
                foreach (var ba in f.base_args)
                    prepare_expr (ba, ref struct_temp_slots, ref ref_temp_slots);
            }
            in_check_pass = true;
            foreach (var s in f.body)
                prepare_stmt (s, ref struct_temp_slots, ref ref_temp_slots);
            deactivate_from (0);
            in_check_pass = false;

            int var_end = next_var_slot;
            for (int k = 0; k < pending_struct_exprs.length; k++) {
                var se = pending_struct_exprs[k];
                int slot = var_end + pending_struct_rel_slots[k];
                if (se is StructLiteral) ((StructLiteral) se).temp_slot = slot;
                else if (se is CallExpr) ((CallExpr) se).temp_slot = slot;
                else if (se is MethodCallExpr) ((MethodCallExpr) se).temp_slot = slot;
                else if (se is MemberAccessExpr) ((MemberAccessExpr) se).temp_slot = slot;
                else if (se is VarRef) ((VarRef) se).temp_slot = slot;
                else if (se is LambdaExpr) ((LambdaExpr) se).temp_slot = slot;
                else if (se is TernaryExpr) ((TernaryExpr) se).temp_slot = slot;
                else if (se is CoalesceExpr) ((CoalesceExpr) se).temp_slot = slot;
            }

            ref_temp_start = var_end + struct_temp_slots;
            for (int k = 0; k < pending_ref_exprs.length; k++)
                pending_ref_exprs[k].ref_temp_slot = ref_temp_start + k;

            return var_end + struct_temp_slots + ref_temp_slots;
        }

        private void prepare_stmt (Statement s, ref int struct_temps, ref int ref_temps)
                throws SemanticError {
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                if (p.value is TemplateExpr) {
                    foreach (var part in ((TemplateExpr) p.value).parts)
                        prepare_expr (part, ref struct_temps, ref ref_temps);
                } else {
                    prepare_expr (p.value, ref struct_temps, ref ref_temps);
                }
            } else if (s is ExitStatement) {
                prepare_expr (((ExitStatement) s).value, ref struct_temps, ref ref_temps);
            } else if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (r.value != null) {
                    bind_delegate_target (r.value, current.return_type, current.return_type_name);
                    prepare_expr (r.value, ref struct_temps, ref ref_temps);
                }
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (lookup (d.name) >= 0)
                    throw new SemanticError.DUPLICATE_VARIABLE (
                        @"duplicate variable: $(d.name) at $(d.line):$(d.column)");
                if (!d.infer_type && d.init != null)
                    bind_delegate_target (d.init, d.decl_type, d.decl_type_name);
                if (d.init != null)
                    prepare_expr (d.init, ref struct_temps, ref ref_temps);
                ValaType vt = d.decl_type;
                string vtname = d.decl_type_name;
                ValaType init_t = ValaType.NULL;
                string init_tname = "";
                bool has_init = (d.init != null);
                if (d.infer_type && d.init != null) {
                    vt = expr_type_full (d.init, out vtname);
                    if (vt == ValaType.NULL)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot infer type of 'var $(d.name)' from 'null' at $(d.line):$(d.column)");
                    init_t = vt;
                    init_tname = vtname;
                } else if (d.init != null) {
                    coerce_byte_array_literal (d.init, vt, vtname);
                    init_t = expr_type_full (d.init, out init_tname);
                    if (!type_compatible (vt, vtname, init_t, init_tname))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot initialize $(type_label (vt, vtname)) variable '$(d.name)' with $(type_label (init_t, init_tname))$(compact_to_object_hint (init_t, init_tname)) at $(d.init.line):$(d.init.column)");
                } else if (d.init == null && da_needs_tracking (vt, vtname)) {
                    // Legal only if the definite-assignment pass approved it;
                    // the slot is zeroed (null) below and never read before
                    // the variable is assigned.
                }
                if (d.is_weak && ((vt != ValaType.CLASS && vt != ValaType.INTERFACE) || !is_nullable_type (vt, vtname)))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'weak' requires a nullable class or interface type, got $(type_label (vt, vtname)) at $(d.line):$(d.column)");
                var n = type_slots (vt, vtname);
                var slot = next_var_slot;
                next_var_slot += n;
                push_local (d.name, vt, vtname, slot, false, false, d.is_weak);
                int uidx = locals.length - 1;
                local_is_user[uidx] = (!d.name.has_prefix ("_") && !d.name.has_prefix ("#"));
                local_decl_line[uidx] = d.line;
                local_decl_col[uidx] = d.column;
                if (has_init)
                    update_non_null_on_assign (d.name, init_t, init_tname);
                else
                    invalidate_non_null_prefix (d.name);
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                var lslot = lookup (a.name);
                bool has_var_or_field = (lslot >= 0);
                if (lslot >= 0) {
                    bind_delegate_target (a.value, local_types[lslot], local_type_names[lslot]);
                } else {
                    var gi = lookup_global (a.name);
                    if (gi >= 0) {
                        has_var_or_field = true;
                        bind_delegate_target (a.value, global_types[gi], global_type_names[gi]);
                    } else {
                        bool bound = false;
                        if (current_class != null && !current.is_static) {
                            unowned ClassField? cf = null;
                            if (class_field_offset_slots (current_class, a.name, out cf) >= 0 && cf != null) {
                                bind_delegate_target (a.value, cf.field_type, cf.type_name);
                                bound = true;
                                has_var_or_field = true;
                            }
                        }
                        if (!bound && current_struct != null && !current.is_static) {
                            unowned StructField? sf = null;
                            if (struct_field_offset_slots (current_struct, a.name, out sf) >= 0 && sf != null) {
                                bind_delegate_target (a.value, sf.field_type, sf.type_name);
                                bound = true;
                                has_var_or_field = true;
                            }
                        }
                        if (!bound) {
                            unowned var sm = find_this_prop_setter (a.name);
                            if (sm != null && sm.params.length >= 2)
                                bind_delegate_target (a.value, sm.params[1].param_type, sm.params[1].type_name);
                        }
                    }
                }
                prepare_expr (a.value, ref struct_temps, ref ref_temps);
                if (has_var_or_field) {
                    string vtn = "";
                    var vt = expr_type_full (a.value, out vtn);
                    update_non_null_on_assign (a.name, vt, vtn);
                } else {
                    unowned var sm = find_this_prop_setter (a.name);
                    if (sm != null && sm.can_throw)
                        check_domains_handled (sm.throws_domains, a.line, a.column);
                }
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                if (fa.target is VarRef && static_field_global_of_type (((VarRef) fa.target).name, fa.field_name) >= 0) {
                    prepare_expr (fa.value, ref struct_temps, ref ref_temps);
                    return;
                }
                prepare_expr (fa.target, ref struct_temps, ref ref_temps);
                string tt_name = "";
                var tt = expr_type_full (fa.target, out tt_name);
                bool has_field = false;
                if (tt == ValaType.CLASS) {
                    unowned var cd = program.find_class (strip_null (tt_name));
                    unowned ClassField? cf = null;
                    if (cd != null && class_field_offset_slots (cd, fa.field_name, out cf) >= 0 && cf != null) {
                        bind_delegate_target (fa.value, cf.field_type, cf.type_name);
                        has_field = true;
                    }
                } else if (tt == ValaType.STRUCT) {
                    unowned var sd = program.find_struct (tt_name);
                    unowned StructField? sf = null;
                    if (sd != null && struct_field_offset_slots (sd, fa.field_name, out sf) >= 0 && sf != null) {
                        bind_delegate_target (fa.value, sf.field_type, sf.type_name);
                        has_field = true;
                    }
                }
                unowned var sm = find_prop_setter (tt, tt_name, fa.field_name);
                if (sm != null && sm.params.length >= 2)
                    bind_delegate_target (fa.value, sm.params[1].param_type, sm.params[1].type_name);
                prepare_expr (fa.value, ref struct_temps, ref ref_temps);
                if (has_field && fa.op == "=" && fa.target is VarRef) {
                    var vn = ((VarRef) fa.target).name;
                    var fkey = (vn == "this") ? fa.field_name : @"$(vn).$(fa.field_name)";
                    string vtn = "";
                    var vt = expr_type_full (fa.value, out vtn);
                    update_non_null_on_assign (fkey, vt, vtn);
                }
                if (sm != null && sm.can_throw)
                    check_domains_handled (sm.throws_domains, fa.line, fa.column);
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                prepare_expr (ia.target, ref struct_temps, ref ref_temps);
                prepare_expr (ia.index, ref struct_temps, ref ref_temps);
                prepare_expr (ia.value, ref struct_temps, ref ref_temps);
            } else if (s is LockStatement) {
                var lk = (LockStatement) s;
                prepare_expr (lk.target, ref struct_temps, ref ref_temps);
                var lock_mark = locals.length;
                var lk_slot = next_var_slot++;
                string lk_tn = "";
                expr_type_full (lk.target, out lk_tn);
                push_local (@"#lock_$(lock_mark)", ValaType.CLASS, strip_null (lk_tn), lk_slot, true);
                prepare_stmt (lk.body, ref struct_temps, ref ref_temps);
                deactivate_from (lock_mark);
            } else if (s is ExprStatement) {
                prepare_expr (((ExprStatement) s).expr, ref struct_temps, ref ref_temps);
            } else if (s is BlockStatement) {
                var saved = locals.length;
                foreach (var inner in ((BlockStatement) s).statements)
                    prepare_stmt (inner, ref struct_temps, ref ref_temps);
                deactivate_from (saved);
            } else if (s is IfStatement) {
                var i = (IfStatement) s;
                prepare_expr (i.condition, ref struct_temps, ref ref_temps);
                var snap = clone_non_null ();
                var nn_then = new GenericArray<string> ();
                var nn_else = new GenericArray<string> ();
                collect_non_null_when (i.condition, true, nn_then);
                collect_non_null_when (i.condition, false, nn_else);

                add_all_non_null (nn_then);
                var saved_then = locals.length;
                prepare_stmt (i.then_body, ref struct_temps, ref ref_temps);
                deactivate_from (saved_then);
                var after_then = clone_non_null ();

                GenericArray<string>? after_else = null;
                if (i.else_body != null) {
                    restore_non_null (snap);
                    add_all_non_null (nn_else);
                    var saved_else = locals.length;
                    prepare_stmt (i.else_body, ref struct_temps, ref ref_temps);
                    deactivate_from (saved_else);
                    after_else = clone_non_null ();
                }
                finalize_if_narrowing (i, snap, after_then, after_else, nn_then, nn_else);
            } else if (s is WhileStatement) {
                var w = (WhileStatement) s;
                prepare_expr (w.condition, ref struct_temps, ref ref_temps);
                var before_w = clone_non_null ();
                var nn_w = new GenericArray<string> ();
                collect_non_null_when (w.condition, true, nn_w);
                add_all_non_null (nn_w);
                var saved = locals.length;
                prepare_stmt (w.body, ref struct_temps, ref ref_temps);
                deactivate_from (saved);
                restore_non_null (before_w);
            } else if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                var before_dw = clone_non_null ();
                var saved = locals.length;
                prepare_stmt (dw.body, ref struct_temps, ref ref_temps);
                deactivate_from (saved);
                prepare_expr (dw.condition, ref struct_temps, ref ref_temps);
                restore_non_null (before_dw);
            } else if (s is ForStatement) {
                var fs = (ForStatement) s;
                var saved = locals.length;
                if (fs.init != null)
                    prepare_stmt (fs.init, ref struct_temps, ref ref_temps);
                if (fs.condition != null)
                    prepare_expr (fs.condition, ref struct_temps, ref ref_temps);
                var before_f = clone_non_null ();
                if (fs.condition != null) {
                    var nn_f = new GenericArray<string> ();
                    collect_non_null_when (fs.condition, true, nn_f);
                    add_all_non_null (nn_f);
                }
                if (fs.step != null)
                    prepare_stmt (fs.step, ref struct_temps, ref ref_temps);
                prepare_stmt (fs.body, ref struct_temps, ref ref_temps);
                restore_non_null (before_f);
                deactivate_from (saved);
            } else if (s is ForeachStatement) {
                var fe = (ForeachStatement) s;
                prepare_expr (fe.collection, ref struct_temps, ref ref_temps);
                string ct_name = "";
                var ct = expr_type_full (fe.collection, out ct_name);
                ValaType et = ValaType.INT;
                string et_name = "";
                bool is_ga = (ct == ValaType.CLASS) && find_generic_array_elem (ct_name, out et, out et_name);
                if (ct != ValaType.ARRAY && !is_ga)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"foreach requires an array collection, got $(type_label (ct, ct_name)) at $(fe.collection.line):$(fe.collection.column)");
                if (!is_ga)
                    parse_array_elem (ct_name, out et, out et_name);
                ValaType vtype = fe.infer_type ? et : fe.elem_type;
                string vtname = fe.infer_type ? et_name : fe.elem_type_name;
                if (!fe.infer_type && !type_compatible (vtype, vtname, et, et_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"foreach variable '$(fe.var_name)' expects $(type_label (vtype, vtname)), got $(type_label (et, et_name)) at $(fe.line):$(fe.column)");
                if (lookup (fe.var_name) >= 0)
                    throw new SemanticError.DUPLICATE_VARIABLE (
                        @"duplicate variable: $(fe.var_name) at $(fe.line):$(fe.column)");
                var col_mark = locals.length;
                var cslot = next_var_slot++;
                push_local (@"#fe_col_$(col_mark)", is_ga ? ValaType.CLASS : ValaType.ARRAY, strip_null (ct_name), cslot, false);

                var islot = next_var_slot++;
                push_local (@"#fe_idx_$(col_mark)", ValaType.INT, "", islot, false);

                var eslot = next_var_slot++;
                push_local (fe.var_name, vtype, vtname, eslot, false);

                prepare_stmt (fe.body, ref struct_temps, ref ref_temps);
                deactivate_from (col_mark);
            } else if (s is SwitchStatement) {
                var sw = (SwitchStatement) s;
                prepare_expr (sw.target, ref struct_temps, ref ref_temps);
                string st_name = "";
                var st = expr_type_full (sw.target, out st_name);
                if (st != ValaType.INT && st != ValaType.BOOL && st != ValaType.ENUM
                    && !(st == ValaType.STRING && !is_nullable_type (st, st_name))) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"switch does not support type $(type_label (st, st_name)) at $(sw.target.line):$(sw.target.column)");
                }
                var sw_mark = locals.length;
                var sw_slot = next_var_slot++;
                push_local (@"#sw_$(sw_mark)", st == ValaType.STRING ? ValaType.STRING : ValaType.INT, "", sw_slot, false);

                foreach (var sc in sw.cases) {
                    foreach (var v in sc.values) {
                        prepare_expr (v, ref struct_temps, ref ref_temps);
                        string vt_name = "";
                        var vt = expr_type_full (v, out vt_name);
                        if (!type_compatible (st, st_name, vt, vt_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"switch case expects $(type_label (st, st_name)), got $(type_label (vt, vt_name)) at $(v.line):$(v.column)");
                    }
                    var case_mark = locals.length;
                    foreach (var bs in sc.body)
                        prepare_stmt (bs, ref struct_temps, ref ref_temps);
                    deactivate_from (case_mark);
                }
                if (sw.has_default) {
                    var def_mark = locals.length;
                    foreach (var ds in sw.default_body)
                        prepare_stmt (ds, ref struct_temps, ref ref_temps);
                    deactivate_from (def_mark);
                }
                deactivate_from (sw_mark);
            } else if (s is ThrowStatement) {
                var ts = (ThrowStatement) s;
                unowned var ed = program.find_error_domain (ts.domain_name);
                if (ed == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown error domain '$(ts.domain_name)' at $(ts.line):$(ts.column)");
                if (ed.find_code (ts.code_name) == null)
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"error domain '$(ts.domain_name)' has no code '$(ts.code_name)' at $(ts.line):$(ts.column)");
                var one = new GenericArray<string> ();
                one.add (ts.domain_name);
                check_domains_handled (one, ts.line, ts.column);
                prepare_expr (ts.message, ref struct_temps, ref ref_temps);
            } else if (s is TryStatement) {
                var tr = (TryStatement) s;
                if (tr.has_finally) {
                    next_var_slot++; // fin_mode_slot
                    next_var_slot++; // fin_ret_slot
                }
                int saved_dom = active_catch_domains.length;
                foreach (var cc in tr.catches) {
                    check_domain_exists (cc.domain_name, cc.line, cc.column);
                    active_catch_domains.add (cc.domain_name);
                }
                var try_mark = locals.length;
                foreach (var st in tr.try_body)
                    prepare_stmt (st, ref struct_temps, ref ref_temps);
                deactivate_from (try_mark);
                while (active_catch_domains.length > saved_dom)
                    active_catch_domains.remove_index (active_catch_domains.length - 1);

                foreach (var cc in tr.catches) {
                    if (lookup (cc.var_name) >= 0)
                        throw new SemanticError.DUPLICATE_VARIABLE (
                            @"duplicate variable: $(cc.var_name) at $(cc.line):$(cc.column)");
                    var c_mark = locals.length;
                    var cslot = next_var_slot++;
                    push_local (cc.var_name, ValaType.ERROR,
                                cc.domain_name == "Error" ? "" : cc.domain_name,
                                cslot, false);
                    foreach (var st in cc.body)
                        prepare_stmt (st, ref struct_temps, ref ref_temps);
                    deactivate_from (c_mark);
                }
                if (tr.has_finally) {
                    var fin_mark = locals.length;
                    foreach (var fs in tr.finally_body)
                        prepare_stmt (fs, ref struct_temps, ref ref_temps);
                    deactivate_from (fin_mark);
                }
            }
        }

        private void prepare_expr (Expr e, ref int struct_temps, ref int ref_temps)
                throws SemanticError {
            if (e is UnaryExpr) {
                prepare_expr (((UnaryExpr) e).operand, ref struct_temps, ref ref_temps);
            } else if (e is SizeofExpr) {
                var sz = (SizeofExpr) e;
                if (sz.operand != null)
                    prepare_expr (sz.operand, ref struct_temps, ref ref_temps);
            } else if (e is TypeCheckExpr) {
                prepare_expr (((TypeCheckExpr) e).operand, ref struct_temps, ref ref_temps);
            } else if (e is SliceExpr) {
                var se = (SliceExpr) e;
                prepare_expr (se.target, ref struct_temps, ref ref_temps);
                prepare_expr (se.start, ref struct_temps, ref ref_temps);
                prepare_expr (se.end, ref struct_temps, ref ref_temps);
            } else if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                prepare_expr (te.condition, ref struct_temps, ref ref_temps);
                if (te.then_expr is LambdaExpr && ((LambdaExpr) te.then_expr).delegate_type_name == ""
                    && !(te.else_expr is NullLiteral) && !(te.else_expr is LambdaExpr)) {
                    string etn = "";
                    var et = expr_type_full (te.else_expr, out etn);
                    if (is_delegate_type (program, et, etn))
                        bind_delegate_target (te.then_expr, et, etn);
                } else if (te.else_expr is LambdaExpr && ((LambdaExpr) te.else_expr).delegate_type_name == ""
                           && !(te.then_expr is NullLiteral) && !(te.then_expr is LambdaExpr)) {
                    string ttn = "";
                    var tt = expr_type_full (te.then_expr, out ttn);
                    if (is_delegate_type (program, tt, ttn))
                        bind_delegate_target (te.else_expr, tt, ttn);
                }
                var snap = clone_non_null ();
                var nn_then = new GenericArray<string> ();
                var nn_else = new GenericArray<string> ();
                collect_non_null_when (te.condition, true, nn_then);
                collect_non_null_when (te.condition, false, nn_else);
                add_all_non_null (nn_then);
                prepare_expr (te.then_expr, ref struct_temps, ref ref_temps);
                restore_non_null (snap);
                add_all_non_null (nn_else);
                prepare_expr (te.else_expr, ref struct_temps, ref ref_temps);
                restore_non_null (snap);
                string res_tn = "";
                var res_t = expr_type_full (e, out res_tn);
                if (is_delegate_type (program, res_t, res_tn)) {
                    pending_struct_exprs.add (e);
                    pending_struct_rel_slots.add (struct_temps);
                    struct_temps += 2;
                    if (program_uses_heap) {
                        pending_ref_exprs.add (e);
                        ref_temps++;
                    }
                }
            } else if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                prepare_expr (ce.left, ref struct_temps, ref ref_temps);
                if (ce.right is LambdaExpr && ((LambdaExpr) ce.right).delegate_type_name == "") {
                    string ltn = "";
                    var lt = expr_type_full (ce.left, out ltn);
                    if (is_delegate_type (program, lt, ltn))
                        bind_delegate_target (ce.right, lt, ltn);
                }
                prepare_expr (ce.right, ref struct_temps, ref ref_temps);
                string res_tn = "";
                var res_t = expr_type_full (e, out res_tn);
                if (is_delegate_type (program, res_t, res_tn)) {
                    pending_struct_exprs.add (e);
                    pending_struct_rel_slots.add (struct_temps);
                    struct_temps += 2;
                    if (program_uses_heap) {
                        pending_ref_exprs.add (e);
                        ref_temps++;
                    }
                }
            } else if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                prepare_expr (b.left, ref struct_temps, ref ref_temps);
                if (b.op == "&&" || b.op == "||") {
                    var snap = clone_non_null ();
                    var nn_rhs = new GenericArray<string> ();
                    collect_non_null_when (b.left, b.op == "&&", nn_rhs);
                    add_all_non_null (nn_rhs);
                    prepare_expr (b.right, ref struct_temps, ref ref_temps);
                    restore_non_null (snap);
                } else {
                    prepare_expr (b.right, ref struct_temps, ref ref_temps);
                }
            } else if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                prepare_expr (ma.target, ref struct_temps, ref ref_temps);
                bool is_type_t = (ma.target is VarRef && is_type_name (((VarRef) ma.target).name));
                if (!is_type_t) {
                    string tt_name = "";
                    var tt = expr_type_full (ma.target, out tt_name);
                    unowned var gm = find_prop_getter (tt, tt_name, ma.member);
                    if (gm != null) {
                        if (gm.can_throw)
                            check_domains_handled (gm.throws_domains, ma.line, ma.column);
                        if (gm.return_type == ValaType.STRUCT) {
                            pending_struct_exprs.add (e);
                            pending_struct_rel_slots.add (struct_temps);
                            struct_temps += type_slots (ValaType.STRUCT, gm.return_type_name);
                            if (program_uses_heap && is_delegate_type (program, gm.return_type, gm.return_type_name)) {
                                pending_ref_exprs.add (e);
                                ref_temps++;
                            }
                        }
                    } else if (ma.target_del_type != "" && !has_real_member (tt, tt_name, ma.member)) {
                        unowned Function? mf = resolve_member_delegate_fn (tt, tt_name, ma.member);
                        if (mf != null) {
                            pending_struct_exprs.add (e);
                            pending_struct_rel_slots.add (struct_temps);
                            struct_temps += 2;
                            if (program_uses_heap && !mf.is_static) {
                                pending_ref_exprs.add (e);
                                ref_temps++;
                            }
                        }
                    } else if (tt == ValaType.CLASS) {
                        unowned var mcd = program.find_class (strip_null (tt_name));
                        unowned ClassField? mcf = null;
                        if (mcd != null && class_field_offset_slots (mcd, ma.member, out mcf) >= 0 && mcf != null && mcf.is_weak) {
                            pending_ref_exprs.add (e);
                            ref_temps++;
                        }
                    }
                } else if (ma.target_del_type != "") {
                    var vr = (VarRef) ma.target;
                    if (program.find_const (vr.name, ma.member) == null
                        && program.find_error_domain (vr.name) == null
                        && program.find_enum (vr.name) == null) {
                        unowned var mf = resolve_type_method (vr.name, ma.member);
                        if (mf != null && mf.is_static) {
                            pending_struct_exprs.add (e);
                            pending_struct_rel_slots.add (struct_temps);
                            struct_temps += 2;
                        }
                    }
                }
            } else if (e is VarRef) {
                var vr = (VarRef) e;
                if (vr.target_del_type != "") {
                    var tf = resolve_call_target (vr.name);
                    if (tf != null) {
                        pending_struct_exprs.add (e);
                        pending_struct_rel_slots.add (struct_temps);
                        struct_temps += 2;
                        if (program_uses_heap && tf.owner_class != "" && !tf.is_static) {
                            pending_ref_exprs.add (e);
                            ref_temps++;
                        }
                    }
                } else {
                    int vidx = lookup (vr.name);
                    if (vidx >= 0) {
                        local_used[vidx] = true;
                        if (local_is_weak[vidx]) {
                            pending_ref_exprs.add (e);
                            ref_temps++;
                        }
                    } else if (lookup_global (vr.name) < 0) {
                        unowned var gm = find_this_prop_getter (vr.name);
                        if (gm != null && gm.can_throw)
                            check_domains_handled (gm.throws_domains, vr.line, vr.column);
                        else if (current_class != null && !current.is_static) {
                            unowned ClassField? tcf = null;
                            if (class_field_offset_slots (current_class, vr.name, out tcf) >= 0 && tcf != null && tcf.is_weak) {
                                pending_ref_exprs.add (e);
                                ref_temps++;
                            }
                        }
                    }
                }
            } else if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                prepare_expr (ix.target, ref struct_temps, ref ref_temps);
                prepare_expr (ix.index, ref struct_temps, ref ref_temps);
            } else if (e is ArrayNewExpr) {
                prepare_expr (((ArrayNewExpr) e).length_expr, ref struct_temps, ref ref_temps);
            } else if (e is ArrayLiteralExpr) {
                foreach (var el in ((ArrayLiteralExpr) e).elements)
                    prepare_expr (el, ref struct_temps, ref ref_temps);
            } else if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                unowned var cd = program.find_class (cn.class_name);
                unowned Function? ctor_fn = (cd != null)
                    ? (cn.ctor_name != "" ? cd.find_own_named_ctor (cn.ctor_name) : cd.ctor)
                    : null;
                if (ctor_fn != null) {
                    fill_default_args (ctor_fn, 1, cn.args);
                    for (int ai = 0; ai < cn.args.length && (1 + ai) < ctor_fn.params.length; ai++) {
                        var p = ctor_fn.params[1 + ai];
                        bind_delegate_target (cn.args[ai], p.param_type, p.type_name);
                    }
                    if (ctor_fn.can_throw)
                        check_domains_handled (ctor_fn.throws_domains, cn.line, cn.column);
                }
                foreach (var a in cn.args)
                    prepare_expr (a, ref struct_temps, ref ref_temps);
                if (cd != null) {
                    for (int ii = 0; ii < cn.init_names.length; ii++) {
                        var iname = cn.init_names[ii];
                        unowned ClassField? cf = null;
                        if (class_field_offset_slots (cd, iname, out cf) >= 0 && cf != null) {
                            bind_delegate_target (cn.init_values[ii], cf.field_type, cf.type_name);
                        } else {
                            unowned var sm = find_prop_setter (ValaType.CLASS, cd.name, iname);
                            if (sm != null && sm.params.length >= 2)
                                bind_delegate_target (cn.init_values[ii], sm.params[1].param_type, sm.params[1].type_name);
                        }
                    }
                    foreach (var iname in cn.init_names) {
                        unowned var sm = find_prop_setter (ValaType.CLASS, cd.name, iname);
                        if (sm != null && sm.can_throw)
                            check_domains_handled (sm.throws_domains, cn.line, cn.column);
                    }
                }
                foreach (var iv in cn.init_values)
                    prepare_expr (iv, ref struct_temps, ref ref_temps);
            } else if (e is TemplateExpr) {
                foreach (var part in ((TemplateExpr) e).parts)
                    prepare_expr (part, ref struct_temps, ref ref_temps);
            } else if (e is StructLiteral) {
                var lit = (StructLiteral) e;
                unowned var sd = program.find_struct (lit.struct_name);
                if (sd != null) {
                    for (int fi = 0; fi < lit.field_names.length; fi++) {
                        unowned StructField? fld = null;
                        if (struct_field_offset_slots (sd, lit.field_names[fi], out fld) >= 0 && fld != null)
                            bind_delegate_target (lit.field_values[fi], fld.field_type, fld.type_name);
                    }
                }
                foreach (var fv in lit.field_values)
                    prepare_expr (fv, ref struct_temps, ref ref_temps);
                pending_struct_exprs.add (e);
                pending_struct_rel_slots.add (struct_temps);
                struct_temps += type_slots (ValaType.STRUCT, lit.struct_name);
            } else if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                string bi_kind = "";
                ValaType bi_ret = ValaType.VOID;
                if (is_builtin_method_call (mc, out bi_kind, out bi_ret)) {
                    if (bi_kind != "int_parse" && bi_kind != "float_parse" && bi_kind != "double_parse" && mc.target != null)
                        prepare_expr (mc.target, ref struct_temps, ref ref_temps);
                    foreach (var a in mc.args)
                        prepare_expr (a, ref struct_temps, ref ref_temps);
                    if (bi_kind == "int_to_string") {
                        string rtn = "";
                        if (mc.target != null)
                            expr_type_full (mc.target, out rtn);
                        if (is_unsigned_int_type (rtn))
                            need_uint_to_str = true;
                        else
                            need_int_to_str = true;
                    } else if (bi_kind == "float_to_string" || bi_kind == "double_to_string")
                        need_double_to_str = true;
                    else if (bi_kind == "str_has_prefix")
                        need_str_has_prefix = true;
                    else if (bi_kind == "str_has_suffix")
                        need_str_has_suffix = true;
                    else if (bi_kind == "str_substring")
                        need_str_slice = true;
                    else if (bi_kind == "str_char_count")
                        need_utf8_char_count = true;
                    else if (bi_kind == "str_get_char")
                        need_utf8_get_char = true;
                    else if (bi_kind == "str_validate")
                        need_utf8_validate = true;
                    else if (bi_kind == "str_index_of" || bi_kind == "str_contains")
                        need_str_index_of = true;
                    else if (bi_kind == "int_parse")
                        need_str_to_int = true;
                    else if (bi_kind == "float_parse" || bi_kind == "double_parse")
                        need_str_to_double = true;
                    else if (bi_kind == "async_run" || bi_kind == "async_run_parallel")
                        need_async = true;
                } else {
            Expr? begin_recv = null;
                    var begin_fn = resolve_begin_call (mc, out begin_recv);
                    if (begin_fn != null) {
                        if (begin_recv != null)
                            prepare_expr (begin_recv, ref struct_temps, ref ref_temps);
                        int p_off = (begin_fn.owner_class != "" && !begin_fn.is_static) ? 1 : 0;
                        fill_default_args (begin_fn, p_off, mc.args);
                        for (int ai = 0; ai < mc.args.length && (p_off + ai) < begin_fn.params.length; ai++) {
                            var p = begin_fn.params[p_off + ai];
                            bind_delegate_target (mc.args[ai], p.param_type, p.type_name);
                        }
                        if (program_uses_heap) {
                            pending_ref_exprs.add (e);
                            ref_temps++;
                        }
                        foreach (var a in mc.args)
                            prepare_expr (a, ref struct_temps, ref ref_temps);
                        return;
                    }
                    Expr? sig_obj = null;
                    unowned SignalDecl? sig_conn = resolve_signal_connect (mc, out sig_obj);
                    if (sig_conn != null) {
                        need_signal = true;
                        if (sig_obj != null)
                            prepare_expr (sig_obj, ref struct_temps, ref ref_temps);
                        if (mc.method_name == "connect" && mc.args.length > 0)
                            bind_delegate_target (mc.args[0], ValaType.STRUCT, sig_conn.handler_delegate_name);
                        foreach (var a in mc.args)
                            prepare_expr (a, ref struct_temps, ref ref_temps);
                        return;
                    }
                    if (mc.target != null)
                        prepare_expr (mc.target, ref struct_temps, ref ref_temps);
                    unowned DelegateDecl? md = (mc.target != null && !mc.is_base_call)
                        ? resolve_member_delegate (mc.target, mc.method_name)
                        : null;
                    if (md != null) {
                        for (int ai = 0; ai < mc.args.length && ai < md.params.length; ai++) {
                            var p = md.params[ai];
                            bind_delegate_target (mc.args[ai], p.param_type, p.type_name);
                        }
                        foreach (var a in mc.args)
                            prepare_expr (a, ref struct_temps, ref ref_temps);
                        if (md.throws_domains.length > 0)
                            check_domains_handled (md.throws_domains, mc.line, mc.column);
                        if (md.return_type == ValaType.STRUCT) {
                            pending_struct_exprs.add (e);
                            pending_struct_rel_slots.add (struct_temps);
                            struct_temps += type_slots (ValaType.STRUCT, md.return_type_name);
                            if (program_uses_heap && is_delegate_type (program, md.return_type, md.return_type_name)) {
                                pending_ref_exprs.add (e);
                                ref_temps++;
                            }
                        }
                    } else {
                        var m = resolve_method_call_fn (mc);
                        if (m != null) {
                            int param_off = m.is_static ? 0 : 1;
                            fill_default_args (m, param_off, mc.args);
                            for (int ai = 0; ai < mc.args.length && (param_off + ai) < m.params.length; ai++) {
                                var p = m.params[param_off + ai];
                                bind_delegate_target (mc.args[ai], p.param_type, p.type_name);
                            }
                            if (m.can_throw)
                                check_domains_handled (m.throws_domains, mc.line, mc.column);
                            if (m.return_type == ValaType.STRUCT) {
                                pending_struct_exprs.add (e);
                                pending_struct_rel_slots.add (struct_temps);
                                struct_temps += type_slots (ValaType.STRUCT, m.return_type_name);
                                if (program_uses_heap && is_delegate_type (program, m.return_type, m.return_type_name)) {
                                    pending_ref_exprs.add (e);
                                    ref_temps++;
                                }
                            }
                        }
                        foreach (var a in mc.args)
                            prepare_expr (a, ref struct_temps, ref ref_temps);
                    }
                }
            } else if (e is YieldExpr) {
                var ye = (YieldExpr) e;
                if (ye.value != null) {
                    prepare_expr (ye.value, ref struct_temps, ref ref_temps);
                    string yt_name = "";
                    var yt = expr_type_full (ye.value, out yt_name);
                    ValaType inner_t = ValaType.VOID;
                    string inner_name = "";
                    if (yt == ValaType.CLASS && parse_async_task_type_name (yt_name, out inner_t, out inner_name)) {
                        if (program_uses_heap && is_ref_type (inner_t)) {
                            pending_ref_exprs.add (e);
                            ref_temps++;
                        }
                    }
                    if (ye.value is CallExpr) {
                        var cf = resolve_call_target (((CallExpr) ye.value).callee);
                        if (cf != null && cf.can_throw)
                            check_domains_handled (cf.throws_domains, ye.line, ye.column);
                    } else if (ye.value is MethodCallExpr) {
                        var mce = (MethodCallExpr) ye.value;
                        string bk = "";
                        ValaType br = ValaType.VOID;
                        if (!is_builtin_method_call (mce, out bk, out br)) {
                            Expr? dummy_r = null;
                            var mf = resolve_begin_call (mce, out dummy_r);
                            if (mf == null) mf = resolve_method_call_fn (mce);
                            if (mf != null && mf.can_throw)
                                check_domains_handled (mf.throws_domains, ye.line, ye.column);
                        }
                    }
                }
            } else if (e is CallExpr) {
                var ce = (CallExpr) e;
                if (ce.callee == "__planc_host_read_file" || ce.callee == "__planc_host_write_file") {
                    var doms = new GenericArray<string> ();
                    doms.add ("FileError");
                    check_domains_handled (doms, ce.line, ce.column);
                }
                if (ce.callee == "__planc_host_eprint") need_eprint = true;
                else if (ce.callee == "__planc_host_chmod") need_chmod = true;
                else if (ce.callee == "__planc_host_bytes_to_str") need_bytes_to_str = true;
                else if (ce.callee == "__planc_host_read_file") need_read_file = true;
                else if (ce.callee == "__planc_host_write_file") need_write_file = true;
                if (is_host_intrinsic (ce.callee)) {
                    foreach (var a in ce.args)
                        prepare_expr (a, ref struct_temps, ref ref_temps);
                } else {
                    unowned DelegateDecl? dd = resolve_delegate_callee (ce.callee);
                    if (dd != null) {
                        for (int ai = 0; ai < ce.args.length && ai < dd.params.length; ai++) {
                            var p = dd.params[ai];
                            bind_delegate_target (ce.args[ai], p.param_type, p.type_name);
                        }
                        foreach (var a in ce.args)
                            prepare_expr (a, ref struct_temps, ref ref_temps);
                        if (dd.throws_domains.length > 0)
                            check_domains_handled (dd.throws_domains, ce.line, ce.column);
                        if (dd.return_type == ValaType.STRUCT) {
                            pending_struct_exprs.add (e);
                            pending_struct_rel_slots.add (struct_temps);
                            struct_temps += type_slots (ValaType.STRUCT, dd.return_type_name);
                            if (program_uses_heap && is_delegate_type (program, dd.return_type, dd.return_type_name)) {
                                pending_ref_exprs.add (e);
                                ref_temps++;
                            }
                        }
                    } else {
                        var f = resolve_call_target (ce.callee, ce);
                        if (f != null) {
                            bool is_synth_init = f.name.has_prefix ("__planc_init_");
                            int param_off = (f.owner_class != "" && !is_synth_init && !f.is_static) ? 1 : 0;
                            fill_default_args (f, param_off, ce.args);
                            for (int ai = 0; ai < ce.args.length && (param_off + ai) < f.params.length; ai++) {
                                var p = f.params[param_off + ai];
                                bind_delegate_target (ce.args[ai], p.param_type, p.type_name);
                            }
                            if (f.can_throw && !f.is_async)
                                check_domains_handled (f.throws_domains, ce.line, ce.column);
                            if (f.return_type == ValaType.STRUCT) {
                                pending_struct_exprs.add (e);
                                pending_struct_rel_slots.add (struct_temps);
                                struct_temps += type_slots (ValaType.STRUCT, f.return_type_name);
                                if (program_uses_heap && is_delegate_type (program, f.return_type, f.return_type_name)) {
                                    pending_ref_exprs.add (e);
                                    ref_temps++;
                                }
                            }
                        }
                        foreach (var a in ce.args)
                            prepare_expr (a, ref struct_temps, ref ref_temps);
                    }
                }
            } else if (e is IncDecExpr) {
                prepare_expr (((IncDecExpr) e).target, ref struct_temps, ref ref_temps);
            } else if (e is LambdaExpr) {
                var lam = (LambdaExpr) e;
                unowned var dd = (lam.delegate_type_name != "") ? program.find_delegate (lam.delegate_type_name) : null;
                if (dd == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"lambda expression requires a known delegate target type at $(lam.line):$(lam.column)");
                if (lam.param_names.length != dd.params.length)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"lambda expects $(dd.params.length) parameter(s) for delegate '$(dd.name)', got $(lam.param_names.length) at $(lam.line):$(lam.column)");
                if (lam.synth_func_name == "") {
                    var bound = new GenericArray<string> ();
                    foreach (var pn in lam.param_names)
                        bound.add (pn);
                    var free_vars = new GenericArray<string> ();
                    if (lam.expr_body != null)
                        collect_expr_free_vars (lam.expr_body, bound, free_vars);
                    foreach (var st in lam.body)
                        collect_stmt_free_vars (st, bound, free_vars);

                    var ref_names = new GenericArray<string> ();
                    var ref_types = new GenericArray<ValaType> ();
                    var ref_tnames = new GenericArray<string> ();
                    var val_names = new GenericArray<string> ();
                    var val_types = new GenericArray<ValaType> ();
                    var val_tnames = new GenericArray<string> ();
                    bool captures_this = false;
                    foreach (var fv in free_vars) {
                        if (fv == "this") {
                            captures_this = true;
                            ref_names.add ("this");
                            ref_types.add (ValaType.CLASS);
                            ref_tnames.add (current_class.name);
                            continue;
                        }
                        var lslot = lookup (fv);
                        if (lslot < 0)
                            continue;
                        if (local_by_ref[lslot])
                            throw new SemanticError.TYPE_MISMATCH (
                                @"lambda cannot capture 'ref'/'out' parameter '$(fv)' at $(lam.line):$(lam.column)");
                        var ct = local_types[lslot];
                        var ctn = local_type_names[lslot];
                        if (ct == ValaType.STRUCT)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"lambda cannot capture value struct '$(fv)' at $(lam.line):$(lam.column)");
                        if (is_ref_type (ct)) {
                            ref_names.add (fv);
                            ref_types.add (ct);
                            ref_tnames.add (ctn);
                        } else {
                            val_names.add (fv);
                            val_types.add (ct);
                            val_tnames.add (ctn);
                        }
                    }
                    lam.ref_cap_count = ref_names.length;
                    for (int ri = 0; ri < ref_names.length; ri++) {
                        lam.captured_names.add (ref_names[ri]);
                        lam.captured_types.add (ref_types[ri]);
                        lam.captured_type_names.add (ref_tnames[ri]);
                    }
                    for (int vi = 0; vi < val_names.length; vi++) {
                        lam.captured_names.add (val_names[vi]);
                        lam.captured_types.add (val_types[vi]);
                        lam.captured_type_names.add (val_tnames[vi]);
                    }

                    lam.synth_func_name = @"__planc_lambda_$(lambda_counter++)";
                    var synth = new Function () {
                        name = lam.synth_func_name,
                        return_type = dd.return_type,
                        return_type_name = dd.return_type_name,
                        owner_class = (captures_this && current_class != null) ? current_class.name : "",
                        from_lambda = lam,
                        line = lam.line,
                        column = lam.column
                    };
                    synth.params.add (new Param () {
                        param_type = ValaType.STRING,
                        type_name = "string?",
                        name = "#env",
                        unmanaged = true,
                        line = lam.line,
                        column = lam.column
                    });
                    for (int pi = 0; pi < dd.params.length; pi++) {
                        var dp = dd.params[pi];
                        synth.params.add (new Param () {
                            param_type = dp.param_type,
                            type_name = dp.type_name,
                            name = lam.param_names[pi],
                            is_ref = dp.is_ref,
                            is_out = dp.is_out,
                            line = lam.line,
                            column = lam.column
                        });
                    }
                    foreach (var td in dd.throws_domains)
                        synth.throws_domains.add (td);
                    if (lam.expr_body != null) {
                        if (dd.return_type == ValaType.VOID) {
                            synth.body.add (new ExprStatement () {
                                expr = lam.expr_body,
                                line = lam.line,
                                column = lam.column
                            });
                        } else {
                            synth.body.add (new ReturnStatement () {
                                value = lam.expr_body,
                                line = lam.line,
                                column = lam.column
                            });
                        }
                    } else {
                        foreach (var bs in lam.body)
                            synth.body.add (bs);
                    }
                    program.functions.add (synth);
                }
                pending_struct_exprs.add (e);
                pending_struct_rel_slots.add (struct_temps);
                struct_temps += 2;
                if (program_uses_heap && lam.captured_names.length > 0) {
                    pending_ref_exprs.add (e);
                    ref_temps++;
                }
            }
            if (program_uses_heap && is_owned_expr (e)) {
                pending_ref_exprs.add (e);
                ref_temps++;
            }
        }

        private delegate void ExprVisitor (Expr? e);

        private void walk_expr_children (Expr e, ExprVisitor fn) {
            if (e is UnaryExpr) {
                fn (((UnaryExpr) e).operand);
            } else if (e is SizeofExpr) {
                var sz = (SizeofExpr) e;
                if (sz.operand != null)
                    fn (sz.operand);
            } else if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                fn (b.left);
                fn (b.right);
            } else if (e is MemberAccessExpr) {
                fn (((MemberAccessExpr) e).target);
            } else if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                fn (ix.target);
                fn (ix.index);
            } else if (e is ArrayNewExpr) {
                fn (((ArrayNewExpr) e).length_expr);
            } else if (e is ArrayLiteralExpr) {
                foreach (var el in ((ArrayLiteralExpr) e).elements)
                    fn (el);
            } else if (e is TemplateExpr) {
                foreach (var part in ((TemplateExpr) e).parts)
                    fn (part);
            } else if (e is StructLiteral) {
                foreach (var fv in ((StructLiteral) e).field_values)
                    fn (fv);
            } else if (e is CallExpr) {
                foreach (var a in ((CallExpr) e).args)
                    fn (a);
            } else if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                foreach (var a in cn.args)
                    fn (a);
                foreach (var iv in cn.init_values)
                    fn (iv);
            } else if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    fn (mc.target);
                foreach (var a in mc.args)
                    fn (a);
            } else if (e is TypeCheckExpr) {
                fn (((TypeCheckExpr) e).operand);
            } else if (e is SliceExpr) {
                var se = (SliceExpr) e;
                fn (se.target);
                fn (se.start);
                fn (se.end);
            } else if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                fn (te.condition);
                fn (te.then_expr);
                fn (te.else_expr);
            } else if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                fn (ce.left);
                fn (ce.right);
            } else if (e is IncDecExpr) {
                fn (((IncDecExpr) e).target);
            } else if (e is YieldExpr) {
                var ye = (YieldExpr) e;
                if (ye.value != null)
                    fn (ye.value);
            }
        }

        private void generate_async_function (Function f) throws SemanticError {
            need_async = true;
            current = f;
            current_file = f.file;
            int ref_temp_start = 0;
            var total_slots = prepare_function (f, out ref_temp_start);

            current_class = (f.owner_class != "") ? program.find_class (f.owner_class) : null;
            current_struct = (f.owner_class != "") ? program.find_struct (f.owner_class) : null;
            current_enum = (f.owner_class != "") ? program.find_enum (f.owner_class) : null;
            cur_ref_temp_start = ref_temp_start;
            cur_total_slots = total_slots;
            cur_func_throw_label = emitter.new_label ();
            need_func_throw = false;
            unwind_labels = new GenericArray<Label> ();
            unwind_marks = new GenericArray<int> ();
            finally_labels = new GenericArray<Label> ();
            finally_mode_slots = new GenericArray<int> ();
            finally_ret_slots = new GenericArray<int> ();
            finally_marks = new GenericArray<int> ();
            live_stmt_ref_slots = new GenericArray<int> ();
            active_catch_domains = new GenericArray<string> ();
            non_null_vars = new GenericArray<string> ();
            reset_locals ();
            next_var_slot = 0;
            push_depth = 0;
            break_labels = new GenericArray<Label> ();
            continue_labels = new GenericArray<Label> ();
            break_scope_marks = new GenericArray<int> ();
            continue_scope_marks = new GenericArray<int> ();

            // 1. Emit __async_resume_<f.name>(AsyncTask* rdi)
            var resume_name = @"__async_resume_$(f.name)";
            in_async_resume = true;
            async_resume_labels = new GenericArray<Label> ();
            var l_state0 = emitter.new_label ();
            async_resume_labels.add (l_state0);
            var l_dispatch = emitter.new_label ();

            var resume_start = emitter.here ();
            emitter.push_rbp ();
            emitter.mov_rsp_to_rbp ();
            emitter.sub_rsp (16);
            emitter.mov_rax_rdi ();
            emitter.store_rbp_disp (-8);
            emitter.async_task_rbp_offset = -8;
            emitter.branch (BranchKind.JMP, l_dispatch);

            emitter.bind (l_state0);
            var param_slots = new int[f.params.length];
            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                bool by_ref = p.is_ref || p.is_out;
                if (by_ref)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'async' function '$(f.name)' cannot have 'ref' or 'out' parameters at $(p.line):$(p.column)");
                param_slots[i] = next_var_slot++;
                if (p.param_type == ValaType.STRUCT)
                    next_var_slot += type_slots (ValaType.STRUCT, p.type_name);
                push_local (p.name, p.param_type, p.type_name, param_slots[i], p.unmanaged, false);
            }
            err_prop_slot = next_var_slot++;

            foreach (var s in f.body)
                gen_statement (s);

            if (program_uses_heap)
                unref_locals_from (0);
            if (f.return_type == ValaType.STRING)
                emitter.lea_rax_rip (emitter.add_string (""));
            else
                emitter.xor_eax ();
            emitter.mov_rsi_rax ();
            emitter.load_rbp_disp (-8);
            emitter.mov_rdi_rax ();
            emitter.xor_edx ();
            call_aligned ("__planc_async_finish");
            emitter.leave ();
            emitter.ret ();

            if (need_func_throw) {
                emitter.bind (cur_func_throw_label);
                emitter.load_local (err_prop_slot);
                emitter.push_rax ();
                emitter.load_rbp_disp (-8);
                emitter.mov_rdi_rax ();
                emitter.xor_eax ();
                emitter.mov_rsi_rax ();
                emitter.pop_reg (Reg.RDX);
                call_aligned ("__planc_async_finish");
                emitter.leave ();
                emitter.ret ();
            }

            emitter.bind (l_dispatch);
            emitter.load_rbp_disp (-8);
            emitter.load_rax_disp (24);
            for (int si = 0; si < async_resume_labels.length; si++) {
                emitter.mov_rcx_rax ();
                emitter.mov_rax_imm ((int64) si);
                emitter.cmp_rax_rcx ();
                emitter.mov_rax_rcx ();
                emitter.branch (BranchKind.JE, async_resume_labels[si]);
            }
            emitter.leave ();
            emitter.ret ();
            symbols.add (new Symbol (resume_name, resume_start, emitter.here () - resume_start));

            emitter.async_task_rbp_offset = 0;
            in_async_resume = false;
            int frame_slots = (cur_total_slots > next_var_slot) ? cur_total_slots : next_var_slot;

            // 2. Emit wrapper f.name(params...) -> AsyncTask*
            var start = emitter.here ();
            emitter.push_rbp ();
            emitter.mov_rsp_to_rbp ();
            int task_slot = f.params.length;
            emitter.sub_rsp (align16 (8 * (task_slot + 2)));

            int gpr_idx = 0;
            int xmm_idx = 0;
            int stack_idx = 0;
            for (int i = 0; i < f.params.length; i++) {
                bool is_fp = is_fp_type (f.params[i].param_type);
                if (is_fp && xmm_idx < 8) {
                    emitter.movq_rax_xmm (xmm_idx++);
                    emitter.store_local (i);
                } else if (!is_fp && gpr_idx < NUM_ARG_REGS) {
                    emitter.store_local_reg (i, arg_reg (gpr_idx++));
                } else {
                    emitter.load_rbp_disp (16 + 8 * stack_idx++);
                    emitter.store_local (i);
                }
            }

            emitter.lea_rax_fn (resume_name);
            emitter.mov_rdi_rax ();
            emitter.mov_esi_imm ((uint32) frame_slots);
            call_aligned ("__planc_async_spawn");
            emitter.store_local (task_slot);

            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                emitter.load_local (i);
                if (program_uses_heap && !p.unmanaged && is_ref_type (p.param_type)) {
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_ref");
                }
                emitter.push_rax ();
                emitter.load_local (task_slot);
                emitter.mov_rcx_rax ();
                emitter.pop_rax ();
                emitter.store_rcx_disp_rax (80 + param_slots[i] * 8);
            }

            emitter.load_local (task_slot);
            emitter.mov_rdi_rax ();
            call_aligned ("__planc_async_enqueue");

            emitter.load_local (task_slot);
            emitter.xor_edx ();
            emitter.leave ();
            emitter.ret ();
            symbols.add (new Symbol (f.name, start, emitter.here () - start));
        }

        private void generate_function (Function f) throws SemanticError {
            if (f.is_asm_body) {
                if (!allow_asm) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"[AsmBody] is forbidden under --no-asm in '$(f.name)' at $(f.asm_line):$(f.asm_column)");
                }
                var start = emitter.here ();
                AsmAssembler.assemble (emitter, program, f);
                symbols.add (new Symbol (f.name, start, emitter.here () - start));
                return;
            }
            if (f.is_async) {
                generate_async_function (f);
                return;
            }
            current = f;
            current_file = f.file;
            int ref_temp_start = 0;
            var total_slots = prepare_function (f, out ref_temp_start);

            current_class = (f.owner_class != "") ? program.find_class (f.owner_class) : null;
            current_struct = (f.owner_class != "") ? program.find_struct (f.owner_class) : null;
            current_enum = (f.owner_class != "") ? program.find_enum (f.owner_class) : null;
            cur_ref_temp_start = ref_temp_start;
            cur_total_slots = total_slots;
            cur_func_throw_label = emitter.new_label ();
            need_func_throw = false;
            unwind_labels = new GenericArray<Label> ();
            unwind_marks = new GenericArray<int> ();
            finally_labels = new GenericArray<Label> ();
            finally_mode_slots = new GenericArray<int> ();
            finally_ret_slots = new GenericArray<int> ();
            finally_marks = new GenericArray<int> ();
            live_stmt_ref_slots = new GenericArray<int> ();
            active_catch_domains = new GenericArray<string> ();
            non_null_vars = new GenericArray<string> ();
            reset_locals ();
            next_var_slot = 0;
            push_depth = 0;
            break_labels = new GenericArray<Label> ();
            continue_labels = new GenericArray<Label> ();
            break_scope_marks = new GenericArray<int> ();
            continue_scope_marks = new GenericArray<int> ();

            var start = emitter.here ();

            emitter.push_rbp ();
            emitter.mov_rsp_to_rbp ();
            emitter.sub_rsp (align16 (8 * total_slots));

            // Zero all ref temp slots in the prologue so unevaluated
            // short-circuit branches never leave stack garbage in them.
            emitter.zero_local_batch (ref_temp_start, total_slots);

            var param_raw_slots = new int[f.params.length];
            var param_final_slots = new int[f.params.length];
            int gpr_idx = 0;
            int xmm_idx = 0;
            int stack_idx = 0;
            for (int i = 0; i < f.params.length; i++) {
                var raw_slot = next_var_slot++;
                param_raw_slots[i] = raw_slot;
                bool by_ref = f.params[i].is_ref || f.params[i].is_out;
                bool is_fp = !by_ref && is_fp_type (f.params[i].param_type);
                if (is_fp && xmm_idx < 8) {
                    emitter.movq_rax_xmm (xmm_idx++);
                    emitter.store_local (raw_slot);
                } else if (!is_fp && gpr_idx < NUM_ARG_REGS) {
                    emitter.store_local_reg (raw_slot, arg_reg (gpr_idx++));
                } else {
                    emitter.load_rbp_disp (16 + 8 * stack_idx++);
                    emitter.store_local (raw_slot);
                }
                if (f.params[i].param_type == ValaType.STRUCT && !by_ref) {
                    var n = type_slots (ValaType.STRUCT, f.params[i].type_name);
                    param_final_slots[i] = next_var_slot;
                    next_var_slot += n;
                } else {
                    param_final_slots[i] = raw_slot;
                }
            }

            // Retain borrowed value parameters, or clear `out` storage via Decision A2.
            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                bool by_ref = p.is_ref || p.is_out;
                if (by_ref) {
                    if (p.is_out) {
                        if (is_ref_type (p.param_type)) {
                            if (program_uses_heap) {
                                emitter.load_local (param_final_slots[i]);
                                emitter.load_rax_disp (0);
                                emitter.mov_rdi_rax ();
                                call_aligned ("__planc_unref");
                            }
                            emitter.load_local (param_final_slots[i]);
                            emitter.mov_rcx_rax ();
                            if (p.param_type == ValaType.STRING && !is_nullable_type (p.param_type, p.type_name))
                                emitter.lea_rax_rip (emitter.add_string (""));
                            else
                                emitter.xor_eax ();
                            emitter.store_rcx_disp_rax (0);
                        } else if (p.param_type == ValaType.STRUCT) {
                            unowned var sd = program.find_struct (p.type_name);
                            emitter.load_local (param_final_slots[i]);
                            emitter.mov_rcx_rax ();
                            if (program_uses_heap && sd != null && struct_has_string (sd))
                                unref_struct_at_rcx (sd, 0);
                            if (sd != null)
                                init_struct_at_rcx (sd, 0);
                        } else {
                            emitter.load_local (param_final_slots[i]);
                            emitter.mov_rcx_rax ();
                            emitter.xor_eax ();
                            emitter.store_rcx_disp_rax (0);
                        }
                    }
                } else if (p.param_type == ValaType.STRUCT) {
                    var n = type_slots (ValaType.STRUCT, p.type_name);
                    emitter.load_local (param_raw_slots[i]);
                    emitter.lea_rcx_rbp_disp (struct_base_disp (param_final_slots[i], n));
                    copy_struct_rax_to_rcx (n);
                    if (program_uses_heap) {
                        unowned var sd = program.find_struct (p.type_name);
                        if (sd != null && struct_has_string (sd))
                            ref_struct_at_rcx (sd, 0);
                    }
                } else if (program_uses_heap && !p.unmanaged && is_ref_type (p.param_type)) {
                    emitter.load_local (param_final_slots[i]);
                    emitter.mov_rdi_rax ();
                    emitter.call_rel32 ("__planc_ref");
                }
                push_local (p.name, p.param_type, p.type_name, param_final_slots[i], p.unmanaged || by_ref, by_ref);
            }

            if (f.from_lambda != null) {
                var lam = f.from_lambda;
                for (int ci = 0; ci < lam.captured_names.length; ci++) {
                    var ct = lam.captured_types[ci];
                    var ctn = lam.captured_type_names[ci];
                    var cslot = next_var_slot++;
                    emitter.load_local (0); // #env
                    emitter.load_rax_disp (16 + 8 * ci);
                    emitter.store_local (cslot);
                    if (program_uses_heap && is_ref_type (ct)) {
                        emitter.mov_rdi_rax ();
                        call_aligned ("__planc_ref");
                    }
                    push_local (lam.captured_names[ci], ct, ctn, cslot, false);
                }
            }
            // Allocated after the capture slots so the generation layout
            // matches prepare_function's (params, captures, err slot).
            err_prop_slot = next_var_slot++;

            if (f.is_dtor && f.name.has_prefix ("__planc_dtor_")) {
                emit_class_finalizer_body ();
                emitter.leave ();
                emitter.ret ();
                symbols.add (new Symbol (f.name, start, emitter.here () - start));
                return;
            }

            if (f.is_compact_free) {
                emit_compact_free_body ();
                emitter.leave ();
                emitter.ret ();
                symbols.add (new Symbol (f.name, start, emitter.here () - start));
                return;
            }

            if (f.is_ctor && f.has_this_call && current_class != null) {
                unowned Function? target_ctor = (f.this_ctor_subname == "")
                    ? current_class.ctor
                    : current_class.find_own_named_ctor (f.this_ctor_subname);
                if (target_ctor == null || target_ctor == f)
                    throw new SemanticError.UNKNOWN_FUNCTION (
                        @"invalid ': this' constructor delegation in '$(current_class.name)' at $(f.line):$(f.column)");
                check_ctor_args (target_ctor, f.base_args, f.line, f.column);
                var this_ref = new VarRef () { name = "this", line = f.line, column = f.column };
                emit_instance_call (this_ref, false, true, target_ctor, f.base_args, -1, -1);
                foreach (var ba in f.base_args)
                    cleanup_expr_temps (ba);
            } else if (f.is_ctor && f.has_base_call && current_class != null && current_class.base_name != "") {
                unowned var base_cd = program.find_class (current_class.base_name);
                unowned var base_ctor = find_class_ctor (base_cd);
                if (base_ctor != null) {
                    check_ctor_args (base_ctor, f.base_args, f.line, f.column);
                    var this_ref = new VarRef () { name = "this", line = f.line, column = f.column };
                    emit_instance_call (this_ref, false, true, base_ctor, f.base_args, -1, -1);
                    foreach (var ba in f.base_args)
                        cleanup_expr_temps (ba);
                }
            }

            foreach (var s in f.body)
                gen_statement (s);

            // Falling off the end: unref locals, then return deterministic default.
            if (program_uses_heap)
                unref_locals_from (0);
            if (f.return_type == ValaType.STRING) {
                emitter.lea_rax_rip (emitter.add_string (""));
            } else if (f.return_type == ValaType.ARRAY || f.return_type == ValaType.CLASS
                       || f.return_type == ValaType.INTERFACE || f.return_type == ValaType.ERROR) {
                emitter.xor_eax ();
            } else if (f.return_type == ValaType.STRUCT) {
                unowned var sd = program.find_struct (f.return_type_name);
                emitter.lea_rcx_space (struct_ret_bss_offset, PatchSpace.BSS);
                if (sd != null)
                    init_struct_at_rcx (sd, 0);
                emitter.mov_rax_rcx ();
            } else {
                emitter.xor_eax ();
            }
            emitter.xor_edx ();
            emitter.leave ();
            emitter.ret ();

            if (need_func_throw) {
                emitter.bind (cur_func_throw_label);
                emitter.load_local (err_prop_slot);
                emitter.mov_rdx_rax ();
                emitter.xor_eax ();
                emitter.leave ();
                emitter.ret ();
            }

            symbols.add (new Symbol (f.name, start, emitter.here () - start));
            var df = new DebugFunc () {
                name = f.name,
                start_offset = start,
                end_offset = emitter.here (),
                line = f.line
            };
            for (int li = 0; li < locals.length; li++) {
                if (local_by_ref[li])
                    continue;
                df.vars.add (new DebugVar () {
                    name = locals[li],
                    slot = local_slots[li],
                    var_type = local_types[li],
                    is_param = (li < f.params.length)
                });
            }
            debug_funcs.add (df);
        }

        // `free ()` on a compact instance: release every reference-typed field
        // once, then hand the block back to the allocator.
        private void emit_compact_free_body () {
            if (current_class == null)
                return;
            for (int i = current_class.fields.length - 1; i >= 0; i--) {
                var fld = current_class.fields[i];
                if (fld.is_static)
                    continue;
                unowned ClassField? dummy = null;
                var slot_off = class_field_offset_slots (current_class, fld.name, out dummy);
                if (slot_off < 0)
                    continue;
                int byte_off = class_field_base (current_class) + 8 * slot_off;
                if (is_ref_type (fld.field_type) && !is_compact_type (fld.field_type, fld.type_name)) {
                    emitter.load_local (0);
                    emitter.load_rax_disp (byte_off);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_unref");
                } else if (fld.field_type == ValaType.STRUCT && struct_has_ref_name (fld.type_name)) {
                    unowned var sd = program.find_struct (fld.type_name);
                    if (sd != null) {
                        emitter.load_local (0);
                        emitter.add_rax_imm (byte_off);
                        emitter.mov_rcx_rax ();
                        unref_struct_at_rcx (sd, 0);
                    }
                }
            }
            emitter.load_local (0);
            emitter.mov_rdi_rax ();
            need_compact_free = true;
            call_aligned ("__planc_compact_free");
        }

        private void emit_class_finalizer_body () {
            if (current_class == null)
                return;
            if (current_class.dtor != null) {
                emitter.load_local (0);
                emitter.mov_rdi_rax ();
                call_aligned (current_class.dtor.name);
            }
            for (int i = current_class.fields.length - 1; i >= 0; i--) {
                var fld = current_class.fields[i];
                if (fld.is_static)
                    continue;
                unowned ClassField? dummy = null;
                var slot_off = class_field_offset_slots (current_class, fld.name, out dummy);
                int byte_off = class_field_base (current_class) + 8 * slot_off;
                if (is_ref_type (fld.field_type) && !is_compact_type (fld.field_type, fld.type_name)) {
                    emitter.load_local (0);
                    emitter.load_rax_disp (byte_off);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_unref");
                } else if (fld.field_type == ValaType.STRUCT && struct_has_ref_name (fld.type_name)) {
                    unowned var sd = program.find_struct (fld.type_name);
                    if (sd != null) {
                        emitter.load_local (0);
                        emitter.add_rax_imm (byte_off);
                        emitter.mov_rcx_rax ();
                        unref_struct_at_rcx (sd, 0);
                    }
                }
            }
            for (int i = current_class.signals.length - 1; i >= 0; i--) {
                var sd = current_class.signals[i];
                emitter.load_local (0);
                emitter.load_rax_disp (16 + 8 * sd.slot_index);
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_sig_free_list");
            }
            if (current_class.base_name != "") {
                unowned var base_cd = program.find_class (current_class.base_name);
                if (base_cd != null && base_cd.needs_finalizer) {
                    emitter.load_local (0);
                    emitter.mov_rdi_rax ();
                    call_aligned (@"__planc_dtor_$(base_cd.name)");
                } else if (has_weak_slot (current_class)) {
                    emitter.load_local (0);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_weak_clear");
                }
            } else if (has_weak_slot (current_class)) {
                emitter.load_local (0);
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_weak_clear");
            }
        }

        // ------------------------------------------------------------------
        // Lookup, types, and ownership predicates.
        // ------------------------------------------------------------------

        private int lookup (string name) {
            for (int i = locals.length - 1; i >= 0; i--) {
                if (local_active[i] && locals[i] == name)
                    return i;
            }
            return -1;
        }

        private int lookup_global (string name) {
            for (int i = 0; i < global_names.length; i++) {
                if (global_names[i] == name)
                    return i;
            }
            return -1;
        }

        private static bool is_nullable_type (ValaType t, string tname) {
            return t == ValaType.NULL || tname.has_suffix ("?");
        }

        private static string strip_null (string tname) {
            return tname.has_suffix ("?") ? tname.substring (0, tname.length - 1) : tname;
        }

        private string compact_to_object_hint (ValaType t, string tname) {
            if (t != ValaType.CLASS || tname == null)
                return "";
            unowned var icd = program.find_class (strip_null (tname));
            if (icd == null || !icd.is_compact)
                return "";
            return @" ('$(icd.name)' is a [Compact] class: it has no reference count and no runtime type)";
        }

        private static string type_label (ValaType t, string tname) {
            if (t == ValaType.ARRAY) {
                var inner = strip_null (tname);
                return tname.has_suffix ("?") ? inner + "[]?" : inner + "[]";
            }
            if (t == ValaType.STRING && tname == "?")
                return "string?";
            if (t == ValaType.ERROR) {
                if (tname == "?") return "Error?";
                return (tname != "") ? tname : "Error";
            }
            if ((t == ValaType.ENUM || t == ValaType.STRUCT || t == ValaType.CLASS
                 || t == ValaType.INTERFACE) && tname != "")
                return tname;
            return t.label ();
        }

        private static bool is_int_like (ValaType t) {
            return t == ValaType.INT || t == ValaType.BOOL;
        }

        private static bool is_ref_type (ValaType t) {
            return t == ValaType.STRING || t == ValaType.ARRAY
                || t == ValaType.CLASS || t == ValaType.INTERFACE || t == ValaType.ERROR;
        }

        private static bool is_int_type_name_cg (string name) {
            return name == "int" || name == "int64" || name == "int32"
                || name == "int16" || name == "int8"
                || name == "uint" || name == "uint64" || name == "uint32" || name == "uint16" || name == "unichar"
                || name == "uint8" || name == "size_t" || name == "ssize_t"
                || name == "short" || name == "ushort" || name == "long" || name == "ulong"
                || name == "char" || name == "uchar";
        }

        private static bool is_unsigned_64 (string name) {
            return name == "uint64" || name == "ulong" || name == "size_t";
        }

        private static bool is_unsigned_32 (string name) {
            return name == "uint32" || name == "uint" || name == "unichar";
        }

        private static bool is_unsigned_int_type (string name) {
            return is_unsigned_64 (name) || is_unsigned_32 (name)
                || name == "uint16" || name == "ushort"
                || name == "uint8" || name == "uchar";
        }

        private static bool is_signed_64_int_type (string name) {
            return name == "" || name == "int" || name == "int64"
                || name == "long" || name == "ssize_t";
        }

        private static string promote_int_type (string l, string r) {
            if (is_unsigned_64 (l) || is_unsigned_64 (r))
                return "uint64";
            if (is_signed_64_int_type (l) || is_signed_64_int_type (r))
                return "";
            if (is_unsigned_32 (l) || is_unsigned_32 (r))
                return "uint32";
            return "";
        }

        private static int64 narrow_const_int (string tname, int64 v) {
            if (tname == "uint8" || tname == "uchar") return v & 0xff;
            if (tname == "uint16" || tname == "ushort") return v & 0xffff;
            if (is_unsigned_32 (tname)) return (int64) ((uint64) v & (uint64) 0xffffffffu);
            if (tname == "int8" || tname == "char") return (int64) ((int8) v);
            if (tname == "int16" || tname == "short") return (int64) ((int16) v);
            if (tname == "int32") return (int64) ((int32) v);
            return v;
        }

        private void emit_int_narrow (string tname) {
            if (tname == "uint8" || tname == "uchar") {
                emitter.and_eax_imm32 (0xffu);
            } else if (tname == "uint16" || tname == "ushort") {
                emitter.and_eax_imm32 (0xffffu);
            } else if (is_unsigned_32 (tname)) {
                emitter.mov_eax_eax ();
            } else if (tname == "int8" || tname == "char") {
                emitter.sign_extend_rax (8);
            } else if (tname == "int16" || tname == "short") {
                emitter.sign_extend_rax (16);
            } else if (tname == "int32") {
                emitter.sign_extend_rax (32);
            }
        }

        private static bool is_byte_array_type (string arr_tname, out bool is_signed) {
            var b = strip_null (arr_tname);
            is_signed = (b == "int8");
            return b == "uint8" || b == "int8";
        }

        private static void coerce_byte_array_literal (Expr? e, ValaType expected_t, string expected_tname) {
            if (e == null || !(e is ArrayLiteralExpr) || expected_t != ValaType.ARRAY)
                return;
            var raw = strip_null (expected_tname);
            if (raw != "" && raw != "int" && is_int_type_name_cg (raw)) {
                var arr = (ArrayLiteralExpr) e;
                arr.elem_type = ValaType.INT;
                arr.elem_type_name = raw;
            }
        }

        private static bool is_fp_type (ValaType t) {
            return t == ValaType.FLOAT || t == ValaType.DOUBLE;
        }

        private static bool is_numeric_type (ValaType t) {
            return t == ValaType.INT || t == ValaType.FLOAT || t == ValaType.DOUBLE;
        }

        private static bool is_fp_type_name_cg (string name) {
            return name == "float" || name == "double";
        }

        private static bool resolve_fp_const_member (string tname, string member, out uint64 bits) {
            bits = 0;
            bool f32 = (tname == "float");
            if (member == "MIN") {
                bits = f32 ? (uint64) 0x00800000 : (uint64) 0x0010000000000000;
                return true;
            }
            if (member == "MAX") {
                bits = f32 ? (uint64) 0x7F7FFFFF : (uint64) 0x7FEFFFFFFFFFFFFF;
                return true;
            }
            if (member == "INFINITY") {
                bits = f32 ? (uint64) 0x7F800000 : (uint64) 0x7FF0000000000000;
                return true;
            }
            if (member == "NAN") {
                bits = f32 ? (uint64) 0x7FC00000 : (uint64) 0x7FF8000000000000;
                return true;
            }
            return false;
        }

        private static bool resolve_int_const_member (string tname, string member, out int64 val) {
            val = 0;
            if (member == "MIN") {
                if (tname == "int8") { val = -128; return true; }
                if (tname == "int16" || tname == "short") { val = -32768; return true; }
                if (tname == "int32" || tname == "int") { val = -2147483648; return true; }
                if (tname == "int64" || tname == "long" || tname == "ssize_t") { val = -9223372036854775807 - 1; return true; }
                if (tname == "uint8" || tname == "uchar" || tname == "char"
                    || tname == "uint16" || tname == "ushort"
                    || tname == "uint32" || tname == "uint" || tname == "unichar"
                    || tname == "uint64" || tname == "ulong" || tname == "size_t") {
                    val = 0; return true;
                }
                return false;
            }
            if (member == "MAX") {
                if (tname == "int8") { val = 127; return true; }
                if (tname == "uint8" || tname == "uchar" || tname == "char") { val = 255; return true; }
                if (tname == "int16" || tname == "short") { val = 32767; return true; }
                if (tname == "uint16" || tname == "ushort") { val = 65535; return true; }
                if (tname == "int32" || tname == "int") { val = 2147483647; return true; }
                if (tname == "uint32" || tname == "uint" || tname == "unichar") { val = 4294967295; return true; }
                if (tname == "int64" || tname == "long" || tname == "ssize_t") { val = 9223372036854775807; return true; }
                if (tname == "uint64" || tname == "ulong" || tname == "size_t") { val = (int64) (-1); return true; }
                return false;
            }
            return false;
        }

        private static bool is_host_intrinsic (string callee) {
            return callee == "__planc_host_eprint"
                || callee == "__planc_host_chmod"
                || callee == "__planc_host_bytes_to_str"
                || callee == "__planc_host_read_file"
                || callee == "__planc_host_write_file";
        }

        private unowned SignalDecl? find_class_signal (ClassDecl? cd, string sname) {
            unowned ClassDecl? cur = cd;
            while (cur != null) {
                unowned var sd = cur.find_own_signal (sname);
                if (sd != null)
                    return sd;
                cur = (cur.base_name != "") ? program.find_class (cur.base_name) : null;
            }
            return null;
        }

        private unowned SignalDecl? find_interface_signal (InterfaceDecl? itf, string sname) {
            unowned var cur = itf;
            if (cur == null)
                return null;
            unowned var own = cur.find_own_signal (sname);
            if (own != null)
                return own;
            foreach (var pn in cur.prereq_names) {
                unowned var p = program.find_interface (pn);
                unowned var res = find_interface_signal (p, sname);
                if (res != null)
                    return res;
            }
            return null;
        }

        private unowned SignalDecl? resolve_signal_access (Expr? target, string sname, out Expr? obj_expr)
                throws SemanticError {
            obj_expr = null;
            if (target == null) {
                if (current_class == null || current == null || current.is_static)
                    return null;
                unowned var sd = find_class_signal (current_class, sname);
                if (sd != null)
                    obj_expr = new VarRef () { name = "this", line = sd.line, column = sd.column };
                return sd;
            }
            if (target is VarRef && is_type_name (((VarRef) target).name))
                return null;
            string tt_name = "";
            var tt = expr_type_full (target, out tt_name);
            if (tt == ValaType.INTERFACE) {
                unowned var itf = program.find_interface (strip_null (tt_name));
                unowned var isd = find_interface_signal (itf, sname);
                if (isd != null)
                    obj_expr = target;
                return isd;
            }
            if (tt != ValaType.CLASS)
                return null;
            unowned var cd = program.find_class (strip_null (tt_name));
            if (cd == null)
                return null;
            unowned var sd = find_class_signal (cd, sname);
            if (sd != null)
                obj_expr = target;
            return sd;
        }

        private unowned SignalDecl? resolve_signal_connect (MethodCallExpr mc, out Expr? obj_expr)
                throws SemanticError {
            obj_expr = null;
            if ((mc.method_name != "connect" && mc.method_name != "disconnect") || mc.target == null || mc.is_base_call)
                return null;
            if (mc.target is MemberAccessExpr) {
                var ma = (MemberAccessExpr) mc.target;
                return resolve_signal_access (ma.target, ma.member, out obj_expr);
            }
            if (mc.target is VarRef) {
                var vr = (VarRef) mc.target;
                return resolve_signal_access (null, vr.name, out obj_expr);
            }
            return null;
        }

        private static string make_async_task_type_name (ValaType ret_t, string ret_name) {
            return @"__AsyncTask:$((int) ret_t):$(ret_name)";
        }

        private static bool parse_async_task_type_name (string tn, out ValaType ret_t, out string ret_name) {
            ret_t = ValaType.VOID;
            ret_name = "";
            if (!tn.has_prefix ("__AsyncTask:"))
                return false;
            int n = tn.length;
            int second_colon = -1;
            int code = 0;
            for (int i = 12; i < n; i++) {
                uint8 ch = tn[i];
                if (ch == ':') {
                    second_colon = i;
                    break;
                }
                if (ch < '0' || ch > '9')
                    return false;
                code = code * 10 + (int) (ch - '0');
            }
            if (second_colon < 0)
                return false;
            switch (code) {
                case 0: ret_t = ValaType.VOID; break;
                case 1: ret_t = ValaType.INT; break;
                case 2: ret_t = ValaType.FLOAT; break;
                case 3: ret_t = ValaType.DOUBLE; break;
                case 4: ret_t = ValaType.BOOL; break;
                case 5: ret_t = ValaType.STRING; break;
                case 6: ret_t = ValaType.ENUM; break;
                case 7: ret_t = ValaType.STRUCT; break;
                case 8: ret_t = ValaType.ARRAY; break;
                case 9: ret_t = ValaType.CLASS; break;
                case 10: ret_t = ValaType.INTERFACE; break;
                case 11: ret_t = ValaType.ERROR; break;
                case 12: ret_t = ValaType.TYPE_PARAM; break;
                default: ret_t = ValaType.NULL; break;
            }
            ret_name = tn.substring (second_colon + 1);
            return true;
        }

        private Function? resolve_begin_call (MethodCallExpr mc, out Expr? recv_target) throws SemanticError {
            recv_target = null;
            if (mc.method_name != "begin" || mc.target == null || mc.is_base_call)
                return null;
            if (mc.target is VarRef) {
                var vn = ((VarRef) mc.target).name;
                var f = resolve_call_target (vn);
                if (f != null && f.is_async)
                    return f;
                return null;
            }
            if (mc.target is MemberAccessExpr) {
                var ma = (MemberAccessExpr) mc.target;
                var synth = new MethodCallExpr () {
                    target = ma.target,
                    method_name = ma.member,
                    line = mc.line,
                    column = mc.column
                };
                var m = resolve_method_call_fn (synth);
                if (m != null && m.is_async) {
                    recv_target = ma.target;
                    return m;
                }
            }
            return null;
        }

        private bool is_builtin_method_call (MethodCallExpr mc, out string kind, out ValaType ret_t)
                throws SemanticError {
            kind = "";
            ret_t = ValaType.VOID;
            if (mc.target == null || mc.is_base_call || mc.method_name == "" || mc.method_name == "begin"
                || mc.method_name == "connect" || mc.method_name == "disconnect")
                return false;
            if (mc.target is VarRef) {
                var vn = ((VarRef) mc.target).name;
                if (vn == "Async" && (mc.method_name == "run" || mc.method_name == "run_parallel")) {
                    kind = (mc.method_name == "run") ? "async_run" : "async_run_parallel";
                    ret_t = ValaType.VOID;
                    return true;
                }
                if (is_int_type_name_cg (vn) && is_type_name (vn) && mc.method_name == "parse") {
                    kind = "int_parse";
                    ret_t = ValaType.INT;
                    return true;
                }
                if (is_fp_type_name_cg (vn) && is_type_name (vn) && mc.method_name == "parse") {
                    kind = (vn == "float") ? "float_parse" : "double_parse";
                    ret_t = (vn == "float") ? ValaType.FLOAT : ValaType.DOUBLE;
                    return true;
                }
                if (is_type_name (vn))
                    return false;
            }
            string tt_name = "";
            var tt = expr_type_full (mc.target, out tt_name);
            if (tt == ValaType.CLASS && tt_name == "Mutex") {
                if (mc.method_name == "lock") {
                    kind = "mutex_lock";
                    ret_t = ValaType.VOID;
                    return true;
                }
                if (mc.method_name == "unlock") {
                    kind = "mutex_unlock";
                    ret_t = ValaType.VOID;
                    return true;
                }
            }
            if (tt == ValaType.CLASS) {
                ValaType ch_et = ValaType.INT;
                string ch_etn = "";
                if (find_channel_elem (tt_name, out ch_et, out ch_etn)) {
                    if (mc.method_name == "send") {
                        kind = "chan_send";
                        ret_t = ValaType.VOID;
                        return true;
                    }
                    if (mc.method_name == "recv") {
                        kind = "chan_recv";
                        ret_t = ValaType.CLASS;
                        return true;
                    }
                    if (mc.method_name == "close") {
                        kind = "chan_close";
                        ret_t = ValaType.VOID;
                        return true;
                    }
                }
            }
            if (tt == ValaType.INT && mc.method_name == "to_string") {
                kind = "int_to_string";
                ret_t = ValaType.STRING;
                return true;
            }
            if (is_fp_type (tt) && mc.method_name == "to_string") {
                kind = (tt == ValaType.FLOAT) ? "float_to_string" : "double_to_string";
                ret_t = ValaType.STRING;
                return true;
            }
            if (tt == ValaType.STRING) {
                if (mc.method_name == "has_prefix") {
                    kind = "str_has_prefix";
                    ret_t = ValaType.BOOL;
                    return true;
                }
                if (mc.method_name == "has_suffix") {
                    kind = "str_has_suffix";
                    ret_t = ValaType.BOOL;
                    return true;
                }
                if (mc.method_name == "substring") {
                    kind = "str_substring";
                    ret_t = ValaType.STRING;
                    return true;
                }
                if (mc.method_name == "char_count") {
                    kind = "str_char_count";
                    ret_t = ValaType.INT;
                    return true;
                }
                if (mc.method_name == "get_char") {
                    kind = "str_get_char";
                    ret_t = ValaType.INT;
                    return true;
                }
                if (mc.method_name == "validate") {
                    kind = "str_validate";
                    ret_t = ValaType.BOOL;
                    return true;
                }
                if (mc.method_name == "index_of") {
                    kind = "str_index_of";
                    ret_t = ValaType.INT;
                    return true;
                }
                if (mc.method_name == "contains") {
                    kind = "str_contains";
                    ret_t = ValaType.BOOL;
                    return true;
                }
            }
            return false;
        }

        private static string canon_int_name (string s) {
            return (s == "") ? "int" : s;
        }

        private void parse_array_elem (string elem_name, out ValaType et, out string et_name) {
            var raw = strip_null (elem_name);
            et_name = "";
            if (is_int_type_name_cg (raw)) {
                et = ValaType.INT;
                et_name = raw;
            } else if (raw == "float") et = ValaType.FLOAT;
            else if (raw == "double") et = ValaType.DOUBLE;
            else if (raw == "bool") et = ValaType.BOOL;
            else if (raw == "string") et = ValaType.STRING;
            else if (raw == "Error") et = ValaType.ERROR;
            else if (program.find_error_domain (raw) != null) {
                et = ValaType.ERROR;
                et_name = raw;
            } else if (program.find_interface (raw) != null) {
                et = ValaType.INTERFACE;
                et_name = elem_name.has_suffix ("?") ? (raw + "?") : raw;
            } else if (program.find_class (raw) != null) {
                et = ValaType.CLASS;
                et_name = elem_name.has_suffix ("?") ? (raw + "?") : raw;
            } else {
                et = ValaType.ENUM;
                et_name = raw;
            }
            if (et == ValaType.STRING && elem_name == "?")
                et_name = "?";
        }

        private bool type_compatible (ValaType expected, string exp_name,
                                      ValaType actual, string act_name) {
            if (actual == ValaType.NULL)
                return is_nullable_type (expected, exp_name);
            if (expected == ValaType.INTERFACE && actual == ValaType.CLASS) {
                if (is_nullable_type (actual, act_name) && !is_nullable_type (expected, exp_name))
                    return false;
                unowned var cd = program.find_class (strip_null (act_name));
                return cd != null && class_implements_iface (cd, strip_null (exp_name));
            }
            if (expected == actual) {
                if (is_nullable_type (actual, act_name) && !is_nullable_type (expected, exp_name))
                    return false;
                var en = strip_null (exp_name);
                var an = strip_null (act_name);
                if (expected == ValaType.ENUM || expected == ValaType.STRUCT || expected == ValaType.ARRAY)
                    return en == an;
                if (expected == ValaType.CLASS)
                    return en == an || is_subclass_of (an, en);
                if (expected == ValaType.INTERFACE) {
                    if (en == an)
                        return true;
                    unowned var sub_itf = program.find_interface (an);
                    return sub_itf != null && iface_inherits_from (sub_itf, en);
                }
                if (expected == ValaType.ERROR)
                    return en == "" || en == an;
                return true;
            }
            if (is_int_like (expected) && is_int_like (actual))
                return true;
            // Measured: valac converts between an enum and int in both
            // directions, because an enum is stored as its integer value.
            if (expected == ValaType.ENUM && actual == ValaType.INT)
                return true;
            if (expected == ValaType.INT && actual == ValaType.ENUM)
                return true;
            if (expected == ValaType.DOUBLE && (actual == ValaType.FLOAT || actual == ValaType.INT))
                return true;
            if (expected == ValaType.FLOAT && actual == ValaType.INT)
                return true;
            return false;
        }

        private bool eq_compatible (ValaType lt, string lt_name, ValaType rt, string rt_name) {
            if (lt == ValaType.STRUCT || rt == ValaType.STRUCT
                || lt == ValaType.ARRAY || rt == ValaType.ARRAY) {
                if (is_delegate_type (program, lt, lt_name) && rt == ValaType.NULL)
                    return true;
                if (is_delegate_type (program, rt, rt_name) && lt == ValaType.NULL)
                    return true;
                if (lt == ValaType.ARRAY && rt == ValaType.NULL)
                    return true;
                if (rt == ValaType.ARRAY && lt == ValaType.NULL)
                    return true;
                return false;
            }
            if (lt == ValaType.NULL && is_ref_type (rt))
                return true;
            if (rt == ValaType.NULL && is_ref_type (lt))
                return true;
            return type_compatible (lt, lt_name, rt, rt_name)
                || type_compatible (rt, rt_name, lt, lt_name);
        }

        private bool is_type_name (string name) {
            if (lookup (name) >= 0 || lookup_global (name) >= 0)
                return false;
            if (current_class != null && current != null && !current.is_static) {
                unowned ClassField? cf = null;
                if (class_field_offset_slots (current_class, name, out cf) >= 0)
                    return false;
            }
            if (current_struct != null && current != null && !current.is_static) {
                unowned StructField? sf = null;
                if (struct_field_offset_slots (current_struct, name, out sf) >= 0)
                    return false;
            }
            if (program.find_const ("", name) != null)
                return false;
            if (current != null && current.owner_class != ""
                && program.find_const (current.owner_class, name) != null) {
                return false;
            }
            return program.find_class (name) != null
                || program.find_interface (name) != null
                || program.find_struct (name) != null
                || program.find_enum (name) != null
                || program.find_error_domain (name) != null
                || is_int_type_name_cg (name)
                || is_fp_type_name_cg (name);
        }

        private unowned Function? resolve_type_method (string type_name, string mname) {
            unowned var cd = program.find_class (type_name);
            if (cd != null)
                return find_class_method (cd, mname);
            unowned var sd = program.find_struct (type_name);
            if (sd != null)
                return sd.find_method (mname);
            unowned var ed = program.find_enum (type_name);
            if (ed != null)
                return ed.find_method (mname);
            unowned var itf = program.find_interface (type_name);
            if (itf != null) {
                unowned var im = itf.find_own_method (mname);
                if (im != null && im.is_static)
                    return im;
            }
            return null;
        }

        private static string make_nullable (ValaType t, string tname) {
            if (is_nullable_type (t, tname))
                return tname;
            return tname + "?";
        }

        private void unify_branch_types (ValaType lt, string lt_name, ValaType rt, string rt_name,
                                         out ValaType out_t, out string out_name, int line, int col)
                throws SemanticError {
            if (lt == ValaType.NULL && rt == ValaType.NULL) {
                out_t = ValaType.NULL;
                out_name = "";
                return;
            }
            if (is_numeric_type (lt) && is_numeric_type (rt) && (is_fp_type (lt) || is_fp_type (rt))) {
                out_t = (lt == ValaType.DOUBLE || rt == ValaType.DOUBLE) ? ValaType.DOUBLE : ValaType.FLOAT;
                out_name = "";
                return;
            }
            if (lt == ValaType.NULL) {
                if (!is_ref_type (rt) && !is_delegate_type (program, rt, rt_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"incompatible branch types $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $line:$col");
                out_t = rt;
                out_name = make_nullable (rt, rt_name);
                return;
            }
            if (rt == ValaType.NULL) {
                if (!is_ref_type (lt) && !is_delegate_type (program, lt, lt_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"incompatible branch types $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $line:$col");
                out_t = lt;
                out_name = make_nullable (lt, lt_name);
                return;
            }
            if (lt == ValaType.CLASS && rt == ValaType.CLASS) {
                bool any_null = is_nullable_type (lt, lt_name) || is_nullable_type (rt, rt_name);
                unowned var common = common_ancestor_class (strip_null (lt_name), strip_null (rt_name));
                if (common == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"incompatible class types $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $line:$col");
                out_t = ValaType.CLASS;
                out_name = any_null ? (common.name + "?") : common.name;
                return;
            }
            if (lt == ValaType.INTERFACE && rt == ValaType.INTERFACE) {
                bool any_null = is_nullable_type (lt, lt_name) || is_nullable_type (rt, rt_name);
                var ln = strip_null (lt_name);
                var rn = strip_null (rt_name);
                unowned var li = program.find_interface (ln);
                unowned var ri = program.find_interface (rn);
                if (li != null && iface_inherits_from (li, rn)) {
                    out_t = ValaType.INTERFACE;
                    out_name = any_null ? (rn + "?") : rn;
                    return;
                }
                if (ri != null && iface_inherits_from (ri, ln)) {
                    out_t = ValaType.INTERFACE;
                    out_name = any_null ? (ln + "?") : ln;
                    return;
                }
                throw new SemanticError.TYPE_MISMATCH (
                    @"incompatible interface types $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $line:$col");
            }
            if ((lt == ValaType.INTERFACE && rt == ValaType.CLASS)
                || (lt == ValaType.CLASS && rt == ValaType.INTERFACE)) {
                bool any_null = is_nullable_type (lt, lt_name) || is_nullable_type (rt, rt_name);
                var iname = strip_null (lt == ValaType.INTERFACE ? lt_name : rt_name);
                var cname = strip_null (lt == ValaType.CLASS ? lt_name : rt_name);
                unowned var cd = program.find_class (cname);
                if (cd != null && class_implements_iface (cd, iname)) {
                    out_t = ValaType.INTERFACE;
                    out_name = any_null ? (iname + "?") : iname;
                    return;
                }
            }
            if (lt == ValaType.INT && rt == ValaType.INT) {
                out_t = ValaType.INT;
                out_name = promote_int_type (lt_name, rt_name);
                return;
            }
            if (type_compatible (lt, lt_name, rt, rt_name)) {
                out_t = (lt == ValaType.BOOL && rt == ValaType.INT) ? ValaType.INT : lt;
                out_name = (lt == ValaType.BOOL && rt == ValaType.INT) ? "" : lt_name;
                return;
            }
            if (type_compatible (rt, rt_name, lt, lt_name)) {
                out_t = (rt == ValaType.BOOL && lt == ValaType.INT) ? ValaType.INT : rt;
                out_name = (rt == ValaType.BOOL && lt == ValaType.INT) ? "" : rt_name;
                return;
            }
            throw new SemanticError.TYPE_MISMATCH (
                @"incompatible branch types $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $line:$col");
        }

        private bool is_owned_expr (Expr e) throws SemanticError {
            if (e is ArrayNewExpr || e is ArrayLiteralExpr || e is ClassNewExpr || e is SliceExpr)
                return true;
            if (e is TernaryExpr || e is CoalesceExpr)
                return is_ref_type (expr_type (e));
            if (e is TemplateExpr)
                return !is_static_template ((TemplateExpr) e);
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                return b.op == "+" && expr_type (b.left) == ValaType.STRING;
            }
            if (e is YieldExpr) {
                var ye = (YieldExpr) e;
                if (ye.value == null)
                    return false;
                return is_ref_type (expr_type (ye));
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                string bi_kind = "";
                ValaType bi_ret = ValaType.VOID;
                if (is_builtin_method_call (mc, out bi_kind, out bi_ret))
                    return is_ref_type (bi_ret);
                Expr? dummy_r = null;
                if (resolve_begin_call (mc, out dummy_r) != null)
                    return true;
                if (mc.target != null && !mc.is_base_call && mc.method_name != "begin"
                    && mc.method_name != "connect" && mc.method_name != "disconnect") {
                    unowned var md = resolve_member_delegate (mc.target, mc.method_name);
                    if (md != null)
                        return is_ref_type (md.return_type);
                }
                var m = resolve_method_call_fn (mc);
                return m != null && (m.is_async || is_ref_type (m.return_type));
            }
            if (e is CallExpr) {
                var ce = (CallExpr) e;
                if (ce.callee == "__planc_host_bytes_to_str" || ce.callee == "__planc_host_read_file")
                    return true;
                if (ce.callee == "__planc_hash" || is_host_intrinsic (ce.callee))
                    return false;
                unowned var dd = resolve_delegate_callee (ce.callee);
                if (dd != null)
                    return is_ref_type (dd.return_type);
                var f = resolve_call_target (ce.callee, ce);
                return f != null && (f.is_async || is_ref_type (f.return_type));
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                if (!(ma.target is VarRef && is_type_name (((VarRef) ma.target).name))) {
                    string tt_name = "";
                    var tt = expr_type_full (ma.target, out tt_name);
                    bool is_field = false;
                    if (tt == ValaType.CLASS) {
                        unowned var cd = program.find_class (strip_null (tt_name));
                        unowned ClassField? mcf = null;
                        if (cd != null && class_field_offset_slots (cd, ma.member, out mcf) >= 0 && mcf != null)
                            is_field = !mcf.is_weak;
                    }
                    if (!is_field) {
                        unowned var gm = find_prop_getter (tt, tt_name, ma.member);
                        if (gm != null)
                            return is_ref_type (gm.return_type);
                    }
                }
            }
            if (e is VarRef) {
                var vr = (VarRef) e;
                if (lookup (vr.name) < 0 && lookup_global (vr.name) < 0) {
                    bool is_field = false;
                    if (current_class != null && !current.is_static) {
                        unowned ClassField? tcf = null;
                        if (class_field_offset_slots (current_class, vr.name, out tcf) >= 0 && tcf != null)
                            is_field = !tcf.is_weak;
                    }
                    if (!is_field) {
                        unowned var gm = find_this_prop_getter (vr.name);
                        if (gm != null)
                            return is_ref_type (gm.return_type);
                    }
                }
            }
            return false;
        }

        private static bool is_static_template (TemplateExpr t) {
            foreach (var part in t.parts) {
                if (!(part is StringLiteral))
                    return false;
            }
            return true;
        }

        private static string static_template_text (TemplateExpr t) {
            var sb = new StrBuilder ();
            foreach (var part in t.parts)
                sb.append (((StringLiteral) part).value);
            return sb.str;
        }

        private Function? resolve_call_target (string callee, CallExpr? call = null)
                throws SemanticError {
            unowned var f = program.find (callee);
            if (f == null && current_class != null)
                f = find_class_method (current_class, callee);
            if (f == null && current_struct != null)
                f = current_struct.find_method (callee);
            if (f == null && current_enum != null)
                f = current_enum.find_method (callee);
            if (f == null && current != null && current.owner_class != "") {
                // Inside an interface default body, a sibling method of the same
                // interface is reachable unqualified and dispatches on `this`.
                unowned var own_itf = program.find_interface (current.owner_class);
                if (own_itf != null)
                    f = find_interface_method (own_itf, callee);
            }
            if (f == null)
                return null;
            if (!f.is_generic_template)
                return f;
            if (call == null)
                return null;
            return instantiate_generic_call (f, call);
        }

        private void resolve_type_arg_name (string n, out ValaType t, out string tn) {
            t = ValaType.VOID;
            tn = "";
            var bare = strip_null (n);
            if (is_int_type_name_cg (bare)) {
                t = ValaType.INT;
                tn = n;
                return;
            }
            if (is_fp_type_name_cg (bare)) {
                t = (bare == "float") ? ValaType.FLOAT : ValaType.DOUBLE;
                tn = n;
                return;
            }
            if (bare == "bool") {
                t = ValaType.BOOL;
                tn = n;
                return;
            }
            if (bare == "string") {
                t = ValaType.STRING;
                tn = n;
                return;
            }
            if (bare.has_suffix ("[]")) {
                var inner = bare.substring (0, bare.length - 2);
                ValaType it;
                string itn;
                resolve_type_arg_name (inner, out it, out itn);
                if (it != ValaType.VOID) {
                    t = ValaType.ARRAY;
                    tn = strip_null (itn) + "[]";
                }
                return;
            }
            if (program.find_class (bare) != null) {
                t = ValaType.CLASS;
                tn = n;
                return;
            }
            if (program.find_interface (bare) != null) {
                t = ValaType.INTERFACE;
                tn = n;
                return;
            }
            if (program.find_struct (bare) != null) {
                t = ValaType.STRUCT;
                tn = n;
                return;
            }
            if (program.find_enum (bare) != null) {
                t = ValaType.ENUM;
                tn = n;
                return;
            }
        }

        private static string mangle_type_arg (string n) {
            var sb = new StrBuilder ();
            for (int i = 0; i < n.length; i++) {
                var c = n[i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')
                    sb.append_c (c);
                else if (c == '?')
                    sb.append_c ('q');
                else if (c == '[' || c == ']')
                    sb.append_c ('_');
            }
            return sb.str;
        }

        private CallExpr method_call_as_call (MethodCallExpr mc) {
            var c = new CallExpr () {
                callee = mc.method_name,
                line = mc.line,
                column = mc.column
            };
            foreach (var a in mc.args)
                c.args.add (a);
            return c;
        }

        private Function? instantiate_generic_call (Function f, CallExpr call)
                throws SemanticError {
            int param_off = (f.owner_class != "" && !f.is_static
                             && f.params.length > 0 && f.params[0].name == "this") ? 1 : 0;
            var targs = new GenericArray<ValaType> ();
            var tnames = new GenericArray<string> ();
            for (int i = 0; i < f.type_params.length; i++) {
                ValaType tt = ValaType.VOID;
                string tn = "";
                if (i < call.type_arg_names.length) {
                    resolve_type_arg_name (call.type_arg_names[i], out tt, out tn);
                } else {
                    for (int pi = 0; pi < f.params.length && pi < call.args.length + param_off; pi++) {
                        if (pi < param_off)
                            continue;
                        var p = f.params[pi];
                        int ai = pi - param_off;
                        if (ai >= call.args.length)
                            break;
                        if (p.param_type == ValaType.TYPE_PARAM && strip_null (p.type_name) == f.type_params[i]) {
                            string atn = "";
                            tt = expr_type_full (call.args[ai], out atn);
                            tn = strip_null (atn);
                            break;
                        }
                        if (p.param_type == ValaType.ARRAY && strip_null (p.type_name) == f.type_params[i] + "[]") {
                            string atn2 = "";
                            var at2 = expr_type_full (call.args[ai], out atn2);
                            if (at2 == ValaType.ARRAY && atn2.has_suffix ("[]")) {
                                var inner = atn2.substring (0, atn2.length - 2);
                                ValaType it;
                                string itn;
                                resolve_type_arg_name (inner, out it, out itn);
                                if (it != ValaType.VOID) {
                                    tt = ValaType.ARRAY;
                                    tn = strip_null (itn) + "[]";
                                }
                            }
                            break;
                        }
                    }
                }
                if (tt == ValaType.VOID)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"cannot infer type parameter '$(f.type_params[i])' of '$(f.name)' at $(call.line):$(call.column)");
                if (strip_null (tn) == "")
                    tn = tt.label ();
                targs.add (tt);
                tnames.add (tn);
            }
            var mangled = new StrBuilder ();
            mangled.append (f.name);
            mangled.append ("__");
            for (int i = 0; i < tnames.length; i++) {
                if (i > 0)
                    mangled.append ("_");
                mangled.append (mangle_type_arg (tnames[i]));
            }
            var gi = program.instantiate_function (f, targs, tnames, mangled.str);
            if (gi != null) {
                gi.owner_class = f.owner_class;
                gi.is_static = f.is_static;
                gi.is_generic_template = false;
            }
            return gi;
        }

        private Function? resolve_method_call_fn (MethodCallExpr mc) throws SemanticError {
            if (mc.is_base_call) {
                if (current_class == null || current_class.base_name == "")
                    throw new SemanticError.UNKNOWN_FUNCTION (
                        @"'base' requires a subclass method context at $(mc.line):$(mc.column)");
                unowned var bcd = program.find_class (current_class.base_name);
                unowned var bm = find_class_method (bcd, mc.method_name);
                if (bm == null)
                    throw new SemanticError.UNKNOWN_FUNCTION (
                        @"base class '$(current_class.base_name)' has no method '$(mc.method_name)' at $(mc.line):$(mc.column)");
                if (bm.is_abstract)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"cannot call abstract base method '$(bm.method_name)' at $(mc.line):$(mc.column)");
                return bm;
            }
            if (mc.target == null)
                return null;
            if (mc.target is VarRef) {
                var vr = (VarRef) mc.target;
                if (is_type_name (vr.name)) {
                    unowned var m = resolve_type_method (vr.name, mc.method_name);
                    if (m == null)
                        throw new SemanticError.UNKNOWN_FUNCTION (
                            @"type '$(vr.name)' has no method '$(mc.method_name)' at $(mc.line):$(mc.column)");
                    if (!m.is_static)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot call instance method '$(vr.name).$(mc.method_name)' without an instance at $(mc.line):$(mc.column)");
                    if (m.is_generic_template)
                        return instantiate_generic_call (m, method_call_as_call (mc));
                    return m;
                }
            }
            string tt_name = "";
            var tt = expr_type_full (mc.target, out tt_name);
            unowned Function? m = null;
            if (tt == ValaType.CLASS) {
                var cname = strip_null (tt_name);
                unowned var cd = program.find_class (cname);
                m = (cd != null) ? find_class_method (cd, mc.method_name) : null;
                if (m != null && m.is_generic_template)
                    return instantiate_generic_call (m, method_call_as_call (mc));
            } else if (tt == ValaType.INTERFACE) {
                var iname = strip_null (tt_name);
                unowned var itf = program.find_interface (iname);
                m = (itf != null) ? find_interface_method (itf, mc.method_name) : null;
            } else if (tt == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tt_name);
                m = (sd != null) ? sd.find_method (mc.method_name) : null;
            } else if (tt == ValaType.ENUM) {
                unowned var ed = program.find_enum (tt_name);
                m = (ed != null) ? ed.find_method (mc.method_name) : null;
            } else {
                throw new SemanticError.TYPE_MISMATCH (
                    @"method '.$(mc.method_name)' not supported on $(type_label (tt, tt_name)) at $(mc.line):$(mc.column)");
            }
            if (m == null) {
                if (tt == ValaType.CLASS) {
                    unowned var cd = program.find_class (strip_null (tt_name));
                    if (cd != null && find_class_signal (cd, mc.method_name) != null)
                        return null;
                }
                throw new SemanticError.UNKNOWN_FUNCTION (
                    @"$(type_label (tt, tt_name)) has no method '$(mc.method_name)' at $(mc.line):$(mc.column)");
            }
            if (m.is_static)
                throw new SemanticError.TYPE_MISMATCH (
                    @"static method '$(mc.method_name)' must be called on type '$(strip_null (tt_name))' at $(mc.line):$(mc.column)");
            return m;
        }

        private void check_arg_param_list (string desc, GenericArray<Param> plist, int param_offset,
                                             GenericArray<Expr> args, int line, int col)
                throws SemanticError {
            int expected_count = plist.length - param_offset;
            if (expected_count != args.length)
                throw new SemanticError.WRONG_ARG_COUNT (
                    @"$(desc) expects $(expected_count) argument(s), got $(args.length) at $(line):$(col)");
            for (int i = 0; i < args.length; i++) {
                var p = plist[param_offset + i];
                if (!p.is_ref && !p.is_out)
                    coerce_byte_array_literal (args[i], p.param_type, p.type_name);
                string at_name = "";
                var at = expr_type_full (args[i], out at_name);
                var pt = p.param_type;
                var pt_name = p.type_name;
                if (p.is_ref || p.is_out) {
                    if (!(args[i] is VarRef || args[i] is MemberAccessExpr || args[i] is IndexExpr))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"argument $(i + 1) of '$(desc)' requires a variable or field lvalue for '$(p.is_out ? "out" : "ref")' at $(args[i].line):$(args[i].column)");
                    bool name_match = (pt == ValaType.INT)
                        ? (canon_int_name (pt_name) == canon_int_name (at_name))
                        : (strip_null (pt_name) == strip_null (at_name));
                    if (pt != at || !name_match)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"argument $(i + 1) of '$(desc)' expects $(type_label (pt, pt_name)), got $(type_label (at, at_name)) at $(args[i].line):$(args[i].column)");
                    if (p.is_ref && is_nullable_type (pt, pt_name) != is_nullable_type (at, at_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"ref argument $(i + 1) of '$(desc)' nullability mismatch: expected $(type_label (pt, pt_name)), got $(type_label (at, at_name)) at $(args[i].line):$(args[i].column)");
                    if (p.is_out && !is_nullable_type (pt, pt_name) && is_nullable_type (at, at_name)) {
                        // OK under Option B if caller holds nullable and callee writes non-null.
                    } else if (!type_compatible (pt, pt_name, at, at_name)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"argument $(i + 1) of '$(desc)' expects $(type_label (pt, pt_name)), got $(type_label (at, at_name)) at $(args[i].line):$(args[i].column)");
                    }
                } else if (!type_compatible (pt, pt_name, at, at_name)) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument $(i + 1) of '$(desc)' expects $(type_label (pt, pt_name)), got $(type_label (at, at_name)) at $(args[i].line):$(args[i].column)");
                }
            }
        }

        private void check_arg_list (string desc, Function fn, int param_offset,
                                     GenericArray<Expr> args, int line, int col)
                throws SemanticError {
            check_arg_param_list (desc, fn.params, param_offset, args, line, col);
        }

        private void check_ctor_args (Function ctor, GenericArray<Expr> args, int line, int col)
                throws SemanticError {
            check_arg_list (ctor.owner_class, ctor, 1, args, line, col);
        }

        private ValaType check_host_intrinsic (CallExpr c, bool want_value) throws SemanticError {
            if (c.callee == "__planc_host_eprint") {
                if (want_value)
                    throw new SemanticError.VOID_IN_EXPRESSION (
                        @"void function '$(c.callee)' cannot be used as a value at $(c.line):$(c.column)");
                if (c.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"$(c.callee) expects 1 argument(s), got $(c.args.length) at $(c.line):$(c.column)");
                string an = "";
                var at = expr_type_full (c.args[0], out an);
                if (!type_compatible (ValaType.STRING, "", at, an))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of '$(c.callee)' expects string, got $(type_label (at, an)) at $(c.args[0].line):$(c.args[0].column)");
                return ValaType.VOID;
            }
            if (c.callee == "__planc_host_chmod") {
                if (want_value)
                    throw new SemanticError.VOID_IN_EXPRESSION (
                        @"void function '$(c.callee)' cannot be used as a value at $(c.line):$(c.column)");
                if (c.args.length != 2)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"$(c.callee) expects 2 argument(s), got $(c.args.length) at $(c.line):$(c.column)");
                string a0n = "";
                var a0t = expr_type_full (c.args[0], out a0n);
                if (!type_compatible (ValaType.STRING, "", a0t, a0n))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of '$(c.callee)' expects string, got $(type_label (a0t, a0n)) at $(c.args[0].line):$(c.args[0].column)");
                string a1n = "";
                var a1t = expr_type_full (c.args[1], out a1n);
                if (!is_int_like (a1t))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 2 of '$(c.callee)' expects int, got $(type_label (a1t, a1n)) at $(c.args[1].line):$(c.args[1].column)");
                return ValaType.VOID;
            }
            if (c.callee == "__planc_host_bytes_to_str") {
                if (c.args.length != 2)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"$(c.callee) expects 2 argument(s), got $(c.args.length) at $(c.line):$(c.column)");
                coerce_byte_array_literal (c.args[0], ValaType.ARRAY, "uint8");
                string a0n = "";
                var a0t = expr_type_full (c.args[0], out a0n);
                if (!type_compatible (ValaType.ARRAY, "uint8", a0t, a0n))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of '$(c.callee)' expects uint8[], got $(type_label (a0t, a0n)) at $(c.args[0].line):$(c.args[0].column)");
                string a1n = "";
                var a1t = expr_type_full (c.args[1], out a1n);
                if (!is_int_like (a1t))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 2 of '$(c.callee)' expects int, got $(type_label (a1t, a1n)) at $(c.args[1].line):$(c.args[1].column)");
                return ValaType.STRING;
            }
            if (c.callee == "__planc_host_read_file") {
                if (c.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"$(c.callee) expects 1 argument(s), got $(c.args.length) at $(c.line):$(c.column)");
                string a0n = "";
                var a0t = expr_type_full (c.args[0], out a0n);
                if (!type_compatible (ValaType.STRING, "", a0t, a0n))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of '$(c.callee)' expects string, got $(type_label (a0t, a0n)) at $(c.args[0].line):$(c.args[0].column)");
                return ValaType.STRING;
            }
            // __planc_host_write_file
            if (want_value)
                throw new SemanticError.VOID_IN_EXPRESSION (
                    @"void function '$(c.callee)' cannot be used as a value at $(c.line):$(c.column)");
            if (c.args.length != 2)
                throw new SemanticError.WRONG_ARG_COUNT (
                    @"$(c.callee) expects 2 argument(s), got $(c.args.length) at $(c.line):$(c.column)");
            string w0n = "";
            var w0t = expr_type_full (c.args[0], out w0n);
            if (!type_compatible (ValaType.STRING, "", w0t, w0n))
                throw new SemanticError.TYPE_MISMATCH (
                    @"argument 1 of '$(c.callee)' expects string, got $(type_label (w0t, w0n)) at $(c.args[0].line):$(c.args[0].column)");
            coerce_byte_array_literal (c.args[1], ValaType.ARRAY, "uint8");
            string w1n = "";
            var w1t = expr_type_full (c.args[1], out w1n);
            if (!type_compatible (ValaType.ARRAY, "uint8", w1t, w1n))
                throw new SemanticError.TYPE_MISMATCH (
                    @"argument 2 of '$(c.callee)' expects uint8[], got $(type_label (w1t, w1n)) at $(c.args[1].line):$(c.args[1].column)");
            return ValaType.VOID;
        }

        private void check_builtin_method_args (MethodCallExpr mc, string kind) throws SemanticError {
            if (kind == "int_parse" || kind == "float_parse" || kind == "double_parse") {
                if (mc.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"parse expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                string an = "";
                var at = expr_type_full (mc.args[0], out an);
                if (!type_compatible (ValaType.STRING, "", at, an))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of 'parse' expects string, got $(type_label (at, an)) at $(mc.args[0].line):$(mc.args[0].column)");
            } else if (kind == "int_to_string" || kind == "float_to_string" || kind == "double_to_string") {
                if (mc.args.length != 0)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"to_string expects 0 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
            } else if (kind == "str_has_prefix" || kind == "str_has_suffix") {
                if (mc.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"$(mc.method_name) expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                string an = "";
                var at = expr_type_full (mc.args[0], out an);
                if (!type_compatible (ValaType.STRING, "", at, an))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of '$(mc.method_name)' expects string, got $(type_label (at, an)) at $(mc.args[0].line):$(mc.args[0].column)");
            } else if (kind == "str_contains") {
                if (mc.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"contains expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                string an = "";
                var at = expr_type_full (mc.args[0], out an);
                if (!type_compatible (ValaType.STRING, "", at, an))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of 'contains' expects string, got $(type_label (at, an)) at $(mc.args[0].line):$(mc.args[0].column)");
            } else if (kind == "str_index_of") {
                if (mc.args.length != 1 && mc.args.length != 2)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"index_of expects 1 or 2 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                string an = "";
                var at = expr_type_full (mc.args[0], out an);
                if (!type_compatible (ValaType.STRING, "", at, an))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of 'index_of' expects string, got $(type_label (at, an)) at $(mc.args[0].line):$(mc.args[0].column)");
                if (mc.args.length == 2) {
                    string sn2 = "";
                    var st2 = expr_type_full (mc.args[1], out sn2);
                    if (!is_int_like (st2))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"argument 2 of 'index_of' expects int, got $(type_label (st2, sn2)) at $(mc.args[1].line):$(mc.args[1].column)");
                }
            } else if (kind == "str_char_count" || kind == "str_validate") {
                if (mc.args.length != 0)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"$(mc.method_name) expects 0 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
            } else if (kind == "str_get_char") {
                if (mc.args.length > 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"get_char expects 0 or 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                if (mc.args.length == 1) {
                    string an = "";
                    var at = expr_type_full (mc.args[0], out an);
                    if (!is_int_like (at))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"argument 1 of 'get_char' expects int, got $(type_label (at, an)) at $(mc.args[0].line):$(mc.args[0].column)");
                }
            } else if (kind == "str_substring") {
                if (mc.args.length != 1 && mc.args.length != 2)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"substring expects 1 or 2 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                for (int i = 0; i < mc.args.length; i++) {
                    string an = "";
                    var at = expr_type_full (mc.args[i], out an);
                    if (!is_int_like (at))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"argument $(i + 1) of 'substring' expects int, got $(type_label (at, an)) at $(mc.args[i].line):$(mc.args[i].column)");
                }
            } else if (kind == "async_run") {
                if (mc.args.length != 0)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"Async.run expects 0 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                need_async = true;
            } else if (kind == "async_run_parallel") {
                if (mc.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"Async.run_parallel expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                string an = "";
                var at = expr_type_full (mc.args[0], out an);
                if (!is_int_like (at))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument 1 of 'Async.run_parallel' expects int, got $(type_label (at, an)) at $(mc.args[0].line):$(mc.args[0].column)");
                need_async = true;
            } else if (kind == "mutex_lock" || kind == "mutex_unlock" || kind == "chan_close" || kind == "chan_recv") {
                if (mc.args.length != 0)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"$(mc.method_name) expects 0 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                need_sync = true;
                if (kind == "chan_recv")
                    need_async = true;
            } else if (kind == "chan_send") {
                if (mc.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"send expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                string tn = "";
                if (mc.target != null)
                    expr_type_full (mc.target, out tn);
                ValaType et = ValaType.INT;
                string etn = "";
                find_channel_elem (tn, out et, out etn);
                string an = "";
                var at = expr_type_full (mc.args[0], out an);
                if (!type_compatible (et, etn, at, an))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"Channel.send expects $(type_label (et, etn)), got $(type_label (at, an)) at $(mc.args[0].line):$(mc.args[0].column)");
                need_sync = true;
                need_async = true;
            }
        }

        private Function? check_call (CallExpr c, bool want_value) throws SemanticError {
            if (c.callee == "__planc_hash") {
                if (c.args.length != 1)
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"__planc_hash expects 1 argument at $(c.line):$(c.column)");
                string atn;
                expr_type_full (c.args[0], out atn);
                return null;
            }
            if (is_host_intrinsic (c.callee)) {
                check_host_intrinsic (c, want_value);
                return null;
            }
            unowned DelegateDecl? dd = resolve_delegate_callee (c.callee);
            if (dd != null) {
                var dslot = lookup (c.callee);
                if (dslot >= 0)
                    local_used[dslot] = true;
                if (want_value && dd.return_type == ValaType.VOID)
                    throw new SemanticError.VOID_IN_EXPRESSION (
                        @"void delegate '$(c.callee)' cannot be used as a value at $(c.line):$(c.column)");
                check_arg_param_list (c.callee, dd.params, 0, c.args, c.line, c.column);
                return null;
            }
            var f = resolve_call_target (c.callee, c);
            if (f == null) {
                Expr? sig_obj = null;
                unowned SignalDecl? sd = resolve_signal_access (null, c.callee, out sig_obj);
                if (sd != null) {
                    need_signal = true;
                    if (want_value && sd.return_type == ValaType.VOID)
                        throw new SemanticError.VOID_IN_EXPRESSION (
                            @"void signal '$(c.callee)' cannot be used as a value at $(c.line):$(c.column)");
                    unowned var sdd = program.find_delegate (sd.handler_delegate_name);
                    if (sdd != null)
                        check_arg_param_list (c.callee, sdd.params, 1, c.args, c.line, c.column);
                    return null;
                }
            }
            bool is_synth_init = (f != null && f.name.has_prefix ("__planc_init_"));
            if (f == null || (f.is_ctor && !is_synth_init) || f.is_dtor)
                throw new SemanticError.UNKNOWN_FUNCTION (
                    @"unknown function: $(c.callee) at $(c.line):$(c.column)");
            if (f.owner_class != "" && !is_synth_init && !f.is_static
                && current != null && current.is_static) {
                throw new SemanticError.TYPE_MISMATCH (
                    @"cannot call instance method '$(c.callee)' from static method '$(current.method_name)' at $(c.line):$(c.column)");
            }
            int param_off = (f.owner_class != "" && !is_synth_init && !f.is_static) ? 1 : 0;
            if (want_value && f.is_void && !f.is_async)
                throw new SemanticError.VOID_IN_EXPRESSION (
                    @"void function '$(c.callee)' cannot be used as a value at $(c.line):$(c.column)");
            check_arg_list (c.callee, f, param_off, c.args, c.line, c.column);
            return f;
        }

        private Function? check_method_call (MethodCallExpr mc, bool want_value) throws SemanticError {
            string bi_kind = "";
            ValaType bi_ret = ValaType.VOID;
            if (is_builtin_method_call (mc, out bi_kind, out bi_ret)) {
                check_builtin_method_args (mc, bi_kind);
                return null;
            }
            Expr? sig_obj_c = null;
            unowned SignalDecl? sig_conn = resolve_signal_connect (mc, out sig_obj_c);
            if (sig_conn != null) {
                need_signal = true;
                if (mc.method_name == "connect") {
                    if (mc.args.length != 1)
                        throw new SemanticError.WRONG_ARG_COUNT (
                            @"connect expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                    bind_delegate_target (mc.args[0], ValaType.STRUCT, sig_conn.handler_delegate_name);
                    string hn = "";
                    var ht = expr_type_full (mc.args[0], out hn);
                    if (!type_compatible (ValaType.STRUCT, sig_conn.handler_delegate_name, ht, hn))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"signal '$(sig_conn.name).connect' expects $(sig_conn.handler_delegate_name), got $(type_label (ht, hn)) at $(mc.args[0].line):$(mc.args[0].column)");
                    return null;
                } else {
                    if (mc.args.length != 1)
                        throw new SemanticError.WRONG_ARG_COUNT (
                            @"disconnect expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                    string idn = "";
                    var idt = expr_type_full (mc.args[0], out idn);
                    if (!is_int_like (idt))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"signal '$(sig_conn.name).disconnect' expects int, got $(type_label (idt, idn)) at $(mc.args[0].line):$(mc.args[0].column)");
                    if (want_value)
                        throw new SemanticError.VOID_IN_EXPRESSION (
                            @"void method 'disconnect' cannot be used as a value at $(mc.line):$(mc.column)");
                    return null;
                }
            }
            Expr? begin_recv = null;
            var begin_fn = resolve_begin_call (mc, out begin_recv);
            if (begin_fn != null) {
                int b_off = (begin_fn.owner_class != "" && !begin_fn.is_static) ? 1 : 0;
                check_arg_list (begin_fn.name, begin_fn, b_off, mc.args, mc.line, mc.column);
                return begin_fn;
            }
            if (mc.target != null && !mc.is_base_call) {
                unowned DelegateDecl? md = resolve_member_delegate (mc.target, mc.method_name);
                if (md != null) {
                    string dlabel = (mc.method_name != "") ? mc.method_name : md.name;
                    if (want_value && md.return_type == ValaType.VOID)
                        throw new SemanticError.VOID_IN_EXPRESSION (
                            @"void delegate '$dlabel' cannot be used as a value at $(mc.line):$(mc.column)");
                    check_arg_param_list (dlabel, md.params, 0, mc.args, mc.line, mc.column);
                    return null;
                }
                if (mc.method_name == "")
                    throw new SemanticError.TYPE_MISMATCH (
                        @"expression is not callable as a delegate at $(mc.line):$(mc.column)");
            }
            var m = resolve_method_call_fn (mc);
            if (m == null) {
                Expr? sig_obj = null;
                unowned SignalDecl? sd_emit = resolve_signal_access (mc.target, mc.method_name, out sig_obj);
                if (sd_emit != null) {
                    need_signal = true;
                    if (want_value && sd_emit.return_type == ValaType.VOID)
                        throw new SemanticError.VOID_IN_EXPRESSION (
                            @"void signal '$(mc.method_name)' cannot be used as a value at $(mc.line):$(mc.column)");
                    unowned var sdd = program.find_delegate (sd_emit.handler_delegate_name);
                    if (sdd != null)
                        check_arg_param_list (mc.method_name, sdd.params, 1, mc.args, mc.line, mc.column);
                    return null;
                }
                throw new SemanticError.UNKNOWN_FUNCTION (
                    @"unknown method '$(mc.method_name)' at $(mc.line):$(mc.column)");
            }
            if (want_value && m.is_void && !m.is_async)
                throw new SemanticError.VOID_IN_EXPRESSION (
                    @"void method '$(mc.method_name)' cannot be used as a value at $(mc.line):$(mc.column)");
            int param_off = m.is_static ? 0 : 1;
            check_arg_list (mc.method_name, m, param_off, mc.args, mc.line, mc.column);
            return m;
        }

        private ValaType expr_type (Expr e) throws SemanticError {
            string unused = "";
            return expr_type_full (e, out unused);
        }

        private ValaType expr_type_full (Expr e, out string tname) throws SemanticError {
            tname = "";
            if (e is IntLiteral) {
                var il = (IntLiteral) e;
                if (il.is_unsigned)
                    tname = (il.is_long || ((uint64) il.value) > (uint64) 0xFFFFFFFFu) ? "uint64" : "uint32";
                else if (il.is_long)
                    tname = "int64";
                return ValaType.INT;
            }
            if (e is FloatLiteral)
                return ((FloatLiteral) e).is_float32 ? ValaType.FLOAT : ValaType.DOUBLE;
            if (e is BoolLiteral)
                return ValaType.BOOL;
            if (e is StringLiteral)
                return ValaType.STRING;
            if (e is NullLiteral)
                return ValaType.NULL;
            if (e is SizeofExpr) {
                var sz = (SizeofExpr) e;
                if (!sz.is_type_form && sz.operand != null)
                    expr_type (sz.operand);
                return ValaType.INT;
            }
            if (e is TemplateExpr) {
                var t = (TemplateExpr) e;
                foreach (var part in t.parts) {
                    var pt = expr_type (part);
                    if (pt != ValaType.INT && pt != ValaType.BOOL
                        && pt != ValaType.FLOAT && pt != ValaType.DOUBLE
                        && pt != ValaType.STRING && pt != ValaType.ENUM) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot interpolate $(pt.label ()) in template string at $(part.line):$(part.column)");
                    }
                }
                return ValaType.STRING;
            }
            if (e is ArrayNewExpr) {
                var an = (ArrayNewExpr) e;
                string lt_name = "";
                var lt = expr_type_full (an.length_expr, out lt_name);
                if (!is_int_like (lt))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"array size must be int, got $(type_label (lt, lt_name)) at $(an.length_expr.line):$(an.length_expr.column)");
                if (an.elem_type == ValaType.STRING && an.elem_type_name == "?")
                    tname = "?";
                else if (an.elem_type == ValaType.INT && an.elem_type_name != "" && an.elem_type_name != "int")
                    tname = an.elem_type_name;
                else if (an.elem_type == ValaType.ENUM || an.elem_type == ValaType.CLASS
                         || an.elem_type == ValaType.INTERFACE
                         || (an.elem_type == ValaType.ERROR && an.elem_type_name != ""))
                    tname = an.elem_type_name;
                else
                    tname = an.elem_type.label ();
                return ValaType.ARRAY;
            }
            if (e is ArrayLiteralExpr) {
                var arr = (ArrayLiteralExpr) e;
                if (arr.elem_type == ValaType.INT
                    && arr.elem_type_name != "" && arr.elem_type_name != "int"
                    && is_int_type_name_cg (arr.elem_type_name)) {
                    for (int i = 0; i < arr.elements.length; i++) {
                        string cur_name = "";
                        var cur = expr_type_full (arr.elements[i], out cur_name);
                        if (!is_int_like (cur))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"array element $(i + 1) expects $(arr.elem_type_name), got $(type_label (cur, cur_name)) at $(arr.elements[i].line):$(arr.elements[i].column)");
                    }
                    tname = arr.elem_type_name;
                    return ValaType.ARRAY;
                }
                string et_name = "";
                var et = expr_type_full (arr.elements[0], out et_name);
                if (et == ValaType.VOID || et == ValaType.STRUCT || et == ValaType.ARRAY || et == ValaType.NULL)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unsupported array literal element type $(type_label (et, et_name)) at $(arr.elements[0].line):$(arr.elements[0].column)");
                if (et == ValaType.CLASS || et == ValaType.INTERFACE)
                    et_name = strip_null (et_name);
                for (int i = 1; i < arr.elements.length; i++) {
                    string cur_name = "";
                    var cur = expr_type_full (arr.elements[i], out cur_name);
                    if (et == ValaType.CLASS && cur == ValaType.CLASS) {
                        unowned var common = common_ancestor_class (et_name, strip_null (cur_name));
                        if (common == null)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"array element $(i + 1) class '$(strip_null (cur_name))' has no common base with '$(et_name)' at $(arr.elements[i].line):$(arr.elements[i].column)");
                        et_name = common.name;
                    } else if (et == ValaType.INTERFACE || cur == ValaType.INTERFACE) {
                        unify_branch_types (et, et_name, cur, cur_name, out et, out et_name, arr.elements[i].line, arr.elements[i].column);
                        et_name = strip_null (et_name);
                    } else if (!type_compatible (et, et_name, cur, cur_name)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"array element $(i + 1) expects $(type_label (et, et_name)), got $(type_label (cur, cur_name)) at $(arr.elements[i].line):$(arr.elements[i].column)");
                    }
                    if (et == ValaType.BOOL && cur == ValaType.INT)
                        et = ValaType.INT;
                }
                arr.elem_type = et;
                arr.elem_type_name = et_name;
                if (et == ValaType.INT && et_name != "" && et_name != "int")
                    tname = et_name;
                else
                    tname = (et == ValaType.ENUM || et == ValaType.CLASS || et == ValaType.INTERFACE) ? et_name : et.label ();
                return ValaType.ARRAY;
            }
            if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                if (cn.class_name == "Mutex" || cn.class_name.has_prefix ("Channel__")) {
                    if (cn.args.length != 0 || cn.init_names.length != 0)
                        throw new SemanticError.WRONG_ARG_COUNT (
                            @"'$(cn.class_name)' constructor expects 0 argument(s) at $(cn.line):$(cn.column)");
                    need_sync = true;
                    tname = cn.class_name;
                    return ValaType.CLASS;
                }
                unowned var cd = program.find_class (cn.class_name);
                if (cd == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown class '$(cn.class_name)' at $(cn.line):$(cn.column)");
                if (cd.is_generic_template)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"generic class '$(cd.name)' requires type arguments at $(cn.line):$(cn.column)");
                if (cd.is_abstract)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"cannot instantiate abstract class '$(cd.name)' at $(cn.line):$(cn.column)");
                unowned Function? ctor_fn = cd.ctor;
                if (cn.ctor_name != "") {
                    ctor_fn = cd.find_own_named_ctor (cn.ctor_name);
                    if (ctor_fn == null)
                        throw new SemanticError.UNKNOWN_FUNCTION (
                            @"class '$(cd.name)' has no constructor '$(cd.name).$(cn.ctor_name)' at $(cn.line):$(cn.column)");
                }
                if (ctor_fn != null) {
                    check_ctor_args (ctor_fn, cn.args, cn.line, cn.column);
                } else if (cn.args.length != 0) {
                    throw new SemanticError.WRONG_ARG_COUNT (
                        @"'$(cd.name)' constructor expects 0 argument(s), got $(cn.args.length) at $(cn.line):$(cn.column)");
                }
                for (int i = 0; i < cn.init_names.length; i++) {
                    var iname = cn.init_names[i];
                    var ival = cn.init_values[i];
                    ValaType ft;
                    string ft_name;
                    unowned ClassField? cf = null;
                    if (class_field_offset_slots (cd, iname, out cf) >= 0 && cf != null) {
                        ft = cf.field_type;
                        ft_name = cf.type_name;
                    } else {
                        unowned var sm = find_prop_setter (ValaType.CLASS, cd.name, iname);
                        if (sm == null)
                            throw new SemanticError.UNKNOWN_MEMBER (
                                @"class '$(cd.name)' has no field or writable property '$(iname)' at $(ival.line):$(ival.column)");
                        ft = sm.params[1].param_type;
                        ft_name = sm.params[1].type_name;
                    }
                    string vt_name = "";
                    var vt = expr_type_full (ival, out vt_name);
                    if (!type_compatible (ft, ft_name, vt, vt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot initialize '$(cd.name).$(iname)' ($(type_label (ft, ft_name))) with $(type_label (vt, vt_name)) at $(ival.line):$(ival.column)");
                }
                tname = cd.name;
                return ValaType.CLASS;
            }
            if (e is TypeCheckExpr) {
                var tc = (TypeCheckExpr) e;
                string ot_name = "";
                var ot = expr_type_full (tc.operand, out ot_name);
                if (tc.op == "nonnull") {
                    if (ot == ValaType.NULL)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"'(!)' cannot be applied to null at $(tc.line):$(tc.column)");
                    if (ot == ValaType.STRING)
                        tname = "";
                    else if (ot == ValaType.CLASS || ot == ValaType.INTERFACE
                             || ot == ValaType.ARRAY || ot == ValaType.ERROR
                             || is_delegate_type (program, ot, ot_name))
                        tname = strip_null (ot_name);
                    else
                        tname = ot_name;
                    return ot;
                }
                if (tc.op == "cast" && is_delegate_type (program, tc.target_type, tc.target_type_name)) {
                    if (ot == ValaType.NULL) {
                        if (!is_nullable_type (tc.target_type, tc.target_type_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot cast null to '$(tc.target_type_name)' at $(tc.line):$(tc.column)");
                    } else if (!is_delegate_type (program, ot, ot_name)
                               || strip_null (ot_name) != strip_null (tc.target_type_name)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot cast $(type_label (ot, ot_name)) to '$(tc.target_type_name)' at $(tc.line):$(tc.column)");
                    }
                    tname = tc.target_type_name;
                    return ValaType.STRUCT;
                }
                if (tc.op == "cast" && (tc.target_type == ValaType.INT || tc.target_type == ValaType.ENUM)) {
                    if (!is_int_like (ot) && ot != ValaType.ENUM && !is_fp_type (ot))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot cast $(type_label (ot, ot_name)) to '$(tc.target_type_name)' at $(tc.line):$(tc.column)");
                    tname = tc.target_type_name;
                    return tc.target_type;
                }
                if (tc.op == "cast" && is_fp_type (tc.target_type)) {
                    if (!is_numeric_type (ot) && ot != ValaType.ENUM)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot cast $(type_label (ot, ot_name)) to '$(tc.target_type_name)' at $(tc.line):$(tc.column)");
                    tname = tc.target_type_name;
                    return tc.target_type;
                }
                if (tc.target_type == ValaType.ERROR) {
                    if (ot != ValaType.ERROR && ot != ValaType.NULL)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"'$(tc.op)' requires an Error value, got $(type_label (ot, ot_name)) at $(tc.line):$(tc.column)");
                    return ValaType.BOOL;
                }
                if (ot != ValaType.CLASS && ot != ValaType.INTERFACE && ot != ValaType.NULL)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'$(tc.op)' requires a class or interface instance, got $(type_label (ot, ot_name)) at $(tc.line):$(tc.column)");
                if (tc.op == "is")
                    return ValaType.BOOL;
                if (tc.op == "as") {
                    tname = strip_null (tc.target_type_name) + "?";
                    tname = tc.target_type_name;
                    return tc.target_type;
                }
                tname = tc.target_type_name;
                return tc.target_type;
            }
            if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                string bi_kind = "";
                ValaType bi_ret = ValaType.VOID;
                if (is_builtin_method_call (mc, out bi_kind, out bi_ret)) {
                    check_builtin_method_args (mc, bi_kind);
                    if (bi_kind == "chan_recv") {
                        string tn = "";
                        if (mc.target != null)
                            expr_type_full (mc.target, out tn);
                        ValaType et = ValaType.INT;
                        string etn = "";
                        find_channel_elem (tn, out et, out etn);
                        tname = make_async_task_type_name (et, etn);
                    }
                    return bi_ret;
                }
                if (mc.target != null && !mc.is_base_call && mc.method_name != "begin"
                    && mc.method_name != "connect" && mc.method_name != "disconnect") {
                    unowned var md = resolve_member_delegate (mc.target, mc.method_name);
                    if (md != null) {
                        string dlabel = (mc.method_name != "") ? mc.method_name : md.name;
                        if (md.return_type == ValaType.VOID)
                            throw new SemanticError.VOID_IN_EXPRESSION (
                                @"void delegate '$dlabel' cannot be used as a value at $(mc.line):$(mc.column)");
                        check_arg_param_list (dlabel, md.params, 0, mc.args, mc.line, mc.column);
                        tname = md.return_type_name;
                        return md.return_type;
                    }
                }
                Expr? sig_obj_c = null;
                unowned SignalDecl? sig_conn = resolve_signal_connect (mc, out sig_obj_c);
                if (sig_conn != null) {
                    need_signal = true;
                    if (mc.method_name == "connect") {
                        if (mc.args.length != 1)
                            throw new SemanticError.WRONG_ARG_COUNT (
                                @"connect expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                        bind_delegate_target (mc.args[0], ValaType.STRUCT, sig_conn.handler_delegate_name);
                        string hn = "";
                        var ht = expr_type_full (mc.args[0], out hn);
                        if (!type_compatible (ValaType.STRUCT, sig_conn.handler_delegate_name, ht, hn))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"signal '$(sig_conn.name).connect' expects $(sig_conn.handler_delegate_name), got $(type_label (ht, hn)) at $(mc.args[0].line):$(mc.args[0].column)");
                        return ValaType.INT;
                    } else {
                        if (mc.args.length != 1)
                            throw new SemanticError.WRONG_ARG_COUNT (
                                @"disconnect expects 1 argument(s), got $(mc.args.length) at $(mc.line):$(mc.column)");
                        string idn = "";
                        var idt = expr_type_full (mc.args[0], out idn);
                        if (!is_int_like (idt))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"signal '$(sig_conn.name).disconnect' expects int, got $(type_label (idt, idn)) at $(mc.args[0].line):$(mc.args[0].column)");
                        throw new SemanticError.VOID_IN_EXPRESSION (
                            @"void method 'disconnect' cannot be used as a value at $(mc.line):$(mc.column)");
                    }
                }
                var m = check_method_call (mc, true);
                if (m == null) {
                    Expr? sig_obj_e = null;
                    unowned SignalDecl? sd_e = resolve_signal_access (mc.target, mc.method_name, out sig_obj_e);
                    if (sd_e != null) {
                        tname = sd_e.return_type_name;
                        return sd_e.return_type;
                    }
                    return ValaType.VOID;
                }
                if (m.is_async) {
                    tname = make_async_task_type_name (m.return_type, m.return_type_name);
                    return ValaType.CLASS;
                }
                tname = m.return_type_name;
                return m.return_type;
            }
            if (e is MemberAccessExpr) {
                var m = (MemberAccessExpr) e;
                if (m.target is VarRef) {
                    var vr = (VarRef) m.target;
                    if (is_type_name (vr.name)) {
                        if (is_int_type_name_cg (vr.name)) {
                            int64 unused_val = 0;
                            if (resolve_int_const_member (vr.name, m.member, out unused_val)) {
                                tname = vr.name;
                                return ValaType.INT;
                            }
                        }
                        if (is_fp_type_name_cg (vr.name)) {
                            uint64 unused_bits = 0;
                            if (resolve_fp_const_member (vr.name, m.member, out unused_bits))
                                return (vr.name == "float") ? ValaType.FLOAT : ValaType.DOUBLE;
                        }
                        unowned var cd_const = program.find_const (vr.name, m.member);
                        if (cd_const != null) {
                            tname = cd_const.type_name;
                            return cd_const.const_type;
                        }
                        unowned var err_d = program.find_error_domain (vr.name);
                        if (err_d != null) {
                            if (err_d.find_code (m.member) == null)
                                throw new SemanticError.UNKNOWN_MEMBER (
                                    @"error domain '$(err_d.name)' has no code '$(m.member)' at $(m.line):$(m.column)");
                            return ValaType.INT;
                        }
                        unowned var ed = program.find_enum (vr.name);
                        if (ed != null) {
                            if (ed.find_member (m.member) == null)
                                throw new SemanticError.UNKNOWN_MEMBER (
                                    @"enum '$(ed.name)' has no member '$(m.member)' at $(m.line):$(m.column)");
                            tname = ed.name;
                            return ValaType.ENUM;
                        }
                        {
                            int sg = static_field_global_of_type (vr.name, m.member);
                            if (sg >= 0) {
                                tname = global_type_names[sg];
                                return global_types[sg];
                            }
                        }
                        if (m.target_del_type != "") {
                            unowned var mf = resolve_type_method (vr.name, m.member);
                            unowned var dd = program.find_delegate (m.target_del_type);
                            if (mf != null && mf.is_static && dd != null) {
                                check_delegate_target_fn (dd, mf, 0, m.line, m.column);
                                tname = dd.name;
                                return ValaType.STRUCT;
                            }
                        }
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"type '$(vr.name)' has no constant or member '$(m.member)' at $(m.line):$(m.column)");
                    }
                }
                string tt_name = "";
                var tt = expr_type_full (m.target, out tt_name);
                if (tt == ValaType.ERROR) {
                    if (m.member == "message")
                        return ValaType.STRING;
                    if (m.member == "domain" || m.member == "code")
                        return ValaType.INT;
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"Error has no member '$(m.member)' at $(m.line):$(m.column)");
                }
                if (tt == ValaType.STRING || tt == ValaType.ARRAY) {
                    if (m.member != "length")
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"$(type_label (tt, tt_name)) has no member '$(m.member)' at $(m.line):$(m.column)");
                    return ValaType.INT;
                }
                if (tt == ValaType.CLASS) {
                    var cname = strip_null (tt_name);
                    unowned var cd = program.find_class (cname);
                    unowned ClassField? cf = null;
                    if (cd != null && class_field_offset_slots (cd, m.member, out cf) >= 0 && cf != null) {
                        tname = maybe_narrow_member (m, cf.type_name);
                        return cf.field_type;
                    }
                    unowned var gm = find_prop_getter (tt, tt_name, m.member);
                    if (gm != null) {
                        tname = maybe_narrow_member (m, gm.return_type_name);
                        return gm.return_type;
                    }
                    if (m.target_del_type != "") {
                        unowned var mf = resolve_member_delegate_fn (tt, tt_name, m.member);
                        unowned var dd = program.find_delegate (m.target_del_type);
                        if (mf != null && dd != null) {
                            check_delegate_target_fn (dd, mf, mf.is_static ? 0 : 1, m.line, m.column);
                            tname = dd.name;
                            return ValaType.STRUCT;
                        }
                    }
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"class '$(cname)' has no field or property '$(m.member)' at $(m.line):$(m.column)");
                }
                if (tt == ValaType.INTERFACE) {
                    unowned var gm = find_prop_getter (tt, tt_name, m.member);
                    if (gm != null) {
                        tname = maybe_narrow_member (m, gm.return_type_name);
                        return gm.return_type;
                    }
                    if (m.target_del_type != "") {
                        unowned var mf = resolve_member_delegate_fn (tt, tt_name, m.member);
                        unowned var dd = program.find_delegate (m.target_del_type);
                        if (mf != null && dd != null) {
                            check_delegate_target_fn (dd, mf, 1, m.line, m.column);
                            tname = dd.name;
                            return ValaType.STRUCT;
                        }
                    }
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"interface '$(strip_null (tt_name))' has no property '$(m.member)' at $(m.line):$(m.column)");
                }
                if (tt == ValaType.STRUCT) {
                    unowned var sd = program.find_struct (tt_name);
                    unowned StructField? fld = null;
                    if (sd != null && struct_field_offset_slots (sd, m.member, out fld) >= 0 && fld != null) {
                        tname = maybe_narrow_member (m, fld.type_name);
                        return fld.field_type;
                    }
                    unowned var gm = find_prop_getter (tt, tt_name, m.member);
                    if (gm != null) {
                        tname = maybe_narrow_member (m, gm.return_type_name);
                        return gm.return_type;
                    }
                    if (m.target_del_type != "") {
                        unowned var mf = resolve_member_delegate_fn (tt, tt_name, m.member);
                        unowned var dd = program.find_delegate (m.target_del_type);
                        if (mf != null && mf.is_static && dd != null) {
                            check_delegate_target_fn (dd, mf, 0, m.line, m.column);
                            tname = dd.name;
                            return ValaType.STRUCT;
                        }
                    }
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"struct '$(tt_name)' has no field or property '$(m.member)' at $(m.line):$(m.column)");
                }
                throw new SemanticError.TYPE_MISMATCH (
                    @"cannot access member '.$(m.member)' on $(type_label (tt, tt_name)) at $(m.line):$(m.column)");
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                string tt_name = "";
                var tt = expr_type_full (ix.target, out tt_name);
                ValaType ga_et = ValaType.INT;
                string ga_etn = "";
                bool is_ga = (tt == ValaType.CLASS) && find_generic_array_elem (tt_name, out ga_et, out ga_etn);
                if (tt == ValaType.CLASS && !is_ga) {
                    unowned var icd = program.find_class (strip_null (tt_name));
                    unowned var gm = (icd != null) ? find_class_method (icd, "get_item") : null;
                    if (gm != null) {
                        string ix_tn2 = "";
                        var ix_t2 = expr_type_full (ix.index, out ix_tn2);
                        if (gm.params.length >= 2
                            && !type_compatible (gm.params[1].param_type, gm.params[1].type_name, ix_t2, ix_tn2))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"indexer of '$(strip_null (tt_name))' expects $(type_label (gm.params[1].param_type, gm.params[1].type_name)), got $(type_label (ix_t2, ix_tn2)) at $(ix.index.line):$(ix.index.column)");
                        tname = gm.return_type_name;
                        return gm.return_type;
                    }
                }
                if (tt != ValaType.STRING && tt != ValaType.ARRAY && !is_ga)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"indexing requires string or array, got $(type_label (tt, tt_name)) at $(ix.line):$(ix.column)");
                string it_name = "";
                var it = expr_type_full (ix.index, out it_name);
                if (!is_int_like (it))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"index must be int, got $(type_label (it, it_name)) at $(ix.index.line):$(ix.index.column)");
                if (is_ga) {
                    tname = ga_etn;
                    return ga_et;
                }
                if (tt == ValaType.ARRAY) {
                    ValaType et;
                    string et_name;
                    parse_array_elem (tt_name, out et, out et_name);
                    tname = et_name;
                    return et;
                }
                return ValaType.INT;
            }
            if (e is SliceExpr) {
                var se = (SliceExpr) e;
                string tt_name = "";
                var tt = expr_type_full (se.target, out tt_name);
                if (tt != ValaType.STRING)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"slicing requires string, got $(type_label (tt, tt_name)) at $(se.line):$(se.column)");
                string st_name = "";
                var st = expr_type_full (se.start, out st_name);
                if (!is_int_like (st))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"slice start index must be int, got $(type_label (st, st_name)) at $(se.start.line):$(se.start.column)");
                string et_name = "";
                var et = expr_type_full (se.end, out et_name);
                if (!is_int_like (et))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"slice end index must be int, got $(type_label (et, et_name)) at $(se.end.line):$(se.end.column)");
                return ValaType.STRING;
            }
            if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                string ct_name = "";
                var ct = expr_type_full (te.condition, out ct_name);
                if (!is_int_like (ct))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"ternary condition must be bool or int, got $(type_label (ct, ct_name)) at $(te.condition.line):$(te.condition.column)");
                var snap = clone_non_null ();
                var nn_then = new GenericArray<string> ();
                var nn_else = new GenericArray<string> ();
                collect_non_null_when (te.condition, true, nn_then);
                collect_non_null_when (te.condition, false, nn_else);
                add_all_non_null (nn_then);
                string tt_name = "";
                var tt = expr_type_full (te.then_expr, out tt_name);
                restore_non_null (snap);
                add_all_non_null (nn_else);
                string et_name = "";
                var et = expr_type_full (te.else_expr, out et_name);
                restore_non_null (snap);
                ValaType res_t;
                unify_branch_types (tt, tt_name, et, et_name, out res_t, out tname, te.line, te.column);
                return res_t;
            }
            if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                string lt_name = "";
                var lt = expr_type_full (ce.left, out lt_name);
                if (lt != ValaType.NULL && !is_ref_type (lt) && !is_delegate_type (program, lt, lt_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"operator '??' requires a reference type on left operand, got $(type_label (lt, lt_name)) at $(ce.line):$(ce.column)");
                string rt_name = "";
                var rt = expr_type_full (ce.right, out rt_name);
                if (lt == ValaType.NULL) {
                    if (rt != ValaType.NULL && !is_ref_type (rt) && !is_delegate_type (program, rt, rt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"operator '??' requires compatible reference types, got $(type_label (rt, rt_name)) at $(ce.line):$(ce.column)");
                    tname = rt_name;
                    return rt;
                }
                if (rt == ValaType.NULL) {
                    tname = make_nullable (lt, lt_name);
                    return lt;
                }
                ValaType ut;
                string uname = "";
                unify_branch_types (lt, lt_name, rt, rt_name, out ut, out uname, ce.line, ce.column);
                tname = is_nullable_type (rt, rt_name) ? uname : strip_null (uname);
                return ut;
            }
            if (e is StructLiteral) {
                var lit = (StructLiteral) e;
                unowned var sd = program.find_struct (lit.struct_name);
                if (sd == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown struct '$(lit.struct_name)' at $(lit.line):$(lit.column)");
                for (int i = 0; i < lit.field_names.length; i++) {
                    var fname = lit.field_names[i];
                    var fval = lit.field_values[i];
                    unowned StructField? fld = null;
                    if (struct_field_offset_slots (sd, fname, out fld) < 0 || fld == null)
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"struct '$(sd.name)' has no field '$(fname)' at $(fval.line):$(fval.column)");
                    string vt_name = "";
                    var vt = expr_type_full (fval, out vt_name);
                    if (!type_compatible (fld.field_type, fld.type_name, vt, vt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"field '$(sd.name).$(fname)' expects $(type_label (fld.field_type, fld.type_name)), got $(type_label (vt, vt_name)) at $(fval.line):$(fval.column)");
                }
                tname = sd.name;
                return ValaType.STRUCT;
            }
            if (e is VarRef) {
                var v = (VarRef) e;
                if (v.target_del_type != "") {
                    unowned var dd = program.find_delegate (v.target_del_type);
                    var f = resolve_call_target (v.name);
                    if (dd != null && f != null) {
                        bool is_synth_init = f.name.has_prefix ("__planc_init_");
                        int param_off = (f.owner_class != "" && !is_synth_init && !f.is_static) ? 1 : 0;
                        check_delegate_target_fn (dd, f, param_off, v.line, v.column);
                        tname = dd.name;
                        return ValaType.STRUCT;
                    }
                }
                var slot = lookup (v.name);
                if (slot >= 0) {
                    local_used[slot] = true;
                    tname = maybe_narrow_var (v.name, local_type_names[slot]);
                    return local_types[slot];
                }
                var gi = lookup_global (v.name);
                if (gi >= 0) {
                    tname = maybe_narrow_var (v.name, global_type_names[gi]);
                    return global_types[gi];
                }
                if (current_class != null) {
                    unowned var c_const = program.find_const (current_class.name, v.name);
                    if (c_const != null) {
                        tname = c_const.type_name;
                        return c_const.const_type;
                    }
                    if (!current.is_static) {
                        unowned ClassField? cf = null;
                        if (class_field_offset_slots (current_class, v.name, out cf) >= 0 && cf != null) {
                            tname = maybe_narrow_var (v.name, cf.type_name);
                            return cf.field_type;
                        }
                    }
                }
                if (current_struct != null) {
                    unowned var s_const = program.find_const (current_struct.name, v.name);
                    if (s_const != null) {
                        tname = s_const.type_name;
                        return s_const.const_type;
                    }
                    if (!current.is_static) {
                        unowned StructField? sf = null;
                        if (struct_field_offset_slots (current_struct, v.name, out sf) >= 0 && sf != null) {
                            tname = maybe_narrow_var (v.name, sf.type_name);
                            return sf.field_type;
                        }
                    }
                }
                if (current_enum != null) {
                    unowned var e_const = program.find_const (current_enum.name, v.name);
                    if (e_const != null) {
                        tname = e_const.type_name;
                        return e_const.const_type;
                    }
                    if (current_enum.find_member (v.name) != null) {
                        tname = current_enum.name;
                        return ValaType.ENUM;
                    }
                }
                unowned var gm = find_this_prop_getter (v.name);
                if (gm != null) {
                    tname = maybe_narrow_var (v.name, gm.return_type_name);
                    return gm.return_type;
                }
                unowned var g_const = program.find_const ("", v.name);
                if (g_const != null) {
                    tname = g_const.type_name;
                    return g_const.const_type;
                }
                {
                    int sg = static_field_global_of_this_class (v.name);
                    if (sg >= 0) {
                        tname = global_type_names[sg];
                        return global_types[sg];
                    }
                }
                throw new SemanticError.UNKNOWN_VARIABLE (
                    @"unknown variable: $(v.name) at $(v.line):$(v.column)");
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                string ot_name = "";
                var ot = expr_type_full (u.operand, out ot_name);
                if (u.op == "-" && is_fp_type (ot))
                    return ot;
                if (!is_int_like (ot))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unary '$(u.op)' requires int or bool, got $(type_label (ot, ot_name)) at $(u.line):$(u.column)");
                if (u.op == "!")
                    return ValaType.BOOL;
                tname = (is_unsigned_64 (ot_name) || is_unsigned_32 (ot_name)) ? ot_name : "";
                return ValaType.INT;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                string lt_name = "";
                string rt_name = "";
                var lt = expr_type_full (b.left, out lt_name);
                ValaType rt;
                if (b.op == "&&" || b.op == "||") {
                    var snap = clone_non_null ();
                    var nn_rhs = new GenericArray<string> ();
                    collect_non_null_when (b.left, b.op == "&&", nn_rhs);
                    add_all_non_null (nn_rhs);
                    rt = expr_type_full (b.right, out rt_name);
                    restore_non_null (snap);
                } else {
                    rt = expr_type_full (b.right, out rt_name);
                }
                if (b.op == "+" && lt == ValaType.STRING && rt == ValaType.STRING
                    && !is_nullable_type (lt, lt_name) && !is_nullable_type (rt, rt_name)) {
                    return ValaType.STRING;
                }
                if (b.op == "==" || b.op == "!=") {
                    if (!eq_compatible (lt, lt_name, rt, rt_name)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot compare $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) with '$(b.op)' at $(b.line):$(b.column)");
                    }
                    return ValaType.BOOL;
                }
                if (lt == ValaType.ENUM && rt == ValaType.ENUM && strip_null (lt_name) == strip_null (rt_name)) {
                    if (b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">=")
                        return ValaType.BOOL;
                    if (b.op == "|" || b.op == "&" || b.op == "^") {
                        tname = strip_null (lt_name);
                        return ValaType.ENUM;
                    }
                }
                if (is_numeric_type (lt) && is_numeric_type (rt) && (is_fp_type (lt) || is_fp_type (rt))) {
                    if (b.op == "+" || b.op == "-" || b.op == "*" || b.op == "/")
                        return (lt == ValaType.DOUBLE || rt == ValaType.DOUBLE) ? ValaType.DOUBLE : ValaType.FLOAT;
                    if (b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">=")
                        return ValaType.BOOL;
                    throw new SemanticError.TYPE_MISMATCH (
                        @"operator '$(b.op)' is not supported on $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $(b.line):$(b.column)");
                }
                if (!is_int_like (lt) || !is_int_like (rt))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"operator '$(b.op)' requires int or bool operands, got $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $(b.line):$(b.column)");
                if (b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">="
                    || b.op == "&&" || b.op == "||") {
                    return ValaType.BOOL;
                }
                if (b.op == "<<" || b.op == ">>") {
                    tname = is_unsigned_64 (lt_name) ? "uint64" : (is_unsigned_32 (lt_name) ? "uint32" : "");
                    return ValaType.INT;
                }
                tname = promote_int_type (lt_name, rt_name);
                return ValaType.INT;
            }
            if (e is CallExpr) {
                var ce = (CallExpr) e;
                if (ce.callee == "__planc_hash") {
                    if (ce.args.length != 1)
                        throw new SemanticError.WRONG_ARG_COUNT (
                            @"__planc_hash expects 1 argument at $(ce.line):$(ce.column)");
                    string atn;
                    expr_type_full (ce.args[0], out atn);
                    tname = "";
                    return ValaType.INT;
                }
                if (is_host_intrinsic (ce.callee))
                    return check_host_intrinsic (ce, true);
                unowned DelegateDecl? dd = resolve_delegate_callee (ce.callee);
                if (dd != null) {
                    if (dd.return_type == ValaType.VOID)
                        throw new SemanticError.VOID_IN_EXPRESSION (
                            @"void delegate '$(ce.callee)' cannot be used as a value at $(ce.line):$(ce.column)");
                    check_arg_param_list (ce.callee, dd.params, 0, ce.args, ce.line, ce.column);
                    tname = dd.return_type_name;
                    return dd.return_type;
                }
                var f = check_call (ce, true);
                if (f == null) {
                    Expr? sig_obj_e = null;
                    unowned SignalDecl? sd_e = resolve_signal_access (null, ce.callee, out sig_obj_e);
                    if (sd_e != null) {
                        tname = sd_e.return_type_name;
                        return sd_e.return_type;
                    }
                    return ValaType.VOID;
                }
                if (f.is_async) {
                    tname = make_async_task_type_name (f.return_type, f.return_type_name);
                    return ValaType.CLASS;
                }
                tname = f.return_type_name;
                return f.return_type;
            }
            if (e is YieldExpr) {
                var ye = (YieldExpr) e;
                if (current == null || !current.is_async)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'yield' is only valid inside an 'async' function at $(ye.line):$(ye.column)");
                if (ye.value == null)
                    return ValaType.VOID;
                string vt_name = "";
                var vt = expr_type_full (ye.value, out vt_name);
                ValaType inner_t = ValaType.VOID;
                string inner_name = "";
                if (vt != ValaType.CLASS || !parse_async_task_type_name (vt_name, out inner_t, out inner_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'yield' expects an async task, got $(type_label (vt, vt_name)) at $(ye.line):$(ye.column)");
                tname = inner_name;
                return inner_t;
            }
            if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                if (!(inc.target is VarRef || inc.target is MemberAccessExpr || inc.target is IndexExpr))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"operator '$(inc.op)' requires a variable or field lvalue at $(inc.line):$(inc.column)");
                string it_name = "";
                var it = expr_type_full (inc.target, out it_name);
                if (it != ValaType.INT)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"operator '$(inc.op)' requires integer operand, got $(type_label (it, it_name)) at $(inc.line):$(inc.column)");
                tname = it_name;
                return ValaType.INT;
            }
            if (e is LambdaExpr) {
                var lam = (LambdaExpr) e;
                unowned var dd = (lam.delegate_type_name != "") ? program.find_delegate (lam.delegate_type_name) : null;
                if (dd == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"lambda expression requires a known delegate target type at $(lam.line):$(lam.column)");
                tname = dd.name;
                return ValaType.STRUCT;
            }
            Host.panic ("unknown expression node");
            return ValaType.VOID;
        }

        // ------------------------------------------------------------------
        // Struct and reference-counting cleanup helpers.
        // ------------------------------------------------------------------

        private void init_struct_at_rcx (StructDecl sd, int byte_offset) {
            int off = byte_offset;
            foreach (var fld in sd.fields) {
                if (fld.field_type == ValaType.STRUCT) {
                    unowned var sub = program.find_struct (fld.type_name);
                    if (sub != null)
                        init_struct_at_rcx (sub, off);
                    off += 8 * type_slots (fld.field_type, fld.type_name);
                } else if (fld.field_type == ValaType.STRING && !is_nullable_type (fld.field_type, fld.type_name)) {
                    emitter.lea_rax_rip (emitter.add_string (""));
                    emitter.store_rcx_disp_rax (off);
                    off += 8;
                } else {
                    emitter.xor_eax ();
                    emitter.store_rcx_disp_rax (off);
                    off += 8;
                }
            }
        }

        // Calls __planc_ref on every reference field of a struct whose base is in `rcx`.
        private void ref_struct_at_rcx (StructDecl sd, int byte_offset) {
            int off = byte_offset;
            foreach (var fld in sd.fields) {
                if (fld.field_type == ValaType.STRUCT) {
                    unowned var sub = program.find_struct (fld.type_name);
                    if (sub != null)
                        ref_struct_at_rcx (sub, off);
                    off += 8 * type_slots (fld.field_type, fld.type_name);
                } else if (is_ref_type (fld.field_type)) {
                    emitter.push_reg (Reg.RCX);
                    push_depth++;
                    emitter.load_rcx_disp_to_rax (off);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_ref");
                    emitter.pop_reg (Reg.RCX);
                    push_depth--;
                    off += 8;
                } else {
                    off += 8;
                }
            }
        }

        // Calls __planc_unref on every reference field of a struct whose base is in `rcx`.
        private void unref_struct_at_rcx (StructDecl sd, int byte_offset) {
            int off = byte_offset;
            foreach (var fld in sd.fields) {
                if (fld.field_type == ValaType.STRUCT) {
                    unowned var sub = program.find_struct (fld.type_name);
                    if (sub != null)
                        unref_struct_at_rcx (sub, off);
                    off += 8 * type_slots (fld.field_type, fld.type_name);
                } else if (is_ref_type (fld.field_type)) {
                    emitter.push_reg (Reg.RCX);
                    push_depth++;
                    emitter.load_rcx_disp_to_rax (off);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_unref");
                    emitter.pop_reg (Reg.RCX);
                    push_depth--;
                    off += 8;
                } else {
                    off += 8;
                }
            }
        }

        private void copy_struct_rax_to_rcx (int slot_count) {
            emitter.mov_rdx_rax ();
            for (int k = 0; k < slot_count; k++) {
                emitter.load_rdx_disp (8 * k);
                emitter.store_rcx_disp_rax (8 * k);
            }
        }

        // Option B software null guard: emits zero instructions when `tt` is statically non-null.
        private void emit_null_check_if_nullable (ValaType tt, string tt_name) throws SemanticError {
            if (is_nullable_type (tt, tt_name)) {
                if (strict_null)
                    throw new SemanticError.TYPE_MISMATCH (@"cannot dereference nullable '$(type_label (tt, tt_name))' without a null check");
                if (null_check) {
                    need_null_panic = true;
                    emitter.test_rax_rax ();
                    emitter.branch (BranchKind.JE, null_panic_label);
                }
            }
        }

        private void remove_live_ref_slot (int slot) {
            for (int i = live_stmt_ref_slots.length - 1; i >= 0; i--) {
                if (live_stmt_ref_slots[i] == slot)
                    live_stmt_ref_slots.remove_index (i);
            }
        }

        // Transfers ownership of a reference-typed expression in `rax` to a
        // storage location (`ref` if borrowed, or zero `ref_temp_slot` if owned).
        private void consume_ref_expr (Expr e) throws SemanticError {
            if (!program_uses_heap)
                return;
            if (is_owned_expr (e)) {
                if (e.ref_temp_slot >= 0) {
                    emitter.zero_local (e.ref_temp_slot);
                    remove_live_ref_slot (e.ref_temp_slot);
                }
            } else {
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_ref");
            }
        }

        private void cleanup_expr_temps (Expr? e) {
            if (!program_uses_heap || e == null)
                return;
            walk_expr_children (e, cleanup_expr_temps);
            if (e.ref_temp_slot >= 0) {
                emitter.load_local (e.ref_temp_slot);
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_unref");
                emitter.zero_local (e.ref_temp_slot);
                remove_live_ref_slot (e.ref_temp_slot);
            }
        }

        private void unref_locals_from (int start_idx) {
            if (!program_uses_heap)
                return;
            for (int i = locals.length - 1; i >= start_idx; i--) {
                if (!local_active[i] || local_unmanaged[i])
                    continue;
                if (local_is_compact[i])
                    continue;
                if (is_ref_type (local_types[i])) {
                    emitter.load_local (local_slots[i]);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_unref");
                } else if (local_types[i] == ValaType.STRUCT) {
                    unowned var sd = program.find_struct (local_type_names[i]);
                    if (sd != null && struct_has_string (sd)) {
                        var n = type_slots (ValaType.STRUCT, local_type_names[i]);
                        emitter.lea_rcx_rbp_disp (struct_base_disp (local_slots[i], n));
                        unref_struct_at_rcx (sd, 0);
                    }
                }
            }
        }

        private void gen_lvalue_addr (Expr e, out ValaType ltype, out string ltname) throws SemanticError {
            if (e is VarRef) {
                var vr = (VarRef) e;
                var idx = lookup (vr.name);
                if (idx >= 0) {
                    ltype = local_types[idx];
                    ltname = is_non_null_narrowed (vr.name)
                        ? strip_null (local_type_names[idx])
                        : local_type_names[idx];
                    if (local_by_ref[idx]) {
                        emitter.load_local (local_slots[idx]);
                    } else if (ltype == ValaType.STRUCT) {
                        var n = type_slots (ValaType.STRUCT, ltname);
                        emitter.lea_rax_rbp_disp (struct_base_disp (local_slots[idx], n));
                    } else {
                        emitter.lea_local (local_slots[idx]);
                    }
                    return;
                }
                var gi = lookup_global (vr.name);
                if (gi >= 0) {
                    ltype = global_types[gi];
                    ltname = global_type_names[gi];
                    emitter.lea_rax_space (global_offsets[gi], global_spaces[gi]);
                    return;
                }
                {
                    int sg = static_field_global_of_this_class (vr.name);
                    if (sg >= 0) {
                        ltype = global_types[sg];
                        ltname = global_type_names[sg];
                        emitter.lea_rax_space (global_offsets[sg], global_spaces[sg]);
                        return;
                    }
                }
                if (current_class != null && !current.is_static) {
                    unowned ClassField? cf = null;
                    var fslot = class_field_offset_slots (current_class, vr.name, out cf);
                    if (fslot >= 0 && cf != null) {
                        load_this_slot ();
                        emitter.add_rax_imm (class_field_base (current_class) + 8 * fslot);
                        ltype = cf.field_type;
                        ltname = cf.type_name;
                        return;
                    }
                }
                if (current_struct != null && !current.is_static) {
                    unowned StructField? sf = null;
                    var fslot = struct_field_offset_slots (current_struct, vr.name, out sf);
                    if (fslot >= 0 && sf != null) {
                        var n = type_slots (ValaType.STRUCT, current_struct.name);
                        emitter.lea_rax_rbp_disp (struct_base_disp (local_slots[0], n));
                        emitter.add_rax_imm (8 * fslot);
                        ltype = sf.field_type;
                        ltname = sf.type_name;
                        return;
                    }
                }
                throw new SemanticError.UNKNOWN_VARIABLE (
                    @"unknown variable: $(vr.name) at $(vr.line):$(vr.column)");
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                if (ma.target is VarRef) {
                    int sg = static_field_global_of_type (((VarRef) ma.target).name, ma.member);
                    if (sg >= 0) {
                        ltype = global_types[sg];
                        ltname = global_type_names[sg];
                        emitter.lea_rax_space (global_offsets[sg], global_spaces[sg]);
                        return;
                    }
                }
                string peek_name = "";
                var peek_t = expr_type_full (ma.target, out peek_name);
                if (peek_t == ValaType.CLASS) {
                    var cname = strip_null (peek_name);
                    unowned var cd = program.find_class (cname);
                    unowned ClassField? cf = null;
                    var slot_off = (cd != null) ? class_field_offset_slots (cd, ma.member, out cf) : -1;
                    if (slot_off < 0 || cf == null)
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"class '$(cname)' has no field '$(ma.member)' at $(ma.line):$(ma.column)");
                    gen_expr (ma.target);
                    emit_null_check_if_nullable (peek_t, peek_name);
                    emitter.add_rax_imm (class_field_base (cd) + 8 * slot_off);
                    ltype = cf.field_type;
                    ltname = cf.type_name;
                    return;
                }
                ValaType base_t;
                string base_name;
                gen_lvalue_addr (ma.target, out base_t, out base_name);
                if (base_t != ValaType.STRUCT)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"cannot assign field '.$(ma.member)' on $(type_label (base_t, base_name)) at $(ma.line):$(ma.column)");
                unowned var sd = program.find_struct (base_name);
                unowned StructField? fld = null;
                var off_slots = (sd != null) ? struct_field_offset_slots (sd, ma.member, out fld) : -1;
                if (off_slots < 0 || fld == null)
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"struct '$(base_name)' has no field '$(ma.member)' at $(ma.line):$(ma.column)");
                emitter.add_rax_imm (8 * off_slots);
                ltype = fld.field_type;
                ltname = fld.type_name;
                return;
            }
            if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                string tt_name = "";
                var tt = expr_type_full (ix.target, out tt_name);
                ValaType ga_et = ValaType.INT;
                string ga_etn = "";
                bool is_ga = (tt == ValaType.CLASS) && find_generic_array_elem (tt_name, out ga_et, out ga_etn);
                if (tt != ValaType.ARRAY && !is_ga)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"indexed address requires an array, got $(type_label (tt, tt_name)) at $(ix.line):$(ix.column)");
                string it_name = "";
                var it = expr_type_full (ix.index, out it_name);
                if (!is_int_like (it))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"array index must be int, got $(type_label (it, it_name)) at $(ix.index.line):$(ix.index.column)");
                gen_expr (ix.target);
                emit_null_check_if_nullable (tt, tt_name);
                emitter.push_rax ();
                push_depth++;
                gen_expr (ix.index);
                emitter.mov_rcx_rax ();
                emitter.pop_rax ();
                push_depth--;
                if (is_ga) {
                    bool ga_signed_b = false;
                    if (ga_et == ValaType.INT && is_byte_array_type (ga_etn, out ga_signed_b))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot pass packed byte array element by ref or out at $(e.line):$(e.column)");
                    if (bounds_check) {
                        need_bounds_panic = true;
                        emitter.push_rax ();
                        push_depth++;
                        emitter.load_rax_disp (24);
                        emitter.cmp_rax_rcx ();
                        emitter.branch (BranchKind.JBE, bounds_panic_label);
                        emitter.pop_rax ();
                        push_depth--;
                    }
                    emitter.load_rax_disp (16);
                    emitter.lea_rax_rax_rcx_8_16 ();
                    ltype = ga_et;
                    ltname = ga_etn;
                    return;
                }
                bool is_signed_b = false;
                if (is_byte_array_type (tt_name, out is_signed_b))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"cannot pass packed byte array element by ref or out at $(e.line):$(e.column)");
                if (bounds_check) {
                    need_bounds_panic = true;
                    emitter.cmp_rcx_rax_len ();
                    emitter.branch (BranchKind.JAE, bounds_panic_label);
                }
                emitter.lea_rax_rax_rcx_8_16 ();
                parse_array_elem (tt_name, out ltype, out ltname);
                return;
            }
            throw new SemanticError.TYPE_MISMATCH (
                @"cannot assign to non-lvalue at $(e.line):$(e.column)");
        }

        // ------------------------------------------------------------------
        // Statements.
        // ------------------------------------------------------------------

        private void call_aligned (string callee) {
            if (push_depth % 2 == 1)
                emitter.sub_rsp (8);
            emitter.call_rel32 (callee);
            if (push_depth % 2 == 1)
                emitter.add_rsp (8);
        }

        private void emit_print_part (Expr part) throws SemanticError {
            string pt_name = "";
            var pt = expr_type_full (part, out pt_name);
            if (pt == ValaType.STRING) {
                gen_expr (part);
                emit_null_check_if_nullable (pt, pt_name);
                emitter.mov_rdi_rax ();
                need_write_str = true;
                call_aligned ("__planc_write_str");
                cleanup_expr_temps (part);
            } else if (pt == ValaType.BOOL) {
                gen_expr (part);
                var l_false = emitter.new_label ();
                var l_print = emitter.new_label ();
                emitter.test_rax_rax ();
                emitter.branch (BranchKind.JE, l_false);
                emitter.lea_rax_rip (emitter.add_string ("true"));
                emitter.branch (BranchKind.JMP, l_print);
                emitter.bind (l_false);
                emitter.lea_rax_rip (emitter.add_string ("false"));
                emitter.bind (l_print);
                emitter.mov_rdi_rax ();
                need_write_str = true;
                call_aligned ("__planc_write_str");
                cleanup_expr_temps (part);
            } else if (pt == ValaType.INT || pt == ValaType.ENUM) {
                gen_expr (part);
                emitter.mov_rdi_rax ();
                if (pt == ValaType.INT && is_unsigned_int_type (pt_name)) {
                    need_write_uint = true;
                    call_aligned ("__planc_write_uint");
                } else {
                    need_write_int = true;
                    call_aligned ("__planc_write_int");
                }
                cleanup_expr_temps (part);
            } else if (pt == ValaType.FLOAT || pt == ValaType.DOUBLE) {
                gen_expr (part);
                if (pt == ValaType.FLOAT)
                    emitter.cvtss2sd_xmm0_xmm0 ();
                need_double_to_str = true;
                call_aligned ("__planc_double_to_str");
                emitter.push_rax ();
                push_depth++;
                emitter.mov_rdi_rax ();
                need_write_str = true;
                call_aligned ("__planc_write_str");
                emitter.pop_reg (Reg.RDI);
                push_depth--;
                if (program_uses_heap)
                    call_aligned ("__planc_unref");
                cleanup_expr_temps (part);
            } else {
                throw new SemanticError.TYPE_MISMATCH (
                    @"cannot format $(pt.label ()) in print template at $(part.line):$(part.column)");
            }
        }

        // Expects field address in `rax`. Evaluates `val` and stores (with ARC/struct/op).
        private void emit_fp_coerce (ValaType from_t, ValaType to_t) {
            if (from_t == to_t)
                return;
            if (to_t == ValaType.DOUBLE) {
                if (from_t == ValaType.INT)
                    emitter.cvtsi2sd_xmm0_rax ();
                else if (from_t == ValaType.FLOAT)
                    emitter.cvtss2sd_xmm0_xmm0 ();
            } else if (to_t == ValaType.FLOAT) {
                if (from_t == ValaType.INT)
                    emitter.cvtsi2ss_xmm0_rax ();
                else if (from_t == ValaType.DOUBLE)
                    emitter.cvtsd2ss_xmm0_xmm0 ();
            }
        }

        private void emit_fp_alu (string op, bool is_f32) {
            if (is_f32) {
                switch (op) {
                    case "+": emitter.addss_xmm0_xmm1 (); break;
                    case "-": emitter.subss_xmm0_xmm1 (); break;
                    case "*": emitter.mulss_xmm0_xmm1 (); break;
                    case "/": emitter.divss_xmm0_xmm1 (); break;
                    default: Host.panic (@"unsupported float compound op: $op"); break;
                }
            } else {
                switch (op) {
                    case "+": emitter.addsd_xmm0_xmm1 (); break;
                    case "-": emitter.subsd_xmm0_xmm1 (); break;
                    case "*": emitter.mulsd_xmm0_xmm1 (); break;
                    case "/": emitter.divsd_xmm0_xmm1 (); break;
                    default: Host.panic (@"unsupported double compound op: $op"); break;
                }
            }
        }

        private void emit_field_store (ValaType ft, string ft_name, string op, Expr val, bool is_weak = false)
                throws SemanticError {
            emitter.push_rax ();
            push_depth++;
            if (is_fp_type (ft)) {
                var vt = expr_type (val);
                gen_expr (val);
                emit_fp_coerce (vt, ft);
                if (op == "=") {
                    emitter.movq_rax_xmm (0);
                    emitter.pop_rcx ();
                    push_depth--;
                    emitter.store_rcx_disp_rax (0);
                } else {
                    emitter.movq_rax_xmm (0);
                    emitter.movq_xmm_rax (1);
                    emitter.load_rsp (0);
                    emitter.mov_rdx_rax ();
                    emitter.load_rdx_disp (0);
                    emitter.movq_xmm_rax (0);
                    emit_fp_alu (op, ft == ValaType.FLOAT);
                    emitter.movq_rax_xmm (0);
                    emitter.pop_rcx ();
                    push_depth--;
                    emitter.store_rcx_disp_rax (0);
                }
                return;
            }
            var vt_expr = expr_type (val);
            gen_expr (val);
            if (op == "=") {
                // A compact value is owned by the program: never ref or unref
                // it on assignment.
                if (program_uses_heap && is_ref_type (ft) && !is_compact_type (ft, ft_name)) {
                    consume_ref_expr (val);
                    if (is_weak)
                        emit_convert_to_weak ();
                    emitter.pop_rcx ();
                    push_depth--;
                    emitter.push_rax ();
                    push_depth++;
                    emitter.push_reg (Reg.RCX);
                    push_depth++;
                    emitter.load_rcx_disp_to_rax (0);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_unref");
                    emitter.pop_reg (Reg.RCX);
                    push_depth--;
                    emitter.pop_rax ();
                    push_depth--;
                    emitter.store_rcx_disp_rax (0);
                } else if (ft == ValaType.STRUCT) {
                    emitter.pop_rcx ();
                    push_depth--;
                    unowned var sub = program.find_struct (ft_name);
                    var fslots = type_slots (ValaType.STRUCT, ft_name);
                    if (vt_expr == ValaType.NULL) {
                        if (program_uses_heap && sub != null && struct_has_string (sub))
                            unref_struct_at_rcx (sub, 0);
                        if (sub != null)
                            init_struct_at_rcx (sub, 0);
                    } else if (program_uses_heap && sub != null && struct_has_string (sub)) {
                        // Ref source before unreffing destination so aliasing/self-assignment stays balanced.
                        emitter.push_reg (Reg.RCX);
                        push_depth++;
                        emitter.push_rax ();
                        push_depth++;
                        emitter.mov_rcx_rax ();
                        ref_struct_at_rcx (sub, 0);
                        emitter.pop_rax ();
                        push_depth--;
                        emitter.pop_reg (Reg.RCX);
                        push_depth--;
                        emitter.push_rax ();
                        push_depth++;
                        unref_struct_at_rcx (sub, 0);
                        emitter.pop_rax ();
                        push_depth--;
                        copy_struct_rax_to_rcx (fslots);
                    } else {
                        copy_struct_rax_to_rcx (fslots);
                    }
                } else {
                    if (ft == ValaType.INT)
                        emit_int_narrow (ft_name);
                    emitter.pop_rcx ();
                    push_depth--;
                    emitter.store_rcx_disp_rax (0);
                }
            } else {
                emitter.mov_rcx_rax ();
                emitter.load_rsp (0);
                emitter.mov_rdx_rax ();
                emitter.load_rdx_disp (0);
                emit_compound_alu (op, ft == ValaType.INT && is_unsigned_int_type (ft_name));
                if (ft == ValaType.INT)
                    emit_int_narrow (ft_name);
                emitter.pop_rcx ();
                push_depth--;
                emitter.store_rcx_disp_rax (0);
            }
        }

        private void emit_compound_alu (string op, bool is_unsigned = false) {
            switch (op) {
                case "+":
                    emitter.add_rax_rcx ();
                    if (!is_unsigned && check_overflow) { need_overflow_panic = true; emitter.branch (BranchKind.JO, overflow_panic_label); }
                    break;
                case "-":
                    emitter.sub_rax_rcx ();
                    if (!is_unsigned && check_overflow) { need_overflow_panic = true; emitter.branch (BranchKind.JO, overflow_panic_label); }
                    break;
                case "*":
                    emitter.imul_rax_rcx ();
                    if (!is_unsigned && check_overflow) { need_overflow_panic = true; emitter.branch (BranchKind.JO, overflow_panic_label); }
                    break;
                case "/":
                    if (is_unsigned) {
                        emitter.xor_edx ();
                        emitter.div_rcx ();
                    } else {
                        emitter.cqo ();
                        emitter.idiv_rcx ();
                    }
                    break;
                case "%":
                    if (is_unsigned) {
                        emitter.xor_edx ();
                        emitter.div_rcx ();
                    } else {
                        emitter.cqo ();
                        emitter.idiv_rcx ();
                    }
                    emitter.mov_rax_rdx ();
                    break;
                case "&":  emitter.and_rax_rcx (); break;
                case "|":  emitter.or_rax_rcx (); break;
                case "^":  emitter.xor_rax_rcx (); break;
                case "<<": emitter.shl_rax_cl (); break;
                case ">>":
                    if (is_unsigned)
                        emitter.shr_rax_cl ();
                    else
                        emitter.sar_rax_cl ();
                    break;
                default:
                    Host.panic (@"unsupported compound assignment op: $op");
                    break;
            }
        }

        private void emit_byte_elem_store (bool is_signed, string op, Expr val)
                throws SemanticError {
            emitter.push_rax ();
            push_depth++;
            gen_expr (val);
            if (op == "=") {
                emitter.pop_rcx ();
                push_depth--;
                emitter.store_rcx_disp_byte_al (0);
            } else {
                emitter.mov_rcx_rax ();
                emitter.load_rsp (0);
                emitter.mov_rdx_rax ();
                emitter.load_rdx_byte_to_zx_rax ();
                if (is_signed)
                    emitter.sign_extend_rax (8);
                emit_compound_alu (op, !is_signed);
                emitter.pop_rcx ();
                push_depth--;
                emitter.store_rcx_disp_byte_al (0);
            }
        }

        private void gen_statement (Statement s) throws SemanticError {
            if (s.line > 0) {
                int cur_off = emitter.here ();
                bool add_line = (debug_lines.length == 0);
                if (!add_line) {
                    var prev = debug_lines[debug_lines.length - 1];
                    if (prev.line != s.line && cur_off >= prev.text_offset)
                        add_line = true;
                }
                if (add_line) {
                    debug_lines.add (new DebugLineEntry () {
                        text_offset = cur_off,
                        file_id = 1,
                        line = s.line
                    });
                }
            }
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                if (p.value is TemplateExpr) {
                    foreach (var part in ((TemplateExpr) p.value).parts)
                        emit_print_part (part);
                } else {
                    string vt_name = "";
                    var vt = expr_type_full (p.value, out vt_name);
                    if (vt != ValaType.STRING)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"print expects string, got $(type_label (vt, vt_name)) at $(p.value.line):$(p.value.column)");
                    gen_expr (p.value);
                    emit_null_check_if_nullable (vt, vt_name);
                    emitter.mov_rdi_rax ();
                    need_write_str = true;
                    call_aligned ("__planc_write_str");
                    cleanup_expr_temps (p.value);
                }
            } else if (s is ExitStatement) {
                var e = (ExitStatement) s;
                string vt_name = "";
                var vt = expr_type_full (e.value, out vt_name);
                if (!is_int_like (vt))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"exit expects int, got $(type_label (vt, vt_name)) at $(e.value.line):$(e.value.column)");
                gen_expr (e.value);
                emitter.push_rax ();
                push_depth++;
                cleanup_expr_temps (e.value);
                emitter.pop_rax ();
                push_depth--;
                if (freestanding) {
                    emitter.code.u8 (0xFA); emitter.code.u8 (0xF4); // cli; hlt
                    emitter.code.u8 (0xEB); emitter.code.u8 (0xFD); // jmp -3
                } else if (target_planetos) {
                    emitter.mov_edi_eax ();
                    emitter.mov_eax (11);
                    emitter.int80 ();
                } else {
                    emitter.mov_edi_eax ();
                    emitter.mov_eax (SYS_EXIT);
                    emitter.syscall ();
                }
            } else if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (finally_labels.length > 0) {
                    int fin_idx = finally_labels.length - 1;
                    if (r.value != null) {
                        if (current.is_void)
                            throw new SemanticError.RETURN_MISMATCH (
                                @"void function '$(current.name)' cannot return a value at $(r.line):$(r.column)");
                        coerce_byte_array_literal (r.value, current.return_type, current.return_type_name);
                        string rt_name = "";
                        var rt = expr_type_full (r.value, out rt_name);
                        if (!type_compatible (current.return_type, current.return_type_name, rt, rt_name))
                            throw new SemanticError.RETURN_MISMATCH (
                                @"function '$(current.name)' returns $(type_label (current.return_type, current.return_type_name)), got $(type_label (rt, rt_name)) at $(r.line):$(r.column)");
                        gen_expr (r.value);
                        if (is_fp_type (current.return_type)) {
                            emit_fp_coerce (rt, current.return_type);
                            emitter.movq_rax_xmm (0);
                        } else if (current.return_type == ValaType.INT) {
                            emit_int_narrow (current.return_type_name);
                        }
                        if (is_ref_type (current.return_type))
                            consume_ref_expr (r.value);
                        if (current.return_type == ValaType.STRUCT) {
                            var n = type_slots (ValaType.STRUCT, current.return_type_name);
                            emitter.lea_rcx_space (struct_ret_bss_offset, PatchSpace.BSS);
                            unowned var sd = program.find_struct (current.return_type_name);
                            if (rt == ValaType.NULL) {
                                if (sd != null)
                                    init_struct_at_rcx (sd, 0);
                            } else {
                                copy_struct_rax_to_rcx (n);
                                if (program_uses_heap && sd != null && struct_has_string (sd))
                                    ref_struct_at_rcx (sd, 0);
                            }
                            emitter.mov_rax_rcx ();
                        }
                        emitter.store_local (finally_ret_slots[fin_idx]);
                        cleanup_expr_temps (r.value);
                    } else {
                        if (!current.is_void)
                            throw new SemanticError.RETURN_MISMATCH (
                                @"$(type_label (current.return_type, current.return_type_name)) function '$(current.name)' must return a value at $(r.line):$(r.column)");
                        emitter.zero_local (finally_ret_slots[fin_idx]);
                    }
                    if (program_uses_heap)
                        unref_locals_from (finally_marks[fin_idx]);
                    emitter.mov_rax_imm (2);
                    emitter.store_local (finally_mode_slots[fin_idx]);
                    emitter.branch (BranchKind.JMP, finally_labels[fin_idx]);
                } else {
                    if (r.value != null) {
                        if (current.is_void)
                            throw new SemanticError.RETURN_MISMATCH (
                                @"void function '$(current.name)' cannot return a value at $(r.line):$(r.column)");
                        coerce_byte_array_literal (r.value, current.return_type, current.return_type_name);
                        string rt_name = "";
                        var rt = expr_type_full (r.value, out rt_name);
                        if (!type_compatible (current.return_type, current.return_type_name, rt, rt_name))
                            throw new SemanticError.RETURN_MISMATCH (
                                @"function '$(current.name)' returns $(type_label (current.return_type, current.return_type_name)), got $(type_label (rt, rt_name)) at $(r.line):$(r.column)");
                        gen_expr (r.value);
                        if (is_fp_type (current.return_type)) {
                            emit_fp_coerce (rt, current.return_type);
                            emitter.movq_rax_xmm (0);
                        } else if (current.return_type == ValaType.INT) {
                            emit_int_narrow (current.return_type_name);
                        }
                        if (is_ref_type (current.return_type))
                            consume_ref_expr (r.value);
                        if (current.return_type == ValaType.STRUCT) {
                            var n = type_slots (ValaType.STRUCT, current.return_type_name);
                            emitter.lea_rcx_space (struct_ret_bss_offset, PatchSpace.BSS);
                            unowned var sd = program.find_struct (current.return_type_name);
                            if (rt == ValaType.NULL) {
                                if (sd != null)
                                    init_struct_at_rcx (sd, 0);
                            } else {
                                copy_struct_rax_to_rcx (n);
                                if (program_uses_heap && sd != null && struct_has_string (sd))
                                    ref_struct_at_rcx (sd, 0);
                            }
                            emitter.mov_rax_rcx ();
                        }
                        emitter.push_rax ();
                        push_depth++;
                        cleanup_expr_temps (r.value);
                        if (program_uses_heap)
                            unref_locals_from (0);
                        emitter.pop_rax ();
                        push_depth--;
                        if (is_fp_type (current.return_type) && !in_async_resume)
                            emitter.movq_xmm_rax (0);
                    } else {
                        if (!current.is_void)
                            throw new SemanticError.RETURN_MISMATCH (
                                @"$(type_label (current.return_type, current.return_type_name)) function '$(current.name)' must return a value at $(r.line):$(r.column)");
                        if (program_uses_heap)
                            unref_locals_from (0);
                        emitter.xor_eax ();
                    }
                    if (in_async_resume) {
                        emitter.mov_rsi_rax ();
                        emitter.load_rbp_disp (-8);
                        emitter.mov_rdi_rax ();
                        emitter.xor_edx ();
                        call_aligned ("__planc_async_finish");
                    } else {
                        emitter.xor_edx ();
                    }
                    emitter.leave ();
                    emitter.ret ();
                }
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (lookup (d.name) >= 0)
                    throw new SemanticError.DUPLICATE_VARIABLE (
                        @"duplicate variable: $(d.name) at $(d.line):$(d.column)");
                ValaType vtype = d.decl_type;
                string vtname = d.decl_type_name;
                ValaType init_t = ValaType.NULL;
                string init_tname = "";
                bool has_init = (d.init != null);
                if (d.infer_type && d.init != null) {
                    vtype = expr_type_full (d.init, out vtname);
                    if (vtype == ValaType.NULL)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot infer type of 'var $(d.name)' from 'null' at $(d.line):$(d.column)");
                    init_t = vtype;
                    init_tname = vtname;
                } else if (d.init != null) {
                    coerce_byte_array_literal (d.init, vtype, vtname);
                    init_t = expr_type_full (d.init, out init_tname);
                    if (!type_compatible (vtype, vtname, init_t, init_tname))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot initialize $(type_label (vtype, vtname)) variable '$(d.name)' with $(type_label (init_t, init_tname))$(compact_to_object_hint (init_t, init_tname)) at $(d.init.line):$(d.init.column)");
                } else if (d.init == null && da_needs_tracking (vtype, vtname)) {
                    // Approved by the definite-assignment pass; the slot is
                    // zeroed (null) below and never read before assignment.
                }
                var nslots = type_slots (vtype, vtname);
                var slot = next_var_slot;
                next_var_slot += nslots;

                if (vtype == ValaType.STRUCT) {
                    var base_disp = struct_base_disp (slot, nslots);
                    unowned var sd = program.find_struct (vtname);
                    if (d.init != null && init_t != ValaType.NULL) {
                        gen_expr (d.init);
                        emitter.lea_rcx_rbp_disp (base_disp);
                        copy_struct_rax_to_rcx (nslots);
                        if (program_uses_heap && sd != null && struct_has_string (sd))
                            ref_struct_at_rcx (sd, 0);
                        cleanup_expr_temps (d.init);
                    } else {
                        if (d.init != null) {
                            gen_expr (d.init);
                            cleanup_expr_temps (d.init);
                        }
                        emitter.lea_rcx_rbp_disp (base_disp);
                        if (sd != null)
                            init_struct_at_rcx (sd, 0);
                    }
                } else if (is_ref_type (vtype)) {
                    if (d.init != null) {
                        gen_expr (d.init);
                        consume_ref_expr (d.init);
                        if (d.is_weak)
                            emit_convert_to_weak ();
                        emitter.store_local (slot);
                        cleanup_expr_temps (d.init);
                    } else if (vtype == ValaType.STRING && !is_nullable_type (vtype, vtname)) {
                        emitter.lea_rax_rip (emitter.add_string (""));
                        emitter.store_local (slot);
                    } else {
                        emitter.zero_local (slot);
                    }
                } else {
                    if (d.init != null) {
                        gen_expr (d.init);
                        if (is_fp_type (vtype)) {
                            emit_fp_coerce (init_t, vtype);
                            emitter.movq_rax_xmm (0);
                        } else if (vtype == ValaType.INT) {
                            emit_int_narrow (vtname);
                        }
                        emitter.store_local (slot);
                        cleanup_expr_temps (d.init);
                    } else {
                        emitter.zero_local (slot);
                    }
                }
                push_local (d.name, vtype, vtname, slot, false, false, d.is_weak);
                if (has_init)
                    update_non_null_on_assign (d.name, init_t, init_tname);
                else
                    invalidate_non_null_prefix (d.name);
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                var idx = lookup (a.name);
                if (idx >= 0) {
                    coerce_byte_array_literal (a.value, local_types[idx], local_type_names[idx]);
                    string vt_name = "";
                    var vt = expr_type_full (a.value, out vt_name);
                    if (!type_compatible (local_types[idx], local_type_names[idx], vt, vt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot assign $(type_label (vt, vt_name)) to $(type_label (local_types[idx], local_type_names[idx])) variable '$(a.name)' at $(a.line):$(a.column)");
                    if (local_by_ref[idx]) {
                        emitter.load_local (local_slots[idx]);
                        emit_field_store (local_types[idx], local_type_names[idx], "=", a.value);
                    } else {
                        gen_expr (a.value);
                        if (local_types[idx] == ValaType.STRUCT) {
                            var n = type_slots (ValaType.STRUCT, local_type_names[idx]);
                            emitter.lea_rcx_rbp_disp (struct_base_disp (local_slots[idx], n));
                            unowned var sd = program.find_struct (local_type_names[idx]);
                            if (vt == ValaType.NULL) {
                                if (program_uses_heap && sd != null && struct_has_string (sd))
                                    unref_struct_at_rcx (sd, 0);
                                if (sd != null)
                                    init_struct_at_rcx (sd, 0);
                            } else if (program_uses_heap && sd != null && struct_has_string (sd)) {
                                emitter.push_reg (Reg.RCX);
                                push_depth++;
                                emitter.push_rax ();
                                push_depth++;
                                emitter.mov_rcx_rax ();
                                ref_struct_at_rcx (sd, 0);
                                emitter.pop_rax ();
                                push_depth--;
                                emitter.pop_reg (Reg.RCX);
                                push_depth--;
                                emitter.push_rax ();
                                push_depth++;
                                unref_struct_at_rcx (sd, 0);
                                emitter.pop_rax ();
                                push_depth--;
                                copy_struct_rax_to_rcx (n);
                            } else {
                                copy_struct_rax_to_rcx (n);
                            }
                        } else if (program_uses_heap && is_ref_type (local_types[idx]) && !local_is_compact[idx]) {
                            consume_ref_expr (a.value);
                            if (local_is_weak[idx])
                                emit_convert_to_weak ();
                            emitter.push_rax ();
                            push_depth++;
                            emitter.load_local (local_slots[idx]);
                            emitter.mov_rdi_rax ();
                            call_aligned ("__planc_unref");
                            emitter.pop_rax ();
                            push_depth--;
                            emitter.store_local (local_slots[idx]);
                        } else {
                            if (is_fp_type (local_types[idx])) {
                                emit_fp_coerce (vt, local_types[idx]);
                                emitter.movq_rax_xmm (0);
                            } else if (local_types[idx] == ValaType.INT) {
                                emit_int_narrow (local_type_names[idx]);
                            }
                            emitter.store_local (local_slots[idx]);
                        }
                    }
                    cleanup_expr_temps (a.value);
                    update_non_null_on_assign (a.name, vt, vt_name);
                } else {
                    var gi = lookup_global (a.name);
                    if (gi < 0) {
                        var sg_static = static_field_global_of_this_class (a.name);
                        if (sg_static >= 0)
                            gi = sg_static;
                    }
                    if (gi < 0) {
                        if (current_class != null && !current.is_static) {
                            unowned ClassField? cf = null;
                            var fslot = class_field_offset_slots (current_class, a.name, out cf);
                            if (fslot >= 0 && cf != null) {
                                coerce_byte_array_literal (a.value, cf.field_type, cf.type_name);
                                string vt_name = "";
                                var vt = expr_type_full (a.value, out vt_name);
                                if (!type_compatible (cf.field_type, cf.type_name, vt, vt_name))
                                    throw new SemanticError.TYPE_MISMATCH (
                                        @"cannot assign $(type_label (vt, vt_name)) to field '$(current_class.name).$(a.name)' ($(type_label (cf.field_type, cf.type_name))) at $(a.line):$(a.column)");
                                load_this_slot ();
                                emitter.add_rax_imm (class_field_base (current_class) + 8 * fslot);
                                emit_field_store (cf.field_type, cf.type_name, "=", a.value);
                                cleanup_expr_temps (a.value);
                                update_non_null_on_assign (a.name, vt, vt_name);
                                return;
                            }
                        }
                        if (current_struct != null && !current.is_static) {
                            unowned StructField? sf = null;
                            var fslot = struct_field_offset_slots (current_struct, a.name, out sf);
                            if (fslot >= 0 && sf != null) {
                                string vt_name = "";
                                var vt = expr_type_full (a.value, out vt_name);
                                if (!type_compatible (sf.field_type, sf.type_name, vt, vt_name))
                                    throw new SemanticError.TYPE_MISMATCH (
                                        @"cannot assign $(type_label (vt, vt_name)) to field '$(current_struct.name).$(a.name)' ($(type_label (sf.field_type, sf.type_name))) at $(a.line):$(a.column)");
                                var n = type_slots (ValaType.STRUCT, current_struct.name);
                                emitter.lea_rax_rbp_disp (struct_base_disp (local_slots[0], n));
                                emitter.add_rax_imm (8 * fslot);
                                emit_field_store (sf.field_type, sf.type_name, "=", a.value);
                                cleanup_expr_temps (a.value);
                                update_non_null_on_assign (a.name, vt, vt_name);
                                return;
                            }
                        }
                        unowned var sm = find_this_prop_setter (a.name);
                        if (sm != null) {
                            string vt_name = "";
                            var vt = expr_type_full (a.value, out vt_name);
                            var pt = sm.params[1].param_type;
                            var pt_name = sm.params[1].type_name;
                            if (!type_compatible (pt, pt_name, vt, vt_name))
                                throw new SemanticError.TYPE_MISMATCH (
                                    @"cannot assign $(type_label (vt, vt_name)) to property '$(a.name)' ($(type_label (pt, pt_name))) at $(a.line):$(a.column)");
                            var arglist = new GenericArray<Expr> ();
                            arglist.add (a.value);
                            emit_instance_call (null, false, true, sm, arglist, -1, -1);
                            cleanup_expr_temps (a.value);
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(a.name) at $(a.line):$(a.column)");
                    }
                    coerce_byte_array_literal (a.value, global_types[gi], global_type_names[gi]);
                    string vt_name = "";
                    var vt = expr_type_full (a.value, out vt_name);
                    if (!type_compatible (global_types[gi], global_type_names[gi], vt, vt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot assign $(type_label (vt, vt_name)) to $(type_label (global_types[gi], global_type_names[gi])) variable '$(a.name)' at $(a.line):$(a.column)");
                    gen_expr (a.value);
                    if (global_types[gi] == ValaType.STRUCT) {
                        var n = type_slots (ValaType.STRUCT, global_type_names[gi]);
                        emitter.lea_rcx_space (global_offsets[gi], global_spaces[gi]);
                        unowned var sd = program.find_struct (global_type_names[gi]);
                        if (vt == ValaType.NULL) {
                            if (program_uses_heap && sd != null && struct_has_string (sd))
                                unref_struct_at_rcx (sd, 0);
                            if (sd != null)
                                init_struct_at_rcx (sd, 0);
                        } else if (program_uses_heap && sd != null && struct_has_string (sd)) {
                            emitter.push_reg (Reg.RCX);
                            push_depth++;
                            emitter.push_rax ();
                            push_depth++;
                            emitter.mov_rcx_rax ();
                            ref_struct_at_rcx (sd, 0);
                            emitter.pop_rax ();
                            push_depth--;
                            emitter.pop_reg (Reg.RCX);
                            push_depth--;
                            emitter.push_rax ();
                            push_depth++;
                            unref_struct_at_rcx (sd, 0);
                            emitter.pop_rax ();
                            push_depth--;
                            copy_struct_rax_to_rcx (n);
                        } else {
                            copy_struct_rax_to_rcx (n);
                        }
                    } else if (program_uses_heap && is_ref_type (global_types[gi])) {
                        consume_ref_expr (a.value);
                        emitter.push_rax ();
                        push_depth++;
                        emitter.load_global (global_offsets[gi], global_spaces[gi]);
                        emitter.mov_rdi_rax ();
                        call_aligned ("__planc_unref");
                        emitter.pop_rax ();
                        push_depth--;
                        emitter.store_global (global_offsets[gi], global_spaces[gi]);
                    } else {
                        if (is_fp_type (global_types[gi])) {
                            emit_fp_coerce (vt, global_types[gi]);
                            emitter.movq_rax_xmm (0);
                        } else if (global_types[gi] == ValaType.INT) {
                            emit_int_narrow (global_type_names[gi]);
                        }
                        emitter.store_global (global_offsets[gi], global_spaces[gi]);
                    }
                    cleanup_expr_temps (a.value);
                    update_non_null_on_assign (a.name, vt, vt_name);
                }
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                if (fa.target is VarRef) {
                    var tvn = ((VarRef) fa.target).name;
                    int sg = static_field_global_of_type (tvn, fa.field_name);
                    if (sg >= 0) {
                        var sgt = global_types[sg];
                        var sgtn = global_type_names[sg];
                        if (fa.op == "=")
                            coerce_byte_array_literal (fa.value, sgt, sgtn);
                        string svt_name = "";
                        var svt = expr_type_full (fa.value, out svt_name);
                        if (fa.op == "=") {
                            if (!type_compatible (sgt, sgtn, svt, svt_name))
                                throw new SemanticError.TYPE_MISMATCH (
                                    @"cannot assign $(type_label (svt, svt_name)) to static field '$(tvn).$(fa.field_name)' ($(type_label (sgt, sgtn))) at $(fa.line):$(fa.column)");
                        } else if (is_fp_type (sgt)) {
                            if (!is_numeric_type (svt) || (fa.op != "+" && fa.op != "-" && fa.op != "*" && fa.op != "/"))
                                throw new SemanticError.TYPE_MISMATCH (
                                    @"operator '$(fa.op)=' is not supported on $(type_label (sgt, sgtn)) at $(fa.line):$(fa.column)");
                        } else if (!is_int_like (sgt) || !is_int_like (svt)) {
                            throw new SemanticError.TYPE_MISMATCH (
                                @"operator '$(fa.op)=' requires int or bool operands at $(fa.line):$(fa.column)");
                        }
                        emitter.lea_rax_space (global_offsets[sg], global_spaces[sg]);
                        emit_field_store (sgt, sgtn, fa.op, fa.value);
                        cleanup_expr_temps (fa.value);
                        return;
                    }
                }
                string peek_name = "";
                var peek_t = expr_type_full (fa.target, out peek_name);
                ValaType ft;
                string ft_name;
                string owner_label;
                int byte_off;
                ValaType fa_vt = ValaType.VOID;
                string fa_vt_name = "";
                bool fa_is_field = false;
                bool fa_is_weak = false;

                if (peek_t == ValaType.CLASS || peek_t == ValaType.INTERFACE) {
                    var cname = strip_null (peek_name);
                    unowned ClassDecl? cd = (peek_t == ValaType.CLASS) ? program.find_class (cname) : null;
                    unowned ClassField? cf = null;
                    var fslot = (cd != null) ? class_field_offset_slots (cd, fa.field_name, out cf) : -1;
                    if (fslot < 0 || cf == null) {
                        unowned var sm = find_prop_setter (peek_t, peek_name, fa.field_name);
                        if (sm != null && fa.op == "=") {
                            string vt_name = "";
                            var vt = expr_type_full (fa.value, out vt_name);
                            var pt = sm.params[1].param_type;
                            var pt_name = sm.params[1].type_name;
                            if (!type_compatible (pt, pt_name, vt, vt_name))
                                throw new SemanticError.TYPE_MISMATCH (
                                    @"cannot assign $(type_label (vt, vt_name)) to property '$(cname).$(fa.field_name)' ($(type_label (pt, pt_name))) at $(fa.line):$(fa.column)");
                            var arglist = new GenericArray<Expr> ();
                            arglist.add (fa.value);
                            emit_instance_call (fa.target, false, false, sm, arglist, -1, -1);
                            cleanup_expr_temps (fa.target);
                            cleanup_expr_temps (fa.value);
                            return;
                        }
                        if (sm != null)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"compound assignment '$(fa.op)=' is not supported on custom property '$(cname).$(fa.field_name)' at $(fa.line):$(fa.column)");
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"$(type_label (peek_t, peek_name)) has no field '$(fa.field_name)' at $(fa.line):$(fa.column)");
                    }
                    ft = cf.field_type;
                    ft_name = cf.type_name;
                    fa_is_weak = cf.is_weak;
                    owner_label = cname;
                    byte_off = class_field_base (cd) + 8 * fslot;
                    string vt_name = "";
                    if (fa.op == "=")
                        coerce_byte_array_literal (fa.value, ft, ft_name);
                    var vt = expr_type_full (fa.value, out vt_name);
                    if (fa.op == "=") {
                        if (!type_compatible (ft, ft_name, vt, vt_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot assign $(type_label (vt, vt_name)) to field '$(owner_label).$(fa.field_name)' ($(type_label (ft, ft_name))) at $(fa.line):$(fa.column)");
                    } else if (is_fp_type (ft)) {
                        if (!is_numeric_type (vt) || (fa.op != "+" && fa.op != "-" && fa.op != "*" && fa.op != "/"))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"operator '$(fa.op)=' is not supported on $(type_label (ft, ft_name)) at $(fa.line):$(fa.column)");
                    } else if (!is_int_like (ft) || !is_int_like (vt)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"operator '$(fa.op)=' requires int or bool operands at $(fa.line):$(fa.column)");
                    }
                    fa_vt = vt;
                    fa_vt_name = vt_name;
                    fa_is_field = true;
                    gen_expr (fa.target);
                    emit_null_check_if_nullable (peek_t, peek_name);
                    emitter.add_rax_imm (byte_off);
                } else {
                    ValaType base_t;
                    string base_name;
                    gen_lvalue_addr (fa.target, out base_t, out base_name);
                    if (base_t != ValaType.STRUCT)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot assign field '.$(fa.field_name)' on $(type_label (base_t, base_name)) at $(fa.line):$(fa.column)");
                    unowned var sd = program.find_struct (base_name);
                    unowned StructField? fld = null;
                    var off_slots = (sd != null) ? struct_field_offset_slots (sd, fa.field_name, out fld) : -1;
                    if (off_slots < 0 || fld == null) {
                        unowned var sm = find_prop_setter (base_t, base_name, fa.field_name);
                        if (sm != null && fa.op == "=") {
                            string vt_name = "";
                            var vt = expr_type_full (fa.value, out vt_name);
                            var pt = sm.params[1].param_type;
                            var pt_name = sm.params[1].type_name;
                            if (!type_compatible (pt, pt_name, vt, vt_name))
                                throw new SemanticError.TYPE_MISMATCH (
                                    @"cannot assign $(type_label (vt, vt_name)) to property '$(base_name).$(fa.field_name)' ($(type_label (pt, pt_name))) at $(fa.line):$(fa.column)");
                            emitter.push_rax ();
                            push_depth++;
                            gen_expr (fa.value);
                            emitter.mov_rsi_rax ();
                            emitter.pop_reg (Reg.RDI);
                            push_depth--;
                            if (sm.can_throw) {
                                call_aligned (sm.name);
                                emit_post_call_error_check (sm);
                            } else {
                                call_aligned (sm.name);
                            }
                            cleanup_expr_temps (fa.target);
                            cleanup_expr_temps (fa.value);
                            return;
                        }
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"struct '$(base_name)' has no field '$(fa.field_name)' at $(fa.line):$(fa.column)");
                    }
                    ft = fld.field_type;
                    ft_name = fld.type_name;
                    owner_label = base_name;
                    byte_off = 8 * off_slots;
                    string vt_name = "";
                    if (fa.op == "=")
                        coerce_byte_array_literal (fa.value, ft, ft_name);
                    var vt = expr_type_full (fa.value, out vt_name);
                    if (fa.op == "=") {
                        if (!type_compatible (ft, ft_name, vt, vt_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot assign $(type_label (vt, vt_name)) to field '$(owner_label).$(fa.field_name)' ($(type_label (ft, ft_name))) at $(fa.line):$(fa.column)");
                    } else if (is_fp_type (ft)) {
                        if (!is_numeric_type (vt) || (fa.op != "+" && fa.op != "-" && fa.op != "*" && fa.op != "/"))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"operator '$(fa.op)=' is not supported on $(type_label (ft, ft_name)) at $(fa.line):$(fa.column)");
                    } else if (!is_int_like (ft) || !is_int_like (vt)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"operator '$(fa.op)=' requires int or bool operands at $(fa.line):$(fa.column)");
                    }
                    fa_vt = vt;
                    fa_vt_name = vt_name;
                    fa_is_field = true;
                    emitter.add_rax_imm (byte_off);
                }

                emit_field_store (ft, ft_name, fa.op, fa.value, fa_is_weak);
                cleanup_expr_temps (fa.target);
                cleanup_expr_temps (fa.value);
                if (fa_is_field && fa.op == "=" && fa.target is VarRef) {
                    var vn = ((VarRef) fa.target).name;
                    var fkey = (vn == "this") ? fa.field_name : @"$(vn).$(fa.field_name)";
                    update_non_null_on_assign (fkey, fa_vt, fa_vt_name);
                }
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                string tt_name = "";
                var tt = expr_type_full (ia.target, out tt_name);
                if (tt == ValaType.STRING)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"strings are immutable and cannot be indexed for assignment at $(ia.line):$(ia.column)");
                ValaType et = ValaType.INT;
                string et_name = "";
                bool is_ga = (tt == ValaType.CLASS) && find_generic_array_elem (tt_name, out et, out et_name);
                if (tt == ValaType.CLASS && !is_ga) {
                    unowned var icd = program.find_class (strip_null (tt_name));
                    unowned var sm = (icd != null) ? find_class_method (icd, "set_item") : null;
                    if (sm != null) {
                        if (ia.op != "=")
                            throw new SemanticError.TYPE_MISMATCH (
                                @"compound assignment is not supported on the indexer of '$(icd.name)' at $(ia.line):$(ia.column)");
                        string s_vt_name = "";
                        var s_vt = expr_type_full (ia.value, out s_vt_name);
                        if (sm.params.length >= 3
                            && !type_compatible (sm.params[2].param_type, sm.params[2].type_name, s_vt, s_vt_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot assign $(type_label (s_vt, s_vt_name)) to the indexer of '$(icd.name)' ($(type_label (sm.params[2].param_type, sm.params[2].type_name))) at $(ia.line):$(ia.column)");
                        var s_args = new GenericArray<Expr> ();
                        s_args.add (ia.index);
                        s_args.add (ia.value);
                        emit_instance_call (ia.target, false, false, sm, s_args, -1, -1);
                        cleanup_expr_temps (ia.value);
                        return;
                    }
                }
                if (tt != ValaType.ARRAY && !is_ga)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"indexed assignment requires array, got $(type_label (tt, tt_name)) at $(ia.line):$(ia.column)");
                string it_name = "";
                var it = expr_type_full (ia.index, out it_name);
                if (!is_int_like (it))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"array index must be int, got $(type_label (it, it_name)) at $(ia.index.line):$(ia.index.column)");

                if (!is_ga)
                    parse_array_elem (tt_name, out et, out et_name);
                bool is_signed_b = false;
                bool is_byte_arr = is_ga
                    ? (et == ValaType.INT && is_byte_array_type (et_name, out is_signed_b))
                    : ((tt == ValaType.ARRAY) && is_byte_array_type (tt_name, out is_signed_b));
                string vt_name = "";
                if (ia.op == "=")
                    coerce_byte_array_literal (ia.value, et, et_name);
                var vt = expr_type_full (ia.value, out vt_name);
                if (ia.op == "=") {
                    if (!type_compatible (et, et_name, vt, vt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot assign $(type_label (vt, vt_name)) to $(type_label (et, et_name))[] element at $(ia.line):$(ia.column)");
                } else if (is_fp_type (et)) {
                    if (!is_numeric_type (vt) || (ia.op != "+" && ia.op != "-" && ia.op != "*" && ia.op != "/"))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"operator '$(ia.op)=' is not supported on $(type_label (et, et_name))[] element at $(ia.line):$(ia.column)");
                } else {
                    if (!is_int_like (et) || !is_int_like (vt))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"operator '$(ia.op)=' requires int or bool operands at $(ia.line):$(ia.column)");
                }

                gen_expr (ia.target);
                emit_null_check_if_nullable (tt, tt_name);
                emitter.push_rax ();
                push_depth++;
                gen_expr (ia.index);
                emitter.mov_rcx_rax ();
                emitter.pop_rax ();
                push_depth--;
                if (is_ga) {
                    if (bounds_check) {
                        need_bounds_panic = true;
                        emitter.push_rax ();
                        push_depth++;
                        emitter.load_rax_disp (24);
                        emitter.cmp_rax_rcx ();
                        emitter.branch (BranchKind.JBE, bounds_panic_label);
                        emitter.pop_rax ();
                        push_depth--;
                    }
                    emitter.load_rax_disp (16);
                } else if (bounds_check) {
                    need_bounds_panic = true;
                    emitter.cmp_rcx_rax_len ();
                    emitter.branch (BranchKind.JAE, bounds_panic_label);
                }
                if (is_byte_arr) {
                    emitter.lea_rax_rax_rcx_1_16 ();
                    emit_byte_elem_store (is_signed_b, ia.op, ia.value);
                } else {
                    emitter.lea_rax_rax_rcx_8_16 ();
                    emit_field_store (et, et_name, ia.op, ia.value);
                }
                cleanup_expr_temps (ia.target);
                cleanup_expr_temps (ia.index);
                cleanup_expr_temps (ia.value);
            } else if (s is LockStatement) {
                var lk = (LockStatement) s;
                string lt_name = "";
                var lt = expr_type_full (lk.target, out lt_name);
                if (!is_ref_type (lt))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"lock requires a reference type, got $(type_label (lt, lt_name)) at $(lk.line):$(lk.column)");
                need_lock = true;
                var lock_mark = locals.length;
                var obj_slot = next_var_slot++;
                gen_expr (lk.target);
                emitter.store_local (obj_slot);
                push_local (@"#lock_$(lock_mark)", ValaType.CLASS, strip_null (lt_name), obj_slot, true);
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_lock_acquire");
                gen_statement (lk.body);
                emitter.load_local (obj_slot);
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_lock_release");
                cleanup_expr_temps (lk.target);
                unref_locals_from (lock_mark);
                deactivate_from (lock_mark);
            } else if (s is ExprStatement) {
                var e = ((ExprStatement) s).expr;
                if (e is CallExpr) {
                    check_call ((CallExpr) e, false);
                    gen_call ((CallExpr) e);
                } else if (e is MethodCallExpr) {
                    check_method_call ((MethodCallExpr) e, false);
                    gen_method_call ((MethodCallExpr) e);
                } else {
                    expr_type (e);
                    gen_expr (e);
                }
                cleanup_expr_temps (e);
            } else if (s is BlockStatement) {
                var saved = locals.length;
                foreach (var inner in ((BlockStatement) s).statements)
                    gen_statement (inner);
                unref_locals_from (saved);
                deactivate_from (saved);
            } else if (s is IfStatement) {
                var i = (IfStatement) s;
                string ct_name = "";
                var ct = expr_type_full (i.condition, out ct_name);
                if (!is_int_like (ct))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"if condition must be bool or int, got $(type_label (ct, ct_name)) at $(i.condition.line):$(i.condition.column)");
                var snap = clone_non_null ();
                // Narrowing analysis, identical to the prepare pass: both
                // phases must agree on which keys are known non-null where.
                var nn_then = new GenericArray<string> ();
                var nn_else = new GenericArray<string> ();
                collect_non_null_when (i.condition, true, nn_then);
                collect_non_null_when (i.condition, false, nn_else);

                var l_else = emitter.new_label ();
                var l_end = emitter.new_label ();
                gen_expr (i.condition);
                emitter.push_rax ();
                push_depth++;
                cleanup_expr_temps (i.condition);
                emitter.pop_rax ();
                push_depth--;
                emitter.test_rax_rax ();
                emitter.branch (BranchKind.JE, l_else);

                if (nn_then != null)
                    add_all_non_null (nn_then);
                var saved_then = locals.length;
                gen_statement (i.then_body);
                unref_locals_from (saved_then);
                deactivate_from (saved_then);
                var after_then = clone_non_null ();
                emitter.branch (BranchKind.JMP, l_end);

                emitter.bind (l_else);
                GenericArray<string>? after_else = null;
                if (i.else_body != null) {
                    restore_non_null (snap);
                    if (nn_else != null)
                        add_all_non_null (nn_else);
                    var saved_else = locals.length;
                    gen_statement (i.else_body);
                    unref_locals_from (saved_else);
                    deactivate_from (saved_else);
                    after_else = clone_non_null ();
                }
                emitter.bind (l_end);
                finalize_if_narrowing (i, snap, after_then, after_else, nn_then, nn_else);
            } else if (s is WhileStatement) {
                var w = (WhileStatement) s;
                string ct_name = "";
                var ct = expr_type_full (w.condition, out ct_name);
                if (!is_int_like (ct))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"while condition must be bool or int, got $(type_label (ct, ct_name)) at $(w.condition.line):$(w.condition.column)");
                var l_start = emitter.new_label ();
                var l_end = emitter.new_label ();
                break_labels.add (l_end);
                continue_labels.add (l_start);
                break_scope_marks.add (locals.length);
                continue_scope_marks.add (locals.length);
                emitter.bind (l_start);
                gen_expr (w.condition);
                emitter.push_rax ();
                push_depth++;
                cleanup_expr_temps (w.condition);
                emitter.pop_rax ();
                push_depth--;
                emitter.test_rax_rax ();
                emitter.branch (BranchKind.JE, l_end);
                var before_w = clone_non_null ();
                var nn_w = new GenericArray<string> ();
                collect_non_null_when (w.condition, true, nn_w);
                add_all_non_null (nn_w);
                var saved = locals.length;
                gen_statement (w.body);
                unref_locals_from (saved);
                deactivate_from (saved);
                restore_non_null (before_w);
                emitter.branch (BranchKind.JMP, l_start);
                emitter.bind (l_end);
                pop_loop_labels ();
            } else if (s is DoWhileStatement) {
                var dw = (DoWhileStatement) s;
                var l_body = emitter.new_label ();
                var l_cond = emitter.new_label ();
                var l_end = emitter.new_label ();
                var saved = locals.length;
                break_labels.add (l_end);
                continue_labels.add (l_cond);
                break_scope_marks.add (saved);
                continue_scope_marks.add (saved);
                var before_dw = clone_non_null ();
                emitter.bind (l_body);
                gen_statement (dw.body);
                unref_locals_from (saved);
                deactivate_from (saved);
                emitter.bind (l_cond);
                string ct_name = "";
                var ct = expr_type_full (dw.condition, out ct_name);
                if (!is_int_like (ct))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"do-while condition must be bool or int, got $(type_label (ct, ct_name)) at $(dw.condition.line):$(dw.condition.column)");
                gen_expr (dw.condition);
                emitter.push_rax ();
                push_depth++;
                cleanup_expr_temps (dw.condition);
                emitter.pop_rax ();
                push_depth--;
                emitter.test_rax_rax ();
                emitter.branch (BranchKind.JNE, l_body);
                emitter.bind (l_end);
                restore_non_null (before_dw);
                pop_loop_labels ();
            } else if (s is ForStatement) {
                var fs = (ForStatement) s;
                var saved = locals.length;
                if (fs.init != null)
                    gen_statement (fs.init);
                var l_cond = emitter.new_label ();
                var l_step = emitter.new_label ();
                var l_end = emitter.new_label ();
                break_labels.add (l_end);
                continue_labels.add (l_step);
                break_scope_marks.add (saved);
                continue_scope_marks.add (locals.length);
                emitter.bind (l_cond);
                if (fs.condition != null) {
                    string ct_name = "";
                    var ct = expr_type_full (fs.condition, out ct_name);
                    if (!is_int_like (ct))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"for condition must be bool or int, got $(type_label (ct, ct_name)) at $(fs.condition.line):$(fs.condition.column)");
                    gen_expr (fs.condition);
                    emitter.push_rax ();
                    push_depth++;
                    cleanup_expr_temps (fs.condition);
                    emitter.pop_rax ();
                    push_depth--;
                    emitter.test_rax_rax ();
                    emitter.branch (BranchKind.JE, l_end);
                }
                var body_mark = locals.length;
                gen_statement (fs.body);
                unref_locals_from (body_mark);
                deactivate_from (body_mark);
                emitter.bind (l_step);
                if (fs.step != null)
                    gen_statement (fs.step);
                emitter.branch (BranchKind.JMP, l_cond);
                emitter.bind (l_end);
                pop_loop_labels ();
                unref_locals_from (saved);
                deactivate_from (saved);
            } else if (s is ForeachStatement) {
                var fe = (ForeachStatement) s;
                string ct_name = "";
                var ct = expr_type_full (fe.collection, out ct_name);
                ValaType et = ValaType.INT;
                string et_name = "";
                bool is_ga = (ct == ValaType.CLASS) && find_generic_array_elem (ct_name, out et, out et_name);
                if (ct != ValaType.ARRAY && !is_ga)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"foreach requires an array collection, got $(type_label (ct, ct_name)) at $(fe.collection.line):$(fe.collection.column)");
                if (!is_ga)
                    parse_array_elem (ct_name, out et, out et_name);
                ValaType vtype = fe.infer_type ? et : fe.elem_type;
                string vtname = fe.infer_type ? et_name : fe.elem_type_name;
                if (!fe.infer_type && !type_compatible (vtype, vtname, et, et_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"foreach variable '$(fe.var_name)' expects $(type_label (vtype, vtname)), got $(type_label (et, et_name)) at $(fe.line):$(fe.column)");
                if (lookup (fe.var_name) >= 0)
                    throw new SemanticError.DUPLICATE_VARIABLE (
                        @"duplicate variable: $(fe.var_name) at $(fe.line):$(fe.column)");

                var col_mark = locals.length;
                var col_slot = next_var_slot++;
                var idx_slot = next_var_slot++;

                gen_expr (fe.collection);
                emit_null_check_if_nullable (ct, ct_name);
                consume_ref_expr (fe.collection);
                emitter.store_local (col_slot);
                cleanup_expr_temps (fe.collection);
                emitter.zero_local (idx_slot);
                push_local (@"#fe_col_$(col_mark)", is_ga ? ValaType.CLASS : ValaType.ARRAY, strip_null (ct_name), col_slot, false);
                push_local (@"#fe_idx_$(col_mark)", ValaType.INT, "", idx_slot, false);

                var l_cond = emitter.new_label ();
                var l_step = emitter.new_label ();
                var l_end = emitter.new_label ();
                var iter_mark = locals.length;
                break_labels.add (l_end);
                continue_labels.add (l_step);
                break_scope_marks.add (iter_mark);
                continue_scope_marks.add (iter_mark);

                var eslot = next_var_slot++;
                push_local (fe.var_name, vtype, vtname, eslot, false);

                emitter.bind (l_cond);
                emitter.load_local (col_slot);
                emitter.load_rax_disp (is_ga ? 24 : 8);
                emitter.mov_rcx_rax ();
                emitter.load_local (idx_slot);
                emitter.cmp_rax_rcx ();
                emitter.branch (BranchKind.JAE, l_end);

                emitter.load_local (idx_slot);
                emitter.mov_rcx_rax ();
                emitter.load_local (col_slot);
                if (is_ga)
                    emitter.load_rax_disp (16);
                bool fe_signed_b = false;
                bool fe_byte = is_ga
                    ? (et == ValaType.INT && is_byte_array_type (et_name, out fe_signed_b))
                    : (ct == ValaType.ARRAY && is_byte_array_type (ct_name, out fe_signed_b));
                if (fe_byte) {
                    emitter.load_byte_rax_rcx_16 ();
                    if (fe_signed_b)
                        emitter.sign_extend_rax (8);
                } else {
                    emitter.load_qword_rax_rcx_16 ();
                    if (et == ValaType.INT)
                        emit_int_narrow (et_name);
                }
                if (vtype == ValaType.INT)
                    emit_int_narrow (vtname);
                if (program_uses_heap && is_ref_type (vtype)) {
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_ref");
                }
                emitter.store_local (eslot);

                var body_mark = locals.length;
                gen_statement (fe.body);
                unref_locals_from (iter_mark);
                deactivate_from (body_mark);

                emitter.bind (l_step);
                emitter.load_local (idx_slot);
                emitter.add_rax_imm (1);
                emitter.store_local (idx_slot);
                emitter.branch (BranchKind.JMP, l_cond);

                emitter.bind (l_end);
                pop_loop_labels ();
                deactivate_from (iter_mark);
                unref_locals_from (col_mark);
                deactivate_from (col_mark);
            } else if (s is SwitchStatement) {
                var sw = (SwitchStatement) s;
                string st_name = "";
                var st = expr_type_full (sw.target, out st_name);
                if (st != ValaType.INT && st != ValaType.BOOL && st != ValaType.ENUM
                    && !(st == ValaType.STRING && !is_nullable_type (st, st_name))) {
                    throw new SemanticError.TYPE_MISMATCH (
                        @"switch does not support type $(type_label (st, st_name)) at $(sw.target.line):$(sw.target.column)");
                }
                var sw_mark = locals.length;
                var sw_slot = next_var_slot++;

                gen_expr (sw.target);
                if (st == ValaType.STRING)
                    consume_ref_expr (sw.target);
                emitter.store_local (sw_slot);
                cleanup_expr_temps (sw.target);
                push_local (@"#sw_$(sw_mark)", st == ValaType.STRING ? ValaType.STRING : ValaType.INT, "", sw_slot, false);

                var l_end = emitter.new_label ();
                var l_default = emitter.new_label ();
                var case_labels = new GenericArray<Label> ();
                for (int ci = 0; ci < sw.cases.length; ci++)
                    case_labels.add (emitter.new_label ());

                break_labels.add (l_end);
                break_scope_marks.add (locals.length);

                for (int ci = 0; ci < sw.cases.length; ci++) {
                    var sc = sw.cases[ci];
                    foreach (var v in sc.values) {
                        string vt_name = "";
                        var vt = expr_type_full (v, out vt_name);
                        if (!type_compatible (st, st_name, vt, vt_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"switch case expects $(type_label (st, st_name)), got $(type_label (vt, vt_name)) at $(v.line):$(v.column)");
                        gen_expr (v);
                        if (st == ValaType.STRING) {
                            emitter.mov_rsi_rax ();
                            emitter.load_local (sw_slot);
                            emitter.mov_rdi_rax ();
                            need_str_eq = true;
                            call_aligned ("__planc_str_eq");
                            emitter.push_rax ();
                            push_depth++;
                            cleanup_expr_temps (v);
                            emitter.pop_rax ();
                            push_depth--;
                            emitter.test_rax_rax ();
                            emitter.branch (BranchKind.JNE, case_labels[ci]);
                        } else {
                            emitter.push_rax ();
                            push_depth++;
                            cleanup_expr_temps (v);
                            emitter.pop_rcx ();
                            push_depth--;
                            emitter.load_local (sw_slot);
                            emitter.cmp_rax_rcx ();
                            emitter.branch (BranchKind.JE, case_labels[ci]);
                        }
                    }
                }
                emitter.branch (BranchKind.JMP, sw.has_default ? l_default : l_end);

                for (int ci = 0; ci < sw.cases.length; ci++) {
                    emitter.bind (case_labels[ci]);
                    var case_mark = locals.length;
                    foreach (var bs in sw.cases[ci].body)
                        gen_statement (bs);
                    unref_locals_from (case_mark);
                    deactivate_from (case_mark);
                    emitter.branch (BranchKind.JMP, l_end);
                }
                if (sw.has_default) {
                    emitter.bind (l_default);
                    var def_mark = locals.length;
                    foreach (var ds in sw.default_body)
                        gen_statement (ds);
                    unref_locals_from (def_mark);
                    deactivate_from (def_mark);
                }
                emitter.bind (l_end);
                pop_break_label ();
                unref_locals_from (sw_mark);
                deactivate_from (sw_mark);
            } else if (s is ThrowStatement) {
                var ts = (ThrowStatement) s;
                unowned var ed = program.find_error_domain (ts.domain_name);
                unowned var em = (ed != null) ? ed.find_code (ts.code_name) : null;
                if (ed == null || em == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown error '$(ts.domain_name).$(ts.code_name)' at $(ts.line):$(ts.column)");
                var one = new GenericArray<string> ();
                one.add (ts.domain_name);
                check_domains_handled (one, ts.line, ts.column);
                string mt_name = "";
                var mt = expr_type_full (ts.message, out mt_name);
                if (mt != ValaType.STRING || is_nullable_type (mt, mt_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"throw message must be a non-null string, got $(type_label (mt, mt_name)) at $(ts.message.line):$(ts.message.column)");
                gen_expr (ts.message);
                consume_ref_expr (ts.message);
                emitter.push_rax ();
                push_depth++;
                emitter.mov_rdi_imm (24);
                emitter.mov_esi_imm (1);
                call_aligned ("__planc_alloc");
                emitter.store_local (err_prop_slot);
                emitter.mov_rcx_rax ();
                emitter.mov_rax_imm (1);
                emitter.store_rcx_disp_rax (8);
                emitter.mov_rax_imm (ed.domain_id);
                emitter.store_rcx_disp_rax (24);
                emitter.mov_rax_imm (em.value);
                emitter.store_rcx_disp_rax (32);
                emitter.pop_rax ();
                push_depth--;
                emitter.store_rcx_disp_rax (16);
                cleanup_expr_temps (ts.message);
                emit_error_jump ();
            } else if (s is TryStatement) {
                var tr = (TryStatement) s;
                int fin_mode_slot = -1;
                int fin_ret_slot = -1;
                Label l_finally = emitter.new_label ();
                Label l_finally_err = emitter.new_label ();
                Label l_end = emitter.new_label ();

                int fin_scope_mark = locals.length;
                if (tr.has_finally) {
                    fin_mode_slot = next_var_slot++;
                    fin_ret_slot = next_var_slot++;
                    emitter.zero_local (fin_mode_slot);
                    emitter.zero_local (fin_ret_slot);
                    finally_labels.add (l_finally);
                    finally_mode_slots.add (fin_mode_slot);
                    finally_ret_slots.add (fin_ret_slot);
                    finally_marks.add (fin_scope_mark);
                }

                int saved_dom = active_catch_domains.length;
                foreach (var cc in tr.catches) {
                    check_domain_exists (cc.domain_name, cc.line, cc.column);
                    active_catch_domains.add (cc.domain_name);
                }

                var l_dispatch = emitter.new_label ();
                var try_mark = locals.length;
                unwind_labels.add (l_dispatch);
                unwind_marks.add (try_mark);

                foreach (var st in tr.try_body)
                    gen_statement (st);
                unref_locals_from (try_mark);
                deactivate_from (try_mark);
                if (tr.has_finally)
                    emitter.zero_local (fin_mode_slot);
                emitter.branch (BranchKind.JMP, tr.has_finally ? l_finally : l_end);

                unwind_labels.remove_index (unwind_labels.length - 1);
                unwind_marks.remove_index (unwind_marks.length - 1);
                while (active_catch_domains.length > saved_dom)
                    active_catch_domains.remove_index (active_catch_domains.length - 1);

                if (tr.has_finally) {
                    unwind_labels.add (l_finally_err);
                    unwind_marks.add (fin_scope_mark);
                }

                var catch_labels = new GenericArray<Label> ();
                for (int ci = 0; ci < tr.catches.length; ci++)
                    catch_labels.add (emitter.new_label ());

                emitter.bind (l_dispatch);
                for (int ci = 0; ci < tr.catches.length; ci++) {
                    var cc = tr.catches[ci];
                    if (cc.domain_name == "Error") {
                        emitter.branch (BranchKind.JMP, catch_labels[ci]);
                    } else {
                        unowned var ed = program.find_error_domain (cc.domain_name);
                        emitter.load_local (err_prop_slot);
                        emitter.load_rax_disp (24);
                        emitter.mov_rcx_rax ();
                        emitter.mov_rax_imm (ed.domain_id);
                        emitter.cmp_rax_rcx ();
                        emitter.branch (BranchKind.JE, catch_labels[ci]);
                    }
                }
                if (tr.has_finally) {
                    emitter.branch (BranchKind.JMP, l_finally_err);
                } else {
                    emit_error_jump ();
                }

                for (int ci = 0; ci < tr.catches.length; ci++) {
                    var cc = tr.catches[ci];
                    emitter.bind (catch_labels[ci]);
                    var catch_mark = locals.length;
                    if (lookup (cc.var_name) >= 0)
                        throw new SemanticError.DUPLICATE_VARIABLE (
                            @"duplicate variable: $(cc.var_name) at $(cc.line):$(cc.column)");
                    var cslot = next_var_slot++;
                    push_local (cc.var_name, ValaType.ERROR,
                                cc.domain_name == "Error" ? "" : cc.domain_name,
                                cslot, false);
                    emitter.load_local (err_prop_slot);
                    emitter.store_local (cslot);
                    foreach (var cs in cc.body)
                        gen_statement (cs);
                    unref_locals_from (catch_mark);
                    deactivate_from (catch_mark);
                    if (tr.has_finally)
                        emitter.zero_local (fin_mode_slot);
                    emitter.branch (BranchKind.JMP, tr.has_finally ? l_finally : l_end);
                }

                if (tr.has_finally) {
                    unwind_labels.remove_index (unwind_labels.length - 1);
                    unwind_marks.remove_index (unwind_marks.length - 1);
                    finally_labels.remove_index (finally_labels.length - 1);
                    finally_mode_slots.remove_index (finally_mode_slots.length - 1);
                    finally_ret_slots.remove_index (finally_ret_slots.length - 1);
                    finally_marks.remove_index (finally_marks.length - 1);

                    emitter.bind (l_finally_err);
                    emitter.mov_rax_imm (1);
                    emitter.store_local (fin_mode_slot);

                    emitter.bind (l_finally);
                    var fin_mark = locals.length;
                    foreach (var fs in tr.finally_body)
                        gen_statement (fs);
                    unref_locals_from (fin_mark);
                    deactivate_from (fin_mark);

                    var l_chk_ret = emitter.new_label ();
                    emitter.load_local (fin_mode_slot);
                    emitter.mov_rcx_rax ();
                    emitter.mov_rax_imm (1);
                    emitter.cmp_rax_rcx ();
                    emitter.branch (BranchKind.JNE, l_chk_ret);
                    emit_error_jump ();

                    emitter.bind (l_chk_ret);
                    var l_chk_brk = emitter.new_label ();
                    emitter.load_local (fin_mode_slot);
                    emitter.mov_rcx_rax ();
                    emitter.mov_rax_imm (2);
                    emitter.cmp_rax_rcx ();
                    emitter.branch (BranchKind.JNE, l_chk_brk);
                    if (finally_labels.length > 0) {
                        int outer_idx = finally_labels.length - 1;
                        emitter.load_local (fin_ret_slot);
                        emitter.store_local (finally_ret_slots[outer_idx]);
                        if (program_uses_heap)
                            unref_locals_from (finally_marks[outer_idx]);
                        emitter.mov_rax_imm (2);
                        emitter.store_local (finally_mode_slots[outer_idx]);
                        emitter.branch (BranchKind.JMP, finally_labels[outer_idx]);
                    } else {
                        if (program_uses_heap)
                            unref_locals_from (0);
                        emitter.load_local (fin_ret_slot);
                        if (is_fp_type (current.return_type))
                            emitter.movq_xmm_rax (0);
                        emitter.xor_edx ();
                        emitter.leave ();
                        emitter.ret ();
                    }

                    emitter.bind (l_chk_brk);
                    if (break_labels.length > 0) {
                        var l_chk_cont = emitter.new_label ();
                        emitter.load_local (fin_mode_slot);
                        emitter.mov_rcx_rax ();
                        emitter.mov_rax_imm (3);
                        emitter.cmp_rax_rcx ();
                        emitter.branch (BranchKind.JNE, l_chk_cont);
                        if (finally_labels.length > 0
                            && finally_marks[finally_labels.length - 1] > break_scope_marks[break_scope_marks.length - 1]) {
                            int outer_idx = finally_labels.length - 1;
                            if (program_uses_heap)
                                unref_locals_from (finally_marks[outer_idx]);
                            emitter.mov_rax_imm (3);
                            emitter.store_local (finally_mode_slots[outer_idx]);
                            emitter.branch (BranchKind.JMP, finally_labels[outer_idx]);
                        } else {
                            unref_locals_from (break_scope_marks[break_scope_marks.length - 1]);
                            emitter.branch (BranchKind.JMP, break_labels[break_labels.length - 1]);
                        }
                        emitter.bind (l_chk_cont);
                    }
                    if (continue_labels.length > 0) {
                        emitter.load_local (fin_mode_slot);
                        emitter.mov_rcx_rax ();
                        emitter.mov_rax_imm (4);
                        emitter.cmp_rax_rcx ();
                        emitter.branch (BranchKind.JNE, l_end);
                        if (finally_labels.length > 0
                            && finally_marks[finally_labels.length - 1] > continue_scope_marks[continue_scope_marks.length - 1]) {
                            int outer_idx = finally_labels.length - 1;
                            if (program_uses_heap)
                                unref_locals_from (finally_marks[outer_idx]);
                            emitter.mov_rax_imm (4);
                            emitter.store_local (finally_mode_slots[outer_idx]);
                            emitter.branch (BranchKind.JMP, finally_labels[outer_idx]);
                        } else {
                            unref_locals_from (continue_scope_marks[continue_scope_marks.length - 1]);
                            emitter.branch (BranchKind.JMP, continue_labels[continue_labels.length - 1]);
                        }
                    }
                }
                emitter.bind (l_end);
            } else if (s is BreakStatement) {
                if (break_labels.length == 0)
                    throw new SemanticError.BAD_LOOP_CONTROL (
                        @"'break' outside of loop at $(s.line):$(s.column)");
                if (finally_labels.length > 0
                    && finally_marks[finally_labels.length - 1] > break_scope_marks[break_scope_marks.length - 1]) {
                    int fin_idx = finally_labels.length - 1;
                    if (program_uses_heap)
                        unref_locals_from (finally_marks[fin_idx]);
                    emitter.mov_rax_imm (3);
                    emitter.store_local (finally_mode_slots[fin_idx]);
                    emitter.branch (BranchKind.JMP, finally_labels[fin_idx]);
                } else {
                    unref_locals_from (break_scope_marks[break_scope_marks.length - 1]);
                    emitter.branch (BranchKind.JMP, break_labels[break_labels.length - 1]);
                }
            } else if (s is ContinueStatement) {
                if (continue_labels.length == 0)
                    throw new SemanticError.BAD_LOOP_CONTROL (
                        @"'continue' outside of loop at $(s.line):$(s.column)");
                if (finally_labels.length > 0
                    && finally_marks[finally_labels.length - 1] > continue_scope_marks[continue_scope_marks.length - 1]) {
                    int fin_idx = finally_labels.length - 1;
                    if (program_uses_heap)
                        unref_locals_from (finally_marks[fin_idx]);
                    emitter.mov_rax_imm (4);
                    emitter.store_local (finally_mode_slots[fin_idx]);
                    emitter.branch (BranchKind.JMP, finally_labels[fin_idx]);
                } else {
                    unref_locals_from (continue_scope_marks[continue_scope_marks.length - 1]);
                    emitter.branch (BranchKind.JMP, continue_labels[continue_labels.length - 1]);
                }
            } else {
                Host.panic ("statement not supported");
            }
        }

        private void pop_break_label () {
            if (break_labels.length > 0)
                break_labels.remove_index (break_labels.length - 1);
            if (break_scope_marks.length > 0)
                break_scope_marks.remove_index (break_scope_marks.length - 1);
        }

        private void pop_loop_labels () {
            pop_break_label ();
            if (continue_labels.length > 0)
                continue_labels.remove_index (continue_labels.length - 1);
            if (continue_scope_marks.length > 0)
                continue_scope_marks.remove_index (continue_scope_marks.length - 1);
        }

        // ------------------------------------------------------------------
        // Expressions. Every path leaves its value (or struct/ref ptr) in rax.
        // ------------------------------------------------------------------

        private void setcc (string op, bool is_unsigned = false) {
            uint8 cc;
            if (op == "==") cc = 0x94;
            else if (op == "!=") cc = 0x95;
            else if (op == "<") cc = is_unsigned ? 0x92 : 0x9C;
            else if (op == "<=") cc = is_unsigned ? 0x96 : 0x9E;
            else if (op == ">") cc = is_unsigned ? 0x97 : 0x9F;
            else cc = is_unsigned ? 0x93 : 0x9D;
            emitter.setcc_al (cc);
            emitter.movzx_eax_al ();
        }

        private void gen_expr (Expr e) throws SemanticError {
            gen_expr_impl (e);
            if (program_uses_heap && e.ref_temp_slot >= 0)
                add_live_ref_slot (e.ref_temp_slot);
        }

        private void gen_expr_impl (Expr e) throws SemanticError {
            if (e is IntLiteral) {
                emitter.mov_rax_imm (((IntLiteral) e).value);
            } else if (e is FloatLiteral) {
                emitter.mov_rax_imm ((int64) ((FloatLiteral) e).bits);
                emitter.movq_xmm_rax (0);
            } else if (e is BoolLiteral) {
                if (((BoolLiteral) e).value)
                    emitter.mov_rax_imm (1);
                else
                    emitter.xor_eax ();
            } else if (e is StringLiteral) {
                var offset = emitter.add_string (((StringLiteral) e).value);
                emitter.lea_rax_rip (offset);
            } else if (e is NullLiteral) {
                emitter.xor_eax ();
            } else if (e is SizeofExpr) {
                var sz = (SizeofExpr) e;
                ValaType st = sz.target_type;
                string st_name = sz.type_name;
                if (!sz.is_type_form) {
                    if (sz.operand == null)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"sizeof requires a type or an expression at $(sz.line):$(sz.column)");
                    string on = "";
                    st = expr_type_full (sz.operand, out on);
                    st_name = on;
                }
                emitter.mov_rax_imm (sizeof_bytes (st, st_name));
            } else if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                if (cn.class_name == "Mutex") {
                    need_sync = true;
                    call_aligned ("__planc_mutex_new");
                    if (program_uses_heap && cn.ref_temp_slot >= 0) {
                        emitter.store_local (cn.ref_temp_slot);
                        add_live_ref_slot (cn.ref_temp_slot);
                    }
                    return;
                }
                if (cn.class_name.has_prefix ("Channel__")) {
                    need_sync = true;
                    call_aligned ("__planc_chan_new");
                    if (program_uses_heap && cn.ref_temp_slot >= 0) {
                        emitter.store_local (cn.ref_temp_slot);
                        add_live_ref_slot (cn.ref_temp_slot);
                    }
                    return;
                }
                unowned var cd = program.find_class (cn.class_name);
                if (cd == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown class '$(cn.class_name)' at $(cn.line):$(cn.column)");
                unowned Function? ctor_fn = (cn.ctor_name != "")
                    ? cd.find_own_named_ctor (cn.ctor_name)
                    : cd.ctor;
                int payload_bytes = 8 * class_total_field_slots (cd);
                if (cd.is_compact) {
                    // Fields start after the 8-byte allocator word, so the block
                    // is 8 bytes shorter than a normal instance; tag 3 disables
                    // reference counting for it.
                    int req = (payload_bytes >= 8) ? payload_bytes - 8 : 0;
                    emitter.mov_rdi_imm (req);
                    emitter.mov_esi_imm (3);
                    call_aligned ("__planc_alloc");
                } else {
                    emitter.mov_rdi_imm (payload_bytes);
                    emitter.mov_esi_imm (2);
                    call_aligned ("__planc_alloc");
                    emitter.lea_rcx_space (cd.vtable_rodata_offset, PatchSpace.RODATA);
                    emitter.store_rax_8_rcx ();
                }
                emitter.store_local (cn.ref_temp_slot);
                emitter.mov_rdi_rax ();
                call_aligned (@"__planc_init_$(cd.name)");
                if (program_uses_heap && cn.ref_temp_slot >= 0)
                    add_live_ref_slot (cn.ref_temp_slot);
                if (ctor_fn != null)
                    emit_instance_call_from_slot (cn.ref_temp_slot, ctor_fn, cn.args);
                for (int i = 0; i < cn.init_names.length; i++) {
                    var iname = cn.init_names[i];
                    var ival = cn.init_values[i];
                    unowned ClassField? cf = null;
                    var fslot = class_field_offset_slots (cd, iname, out cf);
                    if (fslot >= 0 && cf != null) {
                        emitter.load_local (cn.ref_temp_slot);
                        emitter.add_rax_imm (class_field_base (cd) + 8 * fslot);
                        emit_field_store (cf.field_type, cf.type_name, "=", ival);
                    } else {
                        unowned var sm = find_prop_setter (ValaType.CLASS, cd.name, iname);
                        if (sm == null)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"class '$(cd.name)' has no property or field '$iname' at $(ival.line):$(ival.column)");
                        var arglist = new GenericArray<Expr> ();
                        arglist.add (ival);
                        emit_instance_call_from_slot (cn.ref_temp_slot, sm, arglist);
                    }
                }
                emitter.load_local (cn.ref_temp_slot);
            } else if (e is TypeCheckExpr) {
                var tc = (TypeCheckExpr) e;
                if (tc.op == "nonnull") {
                    string ot_name = "";
                    var ot = expr_type_full (tc.operand, out ot_name);
                    gen_expr (tc.operand);
                    if (is_delegate_type (program, ot, ot_name)) {
                        if (is_nullable_type (ot, ot_name) && null_check) {
                            need_null_panic = true;
                            emitter.mov_rcx_rax ();
                            emitter.load_rcx_disp_to_rax (0);
                            emitter.test_rax_rax ();
                            emitter.branch (BranchKind.JE, null_panic_label);
                            emitter.mov_rax_rcx ();
                        }
                        return;
                    }
                    emit_null_check_if_nullable (ot, ot_name);
                    return;
                }
                if (tc.op == "cast" && is_delegate_type (program, tc.target_type, tc.target_type_name)) {
                    string ot_name = "";
                    var ot = expr_type_full (tc.operand, out ot_name);
                    if (ot == ValaType.NULL) {
                        emitter.lea_rax_space (null_delegate_bss_offset, PatchSpace.BSS);
                        return;
                    }
                    gen_expr (tc.operand);
                    if (!is_nullable_type (tc.target_type, tc.target_type_name)
                        && is_nullable_type (ot, ot_name) && null_check) {
                        need_null_panic = true;
                        emitter.mov_rcx_rax ();
                        emitter.load_rcx_disp_to_rax (0);
                        emitter.test_rax_rax ();
                        emitter.branch (BranchKind.JE, null_panic_label);
                        emitter.mov_rax_rcx ();
                    }
                    return;
                }
                if (tc.op == "cast" && (tc.target_type == ValaType.INT || tc.target_type == ValaType.ENUM)) {
                    var ot = expr_type (tc.operand);
                    gen_expr (tc.operand);
                    if (ot == ValaType.FLOAT)
                        emitter.cvttss2si_rax_xmm0 ();
                    else if (ot == ValaType.DOUBLE)
                        emitter.cvttsd2si_rax_xmm0 ();
                    emit_int_narrow (tc.target_type_name);
                    return;
                }
                if (tc.op == "cast" && is_fp_type (tc.target_type)) {
                    var ot = expr_type (tc.operand);
                    gen_expr (tc.operand);
                    var src_t = (ot == ValaType.ENUM || ot == ValaType.BOOL) ? ValaType.INT : ot;
                    emit_fp_coerce (src_t, tc.target_type);
                    return;
                }
                if (tc.target_type == ValaType.ERROR) {
                    unowned var ed = program.find_error_domain (tc.target_type_name);
                    gen_expr (tc.operand);
                    var l_false = emitter.new_label ();
                    var l_done = emitter.new_label ();
                    emitter.test_rax_rax ();
                    emitter.branch (BranchKind.JE, l_false);
                    emitter.load_rax_disp (24);
                    emitter.mov_rcx_rax ();
                    emitter.mov_rax_imm (ed.domain_id);
                    emitter.cmp_rax_rcx ();
                    setcc ("==");
                    emitter.branch (BranchKind.JMP, l_done);
                    emitter.bind (l_false);
                    emitter.xor_eax ();
                    emitter.bind (l_done);
                    return;
                }
                if (tc.target_type == ValaType.INTERFACE) {
                    unowned var itf = program.find_interface (strip_null (tc.target_type_name));
                    need_iface_lookup = true;
                    gen_expr (tc.operand);
                    if (tc.op == "is") {
                        emitter.mov_rdi_rax ();
                        emitter.mov_rax_imm (itf.iface_id);
                        call_aligned ("__planc_iface_lookup");
                        emitter.test_rax_rax ();
                        setcc ("!=");
                    } else if (tc.op == "as") {
                        emitter.push_rax ();
                        push_depth++;
                        emitter.mov_rdi_rax ();
                        emitter.mov_rax_imm (itf.iface_id);
                        call_aligned ("__planc_iface_lookup");
                        emitter.test_rax_rax ();
                        var l_ok = emitter.new_label ();
                        emitter.branch (BranchKind.JNE, l_ok);
                        emitter.pop_rax ();
                        emitter.xor_eax ();
                        var l_done = emitter.new_label ();
                        emitter.branch (BranchKind.JMP, l_done);
                        emitter.bind (l_ok);
                        emitter.pop_rax ();
                        emitter.bind (l_done);
                        push_depth--;
                    } else {
                        var l_ok = emitter.new_label ();
                        if (tc.target_type_name.has_suffix ("?")) {
                            emitter.test_rax_rax ();
                            emitter.branch (BranchKind.JE, l_ok);
                        }
                        emitter.push_rax ();
                        push_depth++;
                        emitter.mov_rdi_rax ();
                        emitter.mov_rax_imm (itf.iface_id);
                        call_aligned ("__planc_iface_lookup");
                        emitter.test_rax_rax ();
                        need_cast_panic = true;
                        emitter.branch (BranchKind.JE, cast_panic_label);
                        emitter.pop_rax ();
                        push_depth--;
                        emitter.bind (l_ok);
                    }
                    return;
                }
                unowned var tcd = program.find_class (strip_null (tc.target_type_name));
                if (tcd != null && tcd.is_compact)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'$(tc.op)' cannot target [Compact] class '$(tcd.name)': it has no runtime type at $(tc.line):$(tc.column)");
                gen_expr (tc.operand);
                if (tc.op == "is") {
                    emitter.mov_rdi_rax ();
                    emitter.lea_rsi_rip (tcd.vtable_rodata_offset);
                    need_is_instance = true;
                    call_aligned ("__planc_is_instance");
                } else if (tc.op == "as") {
                    emitter.push_rax ();
                    push_depth++;
                    emitter.mov_rdi_rax ();
                    emitter.lea_rsi_rip (tcd.vtable_rodata_offset);
                    need_is_instance = true;
                    call_aligned ("__planc_is_instance");
                    emitter.test_rax_rax ();
                    var l_ok = emitter.new_label ();
                    emitter.branch (BranchKind.JNE, l_ok);
                    emitter.pop_rax ();
                    emitter.xor_eax ();
                    var l_done = emitter.new_label ();
                    emitter.branch (BranchKind.JMP, l_done);
                    emitter.bind (l_ok);
                    emitter.pop_rax ();
                    emitter.bind (l_done);
                    push_depth--;
                } else {
                    var l_ok = emitter.new_label ();
                    if (tc.target_type_name.has_suffix ("?")) {
                        emitter.test_rax_rax ();
                        emitter.branch (BranchKind.JE, l_ok);
                    }
                    emitter.push_rax ();
                    push_depth++;
                    emitter.mov_rdi_rax ();
                    emitter.lea_rsi_rip (tcd.vtable_rodata_offset);
                    need_is_instance = true;
                    call_aligned ("__planc_is_instance");
                    emitter.test_rax_rax ();
                    need_cast_panic = true;
                    emitter.branch (BranchKind.JE, cast_panic_label);
                    emitter.pop_rax ();
                    push_depth--;
                    emitter.bind (l_ok);
                }
            } else if (e is MethodCallExpr) {
                gen_method_call ((MethodCallExpr) e);
            } else if (e is TemplateExpr) {
                var t = (TemplateExpr) e;
                if (is_static_template (t)) {
                    var offset = emitter.add_string (static_template_text (t));
                    emitter.lea_rax_rip (offset);
                } else {
                    need_str_concat = true;
                    emitter.lea_rax_rip (emitter.add_string (""));
                    emitter.store_local (t.ref_temp_slot);
                    add_live_ref_slot (t.ref_temp_slot);
                    foreach (var part in t.parts) {
                        string pt_name = "";
                        var pt = expr_type_full (part, out pt_name);
                        bool part_fresh = false;
                        if (pt == ValaType.STRING) {
                            gen_expr (part);
                        } else if (pt == ValaType.INT || pt == ValaType.ENUM) {
                            gen_expr (part);
                            emitter.mov_rdi_rax ();
                            if (pt == ValaType.INT && is_unsigned_int_type (pt_name)) {
                                need_uint_to_str = true;
                                call_aligned ("__planc_uint_to_str");
                            } else {
                                need_int_to_str = true;
                                call_aligned ("__planc_int_to_str");
                            }
                            part_fresh = true;
                        } else if (pt == ValaType.FLOAT || pt == ValaType.DOUBLE) {
                            gen_expr (part);
                            if (pt == ValaType.FLOAT)
                                emitter.cvtss2sd_xmm0_xmm0 ();
                            need_double_to_str = true;
                            call_aligned ("__planc_double_to_str");
                            part_fresh = true;
                        } else if (pt == ValaType.BOOL) {
                            gen_expr (part);
                            var l_f = emitter.new_label ();
                            var l_d = emitter.new_label ();
                            emitter.test_rax_rax ();
                            emitter.branch (BranchKind.JE, l_f);
                            emitter.lea_rax_rip (emitter.add_string ("true"));
                            emitter.branch (BranchKind.JMP, l_d);
                            emitter.bind (l_f);
                            emitter.lea_rax_rip (emitter.add_string ("false"));
                            emitter.bind (l_d);
                        }
                        emitter.push_rax ();
                        push_depth++;
                        emitter.load_local (t.ref_temp_slot);
                        emitter.mov_rdi_rax ();
                        if (part_fresh) {
                            emitter.mov_rsi_rsp ();
                            call_aligned ("__planc_str_concat");
                            emitter.pop_reg (Reg.RDI);
                            push_depth--;
                            emitter.push_rax ();
                            push_depth++;
                            call_aligned ("__planc_unref");
                        } else {
                            emitter.pop_reg (Reg.RSI);
                            push_depth--;
                            call_aligned ("__planc_str_concat");
                            emitter.push_rax ();
                            push_depth++;
                        }
                        emitter.load_local (t.ref_temp_slot);
                        emitter.mov_rdi_rax ();
                        call_aligned ("__planc_unref");
                        emitter.pop_rax ();
                        push_depth--;
                        emitter.store_local (t.ref_temp_slot);
                    }
                    emitter.load_local (t.ref_temp_slot);
                }
            } else if (e is ArrayNewExpr) {
                var an = (ArrayNewExpr) e;
                bool elem_ref = is_ref_type (an.elem_type);
                bool byte_arr = (an.elem_type == ValaType.INT)
                    && (an.elem_type_name == "uint8" || an.elem_type_name == "int8");
                gen_expr (an.length_expr);
                emitter.test_rax_rax ();
                need_bounds_panic = true;
                emitter.branch (BranchKind.JL, bounds_panic_label);
                emitter.push_rax ();
                push_depth++;
                emitter.mov_rdi_rax ();
                if (!byte_arr)
                    emitter.shl_rdi_3 ();
                emitter.mov_esi_imm (elem_ref ? 1 : 0);
                call_aligned ("__planc_alloc");
                emitter.pop_reg (Reg.RCX);
                push_depth--;
                emitter.store_rax_8_rcx ();
                if (an.elem_type == ValaType.STRING && !is_nullable_type (an.elem_type, an.elem_type_name))
                    emitter.emit_fill_empty_strings (emitter.add_string (""));
                if (e.ref_temp_slot >= 0)
                    emitter.store_local (e.ref_temp_slot);
            } else if (e is ArrayLiteralExpr) {
                var arr = (ArrayLiteralExpr) e;
                var n = arr.elements.length;
                bool elem_ref = is_ref_type (arr.elem_type);
                bool byte_arr = (arr.elem_type == ValaType.INT)
                    && (arr.elem_type_name == "uint8" || arr.elem_type_name == "int8");
                emitter.mov_rdi_imm (byte_arr ? (int64) n : (int64) n * 8);
                emitter.mov_esi_imm (elem_ref ? 1 : 0);
                call_aligned ("__planc_alloc");
                emitter.mov_rcx_rax ();
                emitter.mov_rax_imm ((int64) n);
                // Store length: swap into rcx/rax cleanly
                emitter.push_reg (Reg.RCX);
                emitter.mov_rcx_rax ();
                emitter.pop_rax ();
                emitter.store_rax_8_rcx ();
                emitter.store_local (arr.ref_temp_slot);
                add_live_ref_slot (arr.ref_temp_slot);
                for (int i = 0; i < n; i++) {
                    gen_expr (arr.elements[i]);
                    if (elem_ref)
                        consume_ref_expr (arr.elements[i]);
                    else if (!byte_arr && arr.elem_type == ValaType.INT)
                        emit_int_narrow (arr.elem_type_name);
                    emitter.mov_rcx_rax ();
                    emitter.load_local (arr.ref_temp_slot);
                    emitter.push_rax ();
                    emitter.mov_rax_rcx ();
                    emitter.pop_reg (Reg.RCX);
                    if (byte_arr)
                        emitter.store_rcx_disp_byte_al (16 + i);
                    else
                        emitter.store_rcx_disp_rax (16 + 8 * i);
                }
                emitter.load_local (arr.ref_temp_slot);
            } else if (e is MemberAccessExpr) {
                var m = (MemberAccessExpr) e;
                if (m.target is VarRef) {
                    var vr = (VarRef) m.target;
                    if (is_type_name (vr.name)) {
                        if (is_int_type_name_cg (vr.name)) {
                            int64 cval = 0;
                            if (resolve_int_const_member (vr.name, m.member, out cval)) {
                                emitter.mov_rax_imm (cval);
                                return;
                            }
                        }
                        unowned var cd_const = program.find_const (vr.name, m.member);
                        if (cd_const != null) {
                            if (cd_const.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (cd_const.str_value));
                            else
                                emitter.mov_rax_imm (cd_const.int_value);
                            return;
                        }
                        unowned var err_d = program.find_error_domain (vr.name);
                        if (err_d != null) {
                            unowned var em = err_d.find_code (m.member);
                            if (em == null)
                                throw new SemanticError.UNKNOWN_MEMBER (
                                    @"error domain '$(err_d.name)' has no code '$(m.member)' at $(m.line):$(m.column)");
                            emitter.mov_rax_imm (em.value);
                            return;
                        }
                        unowned var ed = program.find_enum (vr.name);
                        if (ed != null) {
                            unowned var mem = ed.find_member (m.member);
                            if (mem != null) {
                                emitter.mov_rax_imm (mem.value);
                                return;
                            }
                            if (m.target_del_type == "")
                                throw new SemanticError.UNKNOWN_MEMBER (
                                    @"enum '$(ed.name)' has no member '$(m.member)' at $(m.line):$(m.column)");
                        }
                        if (is_fp_type_name_cg (vr.name)) {
                            uint64 fbits = 0;
                            if (resolve_fp_const_member (vr.name, m.member, out fbits)) {
                                emitter.mov_rax_imm ((int64) fbits);
                                emitter.movq_xmm_rax (0);
                                return;
                            }
                        }
                        {
                            int sg = static_field_global_of_type (vr.name, m.member);
                            if (sg >= 0) {
                                if (global_types[sg] == ValaType.STRUCT)
                                    emitter.lea_rax_space (global_offsets[sg], global_spaces[sg]);
                                else
                                    emitter.load_global (global_offsets[sg], global_spaces[sg]);
                                if (is_fp_type (global_types[sg]))
                                    emitter.movq_xmm_rax (0);
                                return;
                            }
                        }
                        if (m.target_del_type != "") {
                            unowned var mf = resolve_type_method (vr.name, m.member);
                            unowned var dd = program.find_delegate (m.target_del_type);
                            if (mf != null && mf.is_static && dd != null) {
                                var base_disp = struct_base_disp (m.temp_slot, 2);
                                var thunk_sym = ensure_free_delegate_thunk (mf, dd, false, 0);
                                emitter.lea_rax_fn (thunk_sym);
                                emitter.store_rbp_disp (base_disp);
                                emitter.xor_eax ();
                                emitter.store_rbp_disp (base_disp + 8);
                                emitter.lea_rax_rbp_disp (base_disp);
                                return;
                            }
                        }
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"type '$(vr.name)' has no constant or member '$(m.member)' at $(m.line):$(m.column)");
                    }
                }
                string tt_name = "";
                var tt = expr_type_full (m.target, out tt_name);
                if (tt == ValaType.ERROR) {
                    gen_expr (m.target);
                    emit_null_check_if_nullable (tt, tt_name);
                    if (m.member == "message")
                        emitter.load_rax_disp (16);
                    else if (m.member == "domain")
                        emitter.load_rax_disp (24);
                    else if (m.member == "code")
                        emitter.load_rax_disp (32);
                    else
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"Error has no member '$(m.member)' at $(m.line):$(m.column)");
                    return;
                }
                if (tt == ValaType.STRING || tt == ValaType.ARRAY) {
                    gen_expr (m.target);
                    emit_null_check_if_nullable (tt, tt_name);
                    emitter.load_rax_disp (8);
                    return;
                }
                if (tt == ValaType.CLASS) {
                    var cname = strip_null (tt_name);
                    unowned var cd = program.find_class (cname);
                    unowned ClassField? cf = null;
                    var fslot = (cd != null) ? class_field_offset_slots (cd, m.member, out cf) : -1;
                    if (fslot < 0 || cf == null) {
                        unowned var gm = find_prop_getter (tt, tt_name, m.member);
                        if (gm != null) {
                            emit_instance_call (m.target, false, false, gm, new GenericArray<Expr> (), m.temp_slot, m.ref_temp_slot);
                            return;
                        }
                        if (m.target_del_type != "") {
                            unowned var mf = resolve_member_delegate_fn (tt, tt_name, m.member);
                            unowned var dd = program.find_delegate (m.target_del_type);
                            if (mf != null && dd != null) {
                                var base_disp = struct_base_disp (m.temp_slot, 2);
                                if (mf.is_static) {
                                    gen_expr (m.target);
                                    var thunk_sym = ensure_free_delegate_thunk (mf, dd, false, 0);
                                    emitter.lea_rax_fn (thunk_sym);
                                    emitter.store_rbp_disp (base_disp);
                                    emitter.xor_eax ();
                                    emitter.store_rbp_disp (base_disp + 8);
                                    emitter.lea_rax_rbp_disp (base_disp);
                                    return;
                                }
                                gen_expr (m.target);
                                emit_null_check_if_nullable (tt, tt_name);
                                if (program_uses_heap) {
                                    emitter.mov_rdi_rax ();
                                    call_aligned ("__planc_ref");
                                }
                                if (m.ref_temp_slot >= 0)
                                    emitter.store_local (m.ref_temp_slot);
                                emitter.store_rbp_disp (base_disp + 8);
                                bool need_thunk = (mf.is_virtual || mf.is_abstract || mf.iface_slot >= 0);
                                string code_sym = need_thunk
                                    ? ensure_free_delegate_thunk (mf, dd, true, 1)
                                    : mf.name;
                                emitter.lea_rax_fn (code_sym);
                                emitter.store_rbp_disp (base_disp);
                                emitter.lea_rax_rbp_disp (base_disp);
                                return;
                            }
                        }
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"class '$(cname)' has no field or property '$(m.member)' at $(m.line):$(m.column)");
                    }
                    gen_expr (m.target);
                    emit_null_check_if_nullable (tt, tt_name);
                    if (cf.field_type == ValaType.STRUCT)
                        emitter.add_rax_imm (class_field_base (cd) + 8 * fslot);
                    else
                        emitter.load_rax_disp (class_field_base (cd) + 8 * fslot);
                    if (cf.is_weak)
                        emit_load_weak (m.ref_temp_slot);
                    if (is_fp_type (cf.field_type))
                        emitter.movq_xmm_rax (0);
                    return;
                }
                if (tt == ValaType.INTERFACE) {
                    unowned var gm = find_prop_getter (tt, tt_name, m.member);
                    if (gm != null) {
                        emit_instance_call (m.target, false, false, gm, new GenericArray<Expr> (), m.temp_slot, m.ref_temp_slot);
                        return;
                    }
                    if (m.target_del_type != "") {
                        unowned var mf = resolve_member_delegate_fn (tt, tt_name, m.member);
                        unowned var dd = program.find_delegate (m.target_del_type);
                        if (mf != null && dd != null) {
                            var base_disp = struct_base_disp (m.temp_slot, 2);
                            gen_expr (m.target);
                            emit_null_check_if_nullable (tt, tt_name);
                            if (program_uses_heap) {
                                emitter.mov_rdi_rax ();
                                call_aligned ("__planc_ref");
                            }
                            if (m.ref_temp_slot >= 0)
                                emitter.store_local (m.ref_temp_slot);
                            emitter.store_rbp_disp (base_disp + 8);
                            string code_sym = ensure_free_delegate_thunk (mf, dd, true, 1);
                            emitter.lea_rax_fn (code_sym);
                            emitter.store_rbp_disp (base_disp);
                            emitter.lea_rax_rbp_disp (base_disp);
                            return;
                        }
                    }
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"interface '$(strip_null (tt_name))' has no property '$(m.member)' at $(m.line):$(m.column)");
                }
                unowned var sd = program.find_struct (tt_name);
                unowned StructField? fld = null;
                var off_slots = (sd != null) ? struct_field_offset_slots (sd, m.member, out fld) : -1;
                if (off_slots < 0 || fld == null) {
                    unowned var gm = find_prop_getter (tt, tt_name, m.member);
                    if (gm != null) {
                        emit_instance_call (m.target, false, false, gm, new GenericArray<Expr> (), m.temp_slot, m.ref_temp_slot);
                        return;
                    }
                    if (m.target_del_type != "") {
                        unowned var mf = resolve_member_delegate_fn (tt, tt_name, m.member);
                        unowned var dd = program.find_delegate (m.target_del_type);
                        if (mf != null && mf.is_static && dd != null) {
                            var base_disp = struct_base_disp (m.temp_slot, 2);
                            var thunk_sym = ensure_free_delegate_thunk (mf, dd, false, 0);
                            emitter.lea_rax_fn (thunk_sym);
                            emitter.store_rbp_disp (base_disp);
                            emitter.xor_eax ();
                            emitter.store_rbp_disp (base_disp + 8);
                            emitter.lea_rax_rbp_disp (base_disp);
                            return;
                        }
                    }
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"struct '$(tt_name)' has no field or property '$(m.member)' at $(m.line):$(m.column)");
                }
                gen_expr (m.target);
                if (fld.field_type == ValaType.STRUCT)
                    emitter.add_rax_imm (8 * off_slots);
                else
                    emitter.load_rax_disp (8 * off_slots);
                if (is_fp_type (fld.field_type))
                    emitter.movq_xmm_rax (0);
            } else if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                string tt_name = "";
                var tt = expr_type_full (ix.target, out tt_name);
                ValaType ga_et = ValaType.INT;
                string ga_etn = "";
                bool is_ga = (tt == ValaType.CLASS) && find_generic_array_elem (tt_name, out ga_et, out ga_etn);
                if (tt == ValaType.CLASS && !is_ga) {
                    unowned var icd = program.find_class (strip_null (tt_name));
                    unowned var gm = (icd != null) ? find_class_method (icd, "get_item") : null;
                    if (gm != null) {
                        if (gm.return_type == ValaType.STRUCT || gm.return_type == ValaType.ARRAY)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"indexer of '$(icd.name)' cannot return $(type_label (gm.return_type, gm.return_type_name)) at $(ix.line):$(ix.column)");
                        var arglist = new GenericArray<Expr> ();
                        arglist.add (ix.index);
                        emit_instance_call (ix.target, false, false, gm, arglist, -1, -1);
                        return;
                    }
                }
                gen_expr (ix.target);
                emit_null_check_if_nullable (tt, tt_name);
                emitter.push_rax ();
                push_depth++;
                gen_expr (ix.index);
                emitter.mov_rcx_rax ();
                emitter.pop_rax ();
                push_depth--;
                if (is_ga) {
                    if (bounds_check) {
                        need_bounds_panic = true;
                        emitter.push_rax ();
                        push_depth++;
                        emitter.load_rax_disp (24);
                        emitter.cmp_rax_rcx ();
                        emitter.branch (BranchKind.JBE, bounds_panic_label);
                        emitter.pop_rax ();
                        push_depth--;
                    }
                    emitter.load_rax_disp (16);
                    bool ga_signed_b = false;
                    if (ga_et == ValaType.INT && is_byte_array_type (ga_etn, out ga_signed_b)) {
                        emitter.load_byte_rax_rcx_16 ();
                        if (ga_signed_b)
                            emitter.sign_extend_rax (8);
                    } else {
                        emitter.load_qword_rax_rcx_16 ();
                        if (is_fp_type (ga_et))
                            emitter.movq_xmm_rax (0);
                        else if (ga_et == ValaType.INT)
                            emit_int_narrow (ga_etn);
                    }
                } else {
                    if (bounds_check) {
                        need_bounds_panic = true;
                        emitter.cmp_rcx_rax_len ();
                        emitter.branch (BranchKind.JAE, bounds_panic_label);
                    }
                    if (tt == ValaType.ARRAY) {
                        bool is_signed_b = false;
                        if (is_byte_array_type (tt_name, out is_signed_b)) {
                            emitter.load_byte_rax_rcx_16 ();
                            if (is_signed_b)
                                emitter.sign_extend_rax (8);
                        } else {
                            emitter.load_qword_rax_rcx_16 ();
                            ValaType arr_et;
                            string arr_etn;
                            parse_array_elem (tt_name, out arr_et, out arr_etn);
                            if (is_fp_type (arr_et))
                                emitter.movq_xmm_rax (0);
                            else if (arr_et == ValaType.INT)
                                emit_int_narrow (arr_etn);
                        }
                    } else {
                        emitter.load_byte_rax_rcx_16 ();
                    }
                }
            } else if (e is SliceExpr) {
                var se = (SliceExpr) e;
                string tt_name = "";
                expr_type_full (se.target, out tt_name);
                gen_expr (se.target);
                emit_null_check_if_nullable (ValaType.STRING, tt_name);
                emitter.push_rax ();
                push_depth++;
                gen_expr (se.start);
                emitter.push_rax ();
                push_depth++;
                gen_expr (se.end);
                emitter.mov_rdx_rax ();
                emitter.pop_reg (Reg.RSI);
                push_depth--;
                emitter.pop_reg (Reg.RDI);
                push_depth--;
                need_str_slice = true;
                call_aligned ("__planc_str_slice");
                if (program_uses_heap && se.ref_temp_slot >= 0)
                    emitter.store_local (se.ref_temp_slot);
            } else if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                string res_tname = "";
                var res_t = expr_type_full (te, out res_tname);
                if (is_delegate_type (program, res_t, res_tname)) {
                    unowned var sd = program.find_struct (res_tname);
                    var base_disp = struct_base_disp (te.temp_slot, 2);
                    var l_else = emitter.new_label ();
                    var l_end = emitter.new_label ();
                    gen_expr (te.condition);
                    emitter.push_rax ();
                    push_depth++;
                    cleanup_expr_temps (te.condition);
                    emitter.pop_rax ();
                    push_depth--;
                    emitter.test_rax_rax ();
                    emitter.branch (BranchKind.JE, l_else);

                    var snap = clone_non_null ();
                    var nn_then = new GenericArray<string> ();
                    var nn_else = new GenericArray<string> ();
                    collect_non_null_when (te.condition, true, nn_then);
                    collect_non_null_when (te.condition, false, nn_else);

                    add_all_non_null (nn_then);
                    var then_t = expr_type (te.then_expr);
                    if (then_t == ValaType.NULL) {
                        emitter.lea_rcx_rbp_disp (base_disp);
                        if (sd != null)
                            init_struct_at_rcx (sd, 0);
                        if (program_uses_heap && te.ref_temp_slot >= 0)
                            emitter.zero_local (te.ref_temp_slot);
                    } else {
                        gen_expr (te.then_expr);
                        emitter.lea_rcx_rbp_disp (base_disp);
                        copy_struct_rax_to_rcx (2);
                        if (program_uses_heap && sd != null && struct_has_string (sd))
                            ref_struct_at_rcx (sd, 0);
                        if (program_uses_heap && te.ref_temp_slot >= 0) {
                            emitter.load_rcx_disp_to_rax (8);
                            emitter.store_local (te.ref_temp_slot);
                        }
                        cleanup_expr_temps (te.then_expr);
                    }
                    restore_non_null (snap);
                    emitter.branch (BranchKind.JMP, l_end);

                    emitter.bind (l_else);
                    add_all_non_null (nn_else);
                    var else_t = expr_type (te.else_expr);
                    if (else_t == ValaType.NULL) {
                        emitter.lea_rcx_rbp_disp (base_disp);
                        if (sd != null)
                            init_struct_at_rcx (sd, 0);
                        if (program_uses_heap && te.ref_temp_slot >= 0)
                            emitter.zero_local (te.ref_temp_slot);
                    } else {
                        gen_expr (te.else_expr);
                        emitter.lea_rcx_rbp_disp (base_disp);
                        copy_struct_rax_to_rcx (2);
                        if (program_uses_heap && sd != null && struct_has_string (sd))
                            ref_struct_at_rcx (sd, 0);
                        if (program_uses_heap && te.ref_temp_slot >= 0) {
                            emitter.load_rcx_disp_to_rax (8);
                            emitter.store_local (te.ref_temp_slot);
                        }
                        cleanup_expr_temps (te.else_expr);
                    }
                    restore_non_null (snap);
                    emitter.bind (l_end);
                    emitter.lea_rax_rbp_disp (base_disp);
                    return;
                }
                bool ref_res = program_uses_heap && is_ref_type (res_t);
                var l_else = emitter.new_label ();
                var l_end = emitter.new_label ();
                gen_expr (te.condition);
                emitter.push_rax ();
                push_depth++;
                cleanup_expr_temps (te.condition);
                emitter.pop_rax ();
                push_depth--;
                emitter.test_rax_rax ();
                emitter.branch (BranchKind.JE, l_else);

                var snap = clone_non_null ();
                var nn_then = new GenericArray<string> ();
                var nn_else = new GenericArray<string> ();
                collect_non_null_when (te.condition, true, nn_then);
                collect_non_null_when (te.condition, false, nn_else);

                add_all_non_null (nn_then);
                var then_t = expr_type (te.then_expr);
                gen_expr (te.then_expr);
                if (is_fp_type (res_t))
                    emit_fp_coerce (then_t, res_t);
                if (ref_res) {
                    consume_ref_expr (te.then_expr);
                    if (te.ref_temp_slot >= 0)
                        emitter.store_local (te.ref_temp_slot);
                }
                if (is_fp_type (res_t)) {
                    emitter.push_xmm0 ();
                    push_depth++;
                    cleanup_expr_temps (te.then_expr);
                    emitter.pop_xmm0 ();
                    push_depth--;
                } else if (res_t != ValaType.STRUCT) {
                    emitter.push_rax ();
                    push_depth++;
                    cleanup_expr_temps (te.then_expr);
                    emitter.pop_rax ();
                    push_depth--;
                }
                restore_non_null (snap);
                emitter.branch (BranchKind.JMP, l_end);

                emitter.bind (l_else);
                add_all_non_null (nn_else);
                var else_t = expr_type (te.else_expr);
                gen_expr (te.else_expr);
                if (is_fp_type (res_t))
                    emit_fp_coerce (else_t, res_t);
                if (ref_res) {
                    consume_ref_expr (te.else_expr);
                    if (te.ref_temp_slot >= 0)
                        emitter.store_local (te.ref_temp_slot);
                }
                if (is_fp_type (res_t)) {
                    emitter.push_xmm0 ();
                    push_depth++;
                    cleanup_expr_temps (te.else_expr);
                    emitter.pop_xmm0 ();
                    push_depth--;
                } else if (res_t != ValaType.STRUCT) {
                    emitter.push_rax ();
                    push_depth++;
                    cleanup_expr_temps (te.else_expr);
                    emitter.pop_rax ();
                    push_depth--;
                }
                restore_non_null (snap);
                emitter.bind (l_end);
            } else if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                string res_tname = "";
                var res_t = expr_type_full (ce, out res_tname);
                if (is_delegate_type (program, res_t, res_tname)) {
                    unowned var sd = program.find_struct (res_tname);
                    var base_disp = struct_base_disp (ce.temp_slot, 2);
                    string lt_name = "";
                    var lt = expr_type_full (ce.left, out lt_name);
                    var l_use_left = emitter.new_label ();
                    var l_end = emitter.new_label ();
                    if (lt != ValaType.NULL) {
                        gen_expr (ce.left);
                        emitter.mov_rcx_rax ();
                        emitter.load_rcx_disp_to_rax (0);
                        emitter.test_rax_rax ();
                        emitter.branch (BranchKind.JNE, l_use_left);
                        cleanup_expr_temps (ce.left);
                    }
                    string rt_name = "";
                    var rt = expr_type_full (ce.right, out rt_name);
                    if (rt == ValaType.NULL) {
                        emitter.lea_rcx_rbp_disp (base_disp);
                        if (sd != null)
                            init_struct_at_rcx (sd, 0);
                        if (program_uses_heap && ce.ref_temp_slot >= 0)
                            emitter.zero_local (ce.ref_temp_slot);
                    } else {
                        gen_expr (ce.right);
                        emitter.lea_rcx_rbp_disp (base_disp);
                        copy_struct_rax_to_rcx (2);
                        if (program_uses_heap && sd != null && struct_has_string (sd))
                            ref_struct_at_rcx (sd, 0);
                        if (program_uses_heap && ce.ref_temp_slot >= 0) {
                            emitter.load_rcx_disp_to_rax (8);
                            emitter.store_local (ce.ref_temp_slot);
                        }
                        cleanup_expr_temps (ce.right);
                    }
                    emitter.branch (BranchKind.JMP, l_end);

                    emitter.bind (l_use_left);
                    if (lt != ValaType.NULL) {
                        emitter.mov_rax_rcx ();
                        emitter.lea_rcx_rbp_disp (base_disp);
                        copy_struct_rax_to_rcx (2);
                        if (program_uses_heap && sd != null && struct_has_string (sd))
                            ref_struct_at_rcx (sd, 0);
                        if (program_uses_heap && ce.ref_temp_slot >= 0) {
                            emitter.load_rcx_disp_to_rax (8);
                            emitter.store_local (ce.ref_temp_slot);
                        }
                        cleanup_expr_temps (ce.left);
                    }
                    emitter.bind (l_end);
                    emitter.lea_rax_rbp_disp (base_disp);
                    return;
                }
                bool ref_res = program_uses_heap && is_ref_type (res_t);
                var l_use_left = emitter.new_label ();
                var l_end = emitter.new_label ();
                gen_expr (ce.left);
                emitter.test_rax_rax ();
                emitter.branch (BranchKind.JNE, l_use_left);

                cleanup_expr_temps (ce.left);
                gen_expr (ce.right);
                if (ref_res) {
                    consume_ref_expr (ce.right);
                    if (ce.ref_temp_slot >= 0)
                        emitter.store_local (ce.ref_temp_slot);
                }
                emitter.push_rax ();
                push_depth++;
                cleanup_expr_temps (ce.right);
                emitter.pop_rax ();
                push_depth--;
                emitter.branch (BranchKind.JMP, l_end);

                emitter.bind (l_use_left);
                if (ref_res) {
                    consume_ref_expr (ce.left);
                    if (ce.ref_temp_slot >= 0)
                        emitter.store_local (ce.ref_temp_slot);
                }
                emitter.push_rax ();
                push_depth++;
                cleanup_expr_temps (ce.left);
                emitter.pop_rax ();
                push_depth--;
                emitter.bind (l_end);
            } else if (e is StructLiteral) {
                var lit = (StructLiteral) e;
                unowned var sd = program.find_struct (lit.struct_name);
                if (sd == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown struct '$(lit.struct_name)' at $(lit.line):$(lit.column)");
                var nslots = type_slots (ValaType.STRUCT, lit.struct_name);
                var base_disp = struct_base_disp (lit.temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                init_struct_at_rcx (sd, 0);
                for (int i = 0; i < lit.field_names.length; i++) {
                    unowned StructField? fld = null;
                    var off_slots = struct_field_offset_slots (sd, lit.field_names[i], out fld);
                    gen_expr (lit.field_values[i]);
                    if (fld.field_type == ValaType.STRUCT) {
                        if (expr_type (lit.field_values[i]) != ValaType.NULL) {
                            var fslots = type_slots (ValaType.STRUCT, fld.type_name);
                            emitter.lea_rcx_rbp_disp (base_disp + 8 * off_slots);
                            copy_struct_rax_to_rcx (fslots);
                        }
                    } else {
                        if (fld.field_type == ValaType.INT)
                            emit_int_narrow (fld.type_name);
                        emitter.store_rbp_disp (base_disp + 8 * off_slots);
                    }
                }
                emitter.lea_rax_rbp_disp (base_disp);
            } else if (e is VarRef) {
                var v = (VarRef) e;
                if (v.target_del_type != "") {
                    unowned var dd = program.find_delegate (v.target_del_type);
                    if (dd == null)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"unknown delegate type: $(v.target_del_type) at $(v.line):$(v.column)");
                    var f = resolve_call_target (v.name);
                    if (f == null)
                        throw new SemanticError.UNKNOWN_FUNCTION (
                            @"unknown function: $(v.name) at $(v.line):$(v.column)");
                    var base_disp = struct_base_disp (v.temp_slot, 2);
                    if (f.owner_class != "" && !f.is_static) {
                        load_this_slot ();
                        if (program_uses_heap) {
                            emitter.mov_rdi_rax ();
                            call_aligned ("__planc_ref");
                        }
                        if (v.ref_temp_slot >= 0)
                            emitter.store_local (v.ref_temp_slot);
                        emitter.store_rbp_disp (base_disp + 8);
                        bool need_thunk = (f.is_virtual || f.is_abstract || f.iface_slot >= 0);
                        string code_sym = need_thunk
                            ? ensure_free_delegate_thunk (f, dd, true, 1)
                            : f.name;
                        emitter.lea_rax_fn (code_sym);
                        emitter.store_rbp_disp (base_disp);
                        emitter.lea_rax_rbp_disp (base_disp);
                        return;
                    }
                    var thunk_sym = ensure_free_delegate_thunk (f, dd, false, 0);
                    emitter.lea_rax_fn (thunk_sym);
                    emitter.store_rbp_disp (base_disp);
                    emitter.xor_eax ();
                    emitter.store_rbp_disp (base_disp + 8);
                    emitter.lea_rax_rbp_disp (base_disp);
                    return;
                }
                var idx = lookup (v.name);
                if (idx >= 0) {
                    if (local_by_ref[idx]) {
                        emitter.load_local (local_slots[idx]);
                        if (local_types[idx] != ValaType.STRUCT)
                            emitter.load_rax_disp (0);
                    } else if (local_types[idx] == ValaType.STRUCT) {
                        var n = type_slots (ValaType.STRUCT, local_type_names[idx]);
                        emitter.lea_rax_rbp_disp (struct_base_disp (local_slots[idx], n));
                    } else {
                        emitter.load_local (local_slots[idx]);
                        if (local_is_weak[idx])
                            emit_load_weak (v.ref_temp_slot);
                    }
                    if (is_fp_type (local_types[idx]))
                        emitter.movq_xmm_rax (0);
                } else {
                    var gi = lookup_global (v.name);
                    if (gi >= 0) {
                        if (global_types[gi] == ValaType.STRUCT)
                            emitter.lea_rax_space (global_offsets[gi], global_spaces[gi]);
                        else
                            emitter.load_global (global_offsets[gi], global_spaces[gi]);
                        if (is_fp_type (global_types[gi]))
                            emitter.movq_xmm_rax (0);
                    } else if (static_field_global_of_this_class (v.name) >= 0) {
                        int sg = static_field_global_of_this_class (v.name);
                        if (global_types[sg] == ValaType.STRUCT)
                            emitter.lea_rax_space (global_offsets[sg], global_spaces[sg]);
                        else
                            emitter.load_global (global_offsets[sg], global_spaces[sg]);
                        if (is_fp_type (global_types[sg]))
                            emitter.movq_xmm_rax (0);
                    } else if (current_class != null) {
                        unowned var c_const = program.find_const (current_class.name, v.name);
                        if (c_const != null) {
                            if (c_const.const_type == ValaType.STRING) {
                                emitter.lea_rax_rip (emitter.add_string (c_const.str_value));
                            } else {
                                emitter.mov_rax_imm (c_const.int_value);
                                if (is_fp_type (c_const.const_type))
                                    emitter.movq_xmm_rax (0);
                            }
                            return;
                        }
                        if (!current.is_static) {
                            unowned ClassField? cf = null;
                            var fslot = class_field_offset_slots (current_class, v.name, out cf);
                            if (fslot >= 0 && cf != null) {
                                load_this_slot ();
                                if (cf.field_type == ValaType.STRUCT)
                                    emitter.add_rax_imm (class_field_base (current_class) + 8 * fslot);
                                else
                                    emitter.load_rax_disp (class_field_base (current_class) + 8 * fslot);
                                if (cf.is_weak)
                                    emit_load_weak (v.ref_temp_slot);
                                if (is_fp_type (cf.field_type))
                                    emitter.movq_xmm_rax (0);
                                return;
                            }
                        }
                        unowned var gm_cls = find_this_prop_getter (v.name);
                        if (gm_cls != null) {
                            emit_instance_call (null, false, true, gm_cls, new GenericArray<Expr> (), -1, v.ref_temp_slot);
                            return;
                        }
                        unowned var gc1 = program.find_const ("", v.name);
                        if (gc1 != null) {
                            if (gc1.const_type == ValaType.STRING) {
                                emitter.lea_rax_rip (emitter.add_string (gc1.str_value));
                            } else {
                                emitter.mov_rax_imm (gc1.int_value);
                                if (is_fp_type (gc1.const_type))
                                    emitter.movq_xmm_rax (0);
                            }
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    } else if (current_struct != null) {
                        unowned var s_const = program.find_const (current_struct.name, v.name);
                        if (s_const != null) {
                            if (s_const.const_type == ValaType.STRING) {
                                emitter.lea_rax_rip (emitter.add_string (s_const.str_value));
                            } else {
                                emitter.mov_rax_imm (s_const.int_value);
                                if (is_fp_type (s_const.const_type))
                                    emitter.movq_xmm_rax (0);
                            }
                            return;
                        }
                        if (!current.is_static) {
                            unowned StructField? sf = null;
                            var fslot = struct_field_offset_slots (current_struct, v.name, out sf);
                            if (fslot >= 0 && sf != null) {
                                var n = type_slots (ValaType.STRUCT, current_struct.name);
                                emitter.lea_rax_rbp_disp (struct_base_disp (local_slots[0], n));
                                if (sf.field_type == ValaType.STRUCT)
                                    emitter.add_rax_imm (8 * fslot);
                                else
                                    emitter.load_rax_disp (8 * fslot);
                                if (is_fp_type (sf.field_type))
                                    emitter.movq_xmm_rax (0);
                                return;
                            }
                        }
                        unowned var gm_str = find_this_prop_getter (v.name);
                        if (gm_str != null) {
                            emit_instance_call (null, false, true, gm_str, new GenericArray<Expr> (), -1, v.ref_temp_slot);
                            return;
                        }
                        unowned var gc2 = program.find_const ("", v.name);
                        if (gc2 != null) {
                            if (gc2.const_type == ValaType.STRING) {
                                emitter.lea_rax_rip (emitter.add_string (gc2.str_value));
                            } else {
                                emitter.mov_rax_imm (gc2.int_value);
                                if (is_fp_type (gc2.const_type))
                                    emitter.movq_xmm_rax (0);
                            }
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    } else if (current_enum != null) {
                        unowned var e_const = program.find_const (current_enum.name, v.name);
                        if (e_const != null) {
                            if (e_const.const_type == ValaType.STRING) {
                                emitter.lea_rax_rip (emitter.add_string (e_const.str_value));
                            } else {
                                emitter.mov_rax_imm (e_const.int_value);
                                if (is_fp_type (e_const.const_type))
                                    emitter.movq_xmm_rax (0);
                            }
                            return;
                        }
                        unowned var em = current_enum.find_member (v.name);
                        if (em != null) {
                            emitter.mov_rax_imm (em.value);
                            return;
                        }
                        unowned var gc3 = program.find_const ("", v.name);
                        if (gc3 != null) {
                            if (gc3.const_type == ValaType.STRING) {
                                emitter.lea_rax_rip (emitter.add_string (gc3.str_value));
                            } else {
                                emitter.mov_rax_imm (gc3.int_value);
                                if (is_fp_type (gc3.const_type))
                                    emitter.movq_xmm_rax (0);
                            }
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    } else {
                        unowned var g_const = program.find_const ("", v.name);
                        if (g_const != null) {
                            if (g_const.const_type == ValaType.STRING) {
                                emitter.lea_rax_rip (emitter.add_string (g_const.str_value));
                            } else {
                                emitter.mov_rax_imm (g_const.int_value);
                                if (is_fp_type (g_const.const_type))
                                    emitter.movq_xmm_rax (0);
                            }
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    }
                }
            } else if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                string ot_name = "";
                var ot = expr_type_full (u.operand, out ot_name);
                gen_expr (u.operand);
                if (u.op == "-" && is_fp_type (ot)) {
                    emitter.mov_rax_imm ((ot == ValaType.FLOAT) ? (int64) 0x80000000 : (int64) 0x8000000000000000);
                    emitter.movq_xmm_rax (1);
                    emitter.pxor_xmm0_xmm1 ();
                } else if (u.op == "-") {
                    emitter.neg_rax ();
                    if (is_unsigned_32 (ot_name))
                        emit_int_narrow (ot_name);
                } else if (u.op == "~") {
                    emitter.not_rax ();
                    if (is_unsigned_32 (ot_name))
                        emit_int_narrow (ot_name);
                } else {
                    emitter.test_rax_rax ();
                    emitter.setcc_al (0x94);
                    emitter.movzx_eax_al ();
                }
            } else if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                if (b.op == "&&") {
                    gen_and (b);
                    return;
                }
                if (b.op == "||") {
                    gen_or (b);
                    return;
                }
                string lt_name = "";
                string rt_name = "";
                var lt = expr_type_full (b.left, out lt_name);
                var rt = expr_type_full (b.right, out rt_name);
                if (is_fp_type (lt) || is_fp_type (rt)) {
                    var ct = (lt == ValaType.DOUBLE || rt == ValaType.DOUBLE) ? ValaType.DOUBLE : ValaType.FLOAT;
                    bool is_f32 = (ct == ValaType.FLOAT);
                    gen_expr (b.left);
                    emit_fp_coerce (lt, ct);
                    emitter.push_xmm0 ();
                    push_depth++;
                    gen_expr (b.right);
                    emit_fp_coerce (rt, ct);
                    emitter.movq_rax_xmm (0);
                    emitter.movq_xmm_rax (1);
                    emitter.pop_xmm0 ();
                    push_depth--;
                    if (b.op == "+" || b.op == "-" || b.op == "*" || b.op == "/") {
                        emit_fp_alu (b.op, is_f32);
                    } else if (b.op == "==") {
                        if (is_f32) emitter.ucomiss_xmm0_xmm1 (); else emitter.ucomisd_xmm0_xmm1 ();
                        emitter.setcc_al (0x94);
                        emitter.setcc_cl (0x9B);
                        emitter.and_al_cl ();
                        emitter.movzx_eax_al ();
                    } else if (b.op == "!=") {
                        if (is_f32) emitter.ucomiss_xmm0_xmm1 (); else emitter.ucomisd_xmm0_xmm1 ();
                        emitter.setcc_al (0x95);
                        emitter.setcc_cl (0x9A);
                        emitter.or_al_cl ();
                        emitter.movzx_eax_al ();
                    } else if (b.op == ">") {
                        if (is_f32) emitter.ucomiss_xmm0_xmm1 (); else emitter.ucomisd_xmm0_xmm1 ();
                        emitter.setcc_al (0x97);
                        emitter.movzx_eax_al ();
                    } else if (b.op == ">=") {
                        if (is_f32) emitter.ucomiss_xmm0_xmm1 (); else emitter.ucomisd_xmm0_xmm1 ();
                        emitter.setcc_al (0x93);
                        emitter.movzx_eax_al ();
                    } else if (b.op == "<") {
                        if (is_f32) emitter.ucomiss_xmm1_xmm0 (); else emitter.ucomisd_xmm1_xmm0 ();
                        emitter.setcc_al (0x97);
                        emitter.movzx_eax_al ();
                    } else { // "<="
                        if (is_f32) emitter.ucomiss_xmm1_xmm0 (); else emitter.ucomisd_xmm1_xmm0 ();
                        emitter.setcc_al (0x93);
                        emitter.movzx_eax_al ();
                    }
                    return;
                }
                if (b.op == "+" && expr_type (b.left) == ValaType.STRING) {
                    gen_expr (b.left);
                    emitter.push_rax ();
                    push_depth++;
                    gen_expr (b.right);
                    emitter.mov_rsi_rax ();
                    emitter.pop_reg (Reg.RDI);
                    push_depth--;
                    need_str_concat = true;
                    call_aligned ("__planc_str_concat");
                    if (e.ref_temp_slot >= 0)
                        emitter.store_local (e.ref_temp_slot);
                    return;
                }
                if ((b.op == "==" || b.op == "!=")
                    && ((is_delegate_type (program, lt, lt_name) && rt == ValaType.NULL)
                        || (is_delegate_type (program, rt, rt_name) && lt == ValaType.NULL))) {
                    gen_expr ((rt == ValaType.NULL) ? b.left : b.right);
                    emitter.load_rax_disp (0);
                    emitter.test_rax_rax ();
                    setcc (b.op);
                    return;
                }
                var is_str_cmp = (b.op == "==" || b.op == "!=")
                              && lt == ValaType.STRING
                              && rt == ValaType.STRING;
                gen_expr (b.left);
                emitter.push_rax ();
                push_depth++;
                gen_expr (b.right);
                emitter.mov_rcx_rax ();
                emitter.pop_rax ();
                push_depth--;
                if (is_str_cmp) {
                    emitter.mov_rdi_rax ();
                    emitter.mov_rsi_rcx ();
                    need_str_eq = true;
                    call_aligned ("__planc_str_eq");
                    if (b.op == "!=")
                        emitter.xor_rax_one ();
                    return;
                }
                string res_tn = promote_int_type (lt_name, rt_name);
                bool is_u = is_unsigned_int_type (res_tn);
                bool is_u32 = is_unsigned_32 (res_tn);
                switch (b.op) {
                    case "+":
                        emitter.add_rax_rcx ();
                        if (!is_u && check_overflow) { need_overflow_panic = true; emitter.branch (BranchKind.JO, overflow_panic_label); }
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "-":
                        emitter.sub_rax_rcx ();
                        if (!is_u && check_overflow) { need_overflow_panic = true; emitter.branch (BranchKind.JO, overflow_panic_label); }
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "*":
                        emitter.imul_rax_rcx ();
                        if (!is_u && check_overflow) { need_overflow_panic = true; emitter.branch (BranchKind.JO, overflow_panic_label); }
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "/":
                        if (is_u) {
                            emitter.xor_edx ();
                            emitter.div_rcx ();
                        } else {
                            emitter.cqo ();
                            emitter.idiv_rcx ();
                        }
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "%":
                        if (is_u) {
                            emitter.xor_edx ();
                            emitter.div_rcx ();
                        } else {
                            emitter.cqo ();
                            emitter.idiv_rcx ();
                        }
                        emitter.mov_rax_rdx ();
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "&":
                        emitter.and_rax_rcx ();
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "|":
                        emitter.or_rax_rcx ();
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "^":
                        emitter.xor_rax_rcx ();
                        if (is_u32) emit_int_narrow ("uint32");
                        break;
                    case "<<":
                        emitter.shl_rax_cl ();
                        if (is_unsigned_32 (lt_name)) emit_int_narrow ("uint32");
                        break;
                    case ">>":
                        if (is_unsigned_int_type (lt_name))
                            emitter.shr_rax_cl ();
                        else
                            emitter.sar_rax_cl ();
                        if (is_unsigned_32 (lt_name)) emit_int_narrow ("uint32");
                        break;
                    default:
                        emitter.cmp_rax_rcx ();
                        setcc (b.op, is_u);
                        break;
                }
            } else if (e is YieldExpr) {
                gen_yield_expr ((YieldExpr) e);
            } else if (e is CallExpr) {
                gen_call ((CallExpr) e);
            } else if (e is LambdaExpr) {
                var lam = (LambdaExpr) e;
                var base_disp = struct_base_disp (lam.temp_slot, 2);
                if (lam.captured_names.length == 0) {
                    emitter.lea_rax_fn (lam.synth_func_name);
                    emitter.store_rbp_disp (base_disp);
                    emitter.xor_eax ();
                    emitter.store_rbp_disp (base_disp + 8);
                    emitter.lea_rax_rbp_disp (base_disp);
                } else {
                    int ncap = lam.captured_names.length;
                    // Environment layout: 8 bytes header, refcount at +8,
                    // captures at +16 + 8*ci. The allocation must cover the
                    // header; sizing it 8*ncap overflows the arena.
                    emitter.mov_rdi_imm ((int64) 16 + 8 * ncap);
                    emitter.mov_esi_imm (1);
                    call_aligned ("__planc_alloc");
                    if (lam.ref_temp_slot >= 0)
                        emitter.store_local (lam.ref_temp_slot);
                    emitter.mov_rcx_rax ();
                    emitter.mov_rax_imm ((int64) lam.ref_cap_count);
                    emitter.store_rcx_disp_rax (8);

                    for (int ci = 0; ci < ncap; ci++) {
                        if (lam.captured_names[ci] == "this")
                            load_this_slot ();
                        else
                            emitter.load_local (local_slots[lookup (lam.captured_names[ci])]);
                        if (program_uses_heap && is_ref_type (lam.captured_types[ci])) {
                            emitter.mov_rdi_rax ();
                            call_aligned ("__planc_ref");
                        }
                        emitter.push_rax ();
                        emitter.load_local (lam.ref_temp_slot);
                        emitter.mov_rcx_rax ();
                        emitter.pop_rax ();
                        emitter.store_rcx_disp_rax (16 + 8 * ci);
                    }

                    emitter.lea_rax_fn (lam.synth_func_name);
                    emitter.store_rbp_disp (base_disp);
                    emitter.load_local (lam.ref_temp_slot);
                    emitter.store_rbp_disp (base_disp + 8);
                    emitter.lea_rax_rbp_disp (base_disp);
                }
            } else if (e is IncDecExpr) {
                var inc = (IncDecExpr) e;
                int delta = (inc.op == "++") ? 1 : -1;
                if (inc.target is IndexExpr) {
                    var ix = (IndexExpr) inc.target;
                    string tt_name = "";
                    var tt = expr_type_full (ix.target, out tt_name);
                    bool is_signed_b = false;
                    if (tt == ValaType.ARRAY && is_byte_array_type (tt_name, out is_signed_b)) {
                        gen_expr (ix.target);
                        emit_null_check_if_nullable (tt, tt_name);
                        emitter.push_rax ();
                        push_depth++;
                        gen_expr (ix.index);
                        emitter.mov_rcx_rax ();
                        emitter.pop_rax ();
                        push_depth--;
                        if (bounds_check) {
                            need_bounds_panic = true;
                            emitter.cmp_rcx_rax_len ();
                            emitter.branch (BranchKind.JAE, bounds_panic_label);
                        }
                        emitter.lea_rax_rax_rcx_1_16 ();
                        emitter.mov_rdx_rax ();
                        emitter.load_rdx_byte_to_zx_rax ();
                        if (is_signed_b)
                            emitter.sign_extend_rax (8);
                        if (!inc.is_prefix) {
                            emitter.push_rax ();
                            push_depth++;
                        }
                        emitter.add_rax_imm (delta);
                        emitter.mov_rcx_rdx ();
                        emitter.store_rcx_disp_byte_al (0);
                        if (!inc.is_prefix) {
                            emitter.pop_rax ();
                            push_depth--;
                        } else {
                            emitter.load_rdx_byte_to_zx_rax ();
                            if (is_signed_b)
                                emitter.sign_extend_rax (8);
                        }
                        return;
                    }
                }
                ValaType lt;
                string lt_name;
                gen_lvalue_addr (inc.target, out lt, out lt_name);
                emitter.mov_rcx_rax ();
                emitter.load_rcx_disp_to_rax (0);
                if (!inc.is_prefix) {
                    emitter.push_rax ();
                    push_depth++;
                }
                emitter.add_rax_imm (delta);
                if (lt == ValaType.INT)
                    emit_int_narrow (lt_name);
                emitter.store_rcx_disp_rax (0);
                if (!inc.is_prefix) {
                    emitter.pop_rax ();
                    push_depth--;
                }
            } else {
                Host.panic ("expression not supported");
            }
        }

        private void gen_and (BinaryExpr b) throws SemanticError {
            var l_false = emitter.new_label ();
            var l_end = emitter.new_label ();
            gen_expr (b.left);
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JE, l_false);
            var snap = clone_non_null ();
            var nn_rhs = new GenericArray<string> ();
            collect_non_null_when (b.left, true, nn_rhs);
            add_all_non_null (nn_rhs);
            gen_expr (b.right);
            restore_non_null (snap);
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JE, l_false);
            emitter.mov_rax_imm (1);
            emitter.branch (BranchKind.JMP, l_end);
            emitter.bind (l_false);
            emitter.xor_eax ();
            emitter.bind (l_end);
        }

        private void gen_or (BinaryExpr b) throws SemanticError {
            var l_true = emitter.new_label ();
            var l_end = emitter.new_label ();
            gen_expr (b.left);
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JNE, l_true);
            var snap = clone_non_null ();
            var nn_rhs = new GenericArray<string> ();
            collect_non_null_when (b.left, false, nn_rhs);
            add_all_non_null (nn_rhs);
            gen_expr (b.right);
            restore_non_null (snap);
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JNE, l_true);
            emitter.xor_eax ();
            emitter.branch (BranchKind.JMP, l_end);
            emitter.bind (l_true);
            emitter.mov_rax_imm (1);
            emitter.bind (l_end);
        }

        private void gen_builtin_method_call (MethodCallExpr mc, string kind) throws SemanticError {
            if (kind == "int_parse") {
                string an = "";
                expr_type_full (mc.args[0], out an);
                gen_expr (mc.args[0]);
                emit_null_check_if_nullable (ValaType.STRING, an);
                emitter.mov_rdi_rax ();
                need_str_to_int = true;
                call_aligned ("__planc_str_to_int");
                return;
            }
            if (kind == "float_parse" || kind == "double_parse") {
                string an = "";
                expr_type_full (mc.args[0], out an);
                gen_expr (mc.args[0]);
                emit_null_check_if_nullable (ValaType.STRING, an);
                emitter.mov_rdi_rax ();
                need_str_to_double = true;
                call_aligned ("__planc_str_to_double");
                if (kind == "float_parse")
                    emitter.cvtsd2ss_xmm0_xmm0 ();
                return;
            }
            if (kind == "int_to_string") {
                if (mc.target == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'to_string()' requires a receiver at $(mc.line):$(mc.column)");
                string rtn = "";
                expr_type_full (mc.target, out rtn);
                gen_expr (mc.target);
                emitter.mov_rdi_rax ();
                if (is_unsigned_int_type (rtn)) {
                    need_uint_to_str = true;
                    call_aligned ("__planc_uint_to_str");
                } else {
                    need_int_to_str = true;
                    call_aligned ("__planc_int_to_str");
                }
                if (program_uses_heap && mc.ref_temp_slot >= 0)
                    emitter.store_local (mc.ref_temp_slot);
                return;
            }
            if (kind == "float_to_string" || kind == "double_to_string") {
                if (mc.target == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'to_string()' requires a receiver at $(mc.line):$(mc.column)");
                gen_expr (mc.target);
                if (kind == "float_to_string")
                    emitter.cvtss2sd_xmm0_xmm0 ();
                need_double_to_str = true;
                call_aligned ("__planc_double_to_str");
                if (program_uses_heap && mc.ref_temp_slot >= 0)
                    emitter.store_local (mc.ref_temp_slot);
                return;
            }
            if (kind == "async_run") {
                need_async = true;
                emitter.mov_edi (1);
                call_aligned ("__planc_async_run");
                return;
            }
            if (kind == "async_run_parallel") {
                need_async = true;
                gen_expr (mc.args[0]);
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_async_run");
                return;
            }
            if (kind == "mutex_lock" || kind == "mutex_unlock" || kind == "chan_close") {
                need_sync = true;
                if (mc.target == null) return;
                gen_expr (mc.target);
                emitter.mov_rdi_rax ();
                if (kind == "mutex_lock") call_aligned ("__planc_mutex_lock");
                else if (kind == "mutex_unlock") call_aligned ("__planc_mutex_unlock");
                else call_aligned ("__planc_chan_close");
                return;
            }
            if (kind == "chan_send") {
                need_sync = true;
                if (mc.target == null) return;
                string tn = "";
                if (mc.target != null)
                    expr_type_full (mc.target, out tn);
                ValaType et = ValaType.INT;
                string etn = "";
                find_channel_elem (tn, out et, out etn);
                gen_expr (mc.target);
                emitter.push_rax ();
                push_depth++;
                gen_expr (mc.args[0]);
                if (is_fp_type (et)) {
                    string an = "";
                    var at = expr_type_full (mc.args[0], out an);
                    emit_fp_coerce (at, et);
                    emitter.movq_rax_xmm (0);
                }
                if (program_uses_heap && is_ref_type (et)) {
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_ref");
                }
                emitter.mov_rsi_rax ();
                emitter.pop_reg (Reg.RDI);
                push_depth--;
                call_aligned ("__planc_chan_send");
                return;
            }
            if (kind == "str_has_prefix" || kind == "str_has_suffix") {
                if (mc.target == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'$(mc.method_name)()' requires a string receiver at $(mc.line):$(mc.column)");
                string tn = "";
                if (mc.target != null)
                    expr_type_full (mc.target, out tn);
                gen_expr (mc.target);
                emit_null_check_if_nullable (ValaType.STRING, tn);
                emitter.push_rax ();
                push_depth++;
                string an = "";
                expr_type_full (mc.args[0], out an);
                gen_expr (mc.args[0]);
                emit_null_check_if_nullable (ValaType.STRING, an);
                emitter.mov_rsi_rax ();
                emitter.pop_reg (Reg.RDI);
                push_depth--;
                if (kind == "str_has_prefix") {
                    need_str_has_prefix = true;
                    call_aligned ("__planc_str_has_prefix");
                } else {
                    need_str_has_suffix = true;
                    call_aligned ("__planc_str_has_suffix");
                }
                return;
            }
            if (kind == "str_char_count" || kind == "str_validate") {
                if (mc.target == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'$(mc.method_name)()' requires a string receiver at $(mc.line):$(mc.column)");
                string tn = "";
                expr_type_full (mc.target, out tn);
                gen_expr (mc.target);
                emit_null_check_if_nullable (ValaType.STRING, tn);
                emitter.mov_rdi_rax ();
                if (kind == "str_char_count") {
                    need_utf8_char_count = true;
                    call_aligned ("__planc_utf8_char_count");
                } else {
                    need_utf8_validate = true;
                    call_aligned ("__planc_utf8_validate");
                }
                return;
            }
            if (kind == "str_get_char") {
                if (mc.target == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'get_char()' requires a string receiver at $(mc.line):$(mc.column)");
                string tn = "";
                expr_type_full (mc.target, out tn);
                gen_expr (mc.target);
                emit_null_check_if_nullable (ValaType.STRING, tn);
                if (mc.args.length == 0) {
                    emitter.mov_rdi_rax ();
                    emitter.mov_esi_imm (0);
                } else {
                    emitter.push_rax ();
                    push_depth++;
                    gen_expr (mc.args[0]);
                    emitter.mov_rsi_rax ();
                    emitter.pop_reg (Reg.RDI);
                    push_depth--;
                }
                need_utf8_get_char = true;
                call_aligned ("__planc_utf8_get_char");
                return;
            }
            if (kind == "str_index_of" || kind == "str_contains") {
                if (mc.target == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'$(mc.method_name)()' requires a string receiver at $(mc.line):$(mc.column)");
                string tn = "";
                expr_type_full (mc.target, out tn);
                gen_expr (mc.target);
                emit_null_check_if_nullable (ValaType.STRING, tn);
                emitter.push_rax ();
                push_depth++;
                string an = "";
                expr_type_full (mc.args[0], out an);
                gen_expr (mc.args[0]);
                emit_null_check_if_nullable (ValaType.STRING, an);
                if (mc.args.length == 2) {
                    emitter.push_rax ();
                    push_depth++;
                    gen_expr (mc.args[1]);
                    emitter.mov_rdx_rax ();
                    emitter.pop_reg (Reg.RSI);
                    push_depth--;
                } else {
                    emitter.mov_rsi_rax ();
                    emitter.xor_edx ();
                }
                emitter.pop_reg (Reg.RDI);
                push_depth--;
                need_str_index_of = true;
                call_aligned ("__planc_str_index_of");
                if (kind == "str_contains") {
                    // rax >= 0 -> 1 else 0
                    emitter.code.u8 (0x48); emitter.code.u8 (0x85); emitter.code.u8 (0xC0); // test rax, rax
                    emitter.code.u8 (0x0F); emitter.code.u8 (0x99); emitter.code.u8 (0xC0); // setns al
                    emitter.code.u8 (0x0F); emitter.code.u8 (0xB6); emitter.code.u8 (0xC0); // movzx eax, al
                }
                return;
            }
            // str_substring
            if (mc.target == null)
                throw new SemanticError.TYPE_MISMATCH (
                    @"'substring()' requires a string receiver at $(mc.line):$(mc.column)");
            string sn = "";
            expr_type_full (mc.target, out sn);
            gen_expr (mc.target);
            emit_null_check_if_nullable (ValaType.STRING, sn);
            emitter.push_rax ();
            push_depth++;
            gen_expr (mc.args[0]);
            emitter.push_rax ();
            push_depth++;
            if (mc.args.length == 1) {
                emitter.load_rsp (8);
                emitter.load_rax_disp (8);
                emitter.mov_rdx_rax ();
            } else {
                gen_expr (mc.args[1]);
                emitter.test_rax_rax ();
                var l_end = emitter.new_label ();
                var l_len = emitter.new_label ();
                emitter.branch (BranchKind.JGE, l_len);
                emitter.load_rsp (8);
                emitter.load_rax_disp (8);
                emitter.mov_rdx_rax ();
                emitter.branch (BranchKind.JMP, l_end);
                emitter.bind (l_len);
                emitter.mov_rcx_rax ();
                emitter.load_rsp (0);
                emitter.add_rax_rcx ();
                emitter.mov_rdx_rax ();
                emitter.bind (l_end);
            }
            emitter.pop_reg (Reg.RSI);
            push_depth--;
            emitter.pop_reg (Reg.RDI);
            push_depth--;
            need_str_slice = true;
            call_aligned ("__planc_str_slice");
            if (program_uses_heap && mc.ref_temp_slot >= 0)
                emitter.store_local (mc.ref_temp_slot);
        }

        private void gen_yield_expr (YieldExpr ye) throws SemanticError {
            if (!in_async_resume)
                throw new SemanticError.TYPE_MISMATCH (
                    @"'yield' is only valid inside an 'async' function at $(ye.line):$(ye.column)");
            if (push_depth > 0)
                throw new SemanticError.TYPE_MISMATCH (
                    @"'yield' cannot be used inside a compound expression at $(ye.line):$(ye.column)");
            int next_state = async_resume_labels.length;
            var l_resume = emitter.new_label ();
            async_resume_labels.add (l_resume);

            if (ye.value == null) {
                emitter.load_rbp_disp (-8);
                emitter.mov_rcx_rax ();
                emitter.mov_rax_imm ((int64) next_state);
                emitter.store_rcx_disp_rax (24);
                emitter.mov_rax_rcx ();
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_async_enqueue");
                emitter.leave ();
                emitter.ret ();
                emitter.bind (l_resume);
                emitter.xor_eax ();
                return;
            }

            string vt_name = "";
            var vt = expr_type_full (ye.value, out vt_name);
            ValaType inner_t = ValaType.VOID;
            string inner_name = "";
            if (vt != ValaType.CLASS || !parse_async_task_type_name (vt_name, out inner_t, out inner_name))
                throw new SemanticError.TYPE_MISMATCH (
                    @"'yield' expects an async task, got $(type_label (vt, vt_name)) at $(ye.line):$(ye.column)");

            int child_slot = cur_total_slots++;
            if (ye.value is MethodCallExpr) {
                var mc = (MethodCallExpr) ye.value;
                string bi_kind = "";
                ValaType bi_ret = ValaType.VOID;
                if (is_builtin_method_call (mc, out bi_kind, out bi_ret) && bi_kind == "chan_recv" && mc.target != null) {
                    need_sync = true;
                    var ch_tgt = mc.target;
                    gen_expr (ch_tgt);
                    if (is_owned_expr (ch_tgt)) {
                        consume_ref_expr (ch_tgt);
                    } else {
                        emitter.mov_rdi_rax ();
                        call_aligned ("__planc_ref");
                    }
                    emitter.store_local (child_slot);
                    cleanup_expr_temps (ch_tgt);

                    var l_try_recv = emitter.new_label ();
                    var l_got_recv = emitter.new_label ();
                    emitter.bind (l_try_recv);
                    emitter.load_local (child_slot);
                    emitter.mov_rdi_rax ();
                    emitter.load_rbp_disp (-8);
                    emitter.mov_rsi_rax ();
                    call_aligned ("__planc_chan_try_recv");
                    emitter.test_rax_rax ();
                    emitter.branch (BranchKind.JE, l_got_recv);

                    emitter.load_rbp_disp (-8);
                    emitter.mov_rcx_rax ();
                    emitter.mov_rax_imm ((int64) next_state);
                    emitter.store_rcx_disp_rax (24);
                    emitter.leave ();
                    emitter.ret ();

                    emitter.bind (l_resume);
                    emitter.branch (BranchKind.JMP, l_try_recv);

                    emitter.bind (l_got_recv);
                    emitter.push_reg (Reg.RDX);
                    emitter.load_local (child_slot);
                    emitter.zero_local (child_slot);
                    emitter.mov_rdi_rax ();
                    call_aligned ("__planc_unref");
                    emitter.pop_rax ();
                    if (program_uses_heap && ye.ref_temp_slot >= 0 && is_ref_type (inner_t))
                        emitter.store_local (ye.ref_temp_slot);
                    if (is_fp_type (inner_t))
                        emitter.movq_xmm_rax (0);
                    return;
                }
            }
            gen_expr (ye.value);
            if (is_owned_expr (ye.value)) {
                consume_ref_expr (ye.value);
            } else {
                emitter.mov_rdi_rax ();
                call_aligned ("__planc_ref");
            }
            emitter.store_local (child_slot);
            cleanup_expr_temps (ye.value);

            emitter.load_local (child_slot);
            emitter.mov_rdi_rax ();
            emitter.load_rbp_disp (-8);
            emitter.mov_rsi_rax ();
            call_aligned ("__planc_async_await");
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JE, l_resume);

            emitter.load_rbp_disp (-8);
            emitter.mov_rcx_rax ();
            emitter.mov_rax_imm ((int64) next_state);
            emitter.store_rcx_disp_rax (24);
            emitter.leave ();
            emitter.ret ();

            emitter.bind (l_resume);
            emitter.load_local (child_slot);
            emitter.zero_local (child_slot);
            emitter.push_rax ();
            emitter.load_rax_disp (48);
            emitter.test_rax_rax ();
            var l_no_err = emitter.new_label ();
            emitter.branch (BranchKind.JE, l_no_err);
            emitter.mov_rdx_rax ();
            emitter.pop_rax ();
            emitter.push_reg (Reg.RDX);
            emitter.mov_rdi_rax ();
            call_aligned ("__planc_unref");
            emitter.pop_reg (Reg.RDX);
            emit_post_call_error_check_flag (true);

            emitter.bind (l_no_err);
            emitter.pop_rax ();
            emitter.mov_rdi_rax ();
            emitter.load_rax_disp (40);
            emitter.push_rax ();
            call_aligned ("__planc_unref");
            emitter.pop_rax ();
            if (program_uses_heap && ye.ref_temp_slot >= 0 && is_ref_type (inner_t))
                emitter.store_local (ye.ref_temp_slot);
            if (is_fp_type (inner_t))
                emitter.movq_xmm_rax (0);
        }

        // A signal inherited from an interface has no fixed slot: ask the
        // object through the interface slot accessor, then build the address.
        // The object is read from [rsp + obj_disp]; the address ends in rax.
        private void emit_iface_signal_slot_addr (SignalDecl sd, int obj_disp) throws SemanticError {
            need_iface_lookup = true;
            emitter.load_rsp (obj_disp);
            emitter.mov_rdi_rax ();
            emitter.mov_rax_imm (sd.iface_id);
            call_aligned ("__planc_iface_lookup");     // rax = method table
            emitter.load_rax_disp (8 * sd.iface_slot);  // rax = slot accessor
            emitter.mov_rdx_rax ();
            emitter.load_rsp (obj_disp);
            emitter.mov_rdi_rax ();                     // rdi = object
            emitter.mov_rax_rdx ();                     // rax = accessor
            if (push_depth % 2 == 1)
                emitter.sub_rsp (8);
            emitter.call_rax ();                        // rax = slot index
            if (push_depth % 2 == 1)
                emitter.add_rsp (8);
            emitter.mov_rcx_rax ();
            emitter.load_rsp (obj_disp);
            emitter.lea_rax_rax_rcx_8_16 ();            // object + 8 * index + 16
        }

        private void emit_signal_emit (Expr obj_expr, SignalDecl sd, GenericArray<Expr> args)
                throws SemanticError {
            need_signal = true;
            unowned DelegateDecl? dd = program.find_delegate (sd.handler_delegate_name);
            if (dd == null)
                throw new SemanticError.UNKNOWN_FUNCTION (@"missing signal delegate '$(sd.handler_delegate_name)'");

            int nargs = args.length;
            int area_top = align16 (8 * (3 + nargs));
            emitter.sub_rsp (area_top);

            gen_expr (obj_expr);
            emitter.store_rsp (16);
            for (int i = 0; i < nargs; i++) {
                emit_call_arg_param (dd.params[1 + i], args[i]);
                emitter.store_rsp (24 + 8 * i);
            }
            emitter.xor_eax ();
            emitter.store_rsp (8);

            if (sd.default_handler != null) {
                bool[] d_reg;
                bool[] d_xmm;
                int[] d_rnum;
                int[] d_sidx;
                int d_s = 0;
                plan_call_abi (sd.default_handler.params, false, 1 + nargs, out d_reg, out d_xmm, out d_rnum, out d_sidx, out d_s);
                var d_depth = push_depth;
                var d_area = align16 (8 * d_s);
                if (d_s > 0 && d_depth % 2 == 1)
                    d_area += 8;
                if (d_area != 0)
                    emitter.sub_rsp (d_area);
                int d_pushed = 0;
                for (int idx = 0; idx < 1 + nargs; idx++) {
                    emitter.load_rsp (d_area + 8 * d_pushed + 16 + 8 * idx);
                    if (d_reg[idx]) {
                        emitter.push_rax ();
                        push_depth++;
                        d_pushed++;
                    } else {
                        emitter.store_rsp (8 * (d_pushed + d_sidx[idx]));
                    }
                }
                pop_call_regs (1 + nargs, d_reg, d_xmm, d_rnum);
                if (d_s == 0 && d_depth % 2 == 1)
                    emitter.sub_rsp (8);
                emitter.call_rel32 (sd.default_handler.name);
                if (d_s > 0)
                    emitter.add_rsp (d_area);
                else if (d_depth % 2 == 1)
                    emitter.add_rsp (8);
                if (is_fp_type (sd.return_type))
                    emitter.movq_rax_xmm (0);
                emitter.store_rsp (8);
            }

            if (sd.slot_index >= 0) {
                emitter.load_rsp (16);
                emitter.load_rax_disp (16 + 8 * sd.slot_index);
            } else {
                emit_iface_signal_slot_addr (sd, 16);
                emitter.load_rax_disp (0);
            }
            emitter.store_rsp (0);

            var l_sig_loop = emitter.new_label ();
            var l_sig_done = emitter.new_label ();
            emitter.bind (l_sig_loop);
            emitter.load_rsp (0);
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JE, l_sig_done);
            emitter.mov_rcx_rax ();
            emitter.load_rcx_disp_to_rax (16); // next_node
            emitter.store_rsp (0);

            emitter.load_rcx_disp_to_rax (32); // fn_ptr
            emitter.push_rax ();
            push_depth++;
            emitter.load_rcx_disp_to_rax (40); // env_ptr

            var total_args = 2 + nargs;
            bool[] is_reg;
            bool[] reg_is_xmm;
            int[] reg_num;
            int[] stack_idx;
            int s = 0;
            plan_call_abi (dd.params, true, total_args, out is_reg, out reg_is_xmm, out reg_num, out stack_idx, out s);
            var depth = push_depth;
            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            emitter.push_rax (); // #env (arg 0)
            push_depth++;
            int pushed_regs = 1;

            for (int idx = 1; idx < total_args; idx++) {
                emitter.load_rsp (area + 8 * pushed_regs + 8 + 16 + 8 * (idx - 1));
                if (is_reg[idx]) {
                    emitter.push_rax ();
                    push_depth++;
                    pushed_regs++;
                } else {
                    emitter.store_rsp (8 * (pushed_regs + stack_idx[idx]));
                }
            }

            pop_call_regs (total_args, is_reg, reg_is_xmm, reg_num);
            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);
            int fn_disp = (s > 0) ? area : ((depth % 2 == 1) ? 8 : 0);
            emitter.load_rsp (fn_disp);
            emitter.call_rax ();
            if (s > 0)
                emitter.add_rsp (area);
            else if (depth % 2 == 1)
                emitter.add_rsp (8);
            emitter.add_rsp (8); // discard fn_ptr
            push_depth--;
            if (is_fp_type (sd.return_type))
                emitter.movq_rax_xmm (0);
            emitter.store_rsp (8);
            emitter.branch (BranchKind.JMP, l_sig_loop);

            emitter.bind (l_sig_done);
            emitter.load_rsp (8);
            if (is_fp_type (sd.return_type))
                emitter.movq_xmm_rax (0);
            emitter.add_rsp (area_top);
        }

        private void gen_method_call (MethodCallExpr mc) throws SemanticError {
            string bi_kind = "";
            ValaType bi_ret = ValaType.VOID;
            if (is_builtin_method_call (mc, out bi_kind, out bi_ret)) {
                gen_builtin_method_call (mc, bi_kind);
                return;
            }
            Expr? sig_obj_c = null;
            unowned SignalDecl? sig_conn = resolve_signal_connect (mc, out sig_obj_c);
            if (sig_conn != null && sig_obj_c != null) {
                need_signal = true;
                gen_expr (sig_obj_c);
                if (sig_conn.slot_index >= 0) {
                    emitter.add_rax_imm (16 + 8 * sig_conn.slot_index);
                    emitter.push_rax ();
                    push_depth++;
                } else {
                    emitter.push_rax ();
                    push_depth++;
                    emit_iface_signal_slot_addr (sig_conn, 0);
                    emitter.store_rsp (0);
                }
                if (mc.method_name == "connect") {
                    gen_expr (mc.args[0]);
                    emitter.mov_rcx_rax ();
                    emitter.load_rcx_disp_to_rax (0);
                    emitter.mov_rsi_rax ();
                    emitter.load_rcx_disp_to_rax (8);
                    emitter.mov_rdx_rax ();
                    emitter.pop_reg (Reg.RDI);
                    push_depth--;
                    call_aligned ("__planc_sig_connect");
                } else {
                    gen_expr (mc.args[0]);
                    emitter.mov_rsi_rax ();
                    emitter.pop_reg (Reg.RDI);
                    push_depth--;
                    call_aligned ("__planc_sig_disconnect");
                }
                return;
            }
            Expr? begin_recv = null;
            var begin_fn = resolve_begin_call (mc, out begin_recv);
            if (begin_fn != null) {
                if (begin_fn.owner_class == "" || begin_fn.is_static) {
                    emit_static_call (begin_fn, mc.args, mc.temp_slot, mc.ref_temp_slot);
                } else {
                    Expr recv = (begin_recv != null) ? begin_recv : new VarRef () {
                        name = "this", line = mc.line, column = mc.column
                    };
                    emit_instance_call (recv, false, false, begin_fn, mc.args, mc.temp_slot, mc.ref_temp_slot);
                }
                return;
            }
            if (mc.target != null && !mc.is_base_call && mc.method_name != "begin"
                && mc.method_name != "connect" && mc.method_name != "disconnect") {
                unowned var md = resolve_member_delegate (mc.target, mc.method_name);
                if (md != null) {
                    Expr del_expr = (mc.method_name == "")
                        ? mc.target
                        : (Expr) new MemberAccessExpr () {
                            target = mc.target,
                            member = mc.method_name,
                            line = mc.line,
                            column = mc.column
                        };
                    emit_delegate_call (del_expr, md, mc.args, mc.temp_slot, mc.ref_temp_slot);
                    return;
                }
            }
            var m = resolve_method_call_fn (mc);
            if (m == null) {
                Expr? sig_obj_e = null;
                unowned SignalDecl? sd_e = resolve_signal_access (mc.target, mc.method_name, out sig_obj_e);
                if (sd_e != null && sig_obj_e != null) {
                    emit_signal_emit (sig_obj_e, sd_e, mc.args);
                    return;
                }
                Host.panic (@"unchecked method '$(mc.method_name)'");
                return;
            }
            if (m.is_static) {
                emit_static_call (m, mc.args, mc.temp_slot, mc.ref_temp_slot);
                return;
            }
            emit_instance_call (mc.target, mc.is_base_call, mc.is_base_call,
                                m, mc.args, mc.temp_slot, mc.ref_temp_slot);
        }

        private void emit_call_arg_param (Param p, Expr arg) throws SemanticError {
            if (p.is_ref || p.is_out) {
                ValaType lt;
                string lt_name;
                gen_lvalue_addr (arg, out lt, out lt_name);
                if (arg is VarRef && is_nullable_type (p.param_type, p.type_name))
                    remove_non_null (((VarRef) arg).name);
            } else if (is_fp_type (p.param_type)) {
                var at = expr_type (arg);
                gen_expr (arg);
                emit_fp_coerce (at, p.param_type);
                emitter.movq_rax_xmm (0);
            } else if (p.param_type == ValaType.STRUCT && expr_type (arg) == ValaType.NULL) {
                emitter.lea_rax_space (null_delegate_bss_offset, PatchSpace.BSS);
            } else {
                gen_expr (arg);
                if (p.param_type == ValaType.INT)
                    emit_int_narrow (p.type_name);
            }
        }

        private void emit_call_arg (Function fn, int param_idx, Expr arg) throws SemanticError {
            emit_call_arg_param (fn.params[param_idx], arg);
        }

        private void plan_call_abi (GenericArray<Param> plist, bool has_extra_gpr0, int total_args,
                                    out bool[] is_reg, out bool[] reg_is_xmm,
                                    out int[] reg_num, out int[] stack_idx, out int stack_count) {
            is_reg = new bool[total_args];
            reg_is_xmm = new bool[total_args];
            reg_num = new int[total_args];
            stack_idx = new int[total_args];
            int gpr = 0;
            int xmm = 0;
            stack_count = 0;
            for (int i = 0; i < total_args; i++) {
                bool is_fp = false;
                if (!(has_extra_gpr0 && i == 0)) {
                    var p = plist[has_extra_gpr0 ? (i - 1) : i];
                    is_fp = !(p.is_ref || p.is_out) && is_fp_type (p.param_type);
                }
                if (is_fp && xmm < 8) {
                    is_reg[i] = true;
                    reg_is_xmm[i] = true;
                    reg_num[i] = xmm++;
                } else if (!is_fp && gpr < NUM_ARG_REGS) {
                    is_reg[i] = true;
                    reg_is_xmm[i] = false;
                    reg_num[i] = gpr++;
                } else {
                    is_reg[i] = false;
                    stack_idx[i] = stack_count++;
                }
            }
        }

        private void pop_call_regs (int total_args, bool[] is_reg, bool[] reg_is_xmm, int[] reg_num) {
            int popped = 0;
            for (int i = total_args - 1; i >= 0; i--) {
                if (!is_reg[i])
                    continue;
                if (reg_is_xmm[i]) {
                    emitter.pop_rax ();
                    emitter.movq_xmm_rax (reg_num[i]);
                } else {
                    emitter.pop_reg (arg_reg (reg_num[i]));
                }
                popped++;
            }
            push_depth -= popped;
        }

        private void emit_instance_call_from_slot (int obj_slot, Function m, GenericArray<Expr> args)
                throws SemanticError {
            var total_args = 1 + args.length;
            bool[] is_reg;
            bool[] reg_is_xmm;
            int[] reg_num;
            int[] stack_idx;
            int s = 0;
            plan_call_abi (m.params, false, total_args, out is_reg, out reg_is_xmm, out reg_num, out stack_idx, out s);
            var depth = push_depth;

            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            emitter.load_local (obj_slot);
            emitter.push_rax ();
            push_depth++;
            int pushed_regs = 1;
            for (int i = 0; i < args.length; i++) {
                int idx = i + 1;
                emit_call_arg (m, i + 1, args[i]);
                if (is_reg[idx]) {
                    emitter.push_rax ();
                    push_depth++;
                    pushed_regs++;
                } else {
                    emitter.store_rsp (8 * (pushed_regs + stack_idx[idx]));
                }
            }
            pop_call_regs (total_args, is_reg, reg_is_xmm, reg_num);

            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);
            if (m.vtable_slot >= 0) {
                emitter.load_rdi_disp_to_rax (8);
                emitter.call_rax_disp (24 + 8 * m.vtable_slot);
            } else if (m.iface_slot >= 0) {
                need_iface_lookup = true;
                emitter.mov_rax_imm (m.iface_id);
                emitter.call_rel32 ("__planc_iface_lookup");
                emitter.call_rax_disp (8 * m.iface_slot);
            } else {
                emitter.call_rel32 (m.name);
            }
            if (s > 0)
                emitter.add_rsp (area);
            else if (depth % 2 == 1)
                emitter.add_rsp (8);
            emit_post_call_error_check (m);
        }

        private void emit_instance_call (Expr? target_expr, bool is_base, bool target_is_this,
                                         Function m, GenericArray<Expr> args,
                                         int struct_temp_slot, int ref_temp_slot)
                throws SemanticError {
            var total_args = 1 + args.length;
            bool[] is_reg;
            bool[] reg_is_xmm;
            int[] reg_num;
            int[] stack_idx;
            int s = 0;
            plan_call_abi (m.params, false, total_args, out is_reg, out reg_is_xmm, out reg_num, out stack_idx, out s);
            var depth = push_depth;

            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            if (target_is_this) {
                if (local_types[0] == ValaType.STRUCT)
                    emitter.lea_rax_rbp_disp (struct_base_disp (local_slots[0], type_slots (ValaType.STRUCT, local_type_names[0])));
                else
                    load_this_slot ();
            } else {
                if (target_expr == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"method '$(m.name)' requires an instance target at $(m.line):$(m.column)");
                string tt_name = "";
                var tt = expr_type_full (target_expr, out tt_name);
                gen_expr (target_expr);
                emit_null_check_if_nullable (tt, tt_name);
            }
            emitter.push_rax ();
            push_depth++;
            int pushed_regs = 1;

            for (int i = 0; i < args.length; i++) {
                int idx = i + 1;
                emit_call_arg (m, i + 1, args[i]);
                if (is_reg[idx]) {
                    emitter.push_rax ();
                    push_depth++;
                    pushed_regs++;
                } else {
                    emitter.store_rsp (8 * (pushed_regs + stack_idx[idx]));
                }
            }

            pop_call_regs (total_args, is_reg, reg_is_xmm, reg_num);

            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);

            if (!is_base && m.vtable_slot >= 0) {
                emitter.load_rdi_disp_to_rax (8);
                emitter.call_rax_disp (24 + 8 * m.vtable_slot);
            } else if (!is_base && m.iface_slot >= 0) {
                need_iface_lookup = true;
                emitter.mov_rax_imm (m.iface_id);
                emitter.call_rel32 ("__planc_iface_lookup");
                emitter.call_rax_disp (8 * m.iface_slot);
            } else {
                emitter.call_rel32 (m.name);
            }

            if (s > 0) {
                emitter.add_rsp (area);
            } else if (depth % 2 == 1) {
                emitter.add_rsp (8);
            }

            if (!m.is_async)
                emit_post_call_error_check (m);

            if (!m.is_async && m.return_type == ValaType.STRUCT && struct_temp_slot >= 0) {
                var nslots = type_slots (ValaType.STRUCT, m.return_type_name);
                var base_disp = struct_base_disp (struct_temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                copy_struct_rax_to_rcx (nslots);
                if (program_uses_heap && ref_temp_slot >= 0 && is_delegate_type (program, m.return_type, m.return_type_name)) {
                    emitter.load_rcx_disp_to_rax (8);
                    emitter.store_local (ref_temp_slot);
                }
                emitter.mov_rax_rcx ();
            } else if (program_uses_heap && (m.is_async || is_ref_type (m.return_type)) && ref_temp_slot >= 0) {
                emitter.store_local (ref_temp_slot);
            }
        }

        private void gen_host_intrinsic (CallExpr e) throws SemanticError {
            if (e.callee == "__planc_host_eprint") {
                string an = "";
                expr_type_full (e.args[0], out an);
                gen_expr (e.args[0]);
                emit_null_check_if_nullable (ValaType.STRING, an);
                emitter.mov_rdi_rax ();
                need_eprint = true;
                call_aligned ("__planc_eprint");
                return;
            }
            if (e.callee == "__planc_host_chmod") {
                string an = "";
                expr_type_full (e.args[0], out an);
                gen_expr (e.args[0]);
                emit_null_check_if_nullable (ValaType.STRING, an);
                emitter.push_rax ();
                push_depth++;
                gen_expr (e.args[1]);
                emitter.mov_rsi_rax ();
                emitter.pop_reg (Reg.RDI);
                push_depth--;
                need_chmod = true;
                call_aligned ("__planc_chmod");
                return;
            }
            if (e.callee == "__planc_host_bytes_to_str") {
                string an = "";
                expr_type_full (e.args[0], out an);
                gen_expr (e.args[0]);
                emit_null_check_if_nullable (ValaType.ARRAY, an);
                emitter.push_rax ();
                push_depth++;
                gen_expr (e.args[1]);
                emitter.mov_rsi_rax ();
                emitter.pop_reg (Reg.RDI);
                push_depth--;
                need_bytes_to_str = true;
                call_aligned ("__planc_bytes_to_str");
                if (program_uses_heap && e.ref_temp_slot >= 0)
                    emitter.store_local (e.ref_temp_slot);
                return;
            }
            if (e.callee == "__planc_host_read_file") {
                string an = "";
                expr_type_full (e.args[0], out an);
                gen_expr (e.args[0]);
                emit_null_check_if_nullable (ValaType.STRING, an);
                emitter.mov_rdi_rax ();
                need_read_file = true;
                call_aligned ("__planc_read_file");
                emit_post_call_error_check_flag (true);
                if (program_uses_heap && e.ref_temp_slot >= 0)
                    emitter.store_local (e.ref_temp_slot);
                return;
            }
            // __planc_host_write_file
            string w0n = "";
            expr_type_full (e.args[0], out w0n);
            gen_expr (e.args[0]);
            emit_null_check_if_nullable (ValaType.STRING, w0n);
            emitter.push_rax ();
            push_depth++;
            string w1n = "";
            expr_type_full (e.args[1], out w1n);
            gen_expr (e.args[1]);
            emit_null_check_if_nullable (ValaType.ARRAY, w1n);
            emitter.mov_rsi_rax ();
            emitter.pop_reg (Reg.RDI);
            push_depth--;
            need_write_file = true;
            call_aligned ("__planc_write_file");
            emit_post_call_error_check_flag (true);
        }

        private void gen_planc_hash (Expr arg) throws SemanticError {
            string atn;
            ValaType at = expr_type_full (arg, out atn);
            gen_expr (arg);
            if (at == ValaType.STRING)
                emitter.emit_hash_str ();
            else
                emitter.emit_hash_int64 ();
        }

        private void gen_call (CallExpr e) throws SemanticError {
            if (e.callee == "__planc_hash") {
                gen_planc_hash (e.args[0]);
                return;
            }
            if (is_host_intrinsic (e.callee)) {
                gen_host_intrinsic (e);
                return;
            }
            unowned DelegateDecl? dd = resolve_delegate_callee (e.callee);
            if (dd != null) {
                var del_expr = new VarRef () { name = e.callee, line = e.line, column = e.column };
                emit_delegate_call (del_expr, dd, e.args, e.temp_slot, e.ref_temp_slot);
                return;
            }
            var f = resolve_call_target (e.callee, e);
            if (f == null) {
                Expr? sig_obj_e = null;
                unowned SignalDecl? sd_e = resolve_signal_access (null, e.callee, out sig_obj_e);
                if (sd_e != null && sig_obj_e != null) {
                    emit_signal_emit (sig_obj_e, sd_e, e.args);
                    return;
                }
                Host.panic (@"unchecked callee $(e.callee)");
                return;
            }
            bool is_synth_init = f.name.has_prefix ("__planc_init_");
            if (f.owner_class != "" && !is_synth_init && !f.is_static) {
                emit_instance_call (null, false, true, f, e.args, e.temp_slot, e.ref_temp_slot);
                return;
            }
            emit_static_call (f, e.args, e.temp_slot, e.ref_temp_slot);
        }

        private void emit_delegate_call (Expr del_expr, DelegateDecl dd, GenericArray<Expr> args,
                                         int struct_temp_slot, int ref_temp_slot)
                throws SemanticError {
            string dt_name = "";
            var dt = expr_type_full (del_expr, out dt_name);
            gen_expr (del_expr);
            emitter.mov_rcx_rax ();
            emitter.load_rcx_disp_to_rax (0); // #code
            emit_null_check_if_nullable (dt, dt_name);
            emitter.push_rax ();
            push_depth++;
            emitter.load_rcx_disp_to_rax (8); // #env

            var total_args = 1 + args.length;
            bool[] is_reg;
            bool[] reg_is_xmm;
            int[] reg_num;
            int[] stack_idx;
            int s = 0;
            plan_call_abi (dd.params, true, total_args, out is_reg, out reg_is_xmm, out reg_num, out stack_idx, out s);
            var depth = push_depth;

            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            emitter.push_rax ();
            push_depth++;
            int pushed_regs = 1;

            for (int i = 0; i < args.length; i++) {
                int idx = i + 1;
                emit_call_arg_param (dd.params[i], args[i]);
                if (is_reg[idx]) {
                    emitter.push_rax ();
                    push_depth++;
                    pushed_regs++;
                } else {
                    emitter.store_rsp (8 * (pushed_regs + stack_idx[idx]));
                }
            }

            pop_call_regs (total_args, is_reg, reg_is_xmm, reg_num);

            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);

            int fn_disp = (s > 0) ? area : ((depth % 2 == 1) ? 8 : 0);
            emitter.load_rsp (fn_disp);
            emitter.call_rax ();

            if (s > 0)
                emitter.add_rsp (area);
            else if (depth % 2 == 1)
                emitter.add_rsp (8);

            emitter.add_rsp (8); // discard spilled #code without clobbering rax/rdx
            push_depth--;

            emit_post_call_error_check_flag (dd.throws_domains.length > 0);

            if (dd.return_type == ValaType.STRUCT && struct_temp_slot >= 0) {
                var nslots = type_slots (ValaType.STRUCT, dd.return_type_name);
                var base_disp = struct_base_disp (struct_temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                copy_struct_rax_to_rcx (nslots);
                if (program_uses_heap && ref_temp_slot >= 0 && is_delegate_type (program, dd.return_type, dd.return_type_name)) {
                    emitter.load_rcx_disp_to_rax (8);
                    emitter.store_local (ref_temp_slot);
                }
                emitter.mov_rax_rcx ();
            } else if (program_uses_heap && is_ref_type (dd.return_type) && ref_temp_slot >= 0) {
                emitter.store_local (ref_temp_slot);
            }
        }

        private void emit_static_call (Function f, GenericArray<Expr> args,
                                       int struct_temp_slot, int ref_temp_slot)
                throws SemanticError {
            var n = args.length;
            bool[] is_reg;
            bool[] reg_is_xmm;
            int[] reg_num;
            int[] stack_idx;
            int s = 0;
            plan_call_abi (f.params, false, n, out is_reg, out reg_is_xmm, out reg_num, out stack_idx, out s);
            var depth = push_depth;

            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            int pushed_regs = 0;
            for (int i = 0; i < n; i++) {
                emit_call_arg (f, i, args[i]);
                if (is_reg[i]) {
                    emitter.push_rax ();
                    push_depth++;
                    pushed_regs++;
                } else {
                    emitter.store_rsp (8 * (pushed_regs + stack_idx[i]));
                }
            }

            pop_call_regs (n, is_reg, reg_is_xmm, reg_num);

            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);

            emitter.call_rel32 (f.name);

            if (s > 0) {
                emitter.add_rsp (area);
            } else if (depth % 2 == 1) {
                emitter.add_rsp (8);
            }

            if (!f.is_async)
                emit_post_call_error_check (f);

            if (!f.is_async && f.return_type == ValaType.STRUCT && struct_temp_slot >= 0) {
                var nslots = type_slots (ValaType.STRUCT, f.return_type_name);
                var base_disp = struct_base_disp (struct_temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                copy_struct_rax_to_rcx (nslots);
                if (program_uses_heap && ref_temp_slot >= 0 && is_delegate_type (program, f.return_type, f.return_type_name)) {
                    emitter.load_rcx_disp_to_rax (8);
                    emitter.store_local (ref_temp_slot);
                }
                emitter.mov_rax_rcx ();
            } else if (program_uses_heap && (f.is_async || is_ref_type (f.return_type)) && ref_temp_slot >= 0) {
                emitter.store_local (ref_temp_slot);
            }
        }
    }
}
