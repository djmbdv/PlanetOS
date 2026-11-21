// Pure-Vala C preprocessor for c2vala.
// Handles comments, line splicing, #include, #define (object & function-like),
// #undef, #ifdef/#ifndef/#if/#elif/#else/#endif, and tracks file:line provenance.

using Planc;

namespace C2Vala {

    public class MacroDef : Object {
        public string name;
        public bool is_func = false;
        public GenericArray<string> params = new GenericArray<string> ();
        public bool is_varargs = false;
        public string body = "";
        public bool expanding = false;

        public MacroDef (string name, string body) {
            this.name = name;
            this.body = body;
        }
    }

    public class PreLine : Object {
        public string file;
        public int line;
        public string text;

        public PreLine (string file, int line, string text) {
            this.file = file;
            this.line = line;
            this.text = text;
        }
    }

    public class Preprocessor : Object {
        private const int MACRO_CAP = 32768;
        private GenericArray<string> include_dirs = new GenericArray<string> ();
        private GenericArray<MacroDef> macros = new GenericArray<MacroDef> ();
        private int[] macro_idx = new int[32768];
        private GenericArray<string> included_once = new GenericArray<string> ();
        public bool verbose = false;

        private static uint32 hash_str (string s) {
            uint32 h = 2166136261u;
            int slen = s.length;
            for (int i = 0; i < slen; i++) {
                h ^= (uint32) s[i];
                h *= 16777619u;
            }
            return h;
        }

        public Preprocessor () {
            // Standard predefined macros
            define_object ("__STDC__", "1");
            define_object ("__STDC_VERSION__", "199901L");
            define_object ("NULL", "0");
            define_object ("true", "1");
            define_object ("false", "0");
            // Standard C99 <inttypes.h> format macros
            define_object ("PRId64", "\"lld\"");
            define_object ("PRIi64", "\"lli\"");
            define_object ("PRIu64", "\"llu\"");
            define_object ("PRIx64", "\"llx\"");
            define_object ("PRIX64", "\"llX\"");
            define_object ("PRId32", "\"d\"");
            define_object ("PRIi32", "\"i\"");
            define_object ("PRIu32", "\"u\"");
            define_object ("PRIx32", "\"x\"");
            define_object ("PRIX32", "\"X\"");
        }

        public void add_include_dir (string dir) {
            include_dirs.add (dir);
        }

        public void define_object (string name, string val) {
            define_macro (new MacroDef (name, val));
        }

        public void define_macro (MacroDef m) {
            uint32 idx = hash_str (m.name) & (uint32) (MACRO_CAP - 1);
            int first_tomb = -1;
            for (int probe = 0; probe < MACRO_CAP; probe++) {
                int slot = macro_idx[idx];
                if (slot == 0) {
                    int target = (first_tomb >= 0) ? first_tomb : (int) idx;
                    macros.add (m);
                    macro_idx[target] = macros.length;
                    return;
                }
                if (slot < 0) {
                    if (first_tomb < 0)
                        first_tomb = (int) idx;
                } else if (macros[slot - 1].name == m.name) {
                    macros[slot - 1] = m;
                    return;
                }
                idx = (idx + 1) & (uint32) (MACRO_CAP - 1);
            }
        }

        public void undef (string name) {
            uint32 idx = hash_str (name) & (uint32) (MACRO_CAP - 1);
            for (int probe = 0; probe < MACRO_CAP; probe++) {
                int slot = macro_idx[idx];
                if (slot == 0) return;
                if (slot > 0 && macros[slot - 1].name == name) {
                    macro_idx[idx] = -1;
                    return;
                }
                idx = (idx + 1) & (uint32) (MACRO_CAP - 1);
            }
        }

        private MacroDef? find_macro (string name) {
            uint32 idx = hash_str (name) & (uint32) (MACRO_CAP - 1);
            for (int probe = 0; probe < MACRO_CAP; probe++) {
                int slot = macro_idx[idx];
                if (slot == 0) return null;
                if (slot > 0 && macros[slot - 1].name == name)
                    return macros[slot - 1];
                idx = (idx + 1) & (uint32) (MACRO_CAP - 1);
            }
            return null;
        }

        private static bool is_ident_start (uint8 c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        }

        private static bool is_ident_char (uint8 c) {
            return is_ident_start (c) || (c >= '0' && c <= '9');
        }

        private static string dir_of (string path) {
            int last = -1;
            for (int i = 0; i < path.length; i++) {
                if (path[i] == '/' || path[i] == '\\')
                    last = i;
            }
            if (last < 0)
                return ".";
            if (last == 0)
                return "/";
            return path.substring (0, last);
        }

        private static string base_of (string path) {
            int last = -1;
            for (int i = 0; i < path.length; i++) {
                if (path[i] == '/' || path[i] == '\\')
                    last = i;
            }
            if (last < 0)
                return path;
            return path.substring (last + 1);
        }

        private static string trim_str (string s) {
            int start = 0;
            int end = s.length;
            while (start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\r'))
                start++;
            while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\r'))
                end--;
            return s.substring (start, end - start);
        }

        private static string join_path (string dir, string rel) {
            if (dir == "" || dir == ".")
                return rel;
            if (dir.has_suffix ("/") || dir.has_suffix ("\\"))
                return dir + rel;
            return dir + "/" + rel;
        }

        // Strip // and /* */ comments while preserving line count and string/char literals,
        // and join backslash-continued lines.
        private static GenericArray<PreLine> split_logical_lines (string src, string file) {
            var raw_lines = new GenericArray<string> ();
            int slen = src.length;
            int ls = 0;
            for (int i = 0; i < slen; i++) {
                if (src[i] == '\n') {
                    int le = i;
                    if (le > ls && src[le - 1] == '\r')
                        le--;
                    raw_lines.add (src.substring (ls, le - ls));
                    ls = i + 1;
                }
            }
            if (ls < slen) {
                int le = slen;
                if (le > ls && src[le - 1] == '\r')
                    le--;
                raw_lines.add (src.substring (ls, le - ls));
            }

            // Pass 1: join backslash line continuations, keeping original start line number
            var spliced = new GenericArray<PreLine> ();
            int idx = 0;
            while (idx < raw_lines.length) {
                int start_line = idx + 1;
                var sb = new StrBuilder ();
                while (idx < raw_lines.length) {
                    string ln = raw_lines[idx];
                    if (ln.length > 0 && ln[ln.length - 1] == '\\') {
                        sb.append (ln.substring (0, ln.length - 1));
                        idx++;
                    } else {
                        sb.append (ln);
                        idx++;
                        break;
                    }
                }
                spliced.add (new PreLine (file, start_line, sb.str));
            }

            // Pass 2: strip comments across lines
            var out_lines = new GenericArray<PreLine> ();
            bool in_block = false;
            for (int li = 0; li < spliced.length; li++) {
                var pl = spliced[li];
                string ln = pl.text;
                int llen = ln.length;
                var sb = new StrBuilder ();
                bool in_str = false;
                bool in_chr = false;
                int i = 0;
                while (i < llen) {
                    uint8 c = ln[i];
                    if (in_block) {
                        if (c == '*' && i + 1 < llen && ln[i + 1] == '/') {
                            in_block = false;
                            sb.append_c (' ');
                            i += 2;
                        } else {
                            i++;
                        }
                        continue;
                    }
                    if (in_str) {
                        sb.append_c ((char) c);
                        if (c == '\\' && i + 1 < llen) {
                            sb.append_c ((char) ln[i + 1]);
                            i += 2;
                            continue;
                        }
                        if (c == '"')
                            in_str = false;
                        i++;
                        continue;
                    }
                    if (in_chr) {
                        sb.append_c ((char) c);
                        if (c == '\\' && i + 1 < llen) {
                            sb.append_c ((char) ln[i + 1]);
                            i += 2;
                            continue;
                        }
                        if (c == '\'')
                            in_chr = false;
                        i++;
                        continue;
                    }
                    if (c == '"') {
                        in_str = true;
                        sb.append_c ((char) c);
                        i++;
                    } else if (c == '\'') {
                        in_chr = true;
                        sb.append_c ((char) c);
                        i++;
                    } else if (c == '/' && i + 1 < llen && ln[i + 1] == '/') {
                        break;
                    } else if (c == '/' && i + 1 < llen && ln[i + 1] == '*') {
                        in_block = true;
                        i += 2;
                    } else {
                        sb.append_c ((char) c);
                        i++;
                    }
                }
                out_lines.add (new PreLine (pl.file, pl.line, sb.str));
            }
            return out_lines;
        }

        public GenericArray<PreLine> process_file (string path) throws RefuseError {
            if (verbose) Host.eprintln (@"[pp] read $path...");
            string src;
            try {
                src = Host.read_file (path);
            } catch (FileError e) {
                throw new RefuseError.FAILED (@"$path: cannot read: $(e.message)");
            }
            if (verbose) Host.eprintln (@"[pp] read done ($(src.length) bytes)");
            return process_source (src, path);
        }

        public GenericArray<PreLine> process_source (string src, string file) throws RefuseError {
            var out_lines = new GenericArray<PreLine> ();
            var lines = split_logical_lines (src, file);
            if (verbose) Host.eprintln (@"[pp] $file: $(lines.length) logical lines");

            // Conditional stack: each entry has (active, any_taken)
            var cond_active = new GenericArray<bool> ();
            var cond_taken = new GenericArray<bool> ();

            for (int li = 0; li < lines.length; li++) {
                if (verbose && (li % 10000) == 0 && li > 0)
                    Host.eprintln (@"[pp] $file: $li/$(lines.length)");
                var pl = lines[li];
                string trimmed = trim_str (pl.text);

                bool currently_active = true;
                for (int ci = 0; ci < cond_active.length; ci++) {
                    if (!cond_active[ci]) {
                        currently_active = false;
                        break;
                    }
                }

                if (trimmed.has_prefix ("#")) {
                    string rest = trim_str (trimmed.substring (1));
                    // Extract directive keyword
                    int k = 0;
                    while (k < rest.length && is_ident_char (rest[k]))
                        k++;
                    string dir = rest.substring (0, k);
                    string arg = trim_str (rest.substring (k));

                    if (dir == "ifdef") {
                        string sym = first_ident (arg);
                        bool ok = find_macro (sym) != null;
                        cond_active.add (currently_active && ok);
                        cond_taken.add (ok);
                    } else if (dir == "ifndef") {
                        string sym = first_ident (arg);
                        bool ok = find_macro (sym) == null;
                        cond_active.add (currently_active && ok);
                        cond_taken.add (ok);
                    } else if (dir == "if") {
                        bool ok = currently_active && eval_if_expr (arg, file, pl.line) != 0;
                        cond_active.add (ok);
                        cond_taken.add (ok);
                    } else if (dir == "elif") {
                        if (cond_active.length == 0)
                            throw new RefuseError.FAILED (@"$file:$(pl.line): unexpected #elif");
                        int top = cond_active.length - 1;
                        bool parent_active = true;
                        for (int ci = 0; ci < top; ci++) {
                            if (!cond_active[ci]) {
                                parent_active = false;
                                break;
                            }
                        }
                        if (!parent_active || cond_taken[top]) {
                            cond_active[top] = false;
                        } else {
                            bool ok = eval_if_expr (arg, file, pl.line) != 0;
                            cond_active[top] = ok;
                            if (ok)
                                cond_taken[top] = true;
                        }
                    } else if (dir == "else") {
                        if (cond_active.length == 0)
                            throw new RefuseError.FAILED (@"$file:$(pl.line): unexpected #else");
                        int top = cond_active.length - 1;
                        bool parent_active = true;
                        for (int ci = 0; ci < top; ci++) {
                            if (!cond_active[ci]) {
                                parent_active = false;
                                break;
                            }
                        }
                        if (!parent_active || cond_taken[top]) {
                            cond_active[top] = false;
                        } else {
                            cond_active[top] = true;
                            cond_taken[top] = true;
                        }
                    } else if (dir == "endif") {
                        if (cond_active.length == 0)
                            throw new RefuseError.FAILED (@"$file:$(pl.line): unexpected #endif");
                        cond_active.remove_index (cond_active.length - 1);
                        cond_taken.remove_index (cond_taken.length - 1);
                    } else if (!currently_active) {
                        // Skip inactive directives
                    } else if (dir == "define") {
                        parse_define (arg);
                    } else if (dir == "undef") {
                        undef (first_ident (arg));
                    } else if (dir == "include") {
                        handle_include (arg, file, pl.line, out_lines);
                    } else if (dir == "error") {
                        throw new RefuseError.FAILED (@"$file:$(pl.line): #error $arg");
                    }
                    // #pragma or empty # ignored
                    continue;
                }

                if (!currently_active)
                    continue;

                if (trimmed == "")
                    continue;

                string expanded = expand_macros (pl.text, 0);
                out_lines.add (new PreLine (base_of (pl.file), pl.line, expanded));
            }
            return out_lines;
        }

        private static string first_ident (string s) {
            int i = 0;
            while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
                i++;
            int start = i;
            while (i < s.length && is_ident_char (s[i]))
                i++;
            return s.substring (start, i - start);
        }

        private void parse_define (string arg) {
            int i = 0;
            while (i < arg.length && (arg[i] == ' ' || arg[i] == '\t'))
                i++;
            int start = i;
            while (i < arg.length && is_ident_char (arg[i]))
                i++;
            string name = arg.substring (start, i - start);
            if (name == "")
                return;

            if (i < arg.length && arg[i] == '(') {
                // Function-like macro
                i++;
                var m = new MacroDef (name, "");
                m.is_func = true;
                while (i < arg.length) {
                    while (i < arg.length && (arg[i] == ' ' || arg[i] == '\t'))
                        i++;
                    if (i < arg.length && arg[i] == ')') {
                        i++;
                        break;
                    }
                    if (i + 2 < arg.length && arg[i] == '.' && arg[i + 1] == '.' && arg[i + 2] == '.') {
                        m.is_varargs = true;
                        i += 3;
                        while (i < arg.length && arg[i] != ')')
                            i++;
                        if (i < arg.length)
                            i++;
                        break;
                    }
                    int ps = i;
                    while (i < arg.length && is_ident_char (arg[i]))
                        i++;
                    string pname = arg.substring (ps, i - ps);
                    if (pname != "")
                        m.params.add (pname);
                    while (i < arg.length && (arg[i] == ' ' || arg[i] == '\t'))
                        i++;
                    if (i < arg.length && arg[i] == ',')
                        i++;
                }
                m.body = trim_str (arg.substring (i));
                define_macro (m);
            } else {
                string body = trim_str (arg.substring (i));
                define_object (name, body);
            }
        }

        private void handle_include (string arg, string cur_file, int line, GenericArray<PreLine> out_lines) throws RefuseError {
            if (arg.length < 2)
                return;
            uint8 delim = arg[0];
            if (delim == '<') {
                // System / fake-libc headers: handled natively by built-in type table
                return;
            }
            if (delim != '"')
                return;
            int end = 1;
            while (end < arg.length && arg[end] != '"')
                end++;
            string rel = arg.substring (1, end - 1);

            string? resolved = resolve_include (rel, cur_file);
            if (resolved == null)
                throw new RefuseError.FAILED (@"$cur_file:$line: cannot find include '$rel'");

            var inc_lines = process_file (resolved);
            for (int i = 0; i < inc_lines.length; i++)
                out_lines.add (inc_lines[i]);
        }

        private string? resolve_include (string rel, string cur_file) {
            string cand = join_path (dir_of (cur_file), rel);
            if (file_exists (cand))
                return cand;
            for (int i = 0; i < include_dirs.length; i++) {
                cand = join_path (include_dirs[i], rel);
                if (file_exists (cand))
                    return cand;
            }
            return null;
        }

        private static bool file_exists (string path) {
            try {
                Host.read_file (path);
                return true;
            } catch (FileError e) {
                return false;
            }
        }

        // Expand macros in text with bounded recursion depth.
        private string expand_macros (string text, int depth) {
            if (depth > 20)
                return text;
            var sb = new StrBuilder ();
            int tlen = text.length;
            int i = 0;
            while (i < tlen) {
                uint8 c = text[i];
                if (c == '"' || c == '\'') {
                    uint8 q = c;
                    sb.append_c ((char) c);
                    i++;
                    while (i < text.length) {
                        uint8 sc = text[i];
                        sb.append_c ((char) sc);
                        i++;
                        if (sc == '\\' && i < text.length) {
                            sb.append_c ((char) text[i]);
                            i++;
                        } else if (sc == q) {
                            break;
                        }
                    }
                    continue;
                }
                if (is_ident_start (c)) {
                    int start = i;
                    while (i < text.length && is_ident_char (text[i]))
                        i++;
                    string ident = text.substring (start, i - start);
                    var m = find_macro (ident);
                    if (m != null && !m.expanding) {
                        if (!m.is_func) {
                            m.expanding = true;
                            sb.append (expand_macros (m.body, depth + 1));
                            m.expanding = false;
                            continue;
                        } else {
                            // Check for '(' after optional whitespace
                            int j = i;
                            while (j < text.length && (text[j] == ' ' || text[j] == '\t'))
                                j++;
                            if (j < text.length && text[j] == '(') {
                                int end_paren = j;
                                var args = parse_macro_args (text, j, out end_paren);
                                if (end_paren > j) {
                                    string sub = subst_macro (m, args);
                                    m.expanding = true;
                                    sb.append (expand_macros (sub, depth + 1));
                                    m.expanding = false;
                                    i = end_paren;
                                    continue;
                                }
                            }
                        }
                    }
                    sb.append (ident);
                    continue;
                }
                sb.append_c ((char) c);
                i++;
            }
            return sb.str;
        }

        private static GenericArray<string> parse_macro_args (string text, int open_idx, out int end_idx) {
            var args = new GenericArray<string> ();
            int i = open_idx + 1;
            int depth = 1;
            var cur = new StrBuilder ();
            bool in_str = false;
            bool in_chr = false;
            while (i < text.length && depth > 0) {
                uint8 c = text[i];
                if (in_str) {
                    cur.append_c ((char) c);
                    if (c == '\\' && i + 1 < text.length) {
                        cur.append_c ((char) text[i + 1]);
                        i += 2;
                        continue;
                    }
                    if (c == '"')
                        in_str = false;
                    i++;
                    continue;
                }
                if (in_chr) {
                    cur.append_c ((char) c);
                    if (c == '\\' && i + 1 < text.length) {
                        cur.append_c ((char) text[i + 1]);
                        i += 2;
                        continue;
                    }
                    if (c == '\'')
                        in_chr = false;
                    i++;
                    continue;
                }
                if (c == '"') {
                    in_str = true;
                    cur.append_c ((char) c);
                    i++;
                } else if (c == '\'') {
                    in_chr = true;
                    cur.append_c ((char) c);
                    i++;
                } else if (c == '(') {
                    depth++;
                    cur.append_c ((char) c);
                    i++;
                } else if (c == ')') {
                    depth--;
                    if (depth == 0) {
                        string a = trim_str (cur.str);
                        if (a != "" || args.length > 0)
                            args.add (a);
                        i++;
                        break;
                    }
                    cur.append_c ((char) c);
                    i++;
                } else if (c == ',' && depth == 1) {
                    args.add (trim_str (cur.str));
                    cur = new StrBuilder ();
                    i++;
                } else {
                    cur.append_c ((char) c);
                    i++;
                }
            }
            if (depth != 0) {
                end_idx = open_idx;
                return args;
            }
            end_idx = i;
            return args;
        }

        private static string stringify_arg (string s) {
            string t = trim_str (s);
            var sb = new StrBuilder ("\"");
            for (int i = 0; i < t.length; i++) {
                uint8 ch = t[i];
                if (ch == '"' || ch == '\\')
                    sb.append_c ('\\');
                sb.append_c ((char) ch);
            }
            sb.append_c ('"');
            return sb.str;
        }

        private static string subst_macro (MacroDef m, GenericArray<string> args) {
            var sb = new StrBuilder ();
            string body = m.body;
            int i = 0;
            while (i < body.length) {
                uint8 c = body[i];
                if (c == '"' || c == '\'') {
                    uint8 q = c;
                    sb.append_c ((char) c);
                    i++;
                    while (i < body.length) {
                        uint8 sc = body[i];
                        sb.append_c ((char) sc);
                        i++;
                        if (sc == '\\' && i < body.length) {
                            sb.append_c ((char) body[i]);
                            i++;
                        } else if (sc == q) {
                            break;
                        }
                    }
                    continue;
                }
                if (c == '#' && i + 1 < body.length && body[i + 1] == '#') {
                    // Token pasting: remove trailing whitespace before ## and leading whitespace after ##
                    while (sb.length > 0 && (sb.str[sb.length - 1] == ' ' || sb.str[sb.length - 1] == '\t'))
                        sb.truncate (sb.length - 1);
                    i += 2;
                    while (i < body.length && (body[i] == ' ' || body[i] == '\t'))
                        i++;
                    continue;
                }
                if (c == '#') {
                    int j = i + 1;
                    while (j < body.length && (body[j] == ' ' || body[j] == '\t'))
                        j++;
                    if (j < body.length && is_ident_start (body[j])) {
                        int start = j;
                        while (j < body.length && is_ident_char (body[j]))
                            j++;
                        string pname = body.substring (start, j - start);
                        int p_idx = -1;
                        for (int pi = 0; pi < m.params.length; pi++) {
                            if (m.params[pi] == pname) {
                                p_idx = pi;
                                break;
                            }
                        }
                        if (p_idx >= 0 && p_idx < args.length) {
                            sb.append (stringify_arg (args[p_idx]));
                            i = j;
                            continue;
                        }
                    }
                }
                if (is_ident_start (c)) {
                    int start = i;
                    while (i < body.length && is_ident_char (body[i]))
                        i++;
                    string ident = body.substring (start, i - start);
                    if (m.is_varargs && ident == "__VA_ARGS__") {
                        for (int ai = m.params.length; ai < args.length; ai++) {
                            if (ai > m.params.length)
                                sb.append (", ");
                            sb.append (args[ai]);
                        }
                        continue;
                    }
                    int p_idx = -1;
                    for (int pi = 0; pi < m.params.length; pi++) {
                        if (m.params[pi] == ident) {
                            p_idx = pi;
                            break;
                        }
                    }
                    if (p_idx >= 0 && p_idx < args.length)
                        sb.append (args[p_idx]);
                    else
                        sb.append (ident);
                    continue;
                }
                sb.append_c ((char) c);
                i++;
            }
            return sb.str;
        }

        // ---- #if constant expression evaluator ----

        private string if_src = "";
        private int if_pos = 0;

        private int64 eval_if_expr (string raw, string file, int line) {
            // First handle defined(X) / defined X before macro expansion
            string pre = resolve_defined (raw);
            string expanded = expand_macros (pre, 0);
            if_src = expanded;
            if_pos = 0;
            return parse_if_lor ();
        }

        private string resolve_defined (string s) {
            var sb = new StrBuilder ();
            int i = 0;
            while (i < s.length) {
                if (is_ident_start (s[i])) {
                    int start = i;
                    while (i < s.length && is_ident_char (s[i]))
                        i++;
                    string ident = s.substring (start, i - start);
                    if (ident == "defined") {
                        while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
                            i++;
                        bool has_paren = false;
                        if (i < s.length && s[i] == '(') {
                            has_paren = true;
                            i++;
                            while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
                                i++;
                        }
                        int ns = i;
                        while (i < s.length && is_ident_char (s[i]))
                            i++;
                        string sym = s.substring (ns, i - ns);
                        if (has_paren) {
                            while (i < s.length && s[i] != ')')
                                i++;
                            if (i < s.length)
                                i++;
                        }
                        sb.append (find_macro (sym) != null ? "1" : "0");
                        continue;
                    }
                    sb.append (ident);
                    continue;
                }
                sb.append_c ((char) s[i]);
                i++;
            }
            return sb.str;
        }

        private void if_skip_ws () {
            while (if_pos < if_src.length && (if_src[if_pos] == ' ' || if_src[if_pos] == '\t'))
                if_pos++;
        }

        private bool if_match (string tok) {
            if_skip_ws ();
            if (if_pos + tok.length > if_src.length)
                return false;
            if (if_src.substring (if_pos, tok.length) == tok) {
                if_pos += tok.length;
                return true;
            }
            return false;
        }

        private int64 parse_if_lor () {
            int64 v = parse_if_land ();
            while (if_match ("||")) {
                int64 r = parse_if_land ();
                v = (v != 0 || r != 0) ? 1 : 0;
            }
            return v;
        }

        private int64 parse_if_land () {
            int64 v = parse_if_eq ();
            while (if_match ("&&")) {
                int64 r = parse_if_eq ();
                v = (v != 0 && r != 0) ? 1 : 0;
            }
            return v;
        }

        private int64 parse_if_eq () {
            int64 v = parse_if_rel ();
            while (true) {
                if (if_match ("=="))
                    v = (v == parse_if_rel ()) ? 1 : 0;
                else if (if_match ("!="))
                    v = (v != parse_if_rel ()) ? 1 : 0;
                else
                    break;
            }
            return v;
        }

        private int64 parse_if_rel () {
            int64 v = parse_if_add ();
            while (true) {
                if (if_match ("<="))
                    v = (v <= parse_if_add ()) ? 1 : 0;
                else if (if_match (">="))
                    v = (v >= parse_if_add ()) ? 1 : 0;
                else if (if_match ("<"))
                    v = (v < parse_if_add ()) ? 1 : 0;
                else if (if_match (">"))
                    v = (v > parse_if_add ()) ? 1 : 0;
                else
                    break;
            }
            return v;
        }

        private int64 parse_if_add () {
            int64 v = parse_if_mul ();
            while (true) {
                if (if_match ("+"))
                    v = v + parse_if_mul ();
                else if (if_match ("-"))
                    v = v - parse_if_mul ();
                else
                    break;
            }
            return v;
        }

        private int64 parse_if_mul () {
            int64 v = parse_if_unary ();
            while (true) {
                if (if_match ("*"))
                    v = v * parse_if_unary ();
                else if (if_match ("/")) {
                    int64 d = parse_if_unary ();
                    v = d != 0 ? v / d : 0;
                } else
                    break;
            }
            return v;
        }

        private int64 parse_if_unary () {
            if_skip_ws ();
            if (if_match ("!"))
                return parse_if_unary () == 0 ? 1 : 0;
            if (if_match ("-"))
                return -parse_if_unary ();
            if (if_match ("~"))
                return ~parse_if_unary ();
            if (if_match ("(")) {
                int64 v = parse_if_lor ();
                if_match (")");
                return v;
            }
            if_skip_ws ();
            if (if_pos >= if_src.length)
                return 0;
            if (if_src[if_pos] >= '0' && if_src[if_pos] <= '9') {
                int start = if_pos;
                while (if_pos < if_src.length && is_ident_char (if_src[if_pos]))
                    if_pos++;
                return parse_int_lit (if_src.substring (start, if_pos - start));
            }
            if (is_ident_start (if_src[if_pos])) {
                while (if_pos < if_src.length && is_ident_char (if_src[if_pos]))
                    if_pos++;
                // Unexpanded identifier in #if evaluates to 0 per C standard
                return 0;
            }
            return 0;
        }

        public static int64 parse_int_lit (string raw) {
            string s = raw;
            while (s.length > 0) {
                uint8 last = s[s.length - 1];
                if (last == 'u' || last == 'U' || last == 'l' || last == 'L')
                    s = s.substring (0, s.length - 1);
                else
                    break;
            }
            if (s.has_prefix ("0x") || s.has_prefix ("0X")) {
                int64 v = 0;
                for (int i = 2; i < s.length; i++) {
                    uint8 c = s[i];
                    int64 d = 0;
                    if (c >= '0' && c <= '9') d = (int64) (c - '0');
                    else if (c >= 'a' && c <= 'f') d = (int64) (10 + c - 'a');
                    else if (c >= 'A' && c <= 'F') d = (int64) (10 + c - 'A');
                    v = (v << 4) | d;
                }
                return v;
            }
            if (s.has_prefix ("0b") || s.has_prefix ("0B")) {
                int64 v = 0;
                for (int i = 2; i < s.length; i++) {
                    v = (v << 1) | (int64) (s[i] - '0');
                }
                return v;
            }
            if (s.length > 1 && s[0] == '0') {
                int64 v = 0;
                for (int i = 1; i < s.length; i++) {
                    v = (v << 3) | (int64) (s[i] - '0');
                }
                return v;
            }
            int64 v = 0;
            for (int i = 0; i < s.length; i++) {
                uint8 c = s[i];
                if (c >= '0' && c <= '9')
                    v = v * 10 + (int64) (c - '0');
            }
            return v;
        }
    }
}
