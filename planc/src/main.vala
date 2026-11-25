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

    private sealed class ImportAddr : Object {
        public uint64 addr;
        public uint64 dlib_hash;
        public string sym_name;
        public ImportAddr (uint64 a, uint64 dh, string sn) {
            addr = a;
            dlib_hash = dh;
            sym_name = sn;
        }
    }

    private const string USAGE = "usage: planc <source.vala>... -o <output> [-D NAME] [--dump-text] [--no-bounds-check] [--no-null-check] [--check-leaks] [--debug-memory] [--strict-visibility] [--enforce-visibility] [--error-limit N] [--no-error-recovery]";

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
    private static int mt_src_next = 0;
    private static int[] mt_src_lock;

    private static GenericArray<ParseChunk> mt_parse_chunks;
    private static GenericArray<string> mt_parse_sources;
    private static GenericArray<string> mt_parse_paths;
    private static Program mt_parse_types_prog;
    private static bool mt_parse_recover = true;
    private static int mt_parse_next = 0;
    private static int[] mt_parse_lock;

    private static void mt_parse_worker (int wid) {
        int n = mt_parse_chunks.length;
        while (true) {
            Host.spin_lock (mt_parse_lock);
            int ci = mt_parse_next++;
            Host.spin_unlock (mt_parse_lock);
            if (ci >= n)
                break;
            var ch = mt_parse_chunks[ci];
            var out_prog = new Program ();
            var parser = new Parser.for_chunk (
                mt_parse_sources[ch.file_idx],
                ch.start_pos, ch.end_pos, ch.start_line, ch.start_col,
                mt_parse_types_prog, out_prog);
            parser.recover = mt_parse_recover;
            try {
                parser.parse_unit ();
            } catch (LexError e) {
                ch.err_kind = "lexical error";
                ch.err_msg = e.message;
            } catch (ParseError e) {
                ch.err_kind = "syntax error";
                ch.err_msg = e.message;
            }
            ch.result = out_prog;
        }
    }

    private static void mt_preproc_worker (int wid) {
        int n = mt_src_paths.length;
        while (true) {
            Host.spin_lock (mt_src_lock);
            int i = mt_src_next++;
            Host.spin_unlock (mt_src_lock);
            if (i >= n)
                break;
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
        var strict_visibility = false;
        var enforce_visibility = false;
        var debug_memory = false;
        var asm_anywhere = false;
        var strict_ownership = false;
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
        var target_windows = false;
        var nostdlib = false;
        string library_dir = Host.getenv ("PLANETOS_LIBRARY_DIR");
        if (library_dir == "" && Host.getenv ("OS") == "PlanetOS")
            library_dir = "/library";
        int emit_format = 0; // 0 = elf, 1 = plan, 2 = dlib
        var import_dlibs = new GenericArray<string> ();
        var hlib_paths = new GenericArray<string> ();
        var hlib_seen = new StrIndexMap ();
        var import_map = new StrIndexMap ();
        var import_addrs = new GenericArray<ImportAddr> ();
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
            } else if (a == "--strict-visibility") {
                strict_visibility = true;
            } else if (a == "--enforce-visibility") {
                enforce_visibility = true;
            } else if (a == "--debug-memory") {
                debug_memory = true;
            } else if (a == "--allow-asm-anywhere") {
                asm_anywhere = true;
            } else if (a == "--strict-ownership") {
                strict_ownership = true;
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
            } else if (a == "--nostdlib") {
                nostdlib = true;
            } else if (a.has_prefix ("--library-dir=")) {
                library_dir = a.substring (14);
            } else if (a == "--target=planetos") {
                target_planetos = true;
            } else if (a == "--target=windows") {
                target_windows = true;
            } else if (a == "--target=spirv") {
                target_spirv = true;
            } else if (a == "--format=elf") {
                emit_format = 0;
            } else if (a == "--format=plan") {
                emit_format = 1;
            } else if (a == "--format=dlib") {
                emit_format = 2;
            } else if (a.has_prefix ("--import-dlib=")) {
                import_dlibs.add (a.substring (14));
            } else if (a.has_prefix ("--import-lib=")) {
                string lname = a.substring (13);
                if (lname.has_suffix (".dlib") || lname.contains ("/") || lname.contains ("\\")) {
                    import_dlibs.add (lname);
                } else if (library_dir != "") {
                    import_dlibs.add (@"$library_dir/$lname/$lname.dlib");
                } else {
                    import_dlibs.add (@"library/$lname/$lname.dlib");
                }
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

        // Implicit glib linking on PlanetOS unless --freestanding, --nostdlib,
        // or building glib.dlib itself.
        if (target_planetos && !freestanding && !nostdlib && library_dir != "") {
            bool building_glib = (emit_format == 2) &&
                (output_path == "glib.dlib" || output_path.has_suffix ("/glib.dlib") || output_path.has_suffix ("\\glib.dlib"));
            bool has_glib = false;
            for (int di = 0; di < import_dlibs.length; di++) {
                string dp = import_dlibs[di];
                if (dp == "glib.dlib" || dp.has_suffix ("/glib.dlib") || dp.has_suffix ("\\glib.dlib")) {
                    has_glib = true;
                    break;
                }
            }
            if (!building_glib && !has_glib) {
                string imp_glib = @"$library_dir/glib/glib.dlib";
                // Prepend so glib is loaded before higher-level libraries.
                var new_imps = new GenericArray<string> ();
                new_imps.add (imp_glib);
                for (int di = 0; di < import_dlibs.length; di++)
                    new_imps.add (import_dlibs[di]);
                import_dlibs = new_imps;
            }
        }

        for (int di = 0; di < import_dlibs.length; di++) {
            string dpath = import_dlibs[di];
            string hpath = dpath.has_suffix (".dlib")
                ? (dpath.substring (0, dpath.length - 5) + ".hlib")
                : (dpath + ".hlib");
            if (hlib_seen.lookup (hpath) < 0) {
                try {
                    Host.read_file (hpath);
                    hlib_seen.put (hpath, 1);
                    hlib_paths.add (hpath);
                } catch (FileError e) {
                    // Optional .hlib: caller may still pass raw .vala declarations.
                }
            }
            uint8[] dbuf;
            try {
                dbuf = Host.read_bytes (dpath);
            } catch (FileError e) {
                Host.eprintln (@"planc: cannot read dlib '$dpath': $(e.message)");
                return 1;
            }
            if (dbuf.length < 64 || dbuf[0] != 'P' || dbuf[1] != 'L' || dbuf[2] != 'A' || dbuf[3] != 'N') {
                Host.eprintln (@"planc: '$dpath' is not a valid .dlib");
                return 1;
            }
            int exp_count = (int) ((uint32) dbuf[28] | ((uint32) dbuf[29] << 8)
                                 | ((uint32) dbuf[30] << 16) | ((uint32) dbuf[31] << 24));
            uint64 meta_off = 0;
            for (int k = 0; k < 8; k++)
                meta_off |= ((uint64) dbuf[40 + k]) << (k * 8);
            int pos = (int) meta_off;
            string dbase = dpath;
            for (int k = dpath.length - 1; k >= 0; k--) {
                if (dpath[k] == '/' || dpath[k] == '\\') {
                    dbase = dpath.substring (k + 1);
                    break;
                }
            }
            uint64 dlib_h = Elf.fnv1a_64 (dbase);
            for (int ei = 0; ei < exp_count && pos + 12 <= dbuf.length; ei++) {
                uint64 saddr = 0;
                for (int k = 0; k < 8; k++)
                    saddr |= ((uint64) dbuf[pos + k]) << (k * 8);
                int nlen = (int) ((uint32) dbuf[pos + 8] | ((uint32) dbuf[pos + 9] << 8)
                                | ((uint32) dbuf[pos + 10] << 16) | ((uint32) dbuf[pos + 11] << 24));
                pos += 12;
                if (nlen <= 0 || pos + nlen > dbuf.length)
                    break;
                var nsl = new uint8[nlen];
                for (int k = 0; k < nlen; k++)
                    nsl[k] = dbuf[pos + k];
                string sname = Host.bytes_to_string (nsl, nlen);
                pos += nlen;
                if (import_map.lookup (sname) < 0) {
                    import_addrs.add (new ImportAddr (saddr, dlib_h, sname));
                    import_map.put (sname, import_addrs.length);
                }
            }
        }

        int own_source_start = hlib_paths.length;
        if (own_source_start > 0) {
            var all_paths = new GenericArray<string> ();
            for (int hi = 0; hi < hlib_paths.length; hi++)
                all_paths.add (hlib_paths[hi]);
            for (int si = 0; si < source_paths.length; si++)
                all_paths.add (source_paths[si]);
            source_paths = all_paths;
        }

        var sources = new GenericArray<string> ();
        int ncpus = Host.cpu_count ();
        if (source_paths.length >= 2 && ncpus > 1) {
            int nw = (ncpus < source_paths.length) ? ncpus : source_paths.length;
            mt_src_paths = source_paths;
            mt_defines = defines;
            mt_src_out = new string[source_paths.length];
            mt_src_err = new string[source_paths.length];
            for (int i = 0; i < source_paths.length; i++) {
                mt_src_out[i] = "";
                mt_src_err[i] = "";
            }
            mt_src_next = 0;
            mt_src_lock = new int[1];
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
            program.sync_indexes ();
            for (int i = 0; i < sources.length; i++) {
                current_parse_file = source_paths[i];
                Diagnostics.current_file = source_paths[i];
                if (ncpus > 1 && sources[i].length >= 131072) {
                    var chunks = new GenericArray<ParseChunk> ();
                    Parser.split_chunks (sources[i], i, 65536, chunks);
                    if (chunks.length >= 2) {
                        int nw = (ncpus < chunks.length) ? ncpus : chunks.length;
                        mt_parse_chunks = chunks;
                        mt_parse_sources = sources;
                        mt_parse_paths = source_paths;
                        mt_parse_types_prog = program;
                        mt_parse_recover = error_recovery;
                        mt_parse_next = 0;
                        mt_parse_lock = new int[1];
                        int64[] handles = new int64[nw];
                        for (int wi = 1; wi < nw; wi++)
                            handles[wi] = Host.thread_spawn (mt_parse_worker, wi);
                        mt_parse_worker (0);
                        for (int wi = 1; wi < nw; wi++)
                            Host.thread_join (handles[wi]);

                        for (int ci = 0; ci < chunks.length; ci++) {
                            var ch = chunks[ci];
                            if (ch.err_msg != "") {
                                if (!error_recovery) {
                                    if (ch.err_kind == "lexical error")
                                        throw new LexError.UNEXPECTED_CHARACTER (ch.err_msg);
                                    else
                                        throw new ParseError.UNEXPECTED_TOKEN (ch.err_msg);
                                }
                                Diagnostics.add (source_paths[i], Diagnostics.pos_line (ch.err_msg),
                                                 Diagnostics.pos_column (ch.err_msg), ch.err_kind, ch.err_msg);
                            } else if (ch.result != null) {
                                program.merge_from ((!) ch.result, source_paths[i]);
                            }
                        }
                        program.sync_indexes ();
                        continue;
                    }
                }
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
                program.sync_indexes ();
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
        codegen.strict_visibility = strict_visibility;
        codegen.enforce_visibility = enforce_visibility;
        codegen.debug_memory = debug_memory;
        codegen.asm_anywhere = asm_anywhere;
        codegen.strict_ownership = strict_ownership;
        codegen.warn_unused = warn_unused;
        codegen.check_overflow = check_overflow;
        codegen.allow_asm = allow_asm;
        codegen.check_leaks = check_leaks;
        codegen.freestanding = freestanding;
        codegen.target_planetos = target_planetos;
        codegen.target_windows = target_windows;
        codegen.opt_level = opt_level;
        if (import_addrs.length > 0)
            codegen.imported_syms = import_map;
        codegen.abi_stable_classes = (emit_format == 2) || (import_addrs.length > 0);
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

        var sym_index = new StrIndexMap ();
        for (int si = 0; si < codegen.symbols.length; si++) {
            if (sym_index.lookup (codegen.symbols[si].name) < 0)
                sym_index.put (codegen.symbols[si].name, si + 1);
        }

        // Collect actually-referenced imported symbols and reserve a 6-byte
        // `jmp *slot(%rip)` stub in .text + an 8-byte GOT slot in .data.
        var used_imp_map = new StrIndexMap ();
        var used_imp_idx = new GenericArray<int> ();
        if (!target_windows && import_addrs.length > 0) {
            foreach (var patch in codegen.emitter.calls) {
                if (sym_index.lookup (patch.callee) < 0) {
                    var imp_i = import_map.lookup (patch.callee);
                    if (imp_i > 0 && used_imp_map.lookup (patch.callee) < 0) {
                        used_imp_idx.add (imp_i - 1);
                        used_imp_map.put (patch.callee, used_imp_idx.length);
                    }
                }
            }
            foreach (var patch in codegen.emitter.rodata_patches) {
                if (patch.is_text && sym_index.lookup (patch.text_symbol) < 0) {
                    var imp_i = import_map.lookup (patch.text_symbol);
                    if (imp_i > 0 && used_imp_map.lookup (patch.text_symbol) < 0) {
                        used_imp_idx.add (imp_i - 1);
                        used_imp_map.put (patch.text_symbol, used_imp_idx.length);
                    }
                }
            }
        }
        int orig_text_len = text.length;
        int got_off = (data.length + 7) & ~7;
        if (used_imp_idx.length > 0) {
            var new_text = new uint8[orig_text_len + used_imp_idx.length * 6];
            for (int k = 0; k < orig_text_len; k++)
                new_text[k] = text[k];
            text = new_text;

            var new_data = new uint8[got_off + used_imp_idx.length * 8];
            for (int k = 0; k < data.length; k++)
                new_data[k] = data[k];
            data = new_data;
        }

        uint64 text_vaddr = 0;
        uint64 rodata_vaddr = 0;
        uint64 data_vaddr = 0;
        uint64 iat_vaddr = 0;
        int data_layout_size = data.length;
        uint64 base_addr = target_planetos ? (uint64) 0x800000 : Elf.BASE_ADDRESS;
        if (image_base != 0)
            base_addr = image_base;
        var layout = Elf.compute (text.length, rodata.length, data.length,
                                  codegen.emitter.bss_size, codegen.symbols, base_addr,
                                  used_imp_idx.length > 0);
        var pe_layout = PeLayout ();
        if (target_windows) {
            pe_layout = Pe.compute (text.length, rodata.length, data.length,
                                    codegen.emitter.bss_size, image_base);
            text_vaddr = pe_layout.text_vaddr;
            rodata_vaddr = pe_layout.rodata_vaddr;
            data_vaddr = pe_layout.data_vaddr;
            iat_vaddr = pe_layout.iat_vaddr;
            data_layout_size = pe_layout.data_size;
        } else {
            text_vaddr = layout.text_vaddr;
            rodata_vaddr = layout.rodata_vaddr;
            data_vaddr = layout.data_vaddr;
            data_layout_size = layout.data_size;
        }

        var elf_imports = new GenericArray<ImportEntry> ();
        for (int ui = 0; ui < used_imp_idx.length; ui++) {
            var imp = import_addrs[used_imp_idx[ui]];
            int stub_off = orig_text_len + ui * 6;
            uint64 stub_va = text_vaddr + (uint64) stub_off;
            int slot_off = got_off + ui * 8;
            uint64 got_va = data_vaddr + (uint64) slot_off;
            int64 disp = (int64) got_va - (int64) (stub_va + 6);
            text[stub_off + 0] = 0xFF;
            text[stub_off + 1] = 0x25;
            uint32 d32 = (uint32) (int32) disp;
            for (int k = 0; k < 4; k++)
                text[stub_off + 2 + k] = (uint8) ((d32 >> (8 * k)) & 0xff);
            for (int k = 0; k < 8; k++)
                data[slot_off + k] = (uint8) ((imp.addr >> (8 * k)) & 0xff);
            elf_imports.add (new ImportEntry (imp.dlib_hash, Elf.fnv1a_64 (imp.sym_name), got_va));
        }

        // Relocation pass 1: .text -> allocated data references.
        // disp32 = target - (address of the next instruction)
        foreach (var patch in codegen.emitter.patches) {
            var next = text_vaddr + (uint64) patch.displacement + 4;
            uint64 target;
            switch (patch.space) {
                case PatchSpace.RODATA:
                    target = rodata_vaddr + (uint64) patch.target;
                    break;
                case PatchSpace.DATA:
                    target = data_vaddr + (uint64) patch.target;
                    break;
                case PatchSpace.IAT:
                    target = iat_vaddr + (uint64) patch.target;
                    break;
                default: // BSS: zeroed memory right after .data
                    target = data_vaddr + (uint64) data_layout_size
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

        // Relocation pass 2: call rel32 to a .text symbol (or GOT stub).
        foreach (var patch in codegen.emitter.calls) {
            var delta = (int64) int32.MIN - 1;
            var sym_i = sym_index.lookup (patch.callee);
            if (sym_i > 0) {
                var s = codegen.symbols[sym_i - 1];
                delta = (int64) s.offset - (int64) (patch.displacement + 4);
            } else if (used_imp_map.lookup (patch.callee) > 0) {
                int ui = used_imp_map.lookup (patch.callee) - 1;
                int stub_off = orig_text_len + ui * 6;
                delta = (int64) stub_off - (int64) (patch.displacement + 4);
            } else if (import_addrs.length > 0) {
                var imp_i = import_map.lookup (patch.callee);
                if (imp_i > 0) {
                    uint64 imp_target = import_addrs[imp_i - 1].addr;
                    uint64 call_next = text_vaddr + (uint64) patch.displacement + 4;
                    delta = (int64) imp_target - (int64) call_next;
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
            uint64 target = rodata_vaddr + (uint64) patch.rodata_target;
            for (int k = 0; k < 8; k++)
                data[patch.data_offset + k] = (uint8) ((target >> (8 * k)) & 0xff);
        }

        // Relocation pass 5: .rodata -> .text / .rodata 64-bit vtable pointers.
        foreach (var patch in codegen.emitter.rodata_patches) {
            uint64 target = 0;
            if (patch.is_text) {
                var sym_i = sym_index.lookup (patch.text_symbol);
                if (sym_i > 0) {
                    target = text_vaddr + (uint64) codegen.symbols[sym_i - 1].offset;
                } else if (used_imp_map.lookup (patch.text_symbol) > 0) {
                    int ui = used_imp_map.lookup (patch.text_symbol) - 1;
                    target = text_vaddr + (uint64) (orig_text_len + ui * 6);
                } else {
                    var imp_i = (import_addrs.length > 0) ? import_map.lookup (patch.text_symbol) : -1;
                    if (imp_i > 0) {
                        target = import_addrs[imp_i - 1].addr;
                    } else {
                        Host.panic (@"unresolved rodata text target '$(patch.text_symbol)'");
                        return 1;
                    }
                }
            } else {
                target = rodata_vaddr + (uint64) patch.rodata_target;
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
        if (target_windows) {
            int entry_off = 0;
            var ei = sym_index.lookup (entry_sym);
            if (ei > 0)
                entry_off = codegen.symbols[ei - 1].offset;
            image = Pe.build (pe_layout, text, rodata, data, entry_off);
        } else {
            uint8[] debug_line;
            uint8[] debug_abbrev;
            uint8[] debug_info;
            Dwarf.build (source_paths[0], layout.text_vaddr, text.length,
                         codegen.debug_lines, codegen.debug_funcs,
                         out debug_line, out debug_abbrev, out debug_info);
            Elf.set_dwarf_sizes (ref layout, debug_line.length, debug_abbrev.length, debug_info.length);

            if (emit_format > 0) {
                image = Elf.build_plan (text, rodata, data, codegen.symbols, layout,
                                        entry_sym, emit_format == 2, elf_imports);
            } else {
                image = Elf.build (text, rodata, data, codegen.symbols, layout,
                                   debug_line, debug_abbrev, debug_info, entry_sym, elf_imports);
            }
        }

        try {
            Host.write_file (output_path, image);
        } catch (FileError e) {
            Host.eprintln (@"planc: cannot write $output_path: $(e.message)");
            return 1;
        }

        Host.chmod_755 (output_path);

        if (emit_format == 2) {
            string hlib_out = output_path.has_suffix (".dlib")
                ? (output_path.substring (0, output_path.length - 5) + ".hlib")
                : (output_path + ".hlib");
            var hb = new Buffer (4096);
            for (int si = own_source_start; si < sources.length; si++) {
                string sp = source_paths[si];
                string hdr = @"// ---- $sp ----\n";
                for (int k = 0; k < hdr.length; k++)
                    hb.u8 ((uint8) hdr[k]);
                string body = sources[si];
                for (int k = 0; k < body.length; k++)
                    hb.u8 ((uint8) body[k]);
                if (body.length == 0 || body[body.length - 1] != '\n')
                    hb.u8 ('\n');
            }
            try {
                Host.write_file (hlib_out, hb.to_array ());
            } catch (FileError e) {
                Host.eprintln (@"planc: cannot write $hlib_out: $(e.message)");
                return 1;
            }
        }
        return 0;
    }
}
