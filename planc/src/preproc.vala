// `#if` / `#elif` / `#else` / `#endif` preprocessor (docs/02-compiler.md 2.1).
//
// Line based, like valac's: a directive is only recognised at the beginning of
// a line, after optional blanks. Inactive lines and the directive lines
// themselves are replaced by spaces of the same length so that every later
// diagnostic keeps the original line and column.
//
// The condition grammar is the subset valac accepts: macro names combined with
// `!`, `&&`, `||` and parentheses. Numeric tokens are not conditions (valac
// treats them as undefined macros and they evaluate to false).
namespace Planc {

    public sealed class Preprocessor : Object {

        private string src;
        private int src_len = 0;
        private int pos = 0;
        private GenericArray<string> defines;

        private string expr_text = "";
        private int expr_pos = 0;
        private int expr_len = 0;

        // Lexical state carried across lines so that a '#' inside a string or a
        // block comment is not mistaken for a directive (valac does the same).
        private int lex_state = 0; // 0 code, 1 string, 2 verbatim string, 3 block comment

        public Preprocessor (string source, GenericArray<string> defs) {
            src = source;
            src_len = source.length;
            defines = defs;
        }

        public static string run (string source, GenericArray<string> defs) throws LexError {
            var pp = new Preprocessor (source, defs);
            return pp.process ();
        }

        // valac 0.56 defines VALA_0_<even minor> for every release up to 0.56.
        private bool is_predefined (string name) {
            if (name == "PLANC")
                return true;
            if (!name.has_prefix ("VALA_0_"))
                return false;
            var rest = name.substring (7);
            int n = 0;
            for (int i = 0; i < rest.length; i++) {
                if (rest[i] < '0' || rest[i] > '9')
                    return false;
                n = n * 10 + (int) (rest[i] - '0');
            }
            return n >= 2 && n <= 56 && (n % 2) == 0;
        }

        private bool is_defined (string name) {
            foreach (var d in defines) {
                if (d == name)
                    return true;
            }
            return is_predefined (name);
        }

        private static bool is_ident_start (char c) {
            return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }

        private static bool is_ident_char (char c) {
            return is_ident_start (c) || (c >= '0' && c <= '9');
        }

        private void skip_expr_blanks () {
            while (expr_pos < expr_len
                   && (expr_text[expr_pos] == ' ' || expr_text[expr_pos] == '\t'))
                expr_pos++;
        }

        private bool eval_or () {
            bool v = eval_and ();
            while (true) {
                skip_expr_blanks ();
                if (expr_pos + 1 < expr_len
                    && expr_text[expr_pos] == '|' && expr_text[expr_pos + 1] == '|') {
                    expr_pos += 2;
                    bool r = eval_and ();
                    v = v || r;
                } else {
                    return v;
                }
            }
        }

        private bool eval_and () {
            bool v = eval_unary ();
            while (true) {
                skip_expr_blanks ();
                if (expr_pos + 1 < expr_len
                    && expr_text[expr_pos] == '&' && expr_text[expr_pos + 1] == '&') {
                    expr_pos += 2;
                    bool r = eval_unary ();
                    v = v && r;
                } else {
                    return v;
                }
            }
        }

        private bool eval_unary () {
            skip_expr_blanks ();
            if (expr_pos >= expr_len)
                return false;
            var c = expr_text[expr_pos];
            if (c == '!') {
                expr_pos++;
                return !eval_unary ();
            }
            if (c == '(') {
                expr_pos++;
                bool v = eval_or ();
                skip_expr_blanks ();
                if (expr_pos < expr_len && expr_text[expr_pos] == ')')
                    expr_pos++;
                return v;
            }
            if (is_ident_start (c)) {
                int s = expr_pos;
                while (expr_pos < expr_len && is_ident_char (expr_text[expr_pos]))
                    expr_pos++;
                return is_defined (expr_text[s:expr_pos]);
            }
            // Numbers and anything else are not conditions.
            expr_pos++;
            return false;
        }

        private bool eval_condition (string text) {
            expr_text = text;
            expr_pos = 0;
            expr_len = text.length;
            return eval_or ();
        }

        private void update_lex_state (int ls, int le) {
            int i = ls;
            while (i < le) {
                var c = src[i];
                if (lex_state == 3) {
                    if (c == '*' && i + 1 < le && src[i + 1] == '/') {
                        lex_state = 0;
                        i += 2;
                        continue;
                    }
                    i++;
                    continue;
                }
                if (lex_state == 2) {
                    if (c == '"' && i + 2 < le && src[i + 1] == '"' && src[i + 2] == '"') {
                        lex_state = 0;
                        i += 3;
                        continue;
                    }
                    i++;
                    continue;
                }
                if (lex_state == 1) {
                    if (c == '\\') {
                        i += 2;
                        continue;
                    }
                    if (c == '"') {
                        lex_state = 0;
                        i++;
                        continue;
                    }
                    i++;
                    continue;
                }
                if (c == '/' && i + 1 < le && src[i + 1] == '/')
                    return;
                if (c == '/' && i + 1 < le && src[i + 1] == '*') {
                    lex_state = 3;
                    i += 2;
                    continue;
                }
                if (c == '"' && i + 2 < le && src[i + 1] == '"' && src[i + 2] == '"') {
                    lex_state = 2;
                    i += 3;
                    continue;
                }
                if (c == '"') {
                    lex_state = 1;
                    i++;
                    continue;
                }
                if (c == '\'') {
                    i++;
                    if (i < le && src[i] == '\\')
                        i += 2;
                    else if (i < le)
                        i++;
                    if (i < le && src[i] == '\'')
                        i++;
                    continue;
                }
                i++;
            }
        }

        private static string strip_blanks (string text) {            int s = 0;
            int e = text.length;
            while (s < e && (text[s] == ' ' || text[s] == '\t'))
                s++;
            while (e > s && (text[e - 1] == ' ' || text[e - 1] == '\t'))
                e--;
            return text[s:e];
        }

        private string process () throws LexError {
            var outb = new StrBuilder ();
            // prev_active[i] is the state in effect before the i-th open #if;
            // taken[i] records whether one of its branches was already chosen.
            var prev_active = new GenericArray<int> ();
            var taken_flags = new GenericArray<int> ();
            var open_lines = new GenericArray<int> ();
            bool active = true;
            int line_no = 1;

            while (pos < src_len) {
                int ls = pos;
                while (pos < src_len && src[pos] != '\n')
                    pos++;
                int le = pos;
                bool has_nl = (pos < src_len);
                if (has_nl)
                    pos++;

                int content_end = le;
                while (content_end > ls && src[content_end - 1] == '\r')
                    content_end--;

                int d = ls;
                while (d < content_end && (src[d] == ' ' || src[d] == '\t'))
                    d++;
                bool is_directive = (lex_state == 0 && d < content_end && src[d] == '#');

                if (is_directive) {
                    int k = d + 1;
                    while (k < content_end && (src[k] == ' ' || src[k] == '\t'))
                        k++;
                    int ns = k;
                    while (k < content_end && is_ident_char (src[k]))
                        k++;
                    var dname = src[ns:k];
                    var darg = strip_blanks (src[k:content_end]);

                    if (dname == "if") {
                        bool parent = active;
                        bool cond = false;
                        if (parent)
                            cond = eval_condition (darg);
                        prev_active.add (parent ? 1 : 0);
                        taken_flags.add ((parent && cond) ? 1 : 0);
                        open_lines.add (line_no);
                        active = parent && cond;
                    } else if (dname == "elif") {
                        if (prev_active.length == 0)
                            throw new LexError.DIRECTIVE (@"#elif without #if at $line_no:1");
                        int last = prev_active.length - 1;
                        bool parent = prev_active[last] != 0;
                        bool taken = taken_flags[last] != 0;
                        bool cond = false;
                        if (parent && !taken)
                            cond = eval_condition (darg);
                        active = parent && !taken && cond;
                        taken_flags[last] = (taken || active) ? 1 : 0;
                    } else if (dname == "else") {
                        if (prev_active.length == 0)
                            throw new LexError.DIRECTIVE (@"#else without #if at $line_no:1");
                        int last = prev_active.length - 1;
                        bool parent = prev_active[last] != 0;
                        bool taken = taken_flags[last] != 0;
                        active = parent && !taken;
                        taken_flags[last] = 1;
                    } else if (dname == "endif") {
                        if (prev_active.length == 0)
                            throw new LexError.DIRECTIVE (@"#endif without #if at $line_no:1");
                        int last = prev_active.length - 1;
                        active = prev_active[last] != 0;
                        prev_active.remove_index (last);
                        taken_flags.remove_index (last);
                        open_lines.remove_index (last);
                    } else if (dname == "error") {
                        if (active)
                            throw new LexError.DIRECTIVE (@"#error $darg at $line_no:1");
                    } else if (dname == "warning") {
                        if (active)
                            Host.eprintln (@"planc: warning: $darg at $line_no:1");
                    } else if (dname == "") {
                        // A lone '#' is ignored, as in Vala.
                    } else {
                        throw new LexError.DIRECTIVE (@"unknown preprocessor directive '#$dname' at $line_no:1");
                    }

                    for (int i = ls; i < le; i++)
                        outb.append_c (' ');
                } else if (active) {
                    for (int i = ls; i < le; i++)
                        outb.append_c ((char) src[i]);
                } else {
                    for (int i = ls; i < le; i++)
                        outb.append_c (' ');
                }
                if (has_nl)
                    outb.append_c ('\n');
                if (!is_directive)
                    update_lex_state (ls, content_end);
                line_no++;
            }

            if (prev_active.length > 0)
                throw new LexError.DIRECTIVE (
                    @"unterminated #if opened at $(open_lines[open_lines.length - 1]):1");
            return outb.str;
        }
    }
}
