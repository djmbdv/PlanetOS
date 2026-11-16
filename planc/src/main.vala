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

    private const string USAGE = "usage: planc <source.vala>... -o <output> [--dump-text] [--no-bounds-check] [--no-null-check] [--check-leaks]";

    public static int main (string[] args) {
        var source_paths = new GenericArray<string> ();
        var output_path = "";
        var dump = false;
        var bounds_check = true;
        var null_check = true;
        var check_leaks = false;
        var freestanding = false;
        var target_planetos = false;
        var target_spirv = false;
        uint64 image_base = 0;

        for (int i = 1; i < args.length; i++) {
            var a = args[i];
            if (a == "-o") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                output_path = args[++i];
            } else if (a == "--dump-text") {
                dump = true;
            } else if (a == "--no-bounds-check") {
                bounds_check = false;
            } else if (a == "--no-null-check") {
                null_check = false;
            } else if (a == "--check-leaks") {
                check_leaks = true;
            } else if (a == "--freestanding") {
                freestanding = true;
            } else if (a == "--target=planetos") {
                target_planetos = true;
            } else if (a == "--target=spirv") {
                target_spirv = true;
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

        var sources = new GenericArray<string> ();
        for (int i = 0; i < source_paths.length; i++) {
            string src;
            try {
                src = Host.read_file (source_paths[i]);
            } catch (FileError e) {
                Host.eprintln (@"planc: cannot read $(source_paths[i]): $(e.message)");
                return 1;
            }
            sources.add (src);
        }

        var program = new Program ();
        try {
            for (int i = 0; i < sources.length; i++)
                Parser.prescan_types (sources[i], program);
            for (int i = 0; i < sources.length; i++) {
                var parser = new Parser.with_program (sources[i], program);
                parser.parse_unit ();
            }
            program.monomorphize_all ();
            if (program.find ("main") == null)
                throw new ParseError.MISSING_MAIN ("the program does not define main");
        } catch (LexError e) {
            Host.eprintln (@"planc: lexical error: $(e.message)");
            return 1;
        } catch (ParseError e) {
            Host.eprintln (@"planc: syntax error: $(e.message)");
            return 1;
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
        codegen.check_leaks = check_leaks;
        codegen.freestanding = freestanding;
        codegen.target_planetos = target_planetos;
        try {
            codegen.generate (program);
        } catch (SemanticError e) {
            Host.eprintln (@"planc: semantic error: $(e.message)");
            return 1;
        }
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
        foreach (var patch in codegen.emitter.calls) {
            var delta = (int64) int32.MIN - 1;
            foreach (var s in codegen.symbols) {
                if (s.name == patch.callee) {
                    delta = (int64) s.offset - (int64) (patch.displacement + 4);
                    break;
                }
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
        var image = Elf.build (text, rodata, data, codegen.symbols, layout,
                               debug_line, debug_abbrev, debug_info, entry_sym);

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
