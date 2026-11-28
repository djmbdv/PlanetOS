using Planc;

namespace Plan2Vala {

    public static int main (string[] args) {
        string input_path = "";
        string output_path = "";
        bool strip_asm = true;
        var defines = new GenericArray<string> ();

        for (int i = 1; i < args.length; i++) {
            string a = args[i];
            if (a == "-o" && i + 1 < args.length) {
                output_path = args[++i];
            } else if (a == "-D" && i + 1 < args.length) {
                defines.add (args[++i]);
            } else if (a.has_prefix ("-D")) {
                defines.add (a.substring (2));
            } else if (a == "--keep-asm") {
                strip_asm = false;
            } else if (a == "--strip-asm") {
                strip_asm = true;
            } else if (!a.has_prefix ("-")) {
                input_path = a;
            } else {
                Host.eprintln (@"plan2vala: unknown option '$a'");
                return 2;
            }
        }

        if (input_path == "") {
            Host.eprintln ("usage: plan2vala <input.plan|input.vala> [-o <output.vala>] [-D NAME] [--strip-asm|--keep-asm]");
            return 2;
        }

        string src;
        try {
            src = Host.read_file (input_path);
        } catch (Planc.FileError e) {
            Host.eprintln (@"plan2vala: cannot read $input_path: $(e.message)");
            return 1;
        }

        var tr = new Translator (strip_asm);
        string out_vala;
        try {
            out_vala = tr.translate (src, defines);
        } catch (LexError e) {
            Host.eprintln (@"plan2vala: $input_path: lexical error: $(e.message)");
            return 1;
        }

        if (output_path == "") {
            print ("%s", out_vala);
            return 0;
        }

        try {
            Host.write_file (output_path, out_vala.data);
        } catch (Planc.FileError e) {
            Host.eprintln (@"plan2vala: cannot write $output_path: $(e.message)");
            return 1;
        }
        return 0;
    }
}
