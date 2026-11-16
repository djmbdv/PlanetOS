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

        for (int i = 1; i < args.length; i++) {
            var a = args[i];
            if (a == "-o") {
                if (i + 1 >= args.length) {
                    stderr.printf ("%s\n", USAGE);
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
            } else if (a == "-h" || a == "--help") {
                stdout.printf ("%s\n", USAGE);
                return 0;
            } else if (a.has_prefix ("-")) {
                stderr.printf ("unknown option: %s\n%s\n", a, USAGE);
                return 2;
            } else {
                source_paths.add (a);
            }
        }

        if (source_paths.length == 0 || output_path == "") {
            stderr.printf ("%s\n", USAGE);
            return 2;
        }

        var sources = new GenericArray<string> ();
        for (int i = 0; i < source_paths.length; i++) {
            string src;
            try {
                FileUtils.get_contents (source_paths[i], out src);
            } catch (FileError e) {
                stderr.printf ("planc: cannot read %s: %s\n", source_paths[i], e.message);
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
            if (program.find ("main") == null)
                throw new ParseError.MISSING_MAIN ("the program does not define main");
        } catch (LexError e) {
            stderr.printf ("planc: lexical error: %s\n", e.message);
            return 1;
        } catch (ParseError e) {
            stderr.printf ("planc: syntax error: %s\n", e.message);
            return 1;
        }

        var codegen = new Codegen ();
        codegen.bounds_check = bounds_check;
        codegen.null_check = null_check;
        codegen.check_leaks = check_leaks;
        try {
            codegen.generate (program);
        } catch (SemanticError e) {
            stderr.printf ("planc: semantic error: %s\n", e.message);
            return 1;
        }
        var text = codegen.emitter.code.to_array ();
        var rodata = codegen.emitter.data.to_array ();
        var data = codegen.emitter.init_data.to_array ();
        var layout = Elf.compute (text.length, rodata.length, data.length,
                                  codegen.emitter.bss_size, codegen.symbols);

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
                stderr.printf ("planc: reference out of range at 0x%x\n", patch.displacement);
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
                stderr.printf ("planc: call target out of range for %s at 0x%x\n",
                               patch.callee, patch.displacement);
                return 1;
            }
            var value = (uint32) (int32) delta;
            for (int k = 0; k < 4; k++)
                text[patch.displacement + k] = (uint8) ((value >> (8 * k)) & 0xff);
        }

        // Relocation pass 3: conditional and unconditional branches. Both
        // ends live in .text, so the delta is offset-to-offset.
        foreach (var patch in codegen.emitter.branches) {
            if (patch.label.target < 0)
                error ("unbound label at 0x%x", patch.displacement);
            var delta = (int64) patch.label.target - (int64) (patch.displacement + 4);
            if (delta < int32.MIN || delta > int32.MAX) {
                stderr.printf ("planc: branch out of range at 0x%x\n", patch.displacement);
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
                if (!found_sym)
                    error ("unresolved rodata text target '%s'", patch.text_symbol);
            } else {
                target = layout.rodata_vaddr + (uint64) patch.rodata_target;
            }
            for (int k = 0; k < 8; k++)
                rodata[patch.rodata_offset + k] = (uint8) ((target >> (8 * k)) & 0xff);
        }

        if (dump) {
            stderr.printf (".text: %d bytes\n", text.length);
            for (int i = 0; i < text.length; i++)
                stderr.printf ("%02x%s", text[i], (i % 16 == 15) ? "\n" : " ");
            stderr.printf (".rodata: %d bytes\n", rodata.length);
        }

        var image = Elf.build (text, rodata, data, codegen.symbols, layout);

        try {
            FileUtils.set_contents (output_path, (string) image, image.length);
        } catch (FileError e) {
            stderr.printf ("planc: cannot write %s: %s\n", output_path, e.message);
            return 1;
        }

        FileUtils.chmod (output_path, 0755);
        return 0;
    }
}
