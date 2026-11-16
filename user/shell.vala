// PlanetOS POSIX shell (100% pure Vala, dash-inspired: quotes, variables,
// pipelines, redirections, conditionals, loops, scripts, and background jobs).

using GLib;

namespace PlanetShell {

    [AsmBody(@"
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        int $0x80
        ret
    ")]
    public extern int sys (int num, int a0, int a1, int a2);

    [AsmBody(@"
        mov %sil, (%rdi)
        ret
    ")]
    public extern void poke8 (int addr, int val);

    [AsmBody(@"
        movzbl (%rdi), %eax
        ret
    ")]
    public extern int peek8 (int addr);

    [AsmBody(@"
        # sys_str_call(num in rdi, s in rsi) -> passes (s+16, [s+8], 0)
        mov %rdi, %rax
        mov 8(%rsi), %rdx
        add $16, %rsi
        mov %rsi, %rdi
        mov %rdx, %rsi
        xor %edx, %edx
        int $0x80
        ret
    ")]
    public extern int sys_str (int num, string s);

    [AsmBody(@"
        # sys_exec_str(num in rdi, name in rsi, cmdline in rdx)
        mov %rdi, %rax
        mov 8(%rsi), %rcx
        add $16, %rsi
        mov %rsi, %rdi
        mov %rcx, %rsi
        add $16, %rdx
        int $0x80
        ret
    ")]
    public extern int sys_exec_str (int num, string name, string cmdline);

    [AsmBody(@"
        # sys_rename_str(num in rdi, old in rsi, new in rdx) -> 0 o -1
        mov %rdi, %rax
        mov %rsi, %r9
        mov %rdx, %r10
        mov 8(%r9), %rsi
        mov 8(%r10), %r8
        lea 16(%r9), %rdi
        lea 16(%r10), %rdx
        int $0x80
        ret
    ")]
    public extern int sys_rename_str (int num, string old_name, string new_name);

    private class Tok : Object {
        public string text;
        public bool is_op;
        public Tok (string t, bool op) {
            text = t;
            is_op = op;
        }
    }

    private GenericArray<string> env_keys;
    private GenericArray<string> env_vals;
    private int last_status = 0;
    private int scratch_page = 0;
    private string cwd = "/";

    private string int_to_s (int v) {
        return @"$v";
    }

    private string get_var (string name) {
        if (name == "?")
            return int_to_s (last_status);
        if (name == "$")
            return "0";
        if (name == "PWD")
            return cwd;
        for (int i = 0; i < env_keys.length; i++) {
            if (env_keys[i] == name)
                return env_vals[i];
        }
        return "";
    }

    private void set_var (string name, string val) {
        for (int i = 0; i < env_keys.length; i++) {
            if (env_keys[i] == name) {
                env_vals[i] = val;
                return;
            }
        }
        env_keys.add (name);
        env_vals.add (val);
    }

    private void unset_var (string name) {
        for (int i = 0; i < env_keys.length; i++) {
            if (env_keys[i] == name) {
                env_keys[i] = "";
                env_vals[i] = "";
            }
        }
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
            if (op == "-f" || op == "-e") return FileUtils.test (val, FileTest.EXISTS) ? 0 : 1;
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
            in_fd = sys_str (6, redir_in);
            if (in_fd < 0) {
                print (@"sh: cannot open '$redir_in'\n");
                return 1;
            }
        }
        if (redir_out.length > 0) {
            if (append_out && FileUtils.test (redir_out, FileTest.EXISTS)) {
                out_fd = sys_str (6, redir_out);
                if (out_fd >= 3)
                    sys (20, out_fd, -1, 0); // seek to end
            } else {
                out_fd = sys_str (14, redir_out);
            }
            if (out_fd < 0) {
                if (in_fd >= 3) sys (8, in_fd, 0, 0);
                print (@"sh: cannot write '$redir_out'\n");
                return 1;
            }
        }
        if (in_fd >= 3 || out_fd >= 3)
            sys (19, in_fd, out_fd, 0);

        int rc = exec_command (cmd_args, bg, out should_exit);

        if (in_fd >= 3 || out_fd >= 3)
            sys (19, -1, -1, 0);
        if (in_fd >= 3) sys (8, in_fd, 0, 0);
        if (out_fd >= 3) sys (8, out_fd, 0, 0);
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

    private bool root_entry_equals_ci (int addr, int len, string want) {
        if (len != want.length)
            return false;
        for (int i = 0; i < len; i++) {
            if (ascii_fold ((uint8) peek8 (addr + i)) != ascii_fold (want[i]))
                return false;
        }
        return true;
    }

    private string root_entry_str (int addr, int len) {
        var sb = new StringBuilder ();
        for (int i = 0; i < len; i++)
            sb.append_c ((char) (uint8) peek8 (addr + i));
        return sb.str;
    }

    private string find_root_ci (string want, bool any_name) {
        int buf = scratch_page + 512;
        int n = sys (12, buf, 3584, 0);
        if (n <= 0)
            return "";
        string want_elf = want + ".elf";
        int start = 0;
        for (int i = 0; i <= n; i++) {
            if (i == n || peek8 (buf + i) == '\n') {
                int len = i - start;
                if (len > 0) {
                    bool match = root_entry_equals_ci (buf + start, len, want_elf);
                    if (!match && (any_name || ends_with_elf_ci (want)))
                        match = root_entry_equals_ci (buf + start, len, want);
                    if (match)
                        return root_entry_str (buf + start, len);
                }
                start = i + 1;
            }
        }
        return "";
    }

    // Resolves the name typed at the prompt to an existing file. With
    // `any_name` (used by `exec`) an exact non-.elf file is accepted as before.
    private string resolve_command (string typed, bool any_name) {
        string name = strip_cmd_prefix (typed);
        if (name.length == 0)
            return "";
        if (any_name && FileUtils.test (name, FileTest.EXISTS))
            return name;
        if (ends_with_elf_ci (name) && FileUtils.test (name, FileTest.EXISTS))
            return name;
        if (!ends_with_elf_ci (name) && FileUtils.test (name + ".elf", FileTest.EXISTS))
            return name + ".elf";
        return find_root_ci (name, any_name);
    }

    private int ls_long () {
        int buf = scratch_page + 512;
        int n = sys (12, buf, 3584, 0);
        if (n <= 0)
            return 0;
        int start = 0;
        for (int i = 0; i <= n; i++) {
            if (i == n || peek8 (buf + i) == '\n') {
                int len = i - start;
                if (len > 0) {
                    string name = root_entry_str (buf + start, len);
                    int fd = sys_str (6, name);
                    int sz = -1;
                    if (fd >= 0) {
                        sz = sys (9, fd, 0, 0);
                        sys (8, fd, 0, 0);
                    }
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
                if (eq > 0)
                    set_var (args[i].substring (0, eq), args[i].substring (eq + 1));
            }
            return 0;
        }
        if (cmd == "unset") {
            for (int i = 1; i < args.length; i++)
                unset_var (args[i]);
            return 0;
        }
        if (cmd == "env" || cmd == "set") {
            for (int i = 0; i < env_keys.length; i++) {
                if (env_keys[i].length > 0)
                    print (@"$(env_keys[i])=$(env_vals[i])\n");
            }
            return 0;
        }
        if (cmd == "pwd") {
            print (@"$cwd\n");
            return 0;
        }
        if (cmd == "cd") {
            cwd = (args.length > 1) ? args[1] : "/";
            return 0;
        }
        if (cmd == "test" || cmd == "[")
            return eval_test (args);
        if (cmd == "help") {
            print ("PlanetOS dash (100% Vala POSIX shell)\n");
            print ("commands: help, banner, ls [-l], ps, cat <file>, write <file> <text>,\n");
            print ("          rm <file>, cp <src> <dst>, mv <src> <dst>, touch <file>, echo, test/[],\n");
            print ("          export, unset, env, sh <script>, exec <file> [args] [&], wait <tid>,\n");
            print ("          ticks, mem, exit [code]  |  ops: |, >, >>, <, ;, &&, ||, &, $VAR, if/for\n");
            print ("          <prog> [args] runs <prog>.elf directly (case-insensitive, no exec needed)\n");
            return 0;
        }
        if (cmd == "banner") {
            return sys_exec_str (13, "banner.elf", "banner.elf");
        }
        if (cmd == "ls") {
            if (args.length > 1 && args[1] == "-l")
                return ls_long ();
            int io_buf = scratch_page + 512;
            int n = sys (12, io_buf, 3584, 0);
            if (n > 0)
                sys (1, io_buf, n, 0);
            return 0;
        }
        if (cmd == "ps") {
            int io_buf = scratch_page + 512;
            int n = sys (18, io_buf, 3584, 0);
            if (n > 0)
                sys (1, io_buf, n, 0);
            return 0;
        }
        if (cmd == "cat") {
            if (args.length < 2) {
                int ch_buf = scratch_page + 500;
                while (true) {
                    int ch = sys (5, 0, 0, 0);
                    if (ch == -2) break;
                    if (ch < 0) { sys (10, 0, 0, 0); continue; }
                    poke8 (ch_buf, ch);
                    sys (1, ch_buf, 1, 0);
                }
                return 0;
            }
            string contents = "";
            if (!FileUtils.get_contents (args[1], out contents)) {
                print ("cat: not found\n");
                return 1;
            }
            print (contents);
            return 0;
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
            return FileUtils.set_contents (args[1], sb.str) ? 0 : 1;
        }
        if (cmd == "rm") {
            if (args.length < 2) {
                print ("usage: rm <file>...\n");
                return 1;
            }
            int rc = 0;
            for (int i = 1; i < args.length; i++) {
                if (sys_str (28, args[i]) < 0) {
                    print (@"rm: cannot remove '$(args[i])'\n");
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
            if (sys_rename_str (29, args[1], args[2]) < 0) {
                print (@"mv: cannot move '$(args[1])' to '$(args[2])'\n");
                return 1;
            }
            return 0;
        }
        if (cmd == "cp") {
            if (args.length < 3) {
                print ("usage: cp <src> <dst>\n");
                return 1;
            }
            string contents = "";
            if (!FileUtils.get_contents (args[1], out contents)) {
                print (@"cp: cannot read '$(args[1])'\n");
                return 1;
            }
            if (!FileUtils.set_contents (args[2], contents)) {
                print (@"cp: cannot write '$(args[2])' (only RAMFS is writable)\n");
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
                if (FileUtils.test (args[i], FileTest.EXISTS))
                    continue;
                int fd = sys_str (14, args[i]);
                if (fd < 0) {
                    print (@"touch: cannot create '$(args[i])'\n");
                    return 1;
                }
                sys (8, fd, 0, 0);
            }
            return 0;
        }
        if (cmd == "ticks") {            int t = sys (2, 0, 0, 0);
            print (@"ticks: $t\n");
            return 0;
        }
        if (cmd == "mem") {
            int p = sys (3, 0, 0, 0);
            sys (4, p, 0, 0);
            print (@"mem: page=$p\n");
            return 0;
        }
        if (cmd == "wait") {
            if (args.length < 2) {
                print ("usage: wait <tid>\n");
                return 1;
            }
            int tid = parse_int_s (args[1]);
            int code = sys (17, tid, 0, 0);
            print (@"wait: tid=$tid exit=$code\n");
            return code;
        }
        if (cmd == "sh" || cmd == ".") {
            if (args.length < 2) {
                print ("usage: sh <script>\n");
                return 1;
            }
            return run_script (args[1]);
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
            int tid = sys_exec_str (16, target, cmdline.str);
            if (tid < 0) {
                print (@"$target: cannot execute\n");
                return 127;
            }
            print (@"spawn: tid=$tid\n");
            return 0;
        }
        int code = sys_exec_str (13, target, cmdline.str);
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

            int in_fd = (cur_in.length > 0) ? sys_str (6, cur_in) : -1;
            int out_fd = (cur_out.length > 0) ? sys_str (14, cur_out) : -1;
            if (in_fd >= 3 || out_fd >= 3)
                sys (19, in_fd, out_fd, 0);

            rc = run_simple (toks, starts[st], ends[st], false, out should_exit);

            if (in_fd >= 3 || out_fd >= 3)
                sys (19, -1, -1, 0);
            if (in_fd >= 3) sys (8, in_fd, 0, 0);
            if (out_fd >= 3) sys (8, out_fd, 0, 0);
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
        env_keys = new GenericArray<string> ();
        env_vals = new GenericArray<string> ();
        scratch_page = sys (3, 0, 0, 0);
        int line_buf = scratch_page;
        int ch_buf = scratch_page + 500;

        set_var ("SHELL", "shell.elf");
        set_var ("PS1", "planet> ");

        if (args.length > 1)
            return run_script (args[1]);

        sys_exec_str (13, "banner.elf", "banner.elf");
        print ("PlanetOS Shell v0.2 (dash-compatible 100% Vala, type 'help')\n");

        while (true) {
            print (get_var ("PS1"));
            int len = 0;
            while (true) {
                int ch = sys (5, 0, 0, 0);
                if (ch < 0) {
                    sys (10, 0, 0, 0);
                    continue;
                }
                if (ch == '\r' || ch == '\n') {
                    poke8 (ch_buf, '\n');
                    sys (1, ch_buf, 1, 0);
                    break;
                }
                if (ch == 8 || ch == 127) {
                    if (len > 0) {
                        while (len > 0 && (peek8 (line_buf + len - 1) & 0xC0) == 0x80)
                            len = len - 1;
                        if (len > 0)
                            len = len - 1;
                        poke8 (ch_buf, 8); sys (1, ch_buf, 1, 0);
                        poke8 (ch_buf, ' '); sys (1, ch_buf, 1, 0);
                        poke8 (ch_buf, 8); sys (1, ch_buf, 1, 0);
                    }
                    continue;
                }
                if (len < 480) {
                    poke8 (line_buf + len, ch);
                    len = len + 1;
                    poke8 (ch_buf, ch);
                    sys (1, ch_buf, 1, 0);
                }
            }

            var sb = new StringBuilder ();
            for (int k = 0; k < len; k++)
                sb.append_c ((char) (uint8) peek8 (line_buf + k));

            bool should_exit = false;
            int rc = eval_line (sb.str, out should_exit);
            last_status = rc;
            if (should_exit)
                break;
        }

        sys (4, scratch_page, 0, 0);
        return last_status;
    }
}
