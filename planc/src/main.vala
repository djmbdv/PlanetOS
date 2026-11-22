// planc -- Vala to x86_64 machine code compiler.
//
// State: slice 5. Compiles `int`/`bool`/`string`/`T[]`/`enum`/`struct`/`void`
// programs with a safe mmap+guard-page arena/pool allocator, atomic reference
// counting, `--check-leaks`, dynamic string concatenation, and `@"..."`
// value templates into a static ELF64 that runs without libc.
//
// This particular build of planc uses `valac` (bootstrap stage 0,
// docs/02-compiler.md). The binary that planc *produces* depends on nothing:
// no libc, no GLib, no external linker (I1, I2, TC-02).

namespace Planc {

    private const string USAGE = "usage: planc <source.vala>... -o <output> [-D NAME] [--dump-text] [--no-bounds-check] [--no-null-check] [--check-leaks] [--error-limit N] [--no-error-recovery]";

    private static int parse_uint (string s) {
        int v = 0;
        for (int i = 0; i < s.length; i++) {
            if (s[i] < '0' || s[i] > '9')
                return v;
            v = v * 10 + (int) (s[i] - '0');
        }
        return v;
    }

    private static GenericArray<string> mt_src_paths;
    private static GenericArray<string> mt_defines;
    private static string[] mt_src_out;
    private static string[] mt_src_err;
    private static int mt_src_nw = 1;

    private static void mt_preproc_worker (int wid) {
        int n = mt_src_paths.length;
        for (int i = wid; i < n; i += mt_src_nw) {
            string p = mt_src_paths[i];
            string src;
            try {
                src = Host.read_file (p);
            } catch (FileError e) {
                mt_src_err[i] = @"planc: cannot read $p: $(e.message)";
                continue;
            }
            try {
                src = Preprocessor.run (src, mt_defines);
            } catch (LexError e) {
                mt_src_err[i] = @"planc: $p: lexical error: $(e.message)";
                continue;
            }
            mt_src_out[i] = src;
        }
    }

    public static int main (string[] args) {
        var source_paths = new GenericArray<string> ();
        var defines = new GenericArray<string> ();
        var output_path = "";
        var dump = false;
        var bounds_check = true;
        var null_check = true;
        var strict_null = false;
        var strict_unused = false;
        var warn_unused = true;
        var allow_asm = true;
        var opt_level = 0;
        var check_leaks = false;
        var check_overflow = false;
        var freestanding = false;
        var error_recovery = true;
        var error_limit = 200;
        var target_planetos = (Host.getenv ("OS") == "PlanetOS" || Host.getenv ("PLANC_TARGET") == "planetos");
        var target_spirv = false;
        int emit_format = 0; // 0 = elf, 1 = plan, 2 = dlib
        uint64 image_base = 0;

        for (int i = 1; i < args.length; i++) {
            var a = args[i];
            if (a == "-o") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                output_path = args[++i];
            } else if (a == "-D") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                defines.add (args[++i]);
            } else if (a.has_prefix ("-D") && a.length > 2) {
                defines.add (a.substring (2));
            } else if (a.has_prefix ("--define=")) {
                defines.add (a.substring (9));
            } else if (a == "--dump-text") {
                dump = true;
            } else if (a == "--no-bounds-check") {
                bounds_check = false;
            } else if (a == "--no-null-check") {
                null_check = false;
            } else if (a == "--strict-null") {
                strict_null = true;
            } else if (a == "--strict-unused") {
                strict_unused = true;
            } else if (a == "--no-warn-unused") {
                warn_unused = false;
            } else if (a == "--check-overflow") {
                check_overflow = true;
            } else if (a == "--no-asm") {
                allow_asm = false;
            } else if (a == "-O0") {
                opt_level = 0;
            } else if (a == "-O1" || a == "-O") {
                opt_level = 1;
            } else if (a == "-O2") {
                opt_level = 2;
            } else if (a == "--error-limit") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                error_limit = parse_uint (args[++i]);
            } else if (a.has_prefix ("--error-limit=")) {
                error_limit = parse_uint (a.substring (14));
            } else if (a == "--no-error-recovery") {
                error_recovery = false;
            } else if (a == "--check-leaks") {
                check_leaks = true;
            } else if (a == "--freestanding") {
                freestanding = true;
            } else if (a == "--target=planetos") {
                target_planetos = true;
            } else if (a == "--target=spirv") {
                target_spirv = true;
            } else if (a == "--format=elf") {
                emit_format = 0;
            } else if (a == "--format=plan") {
                emit_format = 1;
            } else if (a == "--format=dlib") {
                emit_format = 2;
            } else if (a.has_prefix ("--image-base=")) {
                var val_str = a.substring (13);
                uint64 parsed = 0;
                if (val_str.has_prefix ("0x") || val_str.has_prefix ("0X")) {
                    for (int k = 2; k < val_str.length; k++) {
                        uint8 c = val_str[k];
                        uint64 d = 0;
                        if (c >= '0' && c <= '9') d = (uint64) (c - '0');
                        else if (c >= 'a' && c <= 'f') d = (uint64) (10 + c - 'a');
                        else if (c >= 'A' && c <= 'F') d = (uint64) (10 + c - 'A');
                        parsed = (parsed << 4) | d;
                    }
                } else {
                    for (int k = 0; k < val_str.length; k++) {
                        uint8 c = val_str[k];
                        if (c >= '0' && c <= '9')
                            parsed = parsed * 10 + (uint64) (c - '0');
                    }
                }
                image_base = parsed;
            } else if (a == "-h" || a == "--help") {
                Host.println (USAGE);
                return 0;
            } else if (a.has_prefix ("-")) {
                Host.eprintln (@"unknown option: $a");
                Host.eprintln (USAGE);
                return 2;
            } else {
                source_paths.add (a);
            }
        }

        if (source_paths.length == 0 || output_path == "") {
            Host.eprintln (USAGE);
            return 2;
        }
        if (emit_format == 0) {
            if (output_path.has_suffix (".plan"))
                emit_format = 1;
            else if (output_path.has_suffix (".dlib"))
                emit_format = 2;
        }
        if (emit_format == 2 && image_base == 0) {
            image_base = (uint64) 0x1800000;
        }

        var sources = new GenericArray<string> ();
        int ncpus = Host.cpu_count ();
        if (source_paths.length >= 4 && ncpus > 1) {
            int nw = (ncpus < source_paths.length) ? ncpus : source_paths.length;
            if (nw > 16) nw = 16;
            mt_src_paths = source_paths;
            mt_defines = defines;
            mt_src_out = new string[source_paths.length];
            mt_src_err = new string[source_paths.length];
            for (int i = 0; i < source_paths.length; i++) {
                mt_src_out[i] = "";
                mt_src_err[i] = "";
            }
            mt_src_nw = nw;
            int64[] handles = new int64[nw];
            for (int wi = 1; wi < nw; wi++)
                handles[wi] = Host.thread_spawn (mt_preproc_worker, wi);
            mt_preproc_worker (0);
            for (int wi = 1; wi < nw; wi++)
                Host.thread_join (handles[wi]);
            for (int i = 0; i < source_paths.length; i++) {
                if (mt_src_err[i] != "") {
                    Host.eprintln (mt_src_err[i]);
                    return 1;
                }
                sources.add (mt_src_out[i]);
            }
        } else {
            for (int i = 0; i < source_paths.length; i++) {
                string src;
                try {
                    src = Host.read_file (source_paths[i]);
                } catch (FileError e) {
                    Host.eprintln (@"planc: cannot read $(source_paths[i]): $(e.message)");
                    return 1;
                }
                try {
                    src = Preprocessor.run (src, defines);
                } catch (LexError e) {
                    Host.eprintln (@"planc: $(source_paths[i]): lexical error: $(e.message)");
                    return 1;
                }
                sources.add (src);
            }
        }

        Diagnostics.init (error_recovery, error_limit);

        var program = new Program ();
        string current_parse_file = "";
        try {
            for (int i = 0; i < sources.length; i++) {
                current_parse_file = source_paths[i];
                int pe = program.enums.length;
                int ps = program.structs.length;
                int pc = program.classes.length;
                Parser.prescan_types (sources[i], program);
                for (int k = pe; k < program.enums.length; k++)
                    program.enums[k].file = source_paths[i];
                for (int k = ps; k < program.structs.length; k++)
                    program.structs[k].file = source_paths[i];
                for (int k = pc; k < program.classes.length; k++)
                    program.classes[k].file = source_paths[i];
            }
            for (int i = 0; i < sources.length; i++) {
                current_parse_file = source_paths[i];
                Diagnostics.current_file = source_paths[i];
                int pf = program.functions.length;
                int pg = program.globals.length;
                int pco = program.consts.length;
                int pe = program.enums.length;
                int ps = program.structs.length;
                int pc = program.classes.length;
                var parser = new Parser.with_program (sources[i], program);
                parser.recover = error_recovery;
                parser.parse_unit ();
                for (int k = pf; k < program.functions.length; k++)
                    program.functions[k].file = source_paths[i];
                for (int k = pg; k < program.globals.length; k++)
                    program.globals[k].file = source_paths[i];
                for (int k = pco; k < program.consts.length; k++)
                    program.consts[k].file = source_paths[i];
                for (int k = pe; k < program.enums.length; k++)
                    program.enums[k].file = source_paths[i];
                for (int k = ps; k < program.structs.length; k++)
                    program.structs[k].file = source_paths[i];
                for (int k = pc; k < program.classes.length; k++)
                    program.classes[k].file = source_paths[i];
            }
            current_parse_file = "";
            for (int i = 0; i < program.classes.length; i++) {
                var cd = program.classes[i];
                if (cd.file != "") {
                    for (int j = 0; j < cd.methods.length; j++)
                        if (cd.methods[j].file == "") cd.methods[j].file = cd.file;
                    for (int j = 0; j < cd.named_ctors.length; j++)
                        if (cd.named_ctors[j].file == "") cd.named_ctors[j].file = cd.file;
                    if (cd.ctor != null && cd.ctor.file == "") cd.ctor.file = cd.file;
                    if (cd.dtor != null && cd.dtor.file == "") cd.dtor.file = cd.file;
                }
            }
            for (int i = 0; i < program.structs.length; i++) {
                var sd = program.structs[i];
                if (sd.file != "") {
                    for (int j = 0; j < sd.methods.length; j++)
                        if (sd.methods[j].file == "") sd.methods[j].file = sd.file;
                }
            }
            for (int i = 0; i < program.enums.length; i++) {
                var ed = program.enums[i];
                if (ed.file != "") {
                    for (int j = 0; j < ed.methods.length; j++)
                        if (ed.methods[j].file == "") ed.methods[j].file = ed.file;
                }
            }
            program.monomorphize_all ();
            if (program.find ("main") == null && Diagnostics.count () == 0) {
                if (emit_format == 2) {
                    var stub_p = new Parser.with_program ("int main () { return 0; }", program);
                    stub_p.parse_unit ();
                } else {
                    throw new ParseError.MISSING_MAIN ("the program does not define main");
                }
            }
        } catch (LexError e) {
            Diagnostics.add (current_parse_file, Diagnostics.pos_line (e.message),
                             Diagnostics.pos_column (e.message), "lexical error", e.message);
        } catch (ParseError e) {
            Diagnostics.add (current_parse_file, Diagnostics.pos_line (e.message),
                             Diagnostics.pos_column (e.message), "syntax error", e.message);
        }

        if (Diagnostics.count () > 0)
            return Diagnostics.report ();

        if (opt_level > 0) {
            Optimizer.optimize (program, opt_level);
        }

        if (target_spirv) {
            try {
                var spv = new SpirvBackend ();
                var spv_bytes = spv.generate (program);
                Host.write_file (output_path, spv_bytes);
            } catch (SemanticError e) {
                Host.eprintln (@"planc: semantic error: $(e.message)");
                return 1;
            } catch (FileError e) {
                Host.eprintln (@"planc: $(e.message)");
                return 1;
            }
            return 0;
        }

        var codegen = new Codegen ();
        codegen.bounds_check = bounds_check;
        codegen.null_check = null_check;
        codegen.strict_null = strict_null;
        codegen.strict_unused = strict_unused;
        codegen.warn_unused = warn_unused;
        codegen.check_overflow = check_overflow;
        codegen.allow_asm = allow_asm;
        codegen.check_leaks = check_leaks;
        codegen.freestanding = freestanding;
        codegen.target_planetos = target_planetos;
        codegen.opt_level = opt_level;
        try {
            codegen.generate (program);
        } catch (SemanticError e) {
            Diagnostics.add (codegen.current_file, Diagnostics.pos_line (e.message),
                             Diagnostics.pos_column (e.message), "semantic error", e.message);
        }

        if (Diagnostics.count () > 0)
            return Diagnostics.report ();
        var text = codegen.emitter.code.to_array ();
        var rodata = codegen.emitter.data.to_array ();
        var data = codegen.emitter.init_data.to_array ();
        uint64 base_addr = target_planetos ? (uint64) 0x800000 : Elf.BASE_ADDRESS;
        if (image_base != 0)
            base_addr = image_base;
        var layout = Elf.compute (text.length, rodata.length, data.length,
                                  codegen.emitter.bss_size, codegen.symbols, base_addr);

        // Relocation pass 1: .text -> allocated data references.
        // disp32 = target - (address of the next instruction)
        foreach (var patch in codegen.emitter.patches) {
            var next = layout.text_vaddr + (uint64) patch.displacement + 4;
            uint64 target;
            switch (patch.space) {
                case PatchSpace.RODATA:
                    target = layout.rodata_vaddr + (uint64) patch.target;
                    break;
                case PatchSpace.DATA:
                    target = layout.data_vaddr + (uint64) patch.target;
                    break;
                default: // BSS: zeroed memory right after .data
                    target = layout.data_vaddr + (uint64) layout.data_size
                           + (uint64) patch.target;
                    break;
            }
            var delta = (int64) target - (int64) next;
            if (delta < int32.MIN || delta > int32.MAX) {
                Host.eprintln (@"planc: reference out of range at 0x$(Host.hex_u32 ((uint32) patch.displacement))");
                return 1;
            }
            var value = (uint32) (int32) delta;
            for (int k = 0; k < 4; k++)
                text[patch.displacement + k] = (uint8) ((value >> (8 * k)) & 0xff);
        }

        // Relocation pass 2: call rel32 to a .text symbol.
        var sym_index = new StrIndexMap ();
        for (int si = 0; si < codegen.symbols.length; si++) {
            if (sym_index.lookup (codegen.symbols[si].name) < 0)
                sym_index.put (codegen.symbols[si].name, si + 1);
        }
        foreach (var patch in codegen.emitter.calls) {
            var delta = (int64) int32.MIN - 1;
            var sym_i = sym_index.lookup (patch.callee);
            if (sym_i > 0) {
                var s = codegen.symbols[sym_i - 1];
                delta = (int64) s.offset - (int64) (patch.displacement + 4);
            }
            if (delta < int32.MIN || delta > int32.MAX) {
                Host.eprintln (@"planc: call target out of range for $(patch.callee) at 0x$(Host.hex_u32 ((uint32) patch.displacement))");
                return 1;
            }
            var value = (uint32) (int32) delta;
            for (int k = 0; k < 4; k++)
                text[patch.displacement + k] = (uint8) ((value >> (8 * k)) & 0xff);
        }

        // Relocation pass 3: conditional and unconditional branches. Both
        // ends live in .text, so the delta is offset-to-offset.
        foreach (var patch in codegen.emitter.branches) {
            if (patch.label.target < 0) {
                Host.panic (@"unbound label at 0x$(Host.hex_u32 ((uint32) patch.displacement))");
                return 1;
            }
            var delta = (int64) patch.label.target - (int64) (patch.displacement + 4);
            if (delta < int32.MIN || delta > int32.MAX) {
                Host.eprintln (@"planc: branch out of range at 0x$(Host.hex_u32 ((uint32) patch.displacement))");
                return 1;
            }
            var value = (uint32) (int32) delta;
            for (int k = 0; k < 4; k++)
                text[patch.displacement + k] = (uint8) ((value >> (8 * k)) & 0xff);
        }

        // Relocation pass 4: .data -> .rodata absolute 64-bit pointers (R_X86_64_64).
        foreach (var patch in codegen.emitter.data_patches) {
            uint64 target = layout.rodata_vaddr + (uint64) patch.rodata_target;
            for (int k = 0; k < 8; k++)
                data[patch.data_offset + k] = (uint8) ((target >> (8 * k)) & 0xff);
        }

        // Relocation pass 5: .rodata -> .text / .rodata 64-bit vtable pointers.
        foreach (var patch in codegen.emitter.rodata_patches) {
            uint64 target = 0;
            if (patch.is_text) {
                bool found_sym = false;
                foreach (var s in codegen.symbols) {
                    if (s.name == patch.text_symbol) {
                        target = layout.text_vaddr + (uint64) s.offset;
                        found_sym = true;
                        break;
                    }
                }
                if (!found_sym) {
                    Host.panic (@"unresolved rodata text target '$(patch.text_symbol)'");
                    return 1;
                }
            } else {
                target = layout.rodata_vaddr + (uint64) patch.rodata_target;
            }
            for (int k = 0; k < 8; k++)
                rodata[patch.rodata_offset + k] = (uint8) ((target >> (8 * k)) & 0xff);
        }

        if (dump) {
            Host.eprintln (@".text: $(text.length) bytes");
            for (int i = 0; i < text.length; i++)
                Host.eprint (@"$(Host.hex_u8 (text[i]))$((i % 16 == 15) ? "\n" : " ")");
            Host.eprintln (@".rodata: $(rodata.length) bytes");
        }

        uint8[] debug_line;
        uint8[] debug_abbrev;
        uint8[] debug_info;
        Dwarf.build (source_paths[0], layout.text_vaddr, text.length,
                     codegen.debug_lines, codegen.debug_funcs,
                     out debug_line, out debug_abbrev, out debug_info);
        Elf.set_dwarf_sizes (ref layout, debug_line.length, debug_abbrev.length, debug_info.length);

        string entry_sym = "_start";
        if (freestanding) {
            foreach (var sym in codegen.symbols) {
                if (sym.name == "_kstart32") {
                    entry_sym = "_kstart32";
                    break;
                }
            }
        }
        uint8[] image;
        if (emit_format > 0) {
            image = Elf.build_plan (text, rodata, data, codegen.symbols, layout,
                                    entry_sym, emit_format == 2);
        } else {
            image = Elf.build (text, rodata, data, codegen.symbols, layout,
                               debug_line, debug_abbrev, debug_info, entry_sym);
        }

        try {
            Host.write_file (output_path, image);
        } catch (FileError e) {
            Host.eprintln (@"planc: cannot write $output_path: $(e.message)");
            return 1;
        }

        Host.chmod_755 (output_path);
        return 0;
    }
}
