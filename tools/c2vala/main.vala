// CLI entry point for the pure-Vala C -> Vala translator.

using Planc;

namespace C2Vala {

    private const string USAGE = "usage: c2vala <input.c>... [-I dir] [-D NAME[=VAL]] [--namespace Name] [-o out.vala] [--report]";

    private static int count_lines (string s) {
        if (s.length == 0)
            return 0;
        int n = 1;
        for (int i = 0; i < s.length; i++) {
            if (s[i] == '\n')
                n++;
        }
        return n;
    }

    public static int main (string[] args) {
        var inputs = new GenericArray<string> ();
        var include_dirs = new GenericArray<string> ();
        var defines = new GenericArray<string> ();
        string output_path = "";
        string ns_name = "";
        bool report_mode = false;
        bool verbose = false;

        for (int i = 1; i < args.length; i++) {
            string a = args[i];
            if (a == "-o") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                output_path = args[++i];
            } else if (a == "-I") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                include_dirs.add (args[++i]);
            } else if (a.has_prefix ("-I") && a.length > 2) {
                include_dirs.add (a.substring (2));
            } else if (a == "-D") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                defines.add (args[++i]);
            } else if (a.has_prefix ("-D") && a.length > 2) {
                defines.add (a.substring (2));
            } else if (a == "--cc") {
                if (i + 1 < args.length)
                    i++;
            } else if (a == "--namespace") {
                if (i + 1 >= args.length) {
                    Host.eprintln (USAGE);
                    return 2;
                }
                ns_name = args[++i];
            } else if (a.has_prefix ("--namespace=")) {
                ns_name = a.substring (12);
            } else if (a == "--report") {
                report_mode = true;
            } else if (a == "-v" || a == "--verbose") {
                verbose = true;
            } else if (a == "-h" || a == "--help") {
                Host.println (USAGE);
                return 0;
            } else if (a.has_prefix ("-")) {
                Host.eprintln (@"c2vala: unknown option '$a'");
                return 2;
            } else {
                inputs.add (a);
            }
        }

        if (inputs.length == 0) {
            Host.eprintln (USAGE);
            return 2;
        }

        var pp = new Preprocessor ();
        pp.verbose = verbose;
        for (int i = 0; i < include_dirs.length; i++)
            pp.add_include_dir (include_dirs[i]);

        for (int i = 0; i < defines.length; i++) {
            string d = defines[i];
            int eq = d.index_of ("=");
            if (eq >= 0) {
                pp.define_object (d.substring (0, eq), d.substring (eq + 1));
            } else {
                pp.define_object (d, "1");
            }
        }

        var all_lines = new GenericArray<PreLine> ();
        try {
            if (verbose) Host.eprintln ("[c2vala] 1/4 preproc...");
            for (int i = 0; i < inputs.length; i++) {
                var lines = pp.process_file (inputs[i]);
                for (int li = 0; li < lines.length; li++)
                    all_lines.add (lines[li]);
            }

            if (verbose) Host.eprintln (@"[c2vala] 2/4 lex ($(all_lines.length) lines)...");
            var toks = CLexer.tokenize (all_lines);
            if (verbose) Host.eprintln (@"[c2vala] 3/4 parse ($(toks.length) toks)...");
            var parser = new CParser (toks);
            var tu = parser.parse_tu ();

            if (verbose) Host.eprintln (@"[c2vala] 4/4 translate ($(tu.funcs.length) funcs)...");
            var tr = new Translator (tu);
            string vala_out = tr.translate (report_mode, ns_name);

            if (output_path != "") {
                try {
                    Host.write_file (output_path, vala_out.data);
                } catch (FileError e) {
                    Host.eprintln (@"c2vala: cannot write $output_path: $(e.message)");
                    return 2;
                }
                int nlines = count_lines (vala_out);
                Host.println (@"c2vala: wrote $output_path ($nlines lines)");
            } else {
                Host.println (vala_out);
            }

            if (report_mode) {
                int total = tr.report_entries.length;
                Host.println (@"c2vala report: $total function(s)");
                for (int i = 0; i < total; i++) {
                    var r = tr.report_entries[i];
                    if (r.ok) {
                        Host.println (@"  ok       $(r.name)");
                    } else {
                        Host.println (@"  refused  $(r.name)  $(r.reason)");
                    }
                }
                Host.println (@"  $(tr.translated_count) translated, $(tr.refused_count) refused");
                if (tr.refused_count > 0)
                    return 3;
            } else if (tr.refused_count > 0) {
                Host.eprintln (@"c2vala: $(tr.refused_count) function(s) left as stubs; look for \"c2vala: UNTRANSLATED\" in the output");
                return 3;
            }
            return 0;
        } catch (RefuseError e) {
            Host.eprintln (@"c2vala: $(e.message)");
            return 2;
        }
    }
}
