// PlanetOS POSIX shell (100% pure Vala, dash-inspired: quotes, variables,
// pipelines, redirections, conditionals, loops, scripts, and background jobs).

using GLib;
using Gee;
using Planet;

namespace PlanetShell {

    private class Tok : Object {
        public string text;
        public bool is_op;
        public Tok (string t, bool op) {
            text = t;
            is_op = op;
        }
    }

    private HashMap<string, string> env_map;
    private int last_status = 0;
    private string cwd = "/";

    private string int_to_s (int v) {
        return @"$v";
    }

    [AsmBody(@"
        mov (%rdi), %eax
        ret
    ")]
    private extern int peek32 (int addr);

    private string klog_cat_name (int cat) {
        if (cat == 0) return "boot";
        if (cat == 1) return "input";
        if (cat == 2) return "gpu";
        if (cat == 3) return "mem";
        if (cat == 4) return "vfs";
        if (cat == 5) return "sched";
        if (cat == 6) return "exec";
        return "?";
    }

    private int klog_cat_id (string name) {
        if (name == "boot") return 0;
        if (name == "input") return 1;
        if (name == "gpu") return 2;
        if (name == "mem") return 3;
        if (name == "vfs") return 4;
        if (name == "sched") return 5;
        if (name == "exec") return 6;
        return -1;
    }

    private string klog_lvl_name (int lvl) {
        if (lvl == 0) return "E";
        if (lvl == 1) return "W";
        if (lvl == 2) return "I";
        if (lvl == 3) return "D";
        return "?";
    }

    private string abs_path (string name) {
        if (name.length == 0)
            return cwd;
        if (name[0] == '/')
            return name;
        if (cwd == "/")
            return "/" + name;
        return cwd + "/" + name;
    }

    private string canonical_path (string path) {
        var parts = new GenericArray<string> ();
        int depth = 0;
        int i = 0;
        while (i < path.length) {
            while (i < path.length && path[i] == '/')
                i = i + 1;
            if (i >= path.length)
                break;
            int start = i;
            while (i < path.length && path[i] != '/')
                i = i + 1;
            string comp = path.substring (start, i - start);
            if (comp == ".")
                continue;
            if (comp == "..") {
                if (depth > 0)
                    depth = depth - 1;
                continue;
            }
            if (depth < parts.length)
                parts[depth] = comp;
            else
                parts.add (comp);
            depth = depth + 1;
        }
        if (depth == 0)
            return "/";
        var sb = new StringBuilder ();
        for (int k = 0; k < depth; k++) {
            sb.append ("/");
            sb.append (parts[k]);
        }
        return sb.str;
    }

    private string get_var (string name) {
        if (name == "?")
            return int_to_s (last_status);
        if (name == "$")
            return "0";
        if (name == "PWD")
            return cwd;
        if (env_map.has_key (name))
            return env_map.get (name);
        return Sys.getenv (name);
    }

    private void set_var (string name, string val) {
        env_map.set (name, val);
    }

    private void unset_var (string name) {
        env_map.unset (name);
    }

    private bool is_var_char (uint8 c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_';
    }

    private int parse_int_s (string s) {
        int neg = 1;
        int i = 0;
        if (s.length > 0 && s[0] == '-') {
            neg = -1;
            i = 1;
        }
        int v = 0;
        while (i < s.length) {
            uint8 c = s[i];
            if (c < '0' || c > '9')
                break;
            v = v * 10 + (int) (c - '0');
            i = i + 1;
        }
        return v * neg;
    }

    private string expand_dollar (string src, ref int i) {
        // src[i] == '$'
        i = i + 1;
        if (i >= src.length)
            return "$";
        uint8 c = src[i];
        if (c == '?' || c == '$') {
            i = i + 1;
            return (c == '?') ? get_var ("?") : get_var ("$");
        }
        if (c == '{') {
            i = i + 1;
            int start = i;
            while (i < src.length && src[i] != '}')
                i = i + 1;
            string nm = src.substring (start, i - start);
            if (i < src.length && src[i] == '}')
                i = i + 1;
            return get_var (nm);
        }
        if (!is_var_char (c))
            return "$";
        int start = i;
        while (i < src.length && is_var_char (src[i]))
            i = i + 1;
        return get_var (src.substring (start, i - start));
    }

    private bool is_escapable (uint8 c) {
        return c == '\\' || c == ' ' || c == '\t' || c == '\r' || c == '\n'
            || c == '\'' || c == '"' || c == '$' || c == '|' || c == '>'
            || c == '<' || c == ';' || c == '&' || c == '#';
    }

    private GenericArray<Tok> tokenize (string line) {
        var toks = new GenericArray<Tok> ();
        int n = line.length;
        int i = 0;
        while (i < n) {
            uint8 c = line[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                i = i + 1;
                continue;
            }
            if (c == '#')
                break;
            // Two-char operators: &&, ||, >>
            if (i + 1 < n) {
                uint8 c2 = line[i + 1];
                if ((c == '&' && c2 == '&') || (c == '|' && c2 == '|') || (c == '>' && c2 == '>')) {
                    toks.add (new Tok (line.substring (i, 2), true));
                    i = i + 2;
                    continue;
                }
            }
            // Single-char operators: |, >, <, ;, &
            if (c == '|' || c == '>' || c == '<' || c == ';' || c == '&') {
                toks.add (new Tok (line.substring (i, 1), true));
                i = i + 1;
                continue;
            }
            // Word with quotes and $VAR expansion
            var sb = new StringBuilder ();
            while (i < n) {
                uint8 w = line[i];
                if (w == ' ' || w == '\t' || w == '\r' || w == '\n'
                    || w == '|' || w == '>' || w == '<' || w == ';' || w == '&')
                    break;
                if (w == '\'') {
                    i = i + 1;
                    while (i < n && line[i] != '\'') {
                        sb.append_c ((char) line[i]);
                        i = i + 1;
                    }
                    if (i < n && line[i] == '\'')
                        i = i + 1;
                } else if (w == '"') {
                    i = i + 1;
                    while (i < n && line[i] != '"') {
                        uint8 dc = line[i];
                        if (dc == '\\' && i + 1 < n) {
                            i = i + 1;
                            sb.append_c ((char) line[i]);
                            i = i + 1;
                        } else if (dc == '$') {
                            sb.append (expand_dollar (line, ref i));
                        } else {
                            sb.append_c ((char) dc);
                            i = i + 1;
                        }
                    }
                    if (i < n && line[i] == '"')
                        i = i + 1;
                } else if (w == '\\' && i + 1 < n && is_escapable (line[i + 1])) {
                    i = i + 1;
                    sb.append_c ((char) line[i]);
                    i = i + 1;
                } else if (w == '$') {
                    sb.append (expand_dollar (line, ref i));
                } else {
                    sb.append_c ((char) w);
                    i = i + 1;
                }
            }
            toks.add (new Tok (sb.str, false));
        }
        return toks;
    }

    private int eval_test (GenericArray<string> args) {
        // Supports: test / [ ... ]
        int end = args.length;
        if (args[0] == "[" && end > 0 && args[end - 1] == "]")
            end = end - 1;
        int n = end - 1;
        if (n <= 0)
            return 1;
        if (n == 1)
            return (args[1].length > 0) ? 0 : 1;
        if (n == 2) {
            string op = args[1];
            string val = args[2];
            if (op == "-z") return (val.length == 0) ? 0 : 1;
            if (op == "-n") return (val.length > 0) ? 0 : 1;
            if (op == "-e") return (Sys.stat (canonical_path (abs_path (val))) != 0) ? 0 : 1;
            if (op == "-f") return (Sys.stat (canonical_path (abs_path (val))) == 1) ? 0 : 1;
            if (op == "-d") return (Sys.stat (canonical_path (abs_path (val))) == 2) ? 0 : 1;
            if (op == "!") return (val.length == 0) ? 0 : 1;
            return 1;
        }
        if (n >= 3) {
            string a = args[1];
            string op = args[2];
            string b = args[3];
            if (op == "=" || op == "==") return (a == b) ? 0 : 1;
            if (op == "!=") return (a != b) ? 0 : 1;
            int ia = parse_int_s (a);
            int ib = parse_int_s (b);
            if (op == "-eq") return (ia == ib) ? 0 : 1;
            if (op == "-ne") return (ia != ib) ? 0 : 1;
            if (op == "-lt") return (ia < ib) ? 0 : 1;
            if (op == "-le") return (ia <= ib) ? 0 : 1;
            if (op == "-gt") return (ia > ib) ? 0 : 1;
            if (op == "-ge") return (ia >= ib) ? 0 : 1;
        }
        return 1;
    }

    private int run_simple (GenericArray<Tok> toks, int lo, int hi, bool bg, out bool should_exit) {
        should_exit = false;
        var args = new GenericArray<string> ();
        string redir_in = "";
        string redir_out = "";
        bool append_out = false;

        int i = lo;
        while (i < hi) {
            Tok t = toks[i];
            if (t.is_op && (t.text == ">" || t.text == ">>" || t.text == "<")) {
                if (i + 1 < hi) {
                    if (t.text == "<") {
                        redir_in = toks[i + 1].text;
                    } else {
                        redir_out = toks[i + 1].text;
                        append_out = (t.text == ">>");
                    }
                    i = i + 2;
                    continue;
                }
            }
            if (!t.is_op)
                args.add (t.text);
            i = i + 1;
        }

        if (args.length == 0)
            return 0;

        // Handle leading VAR=VAL assignments
        int arg_off = 0;
        while (arg_off < args.length) {
            int eq = args[arg_off].index_of ("=");
            if (eq > 0) {
                string k = args[arg_off].substring (0, eq);
                bool ok_k = true;
                for (int ki = 0; ki < k.length; ki++) {
                    if (!is_var_char (k[ki])) { ok_k = false; break; }
                }
                if (ok_k) {
                    set_var (k, args[arg_off].substring (eq + 1));
                    arg_off = arg_off + 1;
                    continue;
                }
            }
            break;
        }
        if (arg_off >= args.length)
            return 0;

        var cmd_args = new GenericArray<string> ();
        for (int k = arg_off; k < args.length; k++)
            cmd_args.add (args[k]);

        // Set up kernel stdio redirection if requested
        int in_fd = -1;
        int out_fd = -1;
        if (redir_in.length > 0) {
            redir_in = canonical_path (abs_path (redir_in));
            in_fd = Sys.open (redir_in);
            if (in_fd < 0) {
                print (@"sh: cannot open '$redir_in'\n");
                return 1;
            }
        }
        if (redir_out.length > 0) {
            redir_out = canonical_path (abs_path (redir_out));
            if (append_out && FileUtils.test (redir_out, FileTest.EXISTS)) {
                out_fd = Sys.open (redir_out);
                if (out_fd >= 3)
                    Sys.seek (out_fd, -1); // seek to end
            } else {
                out_fd = Sys.create (redir_out);
            }
            if (out_fd < 0) {
                if (in_fd >= 3) Sys.close (in_fd);
                print (@"sh: cannot write '$redir_out'\n");
                return 1;
            }
        }
        if (in_fd >= 3 || out_fd >= 3)
            Sys.set_stdio (in_fd, out_fd);

        int rc = exec_command (cmd_args, bg, out should_exit);

        if (in_fd >= 3 || out_fd >= 3)
            Sys.set_stdio (-1, -1);
        if (in_fd >= 3) Sys.close (in_fd);
        if (out_fd >= 3) Sys.close (out_fd);
        return rc;
    }

    // Windows-style command resolution: a bare name gets the .elf extension and
    // matching is case-insensitive against the flat root (XFS + RAMFS).
    private uint8 ascii_fold (uint8 c) {
        return (c >= 'A' && c <= 'Z') ? c + 32 : c;
    }

    private bool ends_with_elf_ci (string s) {
        if (s.length < 4)
            return false;
        int off = s.length - 4;
        return ascii_fold (s[off]) == '.' && ascii_fold (s[off + 1]) == 'e'
            && ascii_fold (s[off + 2]) == 'l' && ascii_fold (s[off + 3]) == 'f';
    }

    private string strip_cmd_prefix (string s) {
        if (s.length > 2 && s[0] == '.' && (s[1] == '/' || s[1] == '\\'))
            return s.substring (2);
        return s;
    }

    private bool root_entry_equals_ci (uint8[] buf, int start, int len, string want) {
        if (len != want.length)
            return false;
        for (int i = 0; i < len; i++) {
            if (ascii_fold (buf[start + i]) != ascii_fold (want[i]))
                return false;
        }
        return true;
    }

    private string root_entry_str (uint8[] buf, int start, int len) {
        var sb = new StringBuilder ();
        for (int i = 0; i < len; i++)
            sb.append_c ((char) buf[start + i]);
        return sb.str;
    }

    private string find_in_dir_ci (string dir, string want, bool any_name) {
        var buf = new uint8[3584];
        int n = Sys.readdir_path (dir, buf, 3584);
        if (n <= 0)
            return "";
        string want_elf = want + ".elf";
        int start = 0;
        for (int i = 0; i <= n; i++) {
            if (i == n || buf[i] == '\n') {
                int len = i - start;
                if (len > 0) {
                    bool match = root_entry_equals_ci (buf, start, len, want_elf);
                    if (!match && (any_name || ends_with_elf_ci (want)))
                        match = root_entry_equals_ci (buf, start, len, want);
                    if (match)
                        return root_entry_str (buf, start, len);
                }
                start = i + 1;
            }
        }
        return "";
    }

    // Resolves the name typed at the prompt to an existing file, relative to
    // the shell's working directory. With `any_name` (used by `exec`) an exact
    // non-.elf file is accepted as before.
    private string resolve_command (string typed, bool any_name) {
        string name = strip_cmd_prefix (typed);
        if (name.length == 0)
            return "";
        string full = canonical_path (abs_path (name));
        if (any_name && FileUtils.test (full, FileTest.EXISTS))
            return full;
        if (ends_with_elf_ci (full) && FileUtils.test (full, FileTest.EXISTS))
            return full;
        if (!ends_with_elf_ci (full) && FileUtils.test (full + ".elf", FileTest.EXISTS))
            return full + ".elf";
        int slash = -1;
        for (int i = full.length - 1; i >= 0; i--) {
            if (full[i] == '/') {
                slash = i;
                break;
            }
        }
        string dir = "/";
        string leaf = full;
        if (slash > 0) {
            dir = full.substring (0, slash);
            leaf = full.substring (slash + 1);
        } else if (slash == 0) {
            leaf = full.substring (1);
        }
        string found = find_in_dir_ci (dir, leaf, any_name);
        if (found.length == 0)
            return "";
        return (dir == "/") ? "/" + found : dir + "/" + found;
    }

    private int ls_long (string dir) {
        var buf = new uint8[3584];
        int n = Sys.readdir_path (dir, buf, 3584);
        if (n < 0) {
            print (@"ls: not a directory: '$dir'\n");
            return 1;
        }
        if (n == 0)
            return 0;
        int start = 0;
        for (int i = 0; i <= n; i++) {
            if (i == n || buf[i] == '\n') {
                int len = i - start;
                if (len > 0) {
                    string name = root_entry_str (buf, start, len);
                    string full = (dir == "/") ? "/" + name : dir + "/" + name;
                    int kind = Sys.stat (full);
                    int sz = -1;
                    if (kind == 1) {
                        int fd = Sys.open (full);
                        if (fd >= 0) {
                            sz = Sys.file_size (fd);
                            Sys.close (fd);
                        }
                    }
                    if (kind == 2)
                        print (@"dir $name\n");
                    else
                        print (@"$sz $name\n");
                }
                start = i + 1;
            }
        }
        return 0;
    }

    private int exec_command (GenericArray<string> args, bool bg, out bool should_exit) {
        should_exit = false;
        string cmd = args[0];

        if (cmd == "exit") {
            should_exit = true;
            return (args.length > 1) ? parse_int_s (args[1]) : last_status;
        }
        if (cmd == "true" || cmd == ":")
            return 0;
        if (cmd == "false")
            return 1;
        if (cmd == "echo") {
            bool nl = true;
            int idx = 1;
            if (idx < args.length && args[idx] == "-n") {
                nl = false;
                idx = idx + 1;
            }
            var sb = new StringBuilder ();
            for (int i = idx; i < args.length; i++) {
                if (i > idx) sb.append (" ");
                sb.append (args[i]);
            }
            if (nl) sb.append ("\n");
            print (sb.str);
            return 0;
        }
        if (cmd == "export") {
            for (int i = 1; i < args.length; i++) {
                int eq = args[i].index_of ("=");
                if (eq > 0) {
                    string k = args[i].substring (0, eq);
                    string v = args[i].substring (eq + 1);
                    set_var (k, v);
                    Sys.setenv (k, v);
                }
            }
            return 0;
        }
        if (cmd == "unset") {
            for (int i = 1; i < args.length; i++) {
                unset_var (args[i]);
                Sys.unsetenv (args[i]);
            }
            return 0;
        }
        if (cmd == "env" || cmd == "set") {
            var entries = env_map.entries ();
            for (int i = 0; i < entries.size; i++) {
                var e = entries.get (i);
                print (@"$(e.key)=$(e.value)\n");
            }
            return 0;
        }
        if (cmd == "pwd") {
            print (@"$cwd\n");
            return 0;
        }
        if (cmd == "cd") {
            string target = (args.length > 1) ? canonical_path (abs_path (args[1])) : "/";
            if (Sys.stat (target) != 2) {
                print (@"cd: not a directory: '$target'\n");
                return 1;
            }
            cwd = target;
            return 0;
        }
        if (cmd == "test" || cmd == "[")
            return eval_test (args);
        if (cmd == "help") {
            print ("PlanetOS dash (100% Vala POSIX shell)\n");
            print ("commands: help, banner, cd <dir>, pwd, mkdir <dir>, ls [-l] [dir], ps,\n");
            print ("          cat <file>, write <file> <text>, rm <file>, cp <src> <dst>,\n");
            print ("          mv <src> <dst>, touch <file>, echo, test/[],\n");
            print ("          export, unset, env, sh <script>, exec <file> [args] [&], wait <tid>,\n");
            print ("          ticks, date, uptime, mem, exit [code]  |  ops: |, >, >>, <, ;, &&, ||, &, $VAR, if/for\n");
            print ("          debug: dmesg [-c], log [<cat> on|off | level <0-3> | clear], mouse, gpu [probe]\n");
            print ("          <prog> [args] runs <prog>.elf directly (case-insensitive, no exec needed)\n");
            return 0;
        }
        if (cmd == "banner") {
            return Sys.exec ("banner.elf", "banner.elf");
        }
        if (cmd == "mkdir") {
            if (args.length < 2) {
                print ("usage: mkdir <dir>...\n");
                return 1;
            }
            int rc = 0;
            for (int i = 1; i < args.length; i++) {
                string target = canonical_path (abs_path (args[i]));
                if (Sys.mkdir (target) < 0) {
                    print (@"mkdir: cannot create '$target'\n");
                    rc = 1;
                }
            }
            return rc;
        }
        if (cmd == "ls") {
            if (args.length > 1 && args[1] == "-l")
                return ls_long ((args.length > 2) ? canonical_path (abs_path (args[2])) : cwd);
            string where = (args.length > 1) ? canonical_path (abs_path (args[1])) : cwd;
            var io_buf = new uint8[3584];
            int n = Sys.readdir_path (where, io_buf, 3584);
            if (n < 0) {
                print (@"ls: not a directory: '$where'\n");
                return 1;
            }
            if (n > 0)
                Sys.write (1, io_buf, n);
            return 0;
        }
        if (cmd == "ps") {
            var io_buf = new uint8[3584];
            int n = Sys.list_tasks (io_buf, 3584);
            if (n > 0)
                Sys.write (1, io_buf, n);
            return 0;
        }
        if (cmd == "cat") {
            if (args.length < 2) {
                var one = new uint8[1];
                while (true) {
                    int ch = Sys.read_key ();
                    if (ch == -2) break;
                    if (ch < 0) { Sys.yield_cpu (); continue; }
                    one[0] = (uint8) ch;
                    Sys.write (1, one, 1);
                }
                return 0;
            }
            string contents = "";
            if (!FileUtils.get_contents (canonical_path (abs_path (args[1])), out contents)) {
                print ("cat: not found\n");
                return 1;
            }
            print (contents);
            return 0;
        }
        if (cmd == "grep") {
            if (args.length < 2) {
                print ("usage: grep <regex> [file]\n");
                return 1;
            }
            Regex re;
            try {
                re = new Regex (args[1]);
            } catch (RegexError e) {
                print (@"grep: $(e.message)\n");
                return 2;
            }
            string contents = "";
            if (args.length >= 3) {
                if (!FileUtils.get_contents (canonical_path (abs_path (args[2])), out contents)) {
                    print ("grep: not found\n");
                    return 1;
                }
            } else {
                var sb = new StringBuilder ();
                while (true) {
                    int ch = Sys.read_key ();
                    if (ch == -2) break;
                    if (ch < 0) { Sys.yield_cpu (); continue; }
                    sb.append_c ((char) ch);
                }
                contents = sb.str;
            }
            int st = 0;
            bool any = false;
            for (int i = 0; i <= contents.length; i++) {
                if (i == contents.length || contents[i] == '\n') {
                    if (i > st) {
                        string ln = contents.substring (st, i - st);
                        MatchInfo? mi = null;
                        if (re.match (ln, out mi)) {
                            print (@"$ln\n");
                            any = true;
                        }
                    }
                    st = i + 1;
                }
            }
            return any ? 0 : 1;
        }
        if (cmd == "write") {
            if (args.length < 2) {
                print ("usage: write <file> <text>\n");
                return 1;
            }
            var sb = new StringBuilder ();
            for (int i = 2; i < args.length; i++) {
                if (i > 2) sb.append (" ");
                sb.append (args[i]);
            }
            sb.append ("\n");
            return FileUtils.set_contents (canonical_path (abs_path (args[1])), sb.str) ? 0 : 1;
        }
        if (cmd == "rm") {
            if (args.length < 2) {
                print ("usage: rm <file>...\n");
                return 1;
            }
            int rc = 0;
            for (int i = 1; i < args.length; i++) {
                string target = canonical_path (abs_path (args[i]));
                if (Sys.unlink (target) < 0) {
                    print (@"rm: cannot remove '$target'\n");
                    rc = 1;
                }
            }
            return rc;
        }
        if (cmd == "mv") {
            if (args.length < 3) {
                print ("usage: mv <src> <dst>\n");
                return 1;
            }
            string from = canonical_path (abs_path (args[1]));
            string to = canonical_path (abs_path (args[2]));
            if (Sys.rename (from, to) < 0) {
                print (@"mv: cannot move '$from' to '$to'\n");
                return 1;
            }
            return 0;
        }
        if (cmd == "cp") {
            if (args.length < 3) {
                print ("usage: cp <src> <dst>\n");
                return 1;
            }
            string from = canonical_path (abs_path (args[1]));
            string to = canonical_path (abs_path (args[2]));
            string contents = "";
            if (!FileUtils.get_contents (from, out contents)) {
                print (@"cp: cannot read '$from'\n");
                return 1;
            }
            if (!FileUtils.set_contents (to, contents)) {
                print (@"cp: cannot write '$to' (only RAMFS is writable)\n");
                return 1;
            }
            return 0;
        }
        if (cmd == "touch") {
            if (args.length < 2) {
                print ("usage: touch <file>...\n");
                return 1;
            }
            for (int i = 1; i < args.length; i++) {
                string target = canonical_path (abs_path (args[i]));
                if (FileUtils.test (target, FileTest.EXISTS))
                    continue;
                int fd = Sys.create (target);
                if (fd < 0) {
                    print (@"touch: cannot create '$target'\n");
                    return 1;
                }
                Sys.close (fd);
            }
            return 0;
        }
        if (cmd == "ticks") {
            int t = Sys.ticks ();
            print (@"ticks: $t\n");
            return 0;
        }
        if (cmd == "date") {
            int pk = Sys.rtc_time ();
            int yr  = 2000 + ((pk >> 26) & 0x3f);
            int mon = (pk >> 22) & 0x0f;
            int day = (pk >> 17) & 0x1f;
            int hr  = (pk >> 12) & 0x1f;
            int min = (pk >> 6) & 0x3f;
            int sec = pk & 0x3f;
            string smon = mon < 10 ? @"0$mon" : @"$mon";
            string sday = day < 10 ? @"0$day" : @"$day";
            string shr  = hr  < 10 ? @"0$hr"  : @"$hr";
            string smin = min < 10 ? @"0$min" : @"$min";
            string ssec = sec < 10 ? @"0$sec" : @"$sec";
            print (@"$yr-$smon-$sday $shr:$smin:$ssec UTC\n");
            return 0;
        }
        if (cmd == "uptime") {
            int t = Sys.ticks ();
            int secs = t / 100;
            int cs = t % 100;
            string scs = cs < 10 ? @"0$cs" : @"$cs";
            print (@"up $secs.$(scs)s ($t ticks)\n");
            return 0;
        }
        if (cmd == "mem") {
            int p = Sys.alloc_pages (1);
            Sys.free_page (p);
            print (@"mem: page=$p\n");
            return 0;
        }
        if (cmd == "wait") {
            if (args.length < 2) {
                print ("usage: wait <tid>\n");
                return 1;
            }
            int tid = parse_int_s (args[1]);
            int code = Sys.wait (tid);
            print (@"wait: tid=$tid exit=$code\n");
            return code;
        }
        if (cmd == "dmesg") {
            bool clear = (args.length > 1 && args[1] == "-c");
            int buf = Sys.alloc_pages (1);
            if (buf == 0) {
                print ("dmesg: out of memory\n");
                return 1;
            }
            int n = Sys.klog_read_at (buf, 64);
            if (n <= 0) {
                print ("dmesg: empty\n");
            } else {
                var txt = new uint8[40];
                for (int i = 0; i < n; i++) {
                    int rec = buf + i * 64;
                    int cat = peek32 (rec + 0);
                    int lvl = peek32 (rec + 4);
                    int len = peek32 (rec + 8);
                    int tick = peek32 (rec + 16);
                    if (len < 0) len = 0;
                    if (len > 40) len = 40;
                    for (int k = 0; k < len; k++)
                        txt[k] = (uint8) (peek32 (rec + 24 + k) & 0xFF);
                    string tag = klog_cat_name (cat);
                    string mark = klog_lvl_name (lvl);
                    print (@"[$tick] $mark $tag: ");
                    Sys.console_write (txt, len);
                    print ("\n");
                }
            }
            Sys.free_page (buf);
            if (clear)
                Sys.klog_clear ();
            return 0;
        }
        if (cmd == "log") {
            if (args.length == 1) {
                int st = Sys.klog_state ();
                int lvl = st & 0xFF;
                int mask = (st >> 8) & 0xFF;
                string head = @"log: level=$lvl records=$(Sys.klog_total ()) categories:";
                print (head);
                for (int c = 0; c < 7; c++) {
                    string nm = klog_cat_name (c);
                    string state = ((mask & (1 << c)) != 0) ? "on" : "off";
                    print (@" $nm=$state");
                }
                print ("\n");
                return 0;
            }
            string sub = args[1];
            if (sub == "clear") {
                Sys.klog_clear ();
                return 0;
            }
            if (sub == "level") {
                if (args.length < 3) {
                    print ("usage: log level <0-3> (0=error 1=warn 2=info 3=debug)\n");
                    return 1;
                }
                Sys.klog_set_level (parse_int_s (args[2]));
                string lv = @"$(Sys.klog_state () & 0xFF)";
                print (@"log: level=$lv\n");
                return 0;
            }
            int cat = klog_cat_id (sub);
            if (cat < 0) {
                print ("log: categories: boot input gpu mem vfs sched exec\n");
                return 1;
            }
            int cur = (Sys.klog_state () >> 8) & 0xFF;
            bool on = (args.length > 2) ? (args[2] == "on") : ((cur & (1 << cat)) != 0);
            if (args.length > 2)
                Sys.klog_set_category (cat, on);
            string state = on ? "on" : "off";
            print (@"log: $sub=$state\n");
            return 0;
        }
        if (cmd == "mouse") {
            int buf = Sys.alloc_pages (1);
            if (buf == 0) {
                print ("mouse: out of memory\n");
                return 1;
            }
            Sys.sys (24, buf, 0, 0);
            int mx = peek32 (buf + 0);
            int my = peek32 (buf + 8);
            int btn = peek32 (buf + 16);
            int pk = peek32 (buf + 24);
            int nbytes = peek32 (buf + 32);
            int rs = peek32 (buf + 40);
            print (@"mouse: x=$mx y=$my btn=$btn packets=$pk bytes=$nbytes resync=$rs\n");
            Sys.free_page (buf);
            return 0;
        }
        if (cmd == "gpu") {
            if (args.length > 1 && args[1] == "probe")
                return Sys.exec ("vk_demo.elf", "vk_demo.elf --probe");
            int caps = Sys.gpu_info ();
            int present = caps & 1;
            int virgl = (caps >> 1) & 1;
            int blob = (caps >> 2) & 1;
            int ctx = (caps >> 3) & 1;
            int venus = (caps >> 4) & 1;
            int gw = (caps >> 16) & 0xFFFF;
            int gh = (caps >> 32) & 0xFFFF;
            print (@"gpu: present=$present virgl=$virgl blob=$blob ctx=$ctx venus=$venus display=$(gw)x$(gh)\n");
            return 0;
        }
        if (cmd == "sh" || cmd == ".") {
            if (args.length < 2) {
                print ("usage: sh <script>\n");
                return 1;
            }
            return run_script (canonical_path (abs_path (args[1])));
        }

        // External execution: `exec <file> [args...]` or a bare command name.
        // `gio_demo`, `GIO_DEMO.ELF` and `.\gio_demo` all run `gio_demo.elf`.
        bool explicit_exec = (cmd == "exec");
        int elf_idx = explicit_exec ? 1 : 0;
        if (elf_idx >= args.length) {
            print ("usage: exec <file> [args...] [&]\n");
            return 1;
        }
        string typed = args[elf_idx];
        string target = resolve_command (typed, explicit_exec);
        if (target.length == 0) {
            print (@"$typed: command not found\n");
            return 127;
        }
        var cmdline = new StringBuilder ();
        for (int i = elf_idx; i < args.length; i++) {
            if (i > elf_idx) cmdline.append (" ");
            cmdline.append (i == elf_idx ? target : args[i]);
        }
        if (bg) {
            int tid = Sys.spawn (target, cmdline.str);
            if (tid < 0) {
                print (@"$target: cannot execute\n");
                return 127;
            }
            print (@"spawn: tid=$tid\n");
            return 0;
        }
        int code = Sys.exec (target, cmdline.str);
        if (code < 0)
            print (@"$target: cannot execute\n");
        else if (explicit_exec)
            print (@"exec: exit=$code\n");
        return (code < 0) ? 127 : code;
    }

    private int run_pipeline (GenericArray<Tok> toks, int lo, int hi, bool bg, out bool should_exit) {
        should_exit = false;
        // Find '|' operators inside [lo, hi)
        var starts = new GenericArray<int> ();
        var ends = new GenericArray<int> ();
        int s = lo;
        for (int i = lo; i < hi; i++) {
            if (toks[i].is_op && toks[i].text == "|") {
                starts.add (s);
                ends.add (i);
                s = i + 1;
            }
        }
        starts.add (s);
        ends.add (hi);

        if (starts.length == 1)
            return run_simple (toks, lo, hi, bg, out should_exit);

        string pipe_a = "__pipe_a";
        string pipe_b = "__pipe_b";
        int rc = 0;
        for (int st = 0; st < starts.length; st++) {
            string cur_in = (st == 0) ? "" : ((st % 2 == 1) ? pipe_a : pipe_b);
            string cur_out = (st == starts.length - 1) ? "" : ((st % 2 == 0) ? pipe_a : pipe_b);

            int in_fd = (cur_in.length > 0) ? Sys.open (cur_in) : -1;
            int out_fd = (cur_out.length > 0) ? Sys.create (cur_out) : -1;
            if (in_fd >= 3 || out_fd >= 3)
                Sys.set_stdio (in_fd, out_fd);

            rc = run_simple (toks, starts[st], ends[st], false, out should_exit);

            if (in_fd >= 3 || out_fd >= 3)
                Sys.set_stdio (-1, -1);
            if (in_fd >= 3) Sys.close (in_fd);
            if (out_fd >= 3) Sys.close (out_fd);
            if (should_exit)
                break;
        }
        return rc;
    }

    private string join_toks (GenericArray<Tok> toks, int lo, int hi) {
        var sb = new StringBuilder ();
        for (int i = lo; i < hi; i++) {
            if (i > lo) sb.append (" ");
            sb.append (toks[i].text);
        }
        return sb.str;
    }

    private int eval_tokens (GenericArray<Tok> toks, out bool should_exit) {
        should_exit = false;
        int n = toks.length;
        if (n == 0)
            return last_status;

        // Structured POSIX control flow: `if <cond>; then <body> [; else <body>]; fi`
        if (!toks[0].is_op && toks[0].text == "if") {
            int then_i = -1;
            int else_i = -1;
            int fi_i = -1;
            for (int i = 1; i < n; i++) {
                if (!toks[i].is_op) {
                    if (toks[i].text == "then" && then_i < 0) then_i = i;
                    else if (toks[i].text == "else" && then_i >= 0 && else_i < 0) else_i = i;
                    else if (toks[i].text == "fi") { fi_i = i; break; }
                }
            }
            if (then_i > 1 && fi_i > then_i) {
                string cond_s = join_toks (toks, 1, then_i);
                int cond_rc = eval_line (cond_s, out should_exit);
                if (should_exit) return cond_rc;
                if (cond_rc == 0) {
                    int b_end = (else_i > then_i) ? else_i : fi_i;
                    return eval_line (join_toks (toks, then_i + 1, b_end), out should_exit);
                } else if (else_i > then_i) {
                    return eval_line (join_toks (toks, else_i + 1, fi_i), out should_exit);
                }
                return 0;
            }
        }

        // Structured `for <var> in <items...>; do <body>; done`
        if (!toks[0].is_op && toks[0].text == "for" && n >= 5 && toks[2].text == "in") {
            int do_i = -1;
            int done_i = -1;
            for (int i = 3; i < n; i++) {
                if (!toks[i].is_op) {
                    if (toks[i].text == "do" && do_i < 0) do_i = i;
                    else if (toks[i].text == "done") { done_i = i; break; }
                }
            }
            if (do_i > 3 && done_i > do_i) {
                string var_name = toks[1].text;
                string body_s = join_toks (toks, do_i + 1, done_i);
                int rc = 0;
                for (int k = 3; k < do_i; k++) {
                    if (toks[k].is_op && toks[k].text == ";")
                        break;
                    set_var (var_name, toks[k].text);
                    rc = eval_line (body_s, out should_exit);
                    if (should_exit)
                        return rc;
                }
                return rc;
            }
        }

        // List splitting is handled on raw strings in eval_line so $VAR expands lazily per segment
        return run_pipeline (toks, 0, n, false, out should_exit);
    }

    private int eval_line (string line, out bool should_exit) {
        should_exit = false;
        // Check for top-level `if` or `for` first
        var peek_toks = tokenize (line);
        if (peek_toks.length == 0)
            return last_status;
        if (!peek_toks[0].is_op && (peek_toks[0].text == "if" || peek_toks[0].text == "for"))
            return eval_tokens (peek_toks, out should_exit);

        // Split on unquoted ;, &&, ||, & so each segment expands $VAR after prior assignments
        int n = line.length;
        int i = 0;
        int seg_start = 0;
        int rc = last_status;
        bool skip_next = false;
        while (i <= n) {
            bool in_sq = false;
            bool in_dq = false;
            string sep = "";
            while (i < n) {
                uint8 c = line[i];
                if (!in_sq && !in_dq && c == '#') {
                    i = n;
                    break;
                }
                if (c == '\\' && !in_sq && i + 1 < n) {
                    i = i + 2;
                    continue;
                }
                if (c == '\'' && !in_dq) { in_sq = !in_sq; i = i + 1; continue; }
                if (c == '"' && !in_sq) { in_dq = !in_dq; i = i + 1; continue; }
                if (!in_sq && !in_dq) {
                    if (i + 1 < n && line[i] == '&' && line[i + 1] == '&') { sep = "&&"; break; }
                    if (i + 1 < n && line[i] == '|' && line[i + 1] == '|') { sep = "||"; break; }
                    if (c == ';') { sep = ";"; break; }
                    if (c == '&') { sep = "&"; break; }
                }
                i = i + 1;
            }
            string seg = line.substring (seg_start, i - seg_start);
            if (sep.length > 0)
                i = i + sep.length;
            seg_start = i;

            var toks = tokenize (seg);
            if (toks.length > 0) {
                if (!skip_next) {
                    rc = run_pipeline (toks, 0, toks.length, sep == "&", out should_exit);
                    last_status = rc;
                    if (should_exit)
                        return rc;
                }
                if (sep == "&&")
                    skip_next = (rc != 0);
                else if (sep == "||")
                    skip_next = (rc == 0);
                else
                    skip_next = false;
            }
            if (sep.length == 0)
                break;
        }
        return rc;
    }

    private int run_script (string path) {
        string text = "";
        if (!FileUtils.get_contents (path, out text)) {
            print (@"sh: cannot open '$path'\n");
            return 127;
        }
        int pos = 0;
        int rc = 0;
        bool should_exit = false;
        while (pos < text.length) {
            int nl = text.index_of ("\n", pos);
            string ln = (nl < 0) ? text.substring (pos) : text.substring (pos, nl - pos);
            rc = eval_line (ln, out should_exit);
            last_status = rc;
            if (should_exit)
                break;
            if (nl < 0)
                break;
            pos = nl + 1;
        }
        return rc;
    }

    int main (string[] args) {
        env_map = new HashMap<string, string> ();
        set_var ("SHELL", "shell.elf");
        set_var ("PS1", "planet> ");
        set_var ("OS", Sys.getenv ("OS"));
        set_var ("ARCH", Sys.getenv ("ARCH"));
        set_var ("TARGET", Sys.getenv ("TARGET"));
        string env_cwd = Sys.getenv ("PLANET_CWD");
        if (env_cwd.length > 0)
            cwd = canonical_path (env_cwd);

        if (args.length > 2 && args[1] == "-c") {
            var cmd_sb = new StringBuilder ();
            for (int i = 2; i < args.length; i++) {
                if (i > 2)
                    cmd_sb.append (" ");
                cmd_sb.append (args[i]);
            }
            bool should_exit_c = false;
            return eval_line (cmd_sb.str, out should_exit_c);
        }
        if (args.length > 1)
            return run_script (canonical_path (abs_path (args[1])));

        Sys.exec ("banner.elf", "banner.elf");
        print ("PlanetOS Shell v0.2 (dash-compatible 100% Vala, type 'help')\n");

        var line = new uint8[480];
        var one = new uint8[1];
        var history = new GenericArray<string> ();
        int hist_idx = -1;
        string draft_line = "";

        while (true) {
            print (get_var ("PS1"));
            int len = 0;
            hist_idx = -1;
            draft_line = "";
            while (true) {
                int ch = Sys.read_key ();
                if (ch < 0) {
                    Sys.yield_cpu ();
                    continue;
                }
                if (ch == '\r' || ch == '\n') {
                    one[0] = (uint8) '\n';
                    Sys.write (1, one, 1);
                    break;
                }
                if (ch == 0x81 || ch == 0x82) {
                    if (history.length == 0)
                        continue;
                    string? next_cmd = null;
                    if (ch == 0x81) {
                        if (hist_idx < 0) {
                            var dsb = new StringBuilder ();
                            for (int k = 0; k < len; k++) dsb.append_c ((char) line[k]);
                            draft_line = dsb.str;
                            hist_idx = history.length - 1;
                            next_cmd = history[hist_idx];
                        } else if (hist_idx > 0) {
                            hist_idx = hist_idx - 1;
                            next_cmd = history[hist_idx];
                        }
                    } else if (hist_idx >= 0) {
                        if (hist_idx + 1 < history.length) {
                            hist_idx = hist_idx + 1;
                            next_cmd = history[hist_idx];
                        } else {
                            hist_idx = -1;
                            next_cmd = draft_line;
                        }
                    }
                    if (next_cmd != null) {
                        for (int k = 0; k < len; k++) {
                            one[0] = (uint8) 8; Sys.write (1, one, 1);
                            one[0] = (uint8) ' '; Sys.write (1, one, 1);
                            one[0] = (uint8) 8; Sys.write (1, one, 1);
                        }
                        int nlen = (next_cmd.length < 480) ? next_cmd.length : 480;
                        for (int k = 0; k < nlen; k++) {
                            line[k] = (uint8) next_cmd[k];
                            one[0] = line[k];
                            Sys.write (1, one, 1);
                        }
                        len = nlen;
                    }
                    continue;
                }
                if (ch == '\t') {
                    var cur_sb = new StringBuilder ();
                    for (int k = 0; k < len; k++) cur_sb.append_c ((char) line[k]);
                    string cur_str = cur_sb.str;
                    int sp = -1;
                    for (int k = cur_str.length - 1; k >= 0; k--) {
                        if (cur_str[k] == ' ') { sp = k; break; }
                    }
                    string pref = (sp >= 0) ? cur_str.substring (sp + 1) : cur_str;
                    bool completed = false;
                    if (pref.length > 0) {
                        var dbuf = new uint8[4096];
                        int dn = Sys.readdir_path (cwd, dbuf, 4096);
                        if (dn > 0) {
                            var matches = new GenericArray<string> ();
                            int st = 0;
                            for (int i = 0; i <= dn; i++) {
                                if (i == dn || dbuf[i] == 0 || dbuf[i] == '\n') {
                                    if (i > st) {
                                        var msb = new StringBuilder ();
                                        for (int j = st; j < i; j++) msb.append_c ((char) dbuf[j]);
                                        string nm = msb.str;
                                        if (nm.has_prefix (pref))
                                            matches.add (nm);
                                    }
                                    st = i + 1;
                                }
                            }
                            if (matches.length == 1) {
                                string rest = matches[0].substring (pref.length);
                                for (int k = 0; k < rest.length && len < 480; k++) {
                                    line[len] = (uint8) rest[k];
                                    len = len + 1;
                                    one[0] = (uint8) rest[k];
                                    Sys.write (1, one, 1);
                                }
                                completed = true;
                            } else if (matches.length > 1) {
                                print ("\n");
                                for (int m = 0; m < matches.length; m++) {
                                    if (m > 0) print ("  ");
                                    print (matches[m]);
                                }
                                print ("\n");
                                print (get_var ("PS1"));
                                for (int k = 0; k < len; k++) {
                                    one[0] = line[k];
                                    Sys.write (1, one, 1);
                                }
                                completed = true;
                            }
                        }
                    }
                    if (!completed) {
                        int spaces = 4 - (len % 4);
                        for (int s = 0; s < spaces && len < 480; s++) {
                            line[len] = (uint8) ' ';
                            len = len + 1;
                            one[0] = (uint8) ' ';
                            Sys.write (1, one, 1);
                        }
                    }
                    continue;
                }
                if (ch == 8 || ch == 127) {
                    if (len > 0) {
                        len = len - 1;
                        while (len > 0 && (line[len - 1] & 0xC0) == 0x80)
                            len = len - 1;
                        one[0] = (uint8) 8; Sys.write (1, one, 1);
                        one[0] = (uint8) ' '; Sys.write (1, one, 1);
                        one[0] = (uint8) 8; Sys.write (1, one, 1);
                    }
                    continue;
                }
                if (ch >= 0x80 && ch <= 0x8F)
                    continue;
                if (len < 480) {
                    line[len] = (uint8) ch;
                    len = len + 1;
                    one[0] = (uint8) ch;
                    Sys.write (1, one, 1);
                }
            }

            var sb = new StringBuilder ();
            for (int k = 0; k < len; k++)
                sb.append_c ((char) line[k]);

            if (len > 0) {
                if (history.length == 0 || history[history.length - 1] != sb.str) {
                    history.add (sb.str);
                    if (history.length > 32)
                        history.remove_index (0);
                }
            }

            bool should_exit = false;
            int rc = eval_line (sb.str, out should_exit);
            last_status = rc;
            if (should_exit)
                break;
        }

        return last_status;
    }
}
