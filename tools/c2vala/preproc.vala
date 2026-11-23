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

                string line_text = pl.text;
                while (has_unclosed_func_macro (line_text) && li + 1 < lines.length) {
                    string nxt_trim = trim_str (lines[li + 1].text);
                    if (nxt_trim.has_prefix ("#"))
                        break;
                    li++;
                    line_text = line_text + " " + lines[li].text;
                }
                string expanded = expand_macros (line_text, 0, base_of (pl.file), pl.line);
                out_lines.add (new PreLine (base_of (pl.file), pl.line, expanded));
            }
            return out_lines;
        }

        private bool has_unclosed_func_macro (string text) {
            int tlen = text.length;
            int i = 0;
            bool in_str = false;
            bool in_chr = false;
            while (i < tlen) {
                uint8 c = text[i];
                if (in_str) {
                    if (c == '\\' && i + 1 < tlen) { i += 2; continue; }
                    if (c == '"') in_str = false;
                    i++; continue;
                }
                if (in_chr) {
                    if (c == '\\' && i + 1 < tlen) { i += 2; continue; }
                    if (c == '\'') in_chr = false;
                    i++; continue;
                }
                if (c == '"') { in_str = true; i++; continue; }
                if (c == '\'') { in_chr = true; i++; continue; }
                if (is_ident_start (c)) {
                    int start = i;
                    i++;
                    while (i < tlen && is_ident_char (text[i])) i++;
                    string ident = text.substring (start, i - start);
                    var m = find_macro (ident);
                    if (m != null && m.is_func) {
                        int j = i;
                        while (j < tlen && (text[j] == ' ' || text[j] == '\t')) j++;
                        if (j < tlen && text[j] == '(') {
                            int depth = 1;
                            j++;
                            bool s2 = false;
                            bool c2 = false;
                            while (j < tlen && depth > 0) {
                                uint8 ch = text[j];
                                if (s2) {
                                    if (ch == '\\' && j + 1 < tlen) { j += 2; continue; }
                                    if (ch == '"') s2 = false;
                                } else if (c2) {
                                    if (ch == '\\' && j + 1 < tlen) { j += 2; continue; }
                                    if (ch == '\'') c2 = false;
                                } else {
                                    if (ch == '"') s2 = true;
                                    else if (ch == '\'') c2 = true;
                                    else if (ch == '(') depth++;
                                    else if (ch == ')') depth--;
                                }
                                j++;
                            }
                            if (depth > 0)
                                return true;
                            i = j;
                            continue;
                        }
                    }
                    continue;
                }
                i++;
            }
            return false;
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

        private bool mark_included_once (string key) {
            for (int i = 0; i < included_once.length; i++) {
                if (included_once[i] == key)
                    return false;
            }
            included_once.add (key);
            return true;
        }

        private void handle_sys_include (string hdr, GenericArray<PreLine> out_lines) throws RefuseError {
            string key = "<" + hdr + ">";
            if (!mark_included_once (key))
                return;
            string src = "";
            if (hdr == "stdint.h" || hdr == "inttypes.h" || hdr == "limits.h") {
                src = "#ifndef _C2V_INT_LIMITS\n#define _C2V_INT_LIMITS 1\n"
                    + "#define CHAR_BIT 8\n"
                    + "#define SCHAR_MIN (-128)\n#define SCHAR_MAX 127\n#define UCHAR_MAX 255\n"
                    + "#define SHRT_MIN (-32768)\n#define SHRT_MAX 32767\n#define USHRT_MAX 65535\n"
                    + "#define INT_MIN (-2147483647 - 1)\n#define INT_MAX 2147483647\n#define UINT_MAX 4294967295U\n"
                    + "#define LONG_MIN (-9223372036854775807L - 1L)\n#define LONG_MAX 9223372036854775807L\n#define ULONG_MAX 18446744073709551615UL\n"
                    + "#define LLONG_MIN (-9223372036854775807LL - 1LL)\n#define LLONG_MAX 9223372036854775807LL\n#define ULLONG_MAX 18446744073709551615ULL\n"
                    + "#define INT8_MIN (-128)\n#define INT8_MAX 127\n#define UINT8_MAX 255\n"
                    + "#define INT16_MIN (-32768)\n#define INT16_MAX 32767\n#define UINT16_MAX 65535\n"
                    + "#define INT32_MIN (-2147483647 - 1)\n#define INT32_MAX 2147483647\n#define UINT32_MAX 4294967295U\n"
                    + "#define INT64_MIN (-9223372036854775807LL - 1LL)\n#define INT64_MAX 9223372036854775807LL\n#define UINT64_MAX 18446744073709551615ULL\n"
                    + "#define SIZE_MAX 18446744073709551615ULL\n"
                    + "#define INTPTR_MIN INT64_MIN\n#define INTPTR_MAX INT64_MAX\n#define UINTPTR_MAX UINT64_MAX\n"
                    + "#define PTRDIFF_MIN INT64_MIN\n#define PTRDIFF_MAX INT64_MAX\n"
                    + "#endif\n";
            } else if (hdr == "float.h") {
                src = "#define DBL_MAX 1.7976931348623157e+308\n#define DBL_MIN 2.2250738585072014e-308\n#define DBL_EPSILON 2.2204460492503131e-16\n"
                    + "#define FLT_MAX 3.40282347e+38F\n#define FLT_MIN 1.17549435e-38F\n#define FLT_EPSILON 1.19209290e-7F\n"
                    + "#define DBL_MANT_DIG 53\n#define FLT_MANT_DIG 24\n";
            } else if (hdr == "stdio.h") {
                src = "#ifndef NULL\n#define NULL 0\n#endif\n#define EOF (-1)\n#define SEEK_SET 0\n#define SEEK_CUR 1\n#define SEEK_END 2\n#define FILENAME_MAX 4096\n"
                    + "typedef struct _c2v_FILE { int _opaque; } FILE;\n"
                    + "extern FILE *stdin;\nextern FILE *stdout;\nextern FILE *stderr;\n"
                    + "FILE *fopen(const char *pathname, const char *mode);\n"
                    + "FILE *fdopen(int fd, const char *mode);\n"
                    + "int fclose(FILE *stream);\n"
                    + "unsigned long fread(void *ptr, unsigned long size, unsigned long nmemb, FILE *stream);\n"
                    + "unsigned long fwrite(const void *ptr, unsigned long size, unsigned long nmemb, FILE *stream);\n"
                    + "char *fgets(char *s, int size, FILE *stream);\n"
                    + "int fputs(const char *s, FILE *stream);\n"
                    + "int fputc(int c, FILE *stream);\n"
                    + "int putc(int c, FILE *stream);\n"
                    + "int fgetc(FILE *stream);\n"
                    + "int getc(FILE *stream);\n"
                    + "int ungetc(int c, FILE *stream);\n"
                    + "int fflush(FILE *stream);\n"
                    + "int fseek(FILE *stream, long offset, int whence);\n"
                    + "long ftell(FILE *stream);\n"
                    + "void rewind(FILE *stream);\n"
                    + "int feof(FILE *stream);\n"
                    + "int ferror(FILE *stream);\n"
                    + "void clearerr(FILE *stream);\n"
                    + "int fileno(FILE *stream);\n"
                    + "int fprintf(FILE *stream, const char *format, ...);\n"
                    + "int snprintf(char *str, unsigned long size, const char *format, ...);\n"
                    + "int vsnprintf(char *str, unsigned long size, const char *format, va_list ap);\n"
                    + "int puts(const char *s);\n"
                    + "int remove(const char *pathname);\n"
                    + "int rename(const char *oldpath, const char *newpath);\n";
            } else if (hdr == "ctype.h") {
                src = "int isspace(int c);\nint isdigit(int c);\nint isalpha(int c);\nint isalnum(int c);\n"
                    + "int isxdigit(int c);\nint isupper(int c);\nint islower(int c);\nint tolower(int c);\nint toupper(int c);\n";
            } else if (hdr == "stdlib.h" || hdr == "stddef.h" || hdr == "string.h") {
                src = "#ifndef NULL\n#define NULL 0\n#endif\n#define EXIT_SUCCESS 0\n#define EXIT_FAILURE 1\n"
                    + "#ifndef _C2V_STDLIB_PROTOS\n#define _C2V_STDLIB_PROTOS 1\n"
                    + "double strtod(const char *nptr, char **endptr);\n"
                    + "char *getenv(const char *name);\n"
                    + "void exit(int status);\n"
                    + "void *alloca(unsigned long size);\n"
                    + "unsigned long malloc_usable_size(const void *ptr);\n"
                    + "void *memchr(const void *s, int c, unsigned long n);\n"
                    + "#endif\n";
            } else if (hdr == "math.h") {
                src = "#define M_E 2.7182818284590452354\n#define M_LN2 0.69314718055994530942\n#define M_LN10 2.30258509299404568402\n#define M_PI 3.14159265358979323846\n"
                    + "#define M_PI_2 1.57079632679489661923\n#define M_PI_4 0.78539816339744830962\n#define M_SQRT2 1.41421356237309504880\n"
                    + "#define NAN (0.0/0.0)\n#define INFINITY (1.0/0.0)\n"
                    + "double fabs(double x);\ndouble floor(double x);\ndouble ceil(double x);\ndouble trunc(double x);\ndouble round(double x);\n"
                    + "double sqrt(double x);\ndouble cbrt(double x);\ndouble hypot(double x, double y);\ndouble pow(double x, double y);\n"
                    + "double exp(double x);\ndouble exp2(double x);\ndouble expm1(double x);\n"
                    + "double log(double x);\ndouble log2(double x);\ndouble log10(double x);\ndouble log1p(double x);\n"
                    + "double sin(double x);\ndouble cos(double x);\ndouble tan(double x);\n"
                    + "double asin(double x);\ndouble acos(double x);\ndouble atan(double x);\ndouble atan2(double y, double x);\n"
                    + "double sinh(double x);\ndouble cosh(double x);\ndouble tanh(double x);\n"
                    + "double asinh(double x);\ndouble acosh(double x);\ndouble atanh(double x);\n"
                    + "double fmax(double x, double y);\ndouble fmin(double x, double y);\n"
                    + "double fmod(double x, double y);\ndouble copysign(double x, double y);\nlong lrint(double x);\nint signbit(double x);\n";
            } else if (hdr == "time.h" || hdr == "sys/time.h") {
                src = "#ifndef _C2V_TIME_H\n#define _C2V_TIME_H 1\n"
                    + "typedef int64_t time_t;\ntypedef int64_t clock_t;\ntypedef int64_t suseconds_t;\n"
                    + "#define CLOCKS_PER_SEC 1000000\n"
                    + "struct tm { int tm_sec; int tm_min; int tm_hour; int tm_mday; int tm_mon; int tm_year; int tm_wday; int tm_yday; int tm_isdst; };\n"
                    + "struct timespec { time_t tv_sec; long tv_nsec; };\n"
                    + "struct timeval { time_t tv_sec; suseconds_t tv_usec; };\n"
                    + "time_t time(time_t *tloc);\n"
                    + "clock_t clock(void);\n"
                    + "double difftime(time_t time1, time_t time0);\n"
                    + "time_t mktime(struct tm *tm);\n"
                    + "struct tm *gmtime(const time_t *timep);\n"
                    + "struct tm *gmtime_r(const time_t *timep, struct tm *result);\n"
                    + "struct tm *localtime(const time_t *timep);\n"
                    + "struct tm *localtime_r(const time_t *timep, struct tm *result);\n"
                    + "size_t strftime(char *s, size_t max, const char *format, const struct tm *tm);\n"
                    + "int gettimeofday(struct timeval *tv, void *tz);\n"
                    + "int nanosleep(const struct timespec *req, struct timespec *rem);\n"
                    + "#endif\n";
            } else if (hdr == "pthread.h") {
                src = "typedef struct _c2v_pthread_t { int _opaque; } pthread_t;\n"
                    + "typedef struct pthread_mutex_t { int _opaque; } pthread_mutex_t;\n"
                    + "typedef struct pthread_mutexattr_t { int _opaque; } pthread_mutexattr_t;\n"
                    + "typedef struct pthread_cond_t { int _opaque; } pthread_cond_t;\n"
                    + "typedef struct pthread_condattr_t { int _opaque; } pthread_condattr_t;\n"
                    + "typedef struct pthread_attr_t { int _opaque; } pthread_attr_t;\n"
                    + "typedef struct pthread_rwlock_t { int _opaque; } pthread_rwlock_t;\n"
                    + "typedef int pthread_once_t;\ntypedef uint32_t pthread_key_t;\n"
                    + "#define PTHREAD_MUTEX_INITIALIZER { 0 }\n#define PTHREAD_COND_INITIALIZER { 0 }\n#define PTHREAD_ONCE_INIT 0\n"
                    + "#define PTHREAD_MUTEX_NORMAL 0\n#define PTHREAD_MUTEX_RECURSIVE 1\n#define PTHREAD_MUTEX_ERRORCHECK 2\n"
                    + "int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start_routine)(void *), void *arg);\n"
                    + "int pthread_join(pthread_t thread, void **retval);\n"
                    + "int pthread_detach(pthread_t thread);\n"
                    + "int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr);\n"
                    + "int pthread_mutexattr_init(pthread_mutexattr_t *attr);\n"
                    + "int pthread_mutexattr_settype(pthread_mutexattr_t *attr, int type);\n"
                    + "int pthread_mutexattr_destroy(pthread_mutexattr_t *attr);\n"
                    + "int pthread_mutex_lock(pthread_mutex_t *mutex);\n"
                    + "int pthread_mutex_trylock(pthread_mutex_t *mutex);\n"
                    + "int pthread_mutex_unlock(pthread_mutex_t *mutex);\n"
                    + "int pthread_mutex_destroy(pthread_mutex_t *mutex);\n"
                    + "int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);\n"
                    + "int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);\n"
                    + "int pthread_cond_signal(pthread_cond_t *cond);\n"
                    + "int pthread_cond_broadcast(pthread_cond_t *cond);\n"
                    + "int pthread_cond_destroy(pthread_cond_t *cond);\n";
            } else if (hdr == "sys/types.h" || hdr == "unistd.h" || hdr == "fcntl.h" || hdr == "sys/stat.h") {
                src = "#ifndef _C2V_POSIX_TYPES\n#define _C2V_POSIX_TYPES 1\n"
                    + "typedef int64_t off_t;\ntypedef int32_t pid_t;\ntypedef uint32_t uid_t;\ntypedef uint32_t gid_t;\n"
                    + "typedef uint32_t mode_t;\ntypedef uint64_t dev_t;\ntypedef uint64_t ino_t;\ntypedef uint32_t socklen_t;\n"
                    + "typedef uint64_t nlink_t;\n"
                    + "struct flock { short l_type; short l_whence; off_t l_start; off_t l_len; pid_t l_pid; };\n"
                    + "struct stat { dev_t st_dev; ino_t st_ino; mode_t st_mode; nlink_t st_nlink; uid_t st_uid; gid_t st_gid; dev_t st_rdev; off_t st_size; int64_t st_blksize; int64_t st_blocks; int64_t st_atime; int64_t st_mtime; int64_t st_ctime; };\n"
                    + "#define S_ISDIR(m) (((m) & 0170000) == 0040000)\n#define S_ISREG(m) (((m) & 0170000) == 0100000)\n"
                    + "#define STDIN_FILENO 0\n#define STDOUT_FILENO 1\n#define STDERR_FILENO 2\n"
                    + "#define F_OK 0\n#define X_OK 1\n#define W_OK 2\n#define R_OK 4\n"
                    + "#define _SC_PAGESIZE 30\n#define _SC_PAGE_SIZE 30\n#define _SC_NPROCESSORS_ONLN 84\n"
                    + "#define O_RDONLY 0\n#define O_WRONLY 1\n#define O_RDWR 2\n#define O_CREAT 64\n#define O_EXCL 128\n#define O_TRUNC 512\n#define O_APPEND 1024\n#define O_NOFOLLOW 131072\n#define O_CLOEXEC 524288\n"
                    + "#define F_DUPFD 0\n#define F_GETFD 1\n#define F_SETFD 2\n#define F_GETFL 3\n#define F_SETFL 4\n"
                    + "#define F_GETLK 5\n#define F_SETLK 6\n#define F_SETLKW 7\n"
                    + "#define F_RDLCK 0\n#define F_WRLCK 1\n#define F_UNLCK 2\n"
                    + "int open(const char *pathname, int flags, ...);\n"
                    + "off_t lseek(int fd, off_t offset, int whence);\n"
                    + "int fsync(int fd);\n"
                    + "pid_t getpid(void);\n"
                    + "long sysconf(int name);\n"
                    + "int utimes(const char *filename, void *times);\n"
                    + "#endif\n";
            } else if (hdr == "setjmp.h") {
                src = "typedef struct jmp_buf { int _opaque; } jmp_buf;\n";
            } else if (hdr == "errno.h") {
                src = "static int _c2v_errno = 0;\n#define errno _c2v_errno\n"
                    + "#define EPERM 1\n#define ENOENT 2\n#define ESRCH 3\n#define EINTR 4\n#define EIO 5\n"
                    + "#define EAGAIN 11\n#define EWOULDBLOCK 11\n#define ENOMEM 12\n#define EACCES 13\n#define EFAULT 14\n"
                    + "#define EBUSY 16\n#define EEXIST 17\n#define ENODEV 19\n#define EINVAL 22\n"
                    + "#define ENOSPC 28\n#define EROFS 30\n#define EPIPE 32\n#define ERANGE 34\n"
                    + "#define ENOLCK 37\n#define ENOSYS 38\n#define ENOTEMPTY 39\n#define EOVERFLOW 75\n#define ETIMEDOUT 110\n";
            } else if (hdr == "fenv.h") {
                src = "#define FE_TONEAREST 0\n#define FE_DOWNWARD 1\n#define FE_UPWARD 2\n#define FE_TOWARDZERO 3\n"
                    + "int fesetround(int round);\n";
            } else if (hdr == "dlfcn.h") {
                src = "#define RTLD_LAZY 1\n#define RTLD_NOW 2\n#define RTLD_GLOBAL 256\n#define RTLD_LOCAL 0\n"
                    + "void *dlopen(const char *filename, int flags);\n"
                    + "void *dlsym(void *handle, const char *symbol);\n"
                    + "char *dlerror(void);\nint dlclose(void *handle);\n";
            } else if (hdr == "utime.h") {
                src = "struct utimbuf { int64_t actime; int64_t modtime; };\n";
            } else if (hdr == "dirent.h") {
                src = "typedef struct _c2v_DIR { int _opaque; } DIR;\n"
                    + "struct dirent { uint64_t d_ino; int64_t d_off; uint16_t d_reclen; uint8_t d_type; char d_name[256]; };\n"
                    + "DIR *opendir(const char *name);\n"
                    + "struct dirent *readdir(DIR *dirp);\n"
                    + "int closedir(DIR *dirp);\n";
            }
            if (src != "") {
                var inc_lines = process_source (src, key);
                for (int i = 0; i < inc_lines.length; i++)
                    out_lines.add (inc_lines[i]);
            }
        }

        private void handle_include (string arg, string cur_file, int line, GenericArray<PreLine> out_lines) throws RefuseError {
            if (arg.length < 2)
                return;
            uint8 delim = arg[0];
            if (delim == '<') {
                int end = 1;
                while (end < arg.length && arg[end] != '>')
                    end++;
                string hdr = arg.substring (1, end - 1);
                handle_sys_include (hdr, out_lines);
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
        private string expand_macros (string text, int depth, string cur_file = "", int cur_line = 0) {
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
                    if (ident == "__LINE__" && cur_line > 0) {
                        sb.append (@"$cur_line");
                        continue;
                    }
                    if (ident == "__FILE__" && cur_file != "") {
                        sb.append (@"\"$cur_file\"");
                        continue;
                    }
                    var m = find_macro (ident);
                    if (m != null && !m.expanding) {
                        if (!m.is_func) {
                            m.expanding = true;
                            sb.append (expand_macros (m.body, depth + 1, cur_file, cur_line));
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
