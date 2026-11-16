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
        UNKNOWN_FUNCTION,
        UNKNOWN_MEMBER,
        WRONG_ARG_COUNT,
        VOID_IN_EXPRESSION,
        RETURN_MISMATCH,
        TYPE_MISMATCH,
        BAD_LOOP_CONTROL,
        BAD_MAIN
    }

    public class Codegen : Object {

        public Emitter emitter { get; private set; }
        public GenericArray<Symbol> symbols { get; private set; }
        public bool bounds_check { get; set; default = true; }
        public bool null_check { get; set; default = true; }
        public bool check_leaks { get; set; default = false; }

        private const uint32 SYS_EXIT = 60;

        private const Reg[] ARG_REGS = { Reg.RDI, Reg.RSI, Reg.RDX, Reg.RCX,
                                         Reg.R8, Reg.R9 };

        private Program program;
        private Function current;
        private ClassDecl? current_class = null;
        private StructDecl? current_struct = null;
        private EnumDecl? current_enum = null;
        private bool program_uses_heap = false;
        private int alloc_bss_offset = -1;
        private GenericArray<string> non_null_vars;

        // Per-function local symbol table.
        private GenericArray<string> locals;
        private GenericArray<ValaType> local_types;
        private GenericArray<string> local_type_names;
        private GenericArray<int> local_slots;
        private GenericArray<bool> local_active;
        private GenericArray<bool> local_by_ref;
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

        // Runtime intrinsics emitted on demand at the end of .text.
        private bool need_write_str = false;
        private bool need_str_eq = false;
        private bool need_write_int = false;
        private bool need_bounds_panic = false;
        private bool need_alloc = false;
        private bool need_ref = false;
        private bool need_unref = false;
        private bool need_str_concat = false;
        private bool need_str_slice = false;
        private bool need_int_to_str = false;
        private bool need_is_instance = false;
        private bool need_mem_panic = false;
        private bool need_null_panic = false;
        private bool need_cast_panic = false;
        private bool need_leak_panic = false;

        private Label bounds_panic_label;
        private Label mem_panic_label;
        private Label null_panic_label;
        private Label cast_panic_label;
        private Label leak_panic_label;

        public Codegen () {
            emitter = new Emitter ();
            symbols = new GenericArray<Symbol> ();
            non_null_vars = new GenericArray<string> ();
            locals = new GenericArray<string> ();
            local_types = new GenericArray<ValaType> ();
            local_type_names = new GenericArray<string> ();
            local_slots = new GenericArray<int> ();
            local_active = new GenericArray<bool> ();
            break_labels = new GenericArray<Label> ();
            continue_labels = new GenericArray<Label> ();
            break_scope_marks = new GenericArray<int> ();
            continue_scope_marks = new GenericArray<int> ();
            global_names = new GenericArray<string> ();
            global_types = new GenericArray<ValaType> ();
            global_type_names = new GenericArray<string> ();
            global_offsets = new GenericArray<int> ();
            global_spaces = new GenericArray<PatchSpace> ();
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
            prepare_classes ();

            var main = program.find ("main");
            if (main == null)
                error ("no main function");
            if (main.params.length != 0)
                throw new SemanticError.BAD_MAIN (
                    @"main takes no parameters at $(main.line):$(main.column)");
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

            program_uses_heap = check_leaks || scan_program_heap ();
            if (program_uses_heap) {
                alloc_bss_offset = emitter.add_bss_bytes (96);
                need_alloc = true;
                need_ref = true;
                need_unref = true;
                need_mem_panic = true;
            }

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

            register_globals ();

            foreach (var f in program.functions)
                generate_function (f);

            emit_start ();
            emit_runtime ();
        }

        private bool scan_program_heap () {
            if (program.classes.length > 0)
                return true;
            foreach (var g in program.globals) {
                if (g.var_type == ValaType.ARRAY || g.var_type == ValaType.CLASS || g.var_type == ValaType.ERROR)
                    return true;
            }
            foreach (var f in program.functions) {
                if (f.can_throw || f.return_type == ValaType.ARRAY || f.return_type == ValaType.ERROR)
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
            if (e is ArrayNewExpr || e is ArrayLiteralExpr || e is ClassNewExpr || e is SliceExpr)
                return true;
            if (e is NullLiteral)
                return false;
            if (e is TemplateExpr)
                return !is_static_template ((TemplateExpr) e);
            if (e is UnaryExpr)
                return scan_expr_heap (((UnaryExpr) e).operand);
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
                foreach (var a in ((CallExpr) e).args) {
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
                // Conservative: any string-typed function or variable in program
                foreach (var f in program.functions) {
                    if (f.return_type == ValaType.STRING)
                        return true;
                    foreach (var p in f.params) {
                        if (p.param_type == ValaType.STRING)
                            return true;
                    }
                }
                foreach (var g in program.globals) {
                    if (g.var_type == ValaType.STRING)
                        return true;
                }
                if (e is VarRef)
                    return true;
            }
            return false;
        }

        private void check_struct_cycles () throws SemanticError {
            var visiting = new GenericArray<string> ();
            var visited = new GenericArray<string> ();
            foreach (var sd in program.structs)
                visit_struct_cycle (sd, visiting, visited);
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
                if (fld.field_type == ValaType.STRUCT) {
                    unowned var sub = program.find_struct (fld.type_name);
                    if (sub != null)
                        visit_struct_cycle (sub, visiting, visited);
                }
            }
            visited.add (sd.name);
        }

        private int type_slots (ValaType t, string tname) {
            if (t == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tname);
                if (sd == null)
                    return 1;
                int total = 0;
                foreach (var fld in sd.fields)
                    total += type_slots (fld.field_type, fld.type_name);
                return total > 0 ? total : 1;
            }
            return 1;
        }

        private int struct_field_offset_slots (StructDecl sd, string fname, out unowned StructField? found) {
            int slot_off = 0;
            foreach (unowned var fld in sd.fields) {
                if (fld.name == fname) {
                    found = fld;
                    return slot_off;
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
                foreach (var m in sd.methods) {
                    m.method_name = m.name;
                    m.name = @"$(sd.name)__$(m.name)";
                    if (!m.is_static)
                        prepend_this_param_typed (m, ValaType.STRUCT, sd.name, false);
                    program.functions.add (m);
                }
            }
        }

        private void prepare_classes () throws SemanticError {
            if (program.classes.length == 0)
                return;

            var ordered = new GenericArray<ClassDecl> ();
            var visiting = new GenericArray<string> ();
            var visited = new GenericArray<string> ();
            foreach (var cd in program.classes)
                visit_class_order (cd, visiting, visited, ordered);

            foreach (var cd in ordered) {
                unowned ClassDecl? base_cd = (cd.base_name != "") ? program.find_class (cd.base_name) : null;
                cd.needs_finalizer = (cd.dtor != null) || (base_cd != null && base_cd.needs_finalizer);

                foreach (var fld in cd.fields) {
                    if (base_cd != null) {
                        unowned ClassField? dummy = null;
                        if (class_field_offset_slots (base_cd, fld.name, out dummy) >= 0)
                            throw new SemanticError.DUPLICATE_VARIABLE (
                                @"field '$(cd.name).$(fld.name)' shadows inherited field at $(fld.line):$(fld.column)");
                    }
                    if ((fld.field_type == ValaType.CLASS || fld.field_type == ValaType.ERROR)
                        && !is_nullable_type (fld.field_type, fld.type_name)) {
                        bool ok = (fld.init != null) || (cd.ctor != null && ctor_assigns_field (cd.ctor, fld.name));
                        if (!ok)
                            throw new SemanticError.TYPE_MISMATCH (
                                @"non-nullable field '$(cd.name).$(fld.name)' must be initialized at $(fld.line):$(fld.column)");
                    }
                    if (is_ref_type (fld.field_type)
                        || (fld.field_type == ValaType.STRUCT && struct_has_ref_name (fld.type_name))) {
                        cd.needs_finalizer = true;
                    }
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
                    if (anc_ctor != null) {
                        int anc_user_params = anc_ctor.params.length - 1;
                        if (!cd.ctor.has_base_call) {
                            if (anc_user_params == 0)
                                cd.ctor.has_base_call = true;
                            else
                                throw new SemanticError.WRONG_ARG_COUNT (
                                    @"constructor '$(cd.name)' must call ': base(...)' with $(anc_user_params) argument(s) at $(cd.ctor.line):$(cd.ctor.column)");
                        }
                    } else if (cd.ctor.has_base_call && cd.ctor.base_args.length > 0) {
                        throw new SemanticError.WRONG_ARG_COUNT (
                            @"base class of '$(cd.name)' has no constructor taking $(cd.ctor.base_args.length) argument(s) at $(cd.ctor.line):$(cd.ctor.column)");
                    }
                    cd.ctor.name = @"$(cd.name)____ctor";
                    prepend_this_param (cd.ctor, cd.name, true);
                    program.functions.add (cd.ctor);
                }

                // Emit .rodata vtable: [ +0 finalizer, +8 parent_vtable, +16+8k methods ].
                cd.vtable_rodata_offset = emitter.align_rodata_8 ();
                if (cd.needs_finalizer)
                    emitter.add_rodata_text_ptr (@"__planc_dtor_$(cd.name)");
                else
                    emitter.add_rodata_u64 (0);
                if (base_cd != null)
                    emitter.add_rodata_rodata_ptr (base_cd.vtable_rodata_offset);
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
                if (base_cd != null) {
                    var bc = new CallExpr () { callee = @"__planc_init_$(base_cd.name)" };
                    var tv = new VarRef () { name = "this", line = cd.line, column = cd.column };
                    bc.args.add (tv);
                    bc.line = cd.line;
                    bc.column = cd.column;
                    var es = new ExprStatement () { expr = bc, line = cd.line, column = cd.column };
                    init_fn.body.add (es);
                }
                foreach (var fld in cd.fields) {
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

        private bool ctor_assigns_field (Function ctor, string fname) {
            string alt = fname.has_prefix ("#prop_") ? fname.substring (6) : fname;
            foreach (var s in ctor.body) {
                if (stmt_assigns_field (s, fname) || (alt != fname && stmt_assigns_field (s, alt)))
                    return true;
            }
            return false;
        }

        private static bool stmt_assigns_field (Statement s, string fname) {
            if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                return fa.target is VarRef && ((VarRef) fa.target).name == "this" && fa.field_name == fname;
            }
            if (s is AssignStatement)
                return ((AssignStatement) s).name == fname;
            if (s is BlockStatement) {
                foreach (var inner in ((BlockStatement) s).statements) {
                    if (stmt_assigns_field (inner, fname))
                        return true;
                }
            }
            return false;
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
            unowned ClassDecl? cur = cd;
            while (cur != null) {
                unowned var m = cur.find_own_method (mname);
                if (m != null)
                    return m;
                cur = (cur.base_name != "") ? program.find_class (cur.base_name) : null;
            }
            return null;
        }

        private int class_total_field_slots (ClassDecl cd) {
            int n = 0;
            if (cd.base_name != "") {
                unowned var b = program.find_class (cd.base_name);
                if (b != null)
                    n += class_total_field_slots (b);
            }
            foreach (var fld in cd.fields)
                n += type_slots (fld.field_type, fld.type_name);
            return n;
        }

        private int class_field_offset_slots (ClassDecl cd, string fname, out unowned ClassField? found) {
            int base_off = 0;
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
                if (fld.name == fname) {
                    found = fld;
                    return off;
                }
                off += type_slots (fld.field_type, fld.type_name);
            }
            found = null;
            return -1;
        }

        private bool is_subclass_of (string child_name, string ancestor_name) {
            unowned ClassDecl? cur = program.find_class (child_name);
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
                    var offset = emitter.add_global (g.value, g.initialized);
                    global_offsets.add (offset);
                    global_spaces.add (g.initialized ? PatchSpace.DATA : PatchSpace.BSS);
                }
            }
        }

        private void emit_runtime () {
            if (need_str_concat || need_int_to_str || need_str_slice) {
                need_alloc = true;
                need_mem_panic = true;
            }
            if (need_str_slice && bounds_check)
                need_bounds_panic = true;
            if (need_alloc || need_ref || need_unref)
                need_mem_panic = true;

            if (need_write_str) {
                var start = emitter.here ();
                emitter.emit_rt_write_str ();
                symbols.add (new Symbol ("__planc_write_str", start, emitter.here () - start));
            }
            if (need_str_eq) {
                var start = emitter.here ();
                emitter.emit_rt_str_eq ();
                symbols.add (new Symbol ("__planc_str_eq", start, emitter.here () - start));
            }
            if (need_write_int) {
                var start = emitter.here ();
                emitter.emit_rt_write_int ();
                symbols.add (new Symbol ("__planc_write_int", start, emitter.here () - start));
            }
            if (need_alloc || need_ref || need_unref) {
                var start_alloc = emitter.here ();
                emitter.emit_rt_alloc (alloc_bss_offset, mem_panic_label);
                symbols.add (new Symbol ("__planc_alloc", start_alloc, emitter.here () - start_alloc));

                var start_ref = emitter.here ();
                emitter.emit_rt_ref (mem_panic_label);
                symbols.add (new Symbol ("__planc_ref", start_ref, emitter.here () - start_ref));

                var start_unref = emitter.here ();
                emitter.emit_rt_unref (alloc_bss_offset, mem_panic_label);
                symbols.add (new Symbol ("__planc_unref", start_unref, emitter.here () - start_unref));
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
            if (need_is_instance) {
                var start = emitter.here ();
                emitter.emit_rt_is_instance ();
                symbols.add (new Symbol ("__planc_is_instance", start, emitter.here () - start));
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
        }

        private void emit_panic_sym (bool needed, Label lbl, string sym_name, string msg) {
            if (!needed)
                return;
            var msg_off = emitter.add_string (msg);
            var start = emitter.here ();
            emitter.bind (lbl);
            emitter.emit_rt_panic (msg_off, msg.length);
            symbols.add (new Symbol (sym_name, start, emitter.here () - start));
        }

        private void emit_start () {
            var start = emitter.here ();

            // xor ebp, ebp                    31 ED
            emitter.code.u8 (0x31); emitter.code.u8 (0xED);
            // and rsp, -16                    48 83 E4 F0
            emitter.code.u8 (0x48); emitter.code.u8 (0x83);
            emitter.code.u8 (0xE4); emitter.code.u8 (0xF0);
            emitter.call_rel32 ("main");

            if (program_uses_heap) {
                emitter.mov_r12d_eax ();
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
            emitter.mov_eax (SYS_EXIT);
            emitter.syscall ();

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
            local_unmanaged = new GenericArray<bool> ();
            local_by_ref = new GenericArray<bool> ();
        }

        private void deactivate_from (int saved_len) {
            for (int i = saved_len; i < local_active.length; i++)
                local_active[i] = false;
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

        private void remove_non_null (string name) {
            for (int i = non_null_vars.length - 1; i >= 0; i--) {
                if (non_null_vars[i] == name)
                    non_null_vars.remove_index (i);
            }
        }

        private static bool match_null_cmp (Expr cond, string want_op, out string? vname) {
            vname = null;
            if (cond is UnaryExpr) {
                var u = (UnaryExpr) cond;
                if (u.op == "!") {
                    var flipped = (want_op == "!=") ? "==" : "!=";
                    return match_null_cmp (u.operand, flipped, out vname);
                }
                return false;
            }
            if (!(cond is BinaryExpr))
                return false;
            var b = (BinaryExpr) cond;
            if (b.op != want_op)
                return false;
            if (b.left is VarRef && b.right is NullLiteral) {
                vname = ((VarRef) b.left).name;
                return true;
            }
            if (b.left is NullLiteral && b.right is VarRef) {
                vname = ((VarRef) b.right).name;
                return true;
            }
            return false;
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

        private void finalize_if_narrowing (IfStatement i,
                                            GenericArray<string> snap,
                                            GenericArray<string> after_then,
                                            GenericArray<string>? after_else,
                                            string? nn_then,
                                            string? nn_else) {
            bool then_exits = stmt_always_exits (i.then_body);
            bool else_exits = (i.else_body != null) && stmt_always_exits (i.else_body);
            if (then_exits && i.else_body == null) {
                restore_non_null (snap);
                if (nn_else != null)
                    add_non_null (nn_else);
                return;
            }
            if (then_exits && i.else_body != null && !else_exits) {
                restore_non_null (after_else);
                if (nn_else != null)
                    add_non_null (nn_else);
                return;
            }
            if (else_exits && !then_exits) {
                restore_non_null (after_then);
                if (nn_then != null)
                    add_non_null (nn_then);
                return;
            }
            var other = (i.else_body != null && after_else != null) ? after_else : snap;
            non_null_vars = new GenericArray<string> ();
            foreach (var v in after_then) {
                if (list_contains (other, v) && (list_contains (snap, v) || v != nn_then))
                    add_non_null (v);
            }
        }

        private void push_local (string name, ValaType t, string tname, int slot,
                                 bool unmanaged, bool by_ref = false) {
            locals.add (name);
            local_types.add (t);
            local_type_names.add (tname);
            local_slots.add (slot);
            local_active.add (true);
            local_unmanaged.add (unmanaged);
            local_by_ref.add (by_ref);
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
            } else if (tt == ValaType.STRUCT) {
                unowned var sd = program.find_struct (tt_name);
                unowned var sm = (sd != null) ? sd.find_method (@"set_$(prop)") : null;
                if (sm != null && !sm.is_static && sm.params.length == 2)
                    return sm;
            }
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

        private void emit_post_call_error_check (Function callee) {
            if (!callee.can_throw)
                return;
            emitter.test_rdx_rdx ();
            var l_ok = emitter.new_label ();
            emitter.branch (BranchKind.JE, l_ok);
            emitter.store_local_reg (err_prop_slot, Reg.RDX);
            emit_error_jump ();
            emitter.bind (l_ok);
        }

        private int prepare_function (Function f, out int ref_temp_start) throws SemanticError {
            current = f;
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
            err_prop_slot = next_var_slot++;

            int struct_temp_slots = 0;
            int ref_temp_slots = 0;
            if (f.is_ctor && f.has_base_call) {
                foreach (var ba in f.base_args)
                    prepare_expr (ba, ref struct_temp_slots, ref ref_temp_slots);
            }
            foreach (var s in f.body)
                prepare_stmt (s, ref struct_temp_slots, ref ref_temp_slots);

            int var_end = next_var_slot;
            for (int k = 0; k < pending_struct_exprs.length; k++) {
                var se = pending_struct_exprs[k];
                int slot = var_end + pending_struct_rel_slots[k];
                if (se is StructLiteral) ((StructLiteral) se).temp_slot = slot;
                else if (se is CallExpr) ((CallExpr) se).temp_slot = slot;
                else if (se is MethodCallExpr) ((MethodCallExpr) se).temp_slot = slot;
                else if (se is MemberAccessExpr) ((MemberAccessExpr) se).temp_slot = slot;
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
                if (r.value != null)
                    prepare_expr (r.value, ref struct_temps, ref ref_temps);
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (lookup (d.name) >= 0)
                    throw new SemanticError.DUPLICATE_VARIABLE (
                        @"duplicate variable: $(d.name) at $(d.line):$(d.column)");
                if (d.init != null)
                    prepare_expr (d.init, ref struct_temps, ref ref_temps);
                ValaType vt;
                string vtname = "";
                if (d.infer_type) {
                    vt = expr_type_full (d.init, out vtname);
                    if (vt == ValaType.NULL)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot infer type of 'var $(d.name)' from 'null' at $(d.line):$(d.column)");
                } else {
                    vt = d.decl_type;
                    vtname = d.decl_type_name;
                    if (d.init != null) {
                        string itname = "";
                        var it = expr_type_full (d.init, out itname);
                        if (!type_compatible (vt, vtname, it, itname))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot initialize $(type_label (vt, vtname)) variable '$(d.name)' with $(type_label (it, itname)) at $(d.init.line):$(d.init.column)");
                    } else if ((vt == ValaType.CLASS || vt == ValaType.ERROR) && !is_nullable_type (vt, vtname)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"non-nullable $(type_label (vt, vtname)) variable '$(d.name)' must be initialized at $(d.line):$(d.column)");
                    }
                }
                var n = type_slots (vt, vtname);
                var slot = next_var_slot;
                next_var_slot += n;
                push_local (d.name, vt, vtname, slot, false);
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                prepare_expr (a.value, ref struct_temps, ref ref_temps);
                if (lookup (a.name) >= 0) {
                    string vtn = "";
                    var vt = expr_type_full (a.value, out vtn);
                    if (is_nullable_type (vt, vtn))
                        remove_non_null (a.name);
                } else if (lookup_global (a.name) < 0) {
                    unowned var sm = find_this_prop_setter (a.name);
                    if (sm != null && sm.can_throw)
                        check_domains_handled (sm.throws_domains, a.line, a.column);
                }
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                prepare_expr (fa.target, ref struct_temps, ref ref_temps);
                prepare_expr (fa.value, ref struct_temps, ref ref_temps);
                string tt_name = "";
                var tt = expr_type_full (fa.target, out tt_name);
                unowned var sm = find_prop_setter (tt, tt_name, fa.field_name);
                if (sm != null && sm.can_throw)
                    check_domains_handled (sm.throws_domains, fa.line, fa.column);
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                prepare_expr (ia.target, ref struct_temps, ref ref_temps);
                prepare_expr (ia.index, ref struct_temps, ref ref_temps);
                prepare_expr (ia.value, ref struct_temps, ref ref_temps);
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
                string? nn_then = null;
                string? nn_else = null;
                if (match_null_cmp (i.condition, "!=", out nn_then) && nn_then != null && lookup (nn_then) < 0)
                    nn_then = null;
                if (match_null_cmp (i.condition, "==", out nn_else) && nn_else != null && lookup (nn_else) < 0)
                    nn_else = null;

                if (nn_then != null)
                    add_non_null (nn_then);
                var saved_then = locals.length;
                prepare_stmt (i.then_body, ref struct_temps, ref ref_temps);
                deactivate_from (saved_then);
                var after_then = clone_non_null ();

                GenericArray<string>? after_else = null;
                if (i.else_body != null) {
                    restore_non_null (snap);
                    if (nn_else != null)
                        add_non_null (nn_else);
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
                string? nn_w = null;
                if (match_null_cmp (w.condition, "!=", out nn_w) && nn_w != null && lookup (nn_w) >= 0)
                    add_non_null (nn_w);
                var saved = locals.length;
                prepare_stmt (w.body, ref struct_temps, ref ref_temps);
                deactivate_from (saved);
                restore_non_null (before_w);
            } else if (s is ForStatement) {
                var fs = (ForStatement) s;
                var saved = locals.length;
                if (fs.init != null)
                    prepare_stmt (fs.init, ref struct_temps, ref ref_temps);
                if (fs.condition != null)
                    prepare_expr (fs.condition, ref struct_temps, ref ref_temps);
                if (fs.step != null)
                    prepare_stmt (fs.step, ref struct_temps, ref ref_temps);
                prepare_stmt (fs.body, ref struct_temps, ref ref_temps);
                deactivate_from (saved);
            } else if (s is ForeachStatement) {
                var fe = (ForeachStatement) s;
                prepare_expr (fe.collection, ref struct_temps, ref ref_temps);
                string ct_name = "";
                var ct = expr_type_full (fe.collection, out ct_name);
                if (ct != ValaType.ARRAY)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"foreach requires an array collection, got $(type_label (ct, ct_name)) at $(fe.collection.line):$(fe.collection.column)");
                ValaType et;
                string et_name;
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
                push_local (@"#fe_col_$(col_mark)", ValaType.ARRAY, strip_null (ct_name), cslot, false);

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
                prepare_expr (te.then_expr, ref struct_temps, ref ref_temps);
                prepare_expr (te.else_expr, ref struct_temps, ref ref_temps);
            } else if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                prepare_expr (ce.left, ref struct_temps, ref ref_temps);
                prepare_expr (ce.right, ref struct_temps, ref ref_temps);
            } else if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                prepare_expr (b.left, ref struct_temps, ref ref_temps);
                prepare_expr (b.right, ref struct_temps, ref ref_temps);
            } else if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                prepare_expr (ma.target, ref struct_temps, ref ref_temps);
                if (!(ma.target is VarRef && is_type_name (((VarRef) ma.target).name))) {
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
                        }
                    }
                }
            } else if (e is VarRef) {
                var vr = (VarRef) e;
                if (lookup (vr.name) < 0 && lookup_global (vr.name) < 0) {
                    unowned var gm = find_this_prop_getter (vr.name);
                    if (gm != null && gm.can_throw)
                        check_domains_handled (gm.throws_domains, vr.line, vr.column);
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
                foreach (var a in cn.args)
                    prepare_expr (a, ref struct_temps, ref ref_temps);
                foreach (var iv in cn.init_values)
                    prepare_expr (iv, ref struct_temps, ref ref_temps);
                unowned var cd = program.find_class (cn.class_name);
                if (cd != null && cd.ctor != null && cd.ctor.can_throw)
                    check_domains_handled (cd.ctor.throws_domains, cn.line, cn.column);
                if (cd != null) {
                    foreach (var iname in cn.init_names) {
                        unowned var sm = find_prop_setter (ValaType.CLASS, cd.name, iname);
                        if (sm != null && sm.can_throw)
                            check_domains_handled (sm.throws_domains, cn.line, cn.column);
                    }
                }
            } else if (e is TemplateExpr) {
                foreach (var part in ((TemplateExpr) e).parts)
                    prepare_expr (part, ref struct_temps, ref ref_temps);
            } else if (e is StructLiteral) {
                var lit = (StructLiteral) e;
                foreach (var fv in lit.field_values)
                    prepare_expr (fv, ref struct_temps, ref ref_temps);
                pending_struct_exprs.add (e);
                pending_struct_rel_slots.add (struct_temps);
                struct_temps += type_slots (ValaType.STRUCT, lit.struct_name);
            } else if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    prepare_expr (mc.target, ref struct_temps, ref ref_temps);
                foreach (var a in mc.args)
                    prepare_expr (a, ref struct_temps, ref ref_temps);
                unowned var m = resolve_method_call_fn (mc);
                if (m != null) {
                    if (m.can_throw)
                        check_domains_handled (m.throws_domains, mc.line, mc.column);
                    if (m.return_type == ValaType.STRUCT) {
                        pending_struct_exprs.add (e);
                        pending_struct_rel_slots.add (struct_temps);
                        struct_temps += type_slots (ValaType.STRUCT, m.return_type_name);
                    }
                }
            } else if (e is CallExpr) {
                var ce = (CallExpr) e;
                foreach (var a in ce.args)
                    prepare_expr (a, ref struct_temps, ref ref_temps);
                unowned var f = resolve_call_target (ce.callee);
                if (f != null) {
                    if (f.can_throw)
                        check_domains_handled (f.throws_domains, ce.line, ce.column);
                    if (f.return_type == ValaType.STRUCT) {
                        pending_struct_exprs.add (e);
                        pending_struct_rel_slots.add (struct_temps);
                        struct_temps += type_slots (ValaType.STRUCT, f.return_type_name);
                    }
                }
            }
            if (program_uses_heap && is_owned_expr (e)) {
                pending_ref_exprs.add (e);
                ref_temps++;
            }
        }

        private delegate void ExprVisitor (Expr e);

        private void walk_expr_children (Expr e, ExprVisitor fn) {
            if (e is UnaryExpr) {
                fn (((UnaryExpr) e).operand);
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
            }
        }

        private void generate_function (Function f) throws SemanticError {
            current = f;
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
            for (int s = ref_temp_start; s < total_slots; s++)
                emitter.zero_local (s);

            var param_raw_slots = new int[f.params.length];
            var param_final_slots = new int[f.params.length];
            for (int i = 0; i < f.params.length; i++) {
                var raw_slot = next_var_slot++;
                param_raw_slots[i] = raw_slot;
                if (i < ARG_REGS.length) {
                    emitter.store_local_reg (raw_slot, ARG_REGS[i]);
                } else {
                    emitter.load_rbp_disp (16 + 8 * (i - ARG_REGS.length));
                    emitter.store_local (raw_slot);
                }
                bool by_ref = f.params[i].is_ref || f.params[i].is_out;
                if (f.params[i].param_type == ValaType.STRUCT && !by_ref) {
                    var n = type_slots (ValaType.STRUCT, f.params[i].type_name);
                    param_final_slots[i] = next_var_slot;
                    next_var_slot += n;
                } else {
                    param_final_slots[i] = raw_slot;
                }
            }
            err_prop_slot = next_var_slot++;

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

            if (f.is_dtor && f.name.has_prefix ("__planc_dtor_")) {
                emit_class_finalizer_body ();
                emitter.leave ();
                emitter.ret ();
                symbols.add (new Symbol (f.name, start, emitter.here () - start));
                return;
            }

            if (f.is_ctor && f.has_base_call && current_class != null && current_class.base_name != "") {
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
            } else if (f.return_type == ValaType.ARRAY || f.return_type == ValaType.CLASS || f.return_type == ValaType.ERROR) {
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
                unowned ClassField? dummy = null;
                var slot_off = class_field_offset_slots (current_class, fld.name, out dummy);
                int byte_off = 16 + 8 * slot_off;
                if (is_ref_type (fld.field_type)) {
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
            if (current_class.base_name != "") {
                unowned var base_cd = program.find_class (current_class.base_name);
                if (base_cd != null && base_cd.needs_finalizer) {
                    emitter.load_local (0);
                    emitter.mov_rdi_rax ();
                    call_aligned (@"__planc_dtor_$(base_cd.name)");
                }
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
            if ((t == ValaType.ENUM || t == ValaType.STRUCT || t == ValaType.CLASS) && tname != "")
                return tname;
            return t.label ();
        }

        private static bool is_int_like (ValaType t) {
            return t == ValaType.INT || t == ValaType.BOOL;
        }

        private static bool is_ref_type (ValaType t) {
            return t == ValaType.STRING || t == ValaType.ARRAY
                || t == ValaType.CLASS || t == ValaType.ERROR;
        }

        private void parse_array_elem (string elem_name, out ValaType et, out string et_name) {
            var raw = strip_null (elem_name);
            et_name = "";
            if (raw == "int") et = ValaType.INT;
            else if (raw == "bool") et = ValaType.BOOL;
            else if (raw == "string") et = ValaType.STRING;
            else if (raw == "Error") et = ValaType.ERROR;
            else if (program.find_error_domain (raw) != null) {
                et = ValaType.ERROR;
                et_name = raw;
            } else if (program.find_class (raw) != null) {
                et = ValaType.CLASS;
                et_name = raw;
            } else {
                et = ValaType.ENUM;
                et_name = raw;
            }
        }

        private bool type_compatible (ValaType expected, string exp_name,
                                      ValaType actual, string act_name) {
            if (actual == ValaType.NULL)
                return is_nullable_type (expected, exp_name);
            if (expected == actual) {
                if (is_nullable_type (actual, act_name) && !is_nullable_type (expected, exp_name))
                    return false;
                var en = strip_null (exp_name);
                var an = strip_null (act_name);
                if (expected == ValaType.ENUM || expected == ValaType.STRUCT || expected == ValaType.ARRAY)
                    return en == an;
                if (expected == ValaType.CLASS)
                    return en == an || is_subclass_of (an, en);
                if (expected == ValaType.ERROR)
                    return en == "" || en == an;
                return true;
            }
            if (is_int_like (expected) && is_int_like (actual))
                return true;
            return false;
        }

        private bool eq_compatible (ValaType lt, string lt_name, ValaType rt, string rt_name) {
            if (lt == ValaType.STRUCT || rt == ValaType.STRUCT
                || lt == ValaType.ARRAY || rt == ValaType.ARRAY) {
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
                || program.find_struct (name) != null
                || program.find_enum (name) != null
                || program.find_error_domain (name) != null;
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
            if (lt == ValaType.NULL) {
                if (!is_ref_type (rt))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"incompatible branch types $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $line:$col");
                out_t = rt;
                out_name = make_nullable (rt, rt_name);
                return;
            }
            if (rt == ValaType.NULL) {
                if (!is_ref_type (lt))
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
            if (e is MethodCallExpr) {
                unowned var m = resolve_method_call_fn ((MethodCallExpr) e);
                return m != null && is_ref_type (m.return_type);
            }
            if (e is CallExpr) {
                unowned var f = resolve_call_target (((CallExpr) e).callee);
                return f != null && is_ref_type (f.return_type);
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                if (!(ma.target is VarRef && is_type_name (((VarRef) ma.target).name))) {
                    string tt_name = "";
                    var tt = expr_type_full (ma.target, out tt_name);
                    unowned var gm = find_prop_getter (tt, tt_name, ma.member);
                    if (gm != null)
                        return is_ref_type (gm.return_type);
                }
            }
            if (e is VarRef) {
                var vr = (VarRef) e;
                if (lookup (vr.name) < 0 && lookup_global (vr.name) < 0) {
                    unowned var gm = find_this_prop_getter (vr.name);
                    if (gm != null)
                        return is_ref_type (gm.return_type);
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
            var sb = new StringBuilder ();
            foreach (var part in t.parts)
                sb.append (((StringLiteral) part).value);
            return sb.str;
        }

        private unowned Function? resolve_call_target (string callee) {
            unowned var f = program.find (callee);
            if (f != null)
                return f;
            if (current_class != null)
                return find_class_method (current_class, callee);
            if (current_struct != null)
                return current_struct.find_method (callee);
            if (current_enum != null)
                return current_enum.find_method (callee);
            return null;
        }

        private unowned Function? resolve_method_call_fn (MethodCallExpr mc) throws SemanticError {
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
            if (m == null)
                throw new SemanticError.UNKNOWN_FUNCTION (
                    @"$(type_label (tt, tt_name)) has no method '$(mc.method_name)' at $(mc.line):$(mc.column)");
            if (m.is_static)
                throw new SemanticError.TYPE_MISMATCH (
                    @"static method '$(mc.method_name)' must be called on type '$(strip_null (tt_name))' at $(mc.line):$(mc.column)");
            return m;
        }

        private void check_arg_list (string desc, Function fn, int param_offset,
                                     GenericArray<Expr> args, int line, int col)
                throws SemanticError {
            int expected_count = fn.params.length - param_offset;
            if (expected_count != args.length)
                throw new SemanticError.WRONG_ARG_COUNT (
                    @"$(desc) expects $(expected_count) argument(s), got $(args.length) at $(line):$(col)");
            for (int i = 0; i < args.length; i++) {
                var p = fn.params[param_offset + i];
                string at_name = "";
                var at = expr_type_full (args[i], out at_name);
                var pt = p.param_type;
                var pt_name = p.type_name;
                if (p.is_ref || p.is_out) {
                    if (!(args[i] is VarRef || args[i] is MemberAccessExpr || args[i] is IndexExpr))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"argument $(i + 1) of '$(desc)' requires a variable or field lvalue for '$(p.is_out ? "out" : "ref")' at $(args[i].line):$(args[i].column)");
                    if (pt != at || strip_null (pt_name) != strip_null (at_name))
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

        private void check_ctor_args (Function ctor, GenericArray<Expr> args, int line, int col)
                throws SemanticError {
            check_arg_list (ctor.owner_class, ctor, 1, args, line, col);
        }

        private unowned Function check_call (CallExpr c, bool want_value) throws SemanticError {
            unowned Function? f = resolve_call_target (c.callee);
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
            if (want_value && f.is_void)
                throw new SemanticError.VOID_IN_EXPRESSION (
                    @"void function '$(c.callee)' cannot be used as a value at $(c.line):$(c.column)");
            check_arg_list (c.callee, f, param_off, c.args, c.line, c.column);
            return f;
        }

        private unowned Function check_method_call (MethodCallExpr mc, bool want_value) throws SemanticError {
            unowned Function? m = resolve_method_call_fn (mc);
            if (m == null)
                throw new SemanticError.UNKNOWN_FUNCTION (
                    @"unknown method '$(mc.method_name)' at $(mc.line):$(mc.column)");
            if (want_value && m.is_void)
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
            if (e is IntLiteral)
                return ValaType.INT;
            if (e is BoolLiteral)
                return ValaType.BOOL;
            if (e is StringLiteral)
                return ValaType.STRING;
            if (e is NullLiteral)
                return ValaType.NULL;
            if (e is TemplateExpr) {
                var t = (TemplateExpr) e;
                foreach (var part in t.parts) {
                    var pt = expr_type (part);
                    if (pt != ValaType.INT && pt != ValaType.BOOL
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
                tname = (an.elem_type == ValaType.ENUM || an.elem_type == ValaType.CLASS)
                    ? an.elem_type_name : an.elem_type.label ();
                return ValaType.ARRAY;
            }
            if (e is ArrayLiteralExpr) {
                var arr = (ArrayLiteralExpr) e;
                string et_name = "";
                var et = expr_type_full (arr.elements[0], out et_name);
                if (et == ValaType.VOID || et == ValaType.STRUCT || et == ValaType.ARRAY || et == ValaType.NULL)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unsupported array literal element type $(type_label (et, et_name)) at $(arr.elements[0].line):$(arr.elements[0].column)");
                if (et == ValaType.CLASS)
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
                    } else if (!type_compatible (et, et_name, cur, cur_name)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"array element $(i + 1) expects $(type_label (et, et_name)), got $(type_label (cur, cur_name)) at $(arr.elements[i].line):$(arr.elements[i].column)");
                    }
                    if (et == ValaType.BOOL && cur == ValaType.INT)
                        et = ValaType.INT;
                }
                arr.elem_type = et;
                arr.elem_type_name = et_name;
                tname = (et == ValaType.ENUM || et == ValaType.CLASS) ? et_name : et.label ();
                return ValaType.ARRAY;
            }
            if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                unowned var cd = program.find_class (cn.class_name);
                if (cd == null)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unknown class '$(cn.class_name)' at $(cn.line):$(cn.column)");
                if (cd.is_abstract)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"cannot instantiate abstract class '$(cd.name)' at $(cn.line):$(cn.column)");
                if (cd.ctor != null) {
                    check_ctor_args (cd.ctor, cn.args, cn.line, cn.column);
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
                if (tc.target_type == ValaType.ERROR) {
                    if (ot != ValaType.ERROR && ot != ValaType.NULL)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"'$(tc.op)' requires an Error value, got $(type_label (ot, ot_name)) at $(tc.line):$(tc.column)");
                    return ValaType.BOOL;
                }
                if (ot != ValaType.CLASS && ot != ValaType.NULL)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"'$(tc.op)' requires a class instance, got $(type_label (ot, ot_name)) at $(tc.line):$(tc.column)");
                if (tc.op == "is")
                    return ValaType.BOOL;
                if (tc.op == "as") {
                    tname = strip_null (tc.target_type_name) + "?";
                    return ValaType.CLASS;
                }
                tname = tc.target_type_name;
                return ValaType.CLASS;
            }
            if (e is MethodCallExpr) {
                unowned var m = check_method_call ((MethodCallExpr) e, true);
                tname = m.return_type_name;
                return m.return_type;
            }
            if (e is MemberAccessExpr) {
                var m = (MemberAccessExpr) e;
                if (m.target is VarRef) {
                    var vr = (VarRef) m.target;
                    if (is_type_name (vr.name)) {
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
                        tname = cf.type_name;
                        return cf.field_type;
                    }
                    unowned var gm = find_prop_getter (tt, tt_name, m.member);
                    if (gm != null) {
                        tname = gm.return_type_name;
                        return gm.return_type;
                    }
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"class '$(cname)' has no field or property '$(m.member)' at $(m.line):$(m.column)");
                }
                if (tt == ValaType.STRUCT) {
                    unowned var sd = program.find_struct (tt_name);
                    unowned StructField? fld = null;
                    if (sd != null && struct_field_offset_slots (sd, m.member, out fld) >= 0 && fld != null) {
                        tname = fld.type_name;
                        return fld.field_type;
                    }
                    unowned var gm = find_prop_getter (tt, tt_name, m.member);
                    if (gm != null) {
                        tname = gm.return_type_name;
                        return gm.return_type;
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
                if (tt != ValaType.STRING && tt != ValaType.ARRAY)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"indexing requires string or array, got $(type_label (tt, tt_name)) at $(ix.line):$(ix.column)");
                string it_name = "";
                var it = expr_type_full (ix.index, out it_name);
                if (!is_int_like (it))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"index must be int, got $(type_label (it, it_name)) at $(ix.index.line):$(ix.index.column)");
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
                string? nn_then = null;
                string? nn_else = null;
                if (match_null_cmp (te.condition, "!=", out nn_then) && nn_then != null && lookup (nn_then) < 0)
                    nn_then = null;
                if (match_null_cmp (te.condition, "==", out nn_else) && nn_else != null && lookup (nn_else) < 0)
                    nn_else = null;
                if (nn_then != null)
                    add_non_null (nn_then);
                string tt_name = "";
                var tt = expr_type_full (te.then_expr, out tt_name);
                restore_non_null (snap);
                if (nn_else != null)
                    add_non_null (nn_else);
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
                if (lt != ValaType.NULL && !is_ref_type (lt))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"operator '??' requires a reference type on left operand, got $(type_label (lt, lt_name)) at $(ce.line):$(ce.column)");
                string rt_name = "";
                var rt = expr_type_full (ce.right, out rt_name);
                if (lt == ValaType.NULL) {
                    if (rt != ValaType.NULL && !is_ref_type (rt))
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
                var slot = lookup (v.name);
                if (slot >= 0) {
                    tname = is_non_null_narrowed (v.name)
                        ? strip_null (local_type_names[slot])
                        : local_type_names[slot];
                    return local_types[slot];
                }
                var gi = lookup_global (v.name);
                if (gi >= 0) {
                    tname = global_type_names[gi];
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
                            tname = cf.type_name;
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
                            tname = sf.type_name;
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
                    tname = gm.return_type_name;
                    return gm.return_type;
                }
                unowned var g_const = program.find_const ("", v.name);
                if (g_const != null) {
                    tname = g_const.type_name;
                    return g_const.const_type;
                }
                throw new SemanticError.UNKNOWN_VARIABLE (
                    @"unknown variable: $(v.name) at $(v.line):$(v.column)");
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                string ot_name = "";
                var ot = expr_type_full (u.operand, out ot_name);
                if (!is_int_like (ot))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"unary '$(u.op)' requires int or bool, got $(type_label (ot, ot_name)) at $(u.line):$(u.column)");
                return (u.op == "!") ? ValaType.BOOL : ValaType.INT;
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                string lt_name = "";
                string rt_name = "";
                var lt = expr_type_full (b.left, out lt_name);
                var rt = expr_type_full (b.right, out rt_name);
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
                if (!is_int_like (lt) || !is_int_like (rt))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"operator '$(b.op)' requires int or bool operands, got $(type_label (lt, lt_name)) and $(type_label (rt, rt_name)) at $(b.line):$(b.column)");
                if (b.op == "<" || b.op == "<=" || b.op == ">" || b.op == ">="
                    || b.op == "&&" || b.op == "||") {
                    return ValaType.BOOL;
                }
                return ValaType.INT;
            }
            if (e is CallExpr) {
                unowned var f = check_call ((CallExpr) e, true);
                tname = f.return_type_name;
                return f.return_type;
            }
            error ("unknown expression node");
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
        private void emit_null_check_if_nullable (ValaType tt, string tt_name) {
            if (null_check && is_nullable_type (tt, tt_name)) {
                need_null_panic = true;
                emitter.test_rax_rax ();
                emitter.branch (BranchKind.JE, null_panic_label);
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
                        emitter.lea_rax_rbp_disp (Emitter.slot_offset (local_slots[idx]));
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
                if (current_class != null && !current.is_static) {
                    unowned ClassField? cf = null;
                    var fslot = class_field_offset_slots (current_class, vr.name, out cf);
                    if (fslot >= 0 && cf != null) {
                        emitter.load_local (0);
                        emitter.add_rax_imm (16 + 8 * fslot);
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
                    emitter.add_rax_imm (16 + 8 * slot_off);
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
                if (tt != ValaType.ARRAY)
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
                need_write_int = true;
                call_aligned ("__planc_write_int");
                cleanup_expr_temps (part);
            } else {
                throw new SemanticError.TYPE_MISMATCH (
                    @"cannot format $(pt.label ()) in print template at $(part.line):$(part.column)");
            }
        }

        // Expects field address in `rax`. Evaluates `val` and stores (with ARC/struct/op).
        private void emit_field_store (ValaType ft, string ft_name, string op, Expr val)
                throws SemanticError {
            emitter.push_rax ();
            push_depth++;
            gen_expr (val);
            if (op == "=") {
                if (program_uses_heap && is_ref_type (ft)) {
                    consume_ref_expr (val);
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
                    if (program_uses_heap && sub != null && struct_has_string (sub)) {
                        emitter.push_rax ();
                        push_depth++;
                        unref_struct_at_rcx (sub, 0);
                        emitter.pop_rax ();
                        push_depth--;
                        copy_struct_rax_to_rcx (fslots);
                        ref_struct_at_rcx (sub, 0);
                    } else {
                        copy_struct_rax_to_rcx (fslots);
                    }
                } else {
                    emitter.pop_rcx ();
                    push_depth--;
                    emitter.store_rcx_disp_rax (0);
                }
            } else {
                emitter.mov_rcx_rax ();
                emitter.pop_rax ();
                push_depth--;
                emitter.mov_rdx_rax ();
                emitter.load_rdx_disp (0);
                if (op == "+")
                    emitter.add_rax_rcx ();
                else
                    emitter.sub_rax_rcx ();
                emitter.mov_rcx_rdx ();
                emitter.store_rcx_disp_rax (0);
            }
        }

        private void gen_statement (Statement s) throws SemanticError {
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
                emitter.mov_edi_eax ();
                emitter.mov_eax (SYS_EXIT);
                emitter.syscall ();
            } else if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (finally_labels.length > 0) {
                    int fin_idx = finally_labels.length - 1;
                    if (r.value != null) {
                        if (current.is_void)
                            throw new SemanticError.RETURN_MISMATCH (
                                @"void function '$(current.name)' cannot return a value at $(r.line):$(r.column)");
                        string rt_name = "";
                        var rt = expr_type_full (r.value, out rt_name);
                        if (!type_compatible (current.return_type, current.return_type_name, rt, rt_name))
                            throw new SemanticError.RETURN_MISMATCH (
                                @"function '$(current.name)' returns $(type_label (current.return_type, current.return_type_name)), got $(type_label (rt, rt_name)) at $(r.line):$(r.column)");
                        gen_expr (r.value);
                        if (is_ref_type (current.return_type))
                            consume_ref_expr (r.value);
                        if (current.return_type == ValaType.STRUCT) {
                            var n = type_slots (ValaType.STRUCT, current.return_type_name);
                            emitter.lea_rcx_space (struct_ret_bss_offset, PatchSpace.BSS);
                            copy_struct_rax_to_rcx (n);
                            if (program_uses_heap) {
                                unowned var sd = program.find_struct (current.return_type_name);
                                if (sd != null && struct_has_string (sd))
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
                        string rt_name = "";
                        var rt = expr_type_full (r.value, out rt_name);
                        if (!type_compatible (current.return_type, current.return_type_name, rt, rt_name))
                            throw new SemanticError.RETURN_MISMATCH (
                                @"function '$(current.name)' returns $(type_label (current.return_type, current.return_type_name)), got $(type_label (rt, rt_name)) at $(r.line):$(r.column)");
                        gen_expr (r.value);
                        if (is_ref_type (current.return_type))
                            consume_ref_expr (r.value);
                        if (current.return_type == ValaType.STRUCT) {
                            var n = type_slots (ValaType.STRUCT, current.return_type_name);
                            emitter.lea_rcx_space (struct_ret_bss_offset, PatchSpace.BSS);
                            copy_struct_rax_to_rcx (n);
                            if (program_uses_heap) {
                                unowned var sd = program.find_struct (current.return_type_name);
                                if (sd != null && struct_has_string (sd))
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
                    } else {
                        if (!current.is_void)
                            throw new SemanticError.RETURN_MISMATCH (
                                @"$(type_label (current.return_type, current.return_type_name)) function '$(current.name)' must return a value at $(r.line):$(r.column)");
                        if (program_uses_heap)
                            unref_locals_from (0);
                        emitter.xor_eax ();
                    }
                    emitter.xor_edx ();
                    emitter.leave ();
                    emitter.ret ();
                }
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (lookup (d.name) >= 0)
                    throw new SemanticError.DUPLICATE_VARIABLE (
                        @"duplicate variable: $(d.name) at $(d.line):$(d.column)");
                ValaType vtype;
                string vtname = "";
                if (d.infer_type) {
                    vtype = expr_type_full (d.init, out vtname);
                    if (vtype == ValaType.NULL)
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot infer type of 'var $(d.name)' from 'null' at $(d.line):$(d.column)");
                } else {
                    vtype = d.decl_type;
                    vtname = d.decl_type_name;
                    if (d.init != null) {
                        string itname = "";
                        var it = expr_type_full (d.init, out itname);
                        if (!type_compatible (vtype, vtname, it, itname))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot initialize $(type_label (vtype, vtname)) variable '$(d.name)' with $(type_label (it, itname)) at $(d.init.line):$(d.init.column)");
                    } else if ((vtype == ValaType.CLASS || vtype == ValaType.ERROR) && !is_nullable_type (vtype, vtname)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"non-nullable $(type_label (vtype, vtname)) variable '$(d.name)' must be initialized at $(d.line):$(d.column)");
                    }
                }
                var nslots = type_slots (vtype, vtname);
                var slot = next_var_slot;
                next_var_slot += nslots;

                if (vtype == ValaType.STRUCT) {
                    var base_disp = struct_base_disp (slot, nslots);
                    unowned var sd = program.find_struct (vtname);
                    if (d.init != null) {
                        gen_expr (d.init);
                        emitter.lea_rcx_rbp_disp (base_disp);
                        copy_struct_rax_to_rcx (nslots);
                        if (program_uses_heap && sd != null && struct_has_string (sd))
                            ref_struct_at_rcx (sd, 0);
                        cleanup_expr_temps (d.init);
                    } else {
                        emitter.lea_rcx_rbp_disp (base_disp);
                        if (sd != null)
                            init_struct_at_rcx (sd, 0);
                    }
                } else if (is_ref_type (vtype)) {
                    if (d.init != null) {
                        gen_expr (d.init);
                        consume_ref_expr (d.init);
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
                        emitter.store_local (slot);
                        cleanup_expr_temps (d.init);
                    } else {
                        emitter.zero_local (slot);
                    }
                }
                push_local (d.name, vtype, vtname, slot, false);
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                var idx = lookup (a.name);
                if (idx >= 0) {
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
                            if (program_uses_heap && sd != null && struct_has_string (sd)) {
                                emitter.push_rax ();
                                push_depth++;
                                unref_struct_at_rcx (sd, 0);
                                emitter.pop_rax ();
                                push_depth--;
                                copy_struct_rax_to_rcx (n);
                                ref_struct_at_rcx (sd, 0);
                            } else {
                                copy_struct_rax_to_rcx (n);
                            }
                        } else if (program_uses_heap && is_ref_type (local_types[idx])) {
                            consume_ref_expr (a.value);
                            emitter.push_rax ();
                            push_depth++;
                            emitter.load_local (local_slots[idx]);
                            emitter.mov_rdi_rax ();
                            call_aligned ("__planc_unref");
                            emitter.pop_rax ();
                            push_depth--;
                            emitter.store_local (local_slots[idx]);
                        } else {
                            emitter.store_local (local_slots[idx]);
                        }
                    }
                    cleanup_expr_temps (a.value);
                    if (is_nullable_type (vt, vt_name))
                        remove_non_null (a.name);
                } else {
                    var gi = lookup_global (a.name);
                    if (gi < 0) {
                        if (current_class != null && !current.is_static) {
                            unowned ClassField? cf = null;
                            var fslot = class_field_offset_slots (current_class, a.name, out cf);
                            if (fslot >= 0 && cf != null) {
                                string vt_name = "";
                                var vt = expr_type_full (a.value, out vt_name);
                                if (!type_compatible (cf.field_type, cf.type_name, vt, vt_name))
                                    throw new SemanticError.TYPE_MISMATCH (
                                        @"cannot assign $(type_label (vt, vt_name)) to field '$(current_class.name).$(a.name)' ($(type_label (cf.field_type, cf.type_name))) at $(a.line):$(a.column)");
                                emitter.load_local (0);
                                emitter.add_rax_imm (16 + 8 * fslot);
                                emit_field_store (cf.field_type, cf.type_name, "=", a.value);
                                cleanup_expr_temps (a.value);
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
                        if (program_uses_heap && sd != null && struct_has_string (sd)) {
                            emitter.push_rax ();
                            push_depth++;
                            unref_struct_at_rcx (sd, 0);
                            emitter.pop_rax ();
                            push_depth--;
                            copy_struct_rax_to_rcx (n);
                            ref_struct_at_rcx (sd, 0);
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
                        emitter.store_global (global_offsets[gi], global_spaces[gi]);
                    }
                    cleanup_expr_temps (a.value);
                }
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                string peek_name = "";
                var peek_t = expr_type_full (fa.target, out peek_name);
                ValaType ft;
                string ft_name;
                string owner_label;
                int byte_off;

                if (peek_t == ValaType.CLASS) {
                    var cname = strip_null (peek_name);
                    unowned var cd = program.find_class (cname);
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
                            @"class '$(cname)' has no field '$(fa.field_name)' at $(fa.line):$(fa.column)");
                    }
                    ft = cf.field_type;
                    ft_name = cf.type_name;
                    owner_label = cname;
                    byte_off = 16 + 8 * fslot;
                    string vt_name = "";
                    var vt = expr_type_full (fa.value, out vt_name);
                    if (fa.op == "=") {
                        if (!type_compatible (ft, ft_name, vt, vt_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot assign $(type_label (vt, vt_name)) to field '$(owner_label).$(fa.field_name)' ($(type_label (ft, ft_name))) at $(fa.line):$(fa.column)");
                    } else if (!is_int_like (ft) || !is_int_like (vt)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"operator '$(fa.op)=' requires int or bool operands at $(fa.line):$(fa.column)");
                    }
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
                    var vt = expr_type_full (fa.value, out vt_name);
                    if (fa.op == "=") {
                        if (!type_compatible (ft, ft_name, vt, vt_name))
                            throw new SemanticError.TYPE_MISMATCH (
                                @"cannot assign $(type_label (vt, vt_name)) to field '$(owner_label).$(fa.field_name)' ($(type_label (ft, ft_name))) at $(fa.line):$(fa.column)");
                    } else if (!is_int_like (ft) || !is_int_like (vt)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"operator '$(fa.op)=' requires int or bool operands at $(fa.line):$(fa.column)");
                    }
                    emitter.add_rax_imm (byte_off);
                }

                emit_field_store (ft, ft_name, fa.op, fa.value);
                cleanup_expr_temps (fa.target);
                cleanup_expr_temps (fa.value);
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                string tt_name = "";
                var tt = expr_type_full (ia.target, out tt_name);
                if (tt == ValaType.STRING)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"strings are immutable and cannot be indexed for assignment at $(ia.line):$(ia.column)");
                if (tt != ValaType.ARRAY)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"indexed assignment requires array, got $(type_label (tt, tt_name)) at $(ia.line):$(ia.column)");
                string it_name = "";
                var it = expr_type_full (ia.index, out it_name);
                if (!is_int_like (it))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"array index must be int, got $(type_label (it, it_name)) at $(ia.index.line):$(ia.index.column)");

                ValaType et;
                string et_name;
                parse_array_elem (tt_name, out et, out et_name);
                string vt_name = "";
                var vt = expr_type_full (ia.value, out vt_name);
                if (ia.op == "=") {
                    if (!type_compatible (et, et_name, vt, vt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot assign $(type_label (vt, vt_name)) to $(type_label (et, et_name))[] element at $(ia.line):$(ia.column)");
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
                if (bounds_check) {
                    need_bounds_panic = true;
                    emitter.cmp_rcx_rax_len ();
                    emitter.branch (BranchKind.JAE, bounds_panic_label);
                }
                emitter.lea_rax_rax_rcx_8_16 ();
                emit_field_store (et, et_name, ia.op, ia.value);
                cleanup_expr_temps (ia.target);
                cleanup_expr_temps (ia.index);
                cleanup_expr_temps (ia.value);
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
                string? nn_then = null;
                string? nn_else = null;
                if (match_null_cmp (i.condition, "!=", out nn_then) && nn_then != null && lookup (nn_then) < 0)
                    nn_then = null;
                if (match_null_cmp (i.condition, "==", out nn_else) && nn_else != null && lookup (nn_else) < 0)
                    nn_else = null;

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
                    add_non_null (nn_then);
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
                        add_non_null (nn_else);
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
                string? nn_w = null;
                if (match_null_cmp (w.condition, "!=", out nn_w) && nn_w != null && lookup (nn_w) >= 0)
                    add_non_null (nn_w);
                var saved = locals.length;
                gen_statement (w.body);
                unref_locals_from (saved);
                deactivate_from (saved);
                restore_non_null (before_w);
                emitter.branch (BranchKind.JMP, l_start);
                emitter.bind (l_end);
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
                if (ct != ValaType.ARRAY)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"foreach requires an array collection, got $(type_label (ct, ct_name)) at $(fe.collection.line):$(fe.collection.column)");
                ValaType et;
                string et_name;
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
                push_local (@"#fe_col_$(col_mark)", ValaType.ARRAY, strip_null (ct_name), col_slot, false);
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
                emitter.load_rax_disp (8);
                emitter.mov_rcx_rax ();
                emitter.load_local (idx_slot);
                emitter.cmp_rax_rcx ();
                emitter.branch (BranchKind.JAE, l_end);

                emitter.load_local (idx_slot);
                emitter.mov_rcx_rax ();
                emitter.load_local (col_slot);
                emitter.load_qword_rax_rcx_16 ();
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
                error ("statement not supported");
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

        private void setcc (string op) {
            uint8 cc;
            if (op == "==") cc = 0x94;
            else if (op == "!=") cc = 0x95;
            else if (op == "<") cc = 0x9C;
            else if (op == "<=") cc = 0x9E;
            else if (op == ">") cc = 0x9F;
            else cc = 0x9D;
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
            } else if (e is ClassNewExpr) {
                var cn = (ClassNewExpr) e;
                unowned var cd = program.find_class (cn.class_name);
                int payload_bytes = 8 * class_total_field_slots (cd);
                emitter.mov_rdi_imm (payload_bytes);
                emitter.mov_esi_imm (2);
                call_aligned ("__planc_alloc");
                emitter.lea_rcx_space (cd.vtable_rodata_offset, PatchSpace.RODATA);
                emitter.store_rax_8_rcx ();
                emitter.store_local (cn.ref_temp_slot);
                emitter.mov_rdi_rax ();
                call_aligned (@"__planc_init_$(cd.name)");
                if (program_uses_heap && cn.ref_temp_slot >= 0)
                    add_live_ref_slot (cn.ref_temp_slot);
                if (cd.ctor != null)
                    emit_instance_call_from_slot (cn.ref_temp_slot, cd.ctor, cn.args);
                for (int i = 0; i < cn.init_names.length; i++) {
                    var iname = cn.init_names[i];
                    var ival = cn.init_values[i];
                    unowned ClassField? cf = null;
                    var fslot = class_field_offset_slots (cd, iname, out cf);
                    if (fslot >= 0 && cf != null) {
                        emitter.load_local (cn.ref_temp_slot);
                        emitter.add_rax_imm (16 + 8 * fslot);
                        emit_field_store (cf.field_type, cf.type_name, "=", ival);
                    } else {
                        unowned var sm = find_prop_setter (ValaType.CLASS, cd.name, iname);
                        var arglist = new GenericArray<Expr> ();
                        arglist.add (ival);
                        emit_instance_call_from_slot (cn.ref_temp_slot, sm, arglist);
                    }
                }
                emitter.load_local (cn.ref_temp_slot);
            } else if (e is TypeCheckExpr) {
                var tc = (TypeCheckExpr) e;
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
                unowned var tcd = program.find_class (strip_null (tc.target_type_name));
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
                        var pt = expr_type (part);
                        bool part_fresh = false;
                        if (pt == ValaType.STRING) {
                            gen_expr (part);
                        } else if (pt == ValaType.INT || pt == ValaType.ENUM) {
                            gen_expr (part);
                            emitter.mov_rdi_rax ();
                            need_int_to_str = true;
                            call_aligned ("__planc_int_to_str");
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
                gen_expr (an.length_expr);
                emitter.test_rax_rax ();
                need_bounds_panic = true;
                emitter.branch (BranchKind.JL, bounds_panic_label);
                emitter.push_rax ();
                push_depth++;
                emitter.mov_rdi_rax ();
                emitter.shl_rdi_3 ();
                emitter.mov_esi_imm (elem_ref ? 1 : 0);
                call_aligned ("__planc_alloc");
                emitter.pop_reg (Reg.RCX);
                push_depth--;
                emitter.store_rax_8_rcx ();
                if (an.elem_type == ValaType.STRING)
                    emitter.emit_fill_empty_strings (emitter.add_string (""));
                if (e.ref_temp_slot >= 0)
                    emitter.store_local (e.ref_temp_slot);
            } else if (e is ArrayLiteralExpr) {
                var arr = (ArrayLiteralExpr) e;
                var n = arr.elements.length;
                bool elem_ref = is_ref_type (arr.elem_type);
                emitter.mov_rdi_imm ((int64) n * 8);
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
                    emitter.mov_rcx_rax ();
                    emitter.load_local (arr.ref_temp_slot);
                    // store element at [rax + 16 + 8*i]
                    emitter.push_rax ();
                    emitter.mov_rax_rcx ();
                    emitter.pop_reg (Reg.RCX);
                    emitter.store_rcx_disp_rax (16 + 8 * i);
                }
                emitter.load_local (arr.ref_temp_slot);
            } else if (e is MemberAccessExpr) {
                var m = (MemberAccessExpr) e;
                if (m.target is VarRef) {
                    var vr = (VarRef) m.target;
                    if (is_type_name (vr.name)) {
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
                            if (mem == null)
                                throw new SemanticError.UNKNOWN_MEMBER (
                                    @"enum '$(ed.name)' has no member '$(m.member)' at $(m.line):$(m.column)");
                            emitter.mov_rax_imm (mem.value);
                            return;
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
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"class '$(cname)' has no field or property '$(m.member)' at $(m.line):$(m.column)");
                    }
                    gen_expr (m.target);
                    emit_null_check_if_nullable (tt, tt_name);
                    if (cf.field_type == ValaType.STRUCT)
                        emitter.add_rax_imm (16 + 8 * fslot);
                    else
                        emitter.load_rax_disp (16 + 8 * fslot);
                    return;
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
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"struct '$(tt_name)' has no field or property '$(m.member)' at $(m.line):$(m.column)");
                }
                gen_expr (m.target);
                if (fld.field_type == ValaType.STRUCT)
                    emitter.add_rax_imm (8 * off_slots);
                else
                    emitter.load_rax_disp (8 * off_slots);
            } else if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                string tt_name = "";
                var tt = expr_type_full (ix.target, out tt_name);
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
                if (tt == ValaType.ARRAY)
                    emitter.load_qword_rax_rcx_16 ();
                else
                    emitter.load_byte_rax_rcx_16 ();
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
                string? nn_then = null;
                string? nn_else = null;
                if (match_null_cmp (te.condition, "!=", out nn_then) && nn_then != null && lookup (nn_then) < 0)
                    nn_then = null;
                if (match_null_cmp (te.condition, "==", out nn_else) && nn_else != null && lookup (nn_else) < 0)
                    nn_else = null;

                if (nn_then != null)
                    add_non_null (nn_then);
                gen_expr (te.then_expr);
                if (ref_res) {
                    consume_ref_expr (te.then_expr);
                    if (te.ref_temp_slot >= 0)
                        emitter.store_local (te.ref_temp_slot);
                }
                if (res_t != ValaType.STRUCT) {
                    emitter.push_rax ();
                    push_depth++;
                    cleanup_expr_temps (te.then_expr);
                    emitter.pop_rax ();
                    push_depth--;
                }
                restore_non_null (snap);
                emitter.branch (BranchKind.JMP, l_end);

                emitter.bind (l_else);
                if (nn_else != null)
                    add_non_null (nn_else);
                gen_expr (te.else_expr);
                if (ref_res) {
                    consume_ref_expr (te.else_expr);
                    if (te.ref_temp_slot >= 0)
                        emitter.store_local (te.ref_temp_slot);
                }
                if (res_t != ValaType.STRUCT) {
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
                var nslots = type_slots (ValaType.STRUCT, lit.struct_name);
                var base_disp = struct_base_disp (lit.temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                init_struct_at_rcx (sd, 0);
                for (int i = 0; i < lit.field_names.length; i++) {
                    unowned StructField? fld = null;
                    var off_slots = struct_field_offset_slots (sd, lit.field_names[i], out fld);
                    gen_expr (lit.field_values[i]);
                    if (fld.field_type == ValaType.STRUCT) {
                        var fslots = type_slots (ValaType.STRUCT, fld.type_name);
                        emitter.lea_rcx_rbp_disp (base_disp + 8 * off_slots);
                        copy_struct_rax_to_rcx (fslots);
                    } else {
                        emitter.store_rbp_disp (base_disp + 8 * off_slots);
                    }
                }
                emitter.lea_rax_rbp_disp (base_disp);
            } else if (e is VarRef) {
                var v = (VarRef) e;
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
                    }
                } else {
                    var gi = lookup_global (v.name);
                    if (gi >= 0) {
                        if (global_types[gi] == ValaType.STRUCT)
                            emitter.lea_rax_space (global_offsets[gi], global_spaces[gi]);
                        else
                            emitter.load_global (global_offsets[gi], global_spaces[gi]);
                    } else if (current_class != null) {
                        unowned var c_const = program.find_const (current_class.name, v.name);
                        if (c_const != null) {
                            if (c_const.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (c_const.str_value));
                            else
                                emitter.mov_rax_imm (c_const.int_value);
                            return;
                        }
                        if (!current.is_static) {
                            unowned ClassField? cf = null;
                            var fslot = class_field_offset_slots (current_class, v.name, out cf);
                            if (fslot >= 0 && cf != null) {
                                emitter.load_local (0);
                                if (cf.field_type == ValaType.STRUCT)
                                    emitter.add_rax_imm (16 + 8 * fslot);
                                else
                                    emitter.load_rax_disp (16 + 8 * fslot);
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
                            if (gc1.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (gc1.str_value));
                            else
                                emitter.mov_rax_imm (gc1.int_value);
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    } else if (current_struct != null) {
                        unowned var s_const = program.find_const (current_struct.name, v.name);
                        if (s_const != null) {
                            if (s_const.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (s_const.str_value));
                            else
                                emitter.mov_rax_imm (s_const.int_value);
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
                            if (gc2.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (gc2.str_value));
                            else
                                emitter.mov_rax_imm (gc2.int_value);
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    } else if (current_enum != null) {
                        unowned var e_const = program.find_const (current_enum.name, v.name);
                        if (e_const != null) {
                            if (e_const.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (e_const.str_value));
                            else
                                emitter.mov_rax_imm (e_const.int_value);
                            return;
                        }
                        unowned var em = current_enum.find_member (v.name);
                        if (em != null) {
                            emitter.mov_rax_imm (em.value);
                            return;
                        }
                        unowned var gc3 = program.find_const ("", v.name);
                        if (gc3 != null) {
                            if (gc3.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (gc3.str_value));
                            else
                                emitter.mov_rax_imm (gc3.int_value);
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    } else {
                        unowned var g_const = program.find_const ("", v.name);
                        if (g_const != null) {
                            if (g_const.const_type == ValaType.STRING)
                                emitter.lea_rax_rip (emitter.add_string (g_const.str_value));
                            else
                                emitter.mov_rax_imm (g_const.int_value);
                            return;
                        }
                        throw new SemanticError.UNKNOWN_VARIABLE (
                            @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                    }
                }
            } else if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                gen_expr (u.operand);
                if (u.op == "-") {
                    emitter.neg_rax ();
                } else if (u.op == "~") {
                    emitter.not_rax ();
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
                var is_str_cmp = (b.op == "==" || b.op == "!=")
                              && expr_type (b.left) == ValaType.STRING
                              && expr_type (b.right) == ValaType.STRING;
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
                switch (b.op) {
                    case "+":  emitter.add_rax_rcx (); break;
                    case "-":  emitter.sub_rax_rcx (); break;
                    case "*":  emitter.imul_rax_rcx (); break;
                    case "/":
                        emitter.cqo ();
                        emitter.idiv_rcx ();
                        break;
                    case "%":
                        emitter.cqo ();
                        emitter.idiv_rcx ();
                        emitter.mov_rax_rdx ();
                        break;
                    case "&":  emitter.and_rax_rcx (); break;
                    case "|":  emitter.or_rax_rcx (); break;
                    case "^":  emitter.xor_rax_rcx (); break;
                    case "<<": emitter.shl_rax_cl (); break;
                    case ">>": emitter.sar_rax_cl (); break;
                    default:
                        emitter.cmp_rax_rcx ();
                        setcc (b.op);
                        break;
                }
            } else if (e is CallExpr) {
                gen_call ((CallExpr) e);
            } else {
                error ("expression not supported");
            }
        }

        private void gen_and (BinaryExpr b) throws SemanticError {
            var l_false = emitter.new_label ();
            var l_end = emitter.new_label ();
            gen_expr (b.left);
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JE, l_false);
            gen_expr (b.right);
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
            gen_expr (b.right);
            emitter.test_rax_rax ();
            emitter.branch (BranchKind.JNE, l_true);
            emitter.xor_eax ();
            emitter.branch (BranchKind.JMP, l_end);
            emitter.bind (l_true);
            emitter.mov_rax_imm (1);
            emitter.bind (l_end);
        }

        private void gen_method_call (MethodCallExpr mc) throws SemanticError {
            unowned var m = resolve_method_call_fn (mc);
            if (m == null)
                error ("unchecked method '%s'", mc.method_name);
            if (m.is_static) {
                emit_static_call (m, mc.args, mc.temp_slot, mc.ref_temp_slot);
                return;
            }
            emit_instance_call (mc.target, mc.is_base_call, mc.is_base_call,
                                m, mc.args, mc.temp_slot, mc.ref_temp_slot);
        }

        private void emit_call_arg (Function fn, int param_idx, Expr arg) throws SemanticError {
            var p = fn.params[param_idx];
            if (p.is_ref || p.is_out) {
                ValaType lt;
                string lt_name;
                gen_lvalue_addr (arg, out lt, out lt_name);
                if (arg is VarRef && is_nullable_type (p.param_type, p.type_name))
                    remove_non_null (((VarRef) arg).name);
            } else {
                gen_expr (arg);
            }
        }

        private void emit_instance_call_from_slot (int obj_slot, Function m, GenericArray<Expr> args)
                throws SemanticError {
            var total_args = 1 + args.length;
            var r = total_args < ARG_REGS.length ? total_args : ARG_REGS.length;
            var s = total_args - r;
            var depth = push_depth;

            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            emitter.load_local (obj_slot);
            emitter.push_rax ();
            push_depth++;
            for (int i = 0; i < args.length; i++) {
                int idx = i + 1;
                emit_call_arg (m, i + 1, args[i]);
                if (idx < r) {
                    emitter.push_rax ();
                    push_depth++;
                } else {
                    emitter.store_rsp (8 * idx);
                }
            }
            for (int i = r - 1; i >= 0; i--)
                emitter.pop_reg (ARG_REGS[i]);
            push_depth -= r;

            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);
            if (m.vtable_slot >= 0) {
                emitter.load_rdi_disp_to_rax (8);
                emitter.call_rax_disp (16 + 8 * m.vtable_slot);
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
            var r = total_args < ARG_REGS.length ? total_args : ARG_REGS.length;
            var s = total_args - r;
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
                    emitter.load_local (0);
            } else {
                string tt_name = "";
                var tt = expr_type_full (target_expr, out tt_name);
                gen_expr (target_expr);
                emit_null_check_if_nullable (tt, tt_name);
            }
            emitter.push_rax ();
            push_depth++;

            for (int i = 0; i < args.length; i++) {
                int idx = i + 1;
                emit_call_arg (m, i + 1, args[i]);
                if (idx < r) {
                    emitter.push_rax ();
                    push_depth++;
                } else {
                    emitter.store_rsp (8 * idx);
                }
            }

            for (int i = r - 1; i >= 0; i--)
                emitter.pop_reg (ARG_REGS[i]);
            push_depth -= r;

            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);

            if (!is_base && m.vtable_slot >= 0) {
                emitter.load_rdi_disp_to_rax (8);
                emitter.call_rax_disp (16 + 8 * m.vtable_slot);
            } else {
                emitter.call_rel32 (m.name);
            }

            if (s > 0) {
                emitter.add_rsp (area);
            } else if (depth % 2 == 1) {
                emitter.add_rsp (8);
            }

            emit_post_call_error_check (m);

            if (m.return_type == ValaType.STRUCT && struct_temp_slot >= 0) {
                var nslots = type_slots (ValaType.STRUCT, m.return_type_name);
                var base_disp = struct_base_disp (struct_temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                copy_struct_rax_to_rcx (nslots);
                emitter.mov_rax_rcx ();
            } else if (program_uses_heap && is_ref_type (m.return_type) && ref_temp_slot >= 0) {
                emitter.store_local (ref_temp_slot);
            }
        }

        private void gen_call (CallExpr e) throws SemanticError {
            unowned var f = resolve_call_target (e.callee);
            if (f == null)
                error ("unchecked callee %s", e.callee);
            bool is_synth_init = f.name.has_prefix ("__planc_init_");
            if (f.owner_class != "" && !is_synth_init && !f.is_static) {
                emit_instance_call (null, false, true, f, e.args, e.temp_slot, e.ref_temp_slot);
                return;
            }
            emit_static_call (f, e.args, e.temp_slot, e.ref_temp_slot);
        }

        private void emit_static_call (Function f, GenericArray<Expr> args,
                                       int struct_temp_slot, int ref_temp_slot)
                throws SemanticError {
            var n = args.length;
            var r = n < ARG_REGS.length ? n : ARG_REGS.length;
            var s = n - r;
            var depth = push_depth;

            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            for (int i = 0; i < n; i++) {
                emit_call_arg (f, i, args[i]);
                if (i < r) {
                    emitter.push_rax ();
                    push_depth++;
                } else {
                    emitter.store_rsp (8 * i);
                }
            }

            for (int i = r - 1; i >= 0; i--)
                emitter.pop_reg (ARG_REGS[i]);
            push_depth -= r;

            if (s == 0 && depth % 2 == 1)
                emitter.sub_rsp (8);

            emitter.call_rel32 (f.name);

            if (s > 0) {
                emitter.add_rsp (area);
            } else if (depth % 2 == 1) {
                emitter.add_rsp (8);
            }

            emit_post_call_error_check (f);

            if (f.return_type == ValaType.STRUCT && struct_temp_slot >= 0) {
                var nslots = type_slots (ValaType.STRUCT, f.return_type_name);
                var base_disp = struct_base_disp (struct_temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                copy_struct_rax_to_rcx (nslots);
                emitter.mov_rax_rcx ();
            } else if (program_uses_heap && is_ref_type (f.return_type) && ref_temp_slot >= 0) {
                emitter.store_local (ref_temp_slot);
            }
        }
    }
}
