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
        private bool program_uses_heap = false;
        private int alloc_bss_offset = -1;
        private GenericArray<string> non_null_vars;

        // Per-function local symbol table.
        private GenericArray<string> locals;
        private GenericArray<ValaType> local_types;
        private GenericArray<string> local_type_names;
        private GenericArray<int> local_slots;
        private GenericArray<bool> local_active;
        private int next_var_slot;
        private int temp_slot_cursor;
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
                if (g.var_type == ValaType.ARRAY || g.var_type == ValaType.CLASS)
                    return true;
            }
            foreach (var f in program.functions) {
                if (f.return_type == ValaType.ARRAY)
                    return true;
                foreach (var p in f.params) {
                    if (p.param_type == ValaType.ARRAY)
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
            return false;
        }

        private bool scan_expr_heap (Expr e) {
            if (e is ArrayNewExpr || e is ArrayLiteralExpr || e is ClassNewExpr)
                return true;
            if (e is NullLiteral)
                return false;
            if (e is TemplateExpr)
                return !is_static_template ((TemplateExpr) e);
            if (e is UnaryExpr)
                return scan_expr_heap (((UnaryExpr) e).operand);
            if (e is TypeCheckExpr)
                return scan_expr_heap (((TypeCheckExpr) e).operand);
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
                    if (fld.field_type == ValaType.CLASS && !is_nullable_type (fld.field_type, fld.type_name)) {
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
                    unowned Function? base_m = (base_cd != null) ? find_class_method (base_cd, m.name) : null;
                    var impl_sym = @"$(cd.name)__$(m.name)";
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
            var orig = new GenericArray<Param> ();
            foreach (var p in f.params)
                orig.add (p);
            while (f.params.length > 0)
                f.params.remove_index (f.params.length - 1);
            f.params.add (new Param () {
                param_type = ValaType.CLASS,
                type_name = cname,
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
                if (dp.param_type != bp.param_type || dp.type_name != bp.type_name)
                    throw new SemanticError.TYPE_MISMATCH (
                        @"override '$(cname).$(derived.name)' parameter $(i + 1) type mismatch at $(dp.line):$(dp.column)");
            }
        }

        private bool ctor_assigns_field (Function ctor, string fname) {
            foreach (var s in ctor.body) {
                if (stmt_assigns_field (s, fname))
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
            if (need_str_concat || need_int_to_str) {
                need_alloc = true;
                need_mem_panic = true;
            }
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
                || s is BreakStatement || s is ContinueStatement) {
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

        private int prepare_function (Function f, out int ref_temp_start) throws SemanticError {
            current_class = (f.owner_class != "") ? program.find_class (f.owner_class) : null;
            non_null_vars = new GenericArray<string> ();
            reset_locals ();
            next_var_slot = 0;

            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                var raw_slot = next_var_slot++;
                int var_slot = raw_slot;
                if (p.param_type == ValaType.STRUCT) {
                    var n = type_slots (ValaType.STRUCT, p.type_name);
                    var_slot = next_var_slot;
                    next_var_slot += n;
                }
                locals.add (p.name);
                local_types.add (p.param_type);
                local_type_names.add (p.type_name);
                local_slots.add (var_slot);
                local_active.add (true);
                local_unmanaged.add (p.unmanaged);
            }

            int struct_temp_slots = 0;
            int ref_temp_slots = 0;
            if (f.is_ctor && f.has_base_call) {
                foreach (var ba in f.base_args)
                    prepare_expr (ba, ref struct_temp_slots, ref ref_temp_slots);
            }
            foreach (var s in f.body)
                prepare_stmt (s, ref struct_temp_slots, ref ref_temp_slots);

            int var_end = next_var_slot;
            temp_slot_cursor = var_end;
            if (f.is_ctor && f.has_base_call) {
                foreach (var ba in f.base_args)
                    assign_struct_temps_expr (ba);
            }
            foreach (var s in f.body)
                assign_struct_temps_stmt (s);

            ref_temp_start = var_end + struct_temp_slots;
            temp_slot_cursor = ref_temp_start;
            if (f.is_ctor && f.has_base_call) {
                foreach (var ba in f.base_args)
                    assign_ref_temps_expr (ba);
            }
            foreach (var s in f.body)
                assign_ref_temps_stmt (s);

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
                    } else if (vt == ValaType.CLASS && !is_nullable_type (vt, vtname)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"non-nullable $(type_label (vt, vtname)) variable '$(d.name)' must be initialized at $(d.line):$(d.column)");
                    }
                }
                var n = type_slots (vt, vtname);
                var slot = next_var_slot;
                next_var_slot += n;
                locals.add (d.name);
                local_types.add (vt);
                local_type_names.add (vtname);
                local_slots.add (slot);
                local_active.add (true);
                local_unmanaged.add (false);
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                prepare_expr (a.value, ref struct_temps, ref ref_temps);
                if (lookup (a.name) >= 0) {
                    string vtn = "";
                    var vt = expr_type_full (a.value, out vtn);
                    if (is_nullable_type (vt, vtn))
                        remove_non_null (a.name);
                }
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                prepare_expr (fa.target, ref struct_temps, ref ref_temps);
                prepare_expr (fa.value, ref struct_temps, ref ref_temps);
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
            }
        }

        private void prepare_expr (Expr e, ref int struct_temps, ref int ref_temps)
                throws SemanticError {
            if (e is UnaryExpr) {
                prepare_expr (((UnaryExpr) e).operand, ref struct_temps, ref ref_temps);
            } else if (e is TypeCheckExpr) {
                prepare_expr (((TypeCheckExpr) e).operand, ref struct_temps, ref ref_temps);
            } else if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                prepare_expr (b.left, ref struct_temps, ref ref_temps);
                prepare_expr (b.right, ref struct_temps, ref ref_temps);
            } else if (e is MemberAccessExpr) {
                prepare_expr (((MemberAccessExpr) e).target, ref struct_temps, ref ref_temps);
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
                foreach (var a in ((ClassNewExpr) e).args)
                    prepare_expr (a, ref struct_temps, ref ref_temps);
            } else if (e is TemplateExpr) {
                foreach (var part in ((TemplateExpr) e).parts)
                    prepare_expr (part, ref struct_temps, ref ref_temps);
            } else if (e is StructLiteral) {
                var lit = (StructLiteral) e;
                foreach (var fv in lit.field_values)
                    prepare_expr (fv, ref struct_temps, ref ref_temps);
                struct_temps += type_slots (ValaType.STRUCT, lit.struct_name);
            } else if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    prepare_expr (mc.target, ref struct_temps, ref ref_temps);
                foreach (var a in mc.args)
                    prepare_expr (a, ref struct_temps, ref ref_temps);
                unowned var m = resolve_method_call_fn (mc);
                if (m != null && m.return_type == ValaType.STRUCT)
                    struct_temps += type_slots (ValaType.STRUCT, m.return_type_name);
            } else if (e is CallExpr) {
                var ce = (CallExpr) e;
                foreach (var a in ce.args)
                    prepare_expr (a, ref struct_temps, ref ref_temps);
                unowned var f = resolve_call_target (ce.callee);
                if (f != null && f.return_type == ValaType.STRUCT)
                    struct_temps += type_slots (ValaType.STRUCT, f.return_type_name);
            }
            if (program_uses_heap && is_owned_expr (e))
                ref_temps++;
        }

        private void assign_struct_temps_stmt (Statement s) {
            walk_stmt_exprs (s, assign_struct_temps_expr);
        }

        private void assign_ref_temps_stmt (Statement s) {
            walk_stmt_exprs (s, assign_ref_temps_expr);
        }

        private delegate void ExprVisitor (Expr e);

        private void walk_stmt_exprs (Statement s, ExprVisitor fn) {
            if (s is PrintStatement) {
                var p = (PrintStatement) s;
                if (p.value is TemplateExpr) {
                    foreach (var part in ((TemplateExpr) p.value).parts)
                        fn (part);
                } else {
                    fn (p.value);
                }
            } else if (s is ExitStatement) {
                fn (((ExitStatement) s).value);
            } else if (s is ReturnStatement) {
                var r = (ReturnStatement) s;
                if (r.value != null)
                    fn (r.value);
            } else if (s is VarDeclStatement) {
                var d = (VarDeclStatement) s;
                if (d.init != null)
                    fn (d.init);
            } else if (s is AssignStatement) {
                fn (((AssignStatement) s).value);
            } else if (s is FieldAssignStatement) {
                var fa = (FieldAssignStatement) s;
                fn (fa.target);
                fn (fa.value);
            } else if (s is IndexAssignStatement) {
                var ia = (IndexAssignStatement) s;
                fn (ia.target);
                fn (ia.index);
                fn (ia.value);
            } else if (s is ExprStatement) {
                fn (((ExprStatement) s).expr);
            } else if (s is BlockStatement) {
                foreach (var inner in ((BlockStatement) s).statements)
                    walk_stmt_exprs (inner, fn);
            } else if (s is IfStatement) {
                var i = (IfStatement) s;
                fn (i.condition);
                walk_stmt_exprs (i.then_body, fn);
                if (i.else_body != null)
                    walk_stmt_exprs (i.else_body, fn);
            } else if (s is WhileStatement) {
                var w = (WhileStatement) s;
                fn (w.condition);
                walk_stmt_exprs (w.body, fn);
            } else if (s is ForStatement) {
                var fs = (ForStatement) s;
                if (fs.init != null)
                    walk_stmt_exprs (fs.init, fn);
                if (fs.condition != null)
                    fn (fs.condition);
                if (fs.step != null)
                    walk_stmt_exprs (fs.step, fn);
                walk_stmt_exprs (fs.body, fn);
            }
        }

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
                foreach (var a in ((ClassNewExpr) e).args)
                    fn (a);
            } else if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    fn (mc.target);
                foreach (var a in mc.args)
                    fn (a);
            } else if (e is TypeCheckExpr) {
                fn (((TypeCheckExpr) e).operand);
            }
        }

        private void assign_struct_temps_expr (Expr e) {
            walk_expr_children (e, assign_struct_temps_expr);
            if (e is StructLiteral) {
                var lit = (StructLiteral) e;
                lit.temp_slot = temp_slot_cursor;
                temp_slot_cursor += type_slots (ValaType.STRUCT, lit.struct_name);
            } else if (e is CallExpr) {
                var ce = (CallExpr) e;
                unowned var f = resolve_call_target (ce.callee);
                if (f != null && f.return_type == ValaType.STRUCT) {
                    ce.temp_slot = temp_slot_cursor;
                    temp_slot_cursor += type_slots (ValaType.STRUCT, f.return_type_name);
                }
            } else if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                unowned var m = resolve_method_call_fn_safe (mc);
                if (m != null && m.return_type == ValaType.STRUCT) {
                    mc.temp_slot = temp_slot_cursor;
                    temp_slot_cursor += type_slots (ValaType.STRUCT, m.return_type_name);
                }
            }
        }

        private void assign_ref_temps_expr (Expr e) {
            walk_expr_children (e, assign_ref_temps_expr);
            if (program_uses_heap && is_owned_expr_safe (e))
                e.ref_temp_slot = temp_slot_cursor++;
        }

        private void generate_function (Function f) throws SemanticError {
            current = f;
            int ref_temp_start = 0;
            var total_slots = prepare_function (f, out ref_temp_start);

            current_class = (f.owner_class != "") ? program.find_class (f.owner_class) : null;
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
                if (f.params[i].param_type == ValaType.STRUCT) {
                    var n = type_slots (ValaType.STRUCT, f.params[i].type_name);
                    param_final_slots[i] = next_var_slot;
                    next_var_slot += n;
                } else {
                    param_final_slots[i] = raw_slot;
                }
            }

            // Retain borrowed reference parameters so the callee owns its
            // local slot and can safely reassign or unref on exit.
            for (int i = 0; i < f.params.length; i++) {
                var p = f.params[i];
                if (p.param_type == ValaType.STRUCT) {
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
                locals.add (p.name);
                local_types.add (p.param_type);
                local_type_names.add (p.type_name);
                local_slots.add (param_final_slots[i]);
                local_active.add (true);
                local_unmanaged.add (p.unmanaged);
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
            } else if (f.return_type == ValaType.ARRAY || f.return_type == ValaType.CLASS) {
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
            emitter.leave ();
            emitter.ret ();

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
            if ((t == ValaType.ENUM || t == ValaType.STRUCT || t == ValaType.CLASS) && tname != "")
                return tname;
            return t.label ();
        }

        private static bool is_int_like (ValaType t) {
            return t == ValaType.INT || t == ValaType.BOOL;
        }

        private static bool is_ref_type (ValaType t) {
            return t == ValaType.STRING || t == ValaType.ARRAY || t == ValaType.CLASS;
        }

        private void parse_array_elem (string elem_name, out ValaType et, out string et_name) {
            var raw = strip_null (elem_name);
            et_name = "";
            if (raw == "int") et = ValaType.INT;
            else if (raw == "bool") et = ValaType.BOOL;
            else if (raw == "string") et = ValaType.STRING;
            else if (program.find_class (raw) != null) {
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

        private bool is_owned_expr (Expr e) throws SemanticError {
            if (e is ArrayNewExpr || e is ArrayLiteralExpr || e is ClassNewExpr)
                return true;
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
            return false;
        }

        private bool is_owned_expr_safe (Expr e) {
            try {
                return is_owned_expr (e);
            } catch (SemanticError err) {
                return false;
            }
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
            string tt_name = "";
            var tt = expr_type_full (mc.target, out tt_name);
            if (tt != ValaType.CLASS)
                throw new SemanticError.TYPE_MISMATCH (
                    @"method '.$(mc.method_name)' requires a class instance, got $(type_label (tt, tt_name)) at $(mc.line):$(mc.column)");
            var cname = strip_null (tt_name);
            unowned var cd = program.find_class (cname);
            unowned var m = (cd != null) ? find_class_method (cd, mc.method_name) : null;
            if (m == null)
                throw new SemanticError.UNKNOWN_FUNCTION (
                    @"class '$(cname)' has no method '$(mc.method_name)' at $(mc.line):$(mc.column)");
            return m;
        }

        private unowned Function? resolve_method_call_fn_safe (MethodCallExpr mc) {
            try {
                return resolve_method_call_fn (mc);
            } catch (SemanticError err) {
                return null;
            }
        }

        private void check_arg_list (string desc, Function fn, int param_offset,
                                     GenericArray<Expr> args, int line, int col)
                throws SemanticError {
            int expected_count = fn.params.length - param_offset;
            if (expected_count != args.length)
                throw new SemanticError.WRONG_ARG_COUNT (
                    @"$(desc) expects $(expected_count) argument(s), got $(args.length) at $(line):$(col)");
            for (int i = 0; i < args.length; i++) {
                string at_name = "";
                var at = expr_type_full (args[i], out at_name);
                var pt = fn.params[param_offset + i].param_type;
                var pt_name = fn.params[param_offset + i].type_name;
                if (!type_compatible (pt, pt_name, at, at_name))
                    throw new SemanticError.TYPE_MISMATCH (
                        @"argument $(i + 1) of '$(desc)' expects $(type_label (pt, pt_name)), got $(type_label (at, at_name)) at $(args[i].line):$(args[i].column)");
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
            int param_off = (f.owner_class != "" && !is_synth_init) ? 1 : 0;
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
            check_arg_list (mc.method_name, m, 1, mc.args, mc.line, mc.column);
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
                tname = cd.name;
                return ValaType.CLASS;
            }
            if (e is TypeCheckExpr) {
                var tc = (TypeCheckExpr) e;
                string ot_name = "";
                var ot = expr_type_full (tc.operand, out ot_name);
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
                    if (lookup (vr.name) < 0 && lookup_global (vr.name) < 0) {
                        unowned var ed = program.find_enum (vr.name);
                        if (ed != null) {
                            if (ed.find_member (m.member) == null)
                                throw new SemanticError.UNKNOWN_MEMBER (
                                    @"enum '$(ed.name)' has no member '$(m.member)' at $(m.line):$(m.column)");
                            tname = ed.name;
                            return ValaType.ENUM;
                        }
                    }
                }
                string tt_name = "";
                var tt = expr_type_full (m.target, out tt_name);
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
                    if (cd == null || class_field_offset_slots (cd, m.member, out cf) < 0 || cf == null)
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"class '$(cname)' has no field '$(m.member)' at $(m.line):$(m.column)");
                    tname = cf.type_name;
                    return cf.field_type;
                }
                if (tt == ValaType.STRUCT) {
                    unowned var sd = program.find_struct (tt_name);
                    unowned StructField? fld = null;
                    if (sd == null || struct_field_offset_slots (sd, m.member, out fld) < 0 || fld == null)
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"struct '$(tt_name)' has no field '$(m.member)' at $(m.line):$(m.column)");
                    tname = fld.type_name;
                    return fld.field_type;
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
                    unowned ClassField? cf = null;
                    if (class_field_offset_slots (current_class, v.name, out cf) >= 0 && cf != null) {
                        tname = cf.type_name;
                        return cf.field_type;
                    }
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

        // Transfers ownership of a reference-typed expression in `rax` to a
        // storage location (`ref` if borrowed, or zero `ref_temp_slot` if owned).
        private void consume_ref_expr (Expr e) throws SemanticError {
            if (!program_uses_heap)
                return;
            if (is_owned_expr (e)) {
                if (e.ref_temp_slot >= 0)
                    emitter.zero_local (e.ref_temp_slot);
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
                    if (ltype == ValaType.STRUCT) {
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
                if (current_class != null) {
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
                emitter.leave ();
                emitter.ret ();
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
                    } else if (vtype == ValaType.CLASS && !is_nullable_type (vtype, vtname)) {
                        throw new SemanticError.TYPE_MISMATCH (
                            @"non-nullable $(type_label (vtype, vtname)) variable '$(d.name)' must be initialized at $(d.line):$(d.column)");
                    }
                }
                var nslots = type_slots (vtype, vtname);
                var slot = next_var_slot;
                next_var_slot += nslots;
                locals.add (d.name);
                local_types.add (vtype);
                local_type_names.add (vtname);
                local_slots.add (slot);
                local_active.add (true);
                local_unmanaged.add (false);

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
            } else if (s is AssignStatement) {
                var a = (AssignStatement) s;
                var idx = lookup (a.name);
                if (idx >= 0) {
                    string vt_name = "";
                    var vt = expr_type_full (a.value, out vt_name);
                    if (!type_compatible (local_types[idx], local_type_names[idx], vt, vt_name))
                        throw new SemanticError.TYPE_MISMATCH (
                            @"cannot assign $(type_label (vt, vt_name)) to $(type_label (local_types[idx], local_type_names[idx])) variable '$(a.name)' at $(a.line):$(a.column)");
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
                    cleanup_expr_temps (a.value);
                    if (is_nullable_type (vt, vt_name))
                        remove_non_null (a.name);
                } else {
                    var gi = lookup_global (a.name);
                    if (gi < 0) {
                        if (current_class != null) {
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
                    if (fslot < 0 || cf == null)
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"class '$(cname)' has no field '$(fa.field_name)' at $(fa.line):$(fa.column)");
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
                    if (off_slots < 0 || fld == null)
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"struct '$(base_name)' has no field '$(fa.field_name)' at $(fa.line):$(fa.column)");
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
            } else if (s is BreakStatement) {
                if (break_labels.length == 0)
                    throw new SemanticError.BAD_LOOP_CONTROL (
                        @"'break' outside of loop at $(s.line):$(s.column)");
                unref_locals_from (break_scope_marks[break_scope_marks.length - 1]);
                emitter.branch (BranchKind.JMP, break_labels[break_labels.length - 1]);
            } else if (s is ContinueStatement) {
                if (continue_labels.length == 0)
                    throw new SemanticError.BAD_LOOP_CONTROL (
                        @"'continue' outside of loop at $(s.line):$(s.column)");
                unref_locals_from (continue_scope_marks[continue_scope_marks.length - 1]);
                emitter.branch (BranchKind.JMP, continue_labels[continue_labels.length - 1]);
            } else {
                error ("statement not supported");
            }
        }

        private void pop_loop_labels () {
            var new_len = break_labels.length - 1;
            var nb = new GenericArray<Label> ();
            var nc = new GenericArray<Label> ();
            var nbm = new GenericArray<int> ();
            var ncm = new GenericArray<int> ();
            for (int i = 0; i < new_len; i++) {
                nb.add (break_labels[i]);
                nc.add (continue_labels[i]);
                nbm.add (break_scope_marks[i]);
                ncm.add (continue_scope_marks[i]);
            }
            break_labels = nb;
            continue_labels = nc;
            break_scope_marks = nbm;
            continue_scope_marks = ncm;
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
                if (cd.ctor != null)
                    emit_instance_call_from_slot (cn.ref_temp_slot, cd.ctor, cn.args);
                emitter.load_local (cn.ref_temp_slot);
            } else if (e is TypeCheckExpr) {
                var tc = (TypeCheckExpr) e;
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
                    if (lookup (vr.name) < 0 && lookup_global (vr.name) < 0) {
                        unowned var ed = program.find_enum (vr.name);
                        if (ed != null) {
                            unowned var mem = ed.find_member (m.member);
                            if (mem == null)
                                throw new SemanticError.UNKNOWN_MEMBER (
                                    @"enum '$(ed.name)' has no member '$(m.member)' at $(m.line):$(m.column)");
                            emitter.mov_rax_imm (mem.value);
                            return;
                        }
                    }
                }
                string tt_name = "";
                var tt = expr_type_full (m.target, out tt_name);
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
                    if (fslot < 0 || cf == null)
                        throw new SemanticError.UNKNOWN_MEMBER (
                            @"class '$(cname)' has no field '$(m.member)' at $(m.line):$(m.column)");
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
                if (off_slots < 0 || fld == null)
                    throw new SemanticError.UNKNOWN_MEMBER (
                        @"struct '$(tt_name)' has no field '$(m.member)' at $(m.line):$(m.column)");
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
                    if (local_types[idx] == ValaType.STRUCT) {
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
                        unowned ClassField? cf = null;
                        var fslot = class_field_offset_slots (current_class, v.name, out cf);
                        if (fslot < 0 || cf == null)
                            throw new SemanticError.UNKNOWN_VARIABLE (
                                @"unknown variable: $(v.name) at $(v.line):$(v.column)");
                        emitter.load_local (0);
                        if (cf.field_type == ValaType.STRUCT)
                            emitter.add_rax_imm (16 + 8 * fslot);
                        else
                            emitter.load_rax_disp (16 + 8 * fslot);
                    } else {
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
            emit_instance_call (mc.target, mc.is_base_call, mc.is_base_call,
                                m, mc.args, mc.temp_slot, mc.ref_temp_slot);
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
                gen_expr (args[i]);
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
            emitter.call_rel32 (m.name);
            if (s > 0)
                emitter.add_rsp (area);
            else if (depth % 2 == 1)
                emitter.add_rsp (8);
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
                gen_expr (args[i]);
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
            unowned var free_fn = program.find (e.callee);
            if (free_fn == null && current_class != null) {
                unowned var m = find_class_method (current_class, e.callee);
                if (m != null) {
                    emit_instance_call (null, false, true, m, e.args, e.temp_slot, e.ref_temp_slot);
                    return;
                }
            }
            unowned var f = free_fn;
            if (f == null)
                error ("unchecked callee %s", e.callee);

            var n = e.args.length;
            var r = n < ARG_REGS.length ? n : ARG_REGS.length;
            var s = n - r;
            var depth = push_depth;

            var area = align16 (8 * s);
            if (s > 0 && depth % 2 == 1)
                area += 8;
            if (area != 0)
                emitter.sub_rsp (area);

            for (int i = 0; i < n; i++) {
                gen_expr (e.args[i]);
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

            emitter.call_rel32 (e.callee);

            if (s > 0) {
                emitter.add_rsp (area);
            } else if (depth % 2 == 1) {
                emitter.add_rsp (8);
            }

            if (f.return_type == ValaType.STRUCT && e.temp_slot >= 0) {
                var nslots = type_slots (ValaType.STRUCT, f.return_type_name);
                var base_disp = struct_base_disp (e.temp_slot, nslots);
                emitter.lea_rcx_rbp_disp (base_disp);
                copy_struct_rax_to_rcx (nslots);
                emitter.mov_rax_rcx ();
            } else if (program_uses_heap && is_ref_type (f.return_type) && e.ref_temp_slot >= 0) {
                emitter.store_local (e.ref_temp_slot);
            }
        }
    }
}
