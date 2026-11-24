// Pure-Vala GLib.Quark, PatternSpec, Shell, and Markup utilities for PlanetOS.
using Planet;

namespace GLib {

    private GenericArray<string>? quark_table = null;

    /**
     * String-to-integer interned identifier table (GLib.Quark).
     */
    public class Quark : Object {
        private static GenericArray<string> get_table () {
            if (quark_table == null) {
                var t = new GenericArray<string> ();
                t.add (""); // 0 = invalid/null quark
                quark_table = t;
            }
            return (!) quark_table;
        }

        public static uint32 from_string (string? str) {
            if (str == null || str.length == 0)
                return 0;
            var t = get_table ();
            for (int i = 1; i < t.length; i++) {
                if (t[i] == str)
                    return (uint32) i;
            }
            t.add (str);
            return (uint32) (t.length - 1);
        }

        public static uint32 try_string (string? str) {
            if (str == null || str.length == 0)
                return 0;
            var t = get_table ();
            for (int i = 1; i < t.length; i++) {
                if (t[i] == str)
                    return (uint32) i;
            }
            return 0;
        }

        public static string? to_string (uint32 quark) {
            var t = get_table ();
            if (quark == 0 || (int) quark >= t.length)
                return null;
            return t[(int) quark];
        }
    }

    /**
     * Glob-style pattern matching ('*' and '?') (GLib.PatternSpec).
     */
    public class PatternSpec : Object {
        private string pat;

        public PatternSpec (string pattern) {
            pat = pattern;
        }

        public bool equal (PatternSpec other) {
            return pat == other.pat;
        }

        public bool match_string (string str) {
            return match_simple (pat, str);
        }

        public static bool match_simple (string pattern, string str) {
            int pi = 0;
            int si = 0;
            int star_p = -1;
            int star_s = -1;
            int plen = pattern.length;
            int slen = str.length;
            while (si < slen) {
                if (pi < plen && (pattern[pi] == '?' || pattern[pi] == str[si])) {
                    pi++;
                    si++;
                } else if (pi < plen && pattern[pi] == '*') {
                    star_p = pi;
                    star_s = si;
                    pi++;
                } else if (star_p >= 0) {
                    pi = star_p + 1;
                    star_s++;
                    si = star_s;
                } else {
                    return false;
                }
            }
            while (pi < plen && pattern[pi] == '*')
                pi++;
            return pi == plen;
        }
    }

    public errordomain ShellError {
        BAD_QUOTING,
        EMPTY_STRING,
        FAILED
    }

    /**
     * Shell-style command line quoting and tokenization (GLib.Shell).
     */
    public class Shell : Object {
        public static string quote (string unquoted_string) {
            var sb = new StringBuilder ();
            sb.append_c ('\'');
            for (int i = 0; i < unquoted_string.length; i++) {
                uint8 c = unquoted_string[i];
                if (c == '\'') {
                    sb.append ("'\\''");
                } else {
                    sb.append_c ((char) c);
                }
            }
            sb.append_c ('\'');
            return sb.str;
        }

        public static string unquote (string quoted_string) throws ShellError {
            var sb = new StringBuilder ();
            int n = quoted_string.length;
            int i = 0;
            while (i < n) {
                uint8 c = quoted_string[i];
                if (c == '\\') {
                    i++;
                    if (i >= n)
                        throw new ShellError.BAD_QUOTING ("Text ended just after a '\\' character");
                    sb.append_c ((char) quoted_string[i]);
                    i++;
                } else if (c == '\'') {
                    i++;
                    while (i < n && quoted_string[i] != '\'') {
                        sb.append_c ((char) quoted_string[i]);
                        i++;
                    }
                    if (i >= n)
                        throw new ShellError.BAD_QUOTING ("Unmatched single quote");
                    i++;
                } else if (c == '"') {
                    i++;
                    while (i < n && quoted_string[i] != '"') {
                        if (quoted_string[i] == '\\' && i + 1 < n) {
                            uint8 nx = quoted_string[i + 1];
                            if (nx == '"' || nx == '\\' || nx == '$' || nx == '`') {
                                sb.append_c ((char) nx);
                                i += 2;
                                continue;
                            }
                        }
                        sb.append_c ((char) quoted_string[i]);
                        i++;
                    }
                    if (i >= n)
                        throw new ShellError.BAD_QUOTING ("Unmatched double quote");
                    i++;
                } else {
                    sb.append_c ((char) c);
                    i++;
                }
            }
            return sb.str;
        }

        public static bool parse_argv (string command_line, out string[] argv) throws ShellError {
            var tokens = new StrvBuilder ();
            int n = command_line.length;
            int i = 0;
            while (i < n) {
                while (i < n && (command_line[i] == ' ' || command_line[i] == '\t' || command_line[i] == '\n' || command_line[i] == '\r'))
                    i++;
                if (i >= n)
                    break;
                var sb = new StringBuilder ();
                while (i < n) {
                    uint8 c = command_line[i];
                    if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
                        break;
                    if (c == '\\') {
                        i++;
                        if (i >= n)
                            throw new ShellError.BAD_QUOTING ("Text ended just after a '\\' character");
                        sb.append_c ((char) command_line[i]);
                        i++;
                    } else if (c == '\'') {
                        i++;
                        while (i < n && command_line[i] != '\'') {
                            sb.append_c ((char) command_line[i]);
                            i++;
                        }
                        if (i >= n)
                            throw new ShellError.BAD_QUOTING ("Unmatched single quote");
                        i++;
                    } else if (c == '"') {
                        i++;
                        while (i < n && command_line[i] != '"') {
                            if (command_line[i] == '\\' && i + 1 < n) {
                                uint8 nx = command_line[i + 1];
                                if (nx == '"' || nx == '\\' || nx == '$' || nx == '`') {
                                    sb.append_c ((char) nx);
                                    i += 2;
                                    continue;
                                }
                            }
                            sb.append_c ((char) command_line[i]);
                            i++;
                        }
                        if (i >= n)
                            throw new ShellError.BAD_QUOTING ("Unmatched double quote");
                        i++;
                    } else {
                        sb.append_c ((char) c);
                        i++;
                    }
                }
                tokens.add (sb.str);
            }
            if (tokens.length () == 0) {
                argv = new string[0];
                throw new ShellError.EMPTY_STRING ("Text was empty");
            }
            argv = tokens.end ();
            return true;
        }
    }

    public errordomain MarkupError {
        BAD_UTF8,
        EMPTY,
        PARSE,
        UNKNOWN_ELEMENT,
        UNKNOWN_ATTRIBUTE,
        INVALID_CONTENT
    }

    /**
     * Simple XML/Pango-style markup escaping and tag stripping (GLib.Markup).
     */
    public class Markup : Object {
        public static string escape_text (string text, int length = -1) {
            int n = (length < 0 || length > text.length) ? text.length : length;
            var sb = new StringBuilder.sized (n + 16);
            for (int i = 0; i < n; i++) {
                uint8 c = text[i];
                if (c == '&')
                    sb.append ("&amp;");
                else if (c == '<')
                    sb.append ("&lt;");
                else if (c == '>')
                    sb.append ("&gt;");
                else if (c == '"')
                    sb.append ("&quot;");
                else if (c == '\'')
                    sb.append ("&apos;");
                else
                    sb.append_c ((char) c);
            }
            return sb.str;
        }

        public static string unescape_text (string text) throws MarkupError {
            var sb = new StringBuilder.sized (text.length);
            int n = text.length;
            int i = 0;
            while (i < n) {
                if (text[i] != '&') {
                    sb.append_c ((char) text[i]);
                    i++;
                    continue;
                }
                int semi = text.index_of_char (';', i + 1);
                if (semi < 0)
                    throw new MarkupError.PARSE ("Unterminated entity reference");
                string ent = text.substring (i + 1, semi - i - 1);
                if (ent == "amp") sb.append_c ('&');
                else if (ent == "lt") sb.append_c ('<');
                else if (ent == "gt") sb.append_c ('>');
                else if (ent == "quot") sb.append_c ('"');
                else if (ent == "apos") sb.append_c ('\'');
                else if (ent.has_prefix ("#x") || ent.has_prefix ("#X")) {
                    int val = parse_hex (ent.substring (2));
                    if (val <= 0)
                        throw new MarkupError.PARSE ("Invalid hex character reference");
                    sb.append_unichar ((unichar) val);
                } else if (ent.has_prefix ("#")) {
                    int val = parse_dec (ent.substring (1));
                    if (val <= 0)
                        throw new MarkupError.PARSE ("Invalid decimal character reference");
                    sb.append_unichar ((unichar) val);
                } else {
                    throw new MarkupError.PARSE (@"Unknown entity '&$ent;'");
                }
                i = semi + 1;
            }
            return sb.str;
        }

        public static string strip_tags (string markup) throws MarkupError {
            var sb = new StringBuilder.sized (markup.length);
            int n = markup.length;
            int i = 0;
            while (i < n) {
                if (markup[i] == '<') {
                    int close = markup.index_of_char ('>', i + 1);
                    if (close < 0)
                        throw new MarkupError.PARSE ("Unterminated markup tag");
                    i = close + 1;
                } else {
                    int next_tag = markup.index_of_char ('<', i);
                    string chunk = (next_tag < 0) ? markup.substring (i) : markup.substring (i, next_tag - i);
                    sb.append (unescape_text (chunk));
                    if (next_tag < 0)
                        break;
                    i = next_tag;
                }
            }
            return sb.str;
        }

        private static int parse_dec (string s) {
            if (s.length == 0) return -1;
            int v = 0;
            for (int i = 0; i < s.length; i++) {
                uint8 c = s[i];
                if (c < '0' || c > '9') return -1;
                v = v * 10 + (int) (c - '0');
                if (v > 0x10FFFF) return -1;
            }
            return v;
        }

        private static int parse_hex (string s) {
            if (s.length == 0) return -1;
            int v = 0;
            for (int i = 0; i < s.length; i++) {
                uint8 c = s[i];
                int d = -1;
                if (c >= '0' && c <= '9') d = (int) (c - '0');
                else if (c >= 'a' && c <= 'f') d = 10 + (int) (c - 'a');
                else if (c >= 'A' && c <= 'F') d = 10 + (int) (c - 'A');
                if (d < 0) return -1;
                v = v * 16 + d;
                if (v > 0x10FFFF) return -1;
            }
            return v;
        }
    }

    public enum MarkupParseFlags {
        NONE = 0,
        TREAT_CDATA_AS_TEXT = 2
    }

    public delegate void MarkupStartElement (MarkupParseContext context, string element_name, string[] attribute_names, string[] attribute_values);
    public delegate void MarkupEndElement (MarkupParseContext context, string element_name);
    public delegate void MarkupText (MarkupParseContext context, string text, size_t text_len);
    public delegate void MarkupPassthrough (MarkupParseContext context, string passthrough_text, size_t text_len);
    public delegate void MarkupErrorFunc (MarkupParseContext context, string message);

    /**
     * Callback table for MarkupParseContext (GLib.MarkupParser). It is a class
     * here because struct constructors are not part of the dialect; callbacks
     * that are not supplied stay as no-ops so the reader never has to test
     * them.
     */
    public class MarkupParser : Object {
        public MarkupStartElement start_element;
        public MarkupEndElement end_element;
        public MarkupText text;
        public MarkupPassthrough passthrough;
        public MarkupErrorFunc error;

        public MarkupParser (MarkupStartElement? start = null,
                             MarkupEndElement? end = null,
                             MarkupText? text_cb = null,
                             MarkupPassthrough? passthrough_cb = null,
                             MarkupErrorFunc? error_cb = null) {
            start_element = (start != null) ? (!) start : no_start;
            end_element = (end != null) ? (!) end : no_end;
            text = (text_cb != null) ? (!) text_cb : no_text;
            passthrough = (passthrough_cb != null) ? (!) passthrough_cb : no_passthrough;
            error = (error_cb != null) ? (!) error_cb : no_error;
        }

        private static void no_start (MarkupParseContext c, string n, string[] an, string[] av) {}
        private static void no_end (MarkupParseContext c, string n) {}
        private static void no_text (MarkupParseContext c, string t, size_t len) {}
        private static void no_passthrough (MarkupParseContext c, string t, size_t len) {}
        private static void no_error (MarkupParseContext c, string m) {}
    }

    /**
     * Incremental XML-ish reader (GLib.MarkupParseContext): elements,
     * attributes, character data, CDATA and processing instructions.
     */
    public class MarkupParseContext : Object {
        private MarkupParser parser;
        private MarkupParseFlags parse_flags;
        private GenericArray<string> stack = new GenericArray<string> ();
        private int line = 1;
        private int column = 1;

        public MarkupParseContext (MarkupParser parser, MarkupParseFlags flags = MarkupParseFlags.NONE) {
            this.parser = parser;
            this.parse_flags = flags;
        }

        public string? get_element () {
            if (stack.length == 0)
                return null;
            return stack[stack.length - 1];
        }

        public string[] get_element_stack () {
            var res = new string[stack.length];
            for (int i = 0; i < stack.length; i++)
                res[i] = stack[i];
            return res;
        }

        public int get_current_line_number () {
            return line;
        }

        public int get_current_char_number () {
            return column;
        }

        public void push (MarkupParser parser) {
            this.parser = parser;
        }

        public void pop () {
        }

        private void advance (string text, int from, int to) {
            for (int i = from; i < to; i++) {
                if (text[i] == '\n') {
                    line = line + 1;
                    column = 1;
                } else {
                    column = column + 1;
                }
            }
        }

        private void emit_text (string raw) throws MarkupError {
            if (raw.length == 0)
                return;
            parser.text (this, Markup.unescape_text (raw), (size_t) raw.length);
        }

        private void emit_passthrough (string raw) {
            parser.passthrough (this, raw, (size_t) raw.length);
        }

        private static int skip_space (string text, int i) {
            while (i < text.length && (text[i] == ' ' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r'))
                i++;
            return i;
        }

        private static string read_name (string text, int from, out int end) {
            int i = from;
            while (i < text.length) {
                uint8 c = text[i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                        || c == ':' || c == '-' || c == '_' || c == '.')
                    i++;
                else
                    break;
            }
            end = i;
            return text.substring (from, i - from);
        }

        public void parse (string text, ssize_t length = -1) throws MarkupError {
            int n = (length < 0 || (int) length > text.length) ? text.length : (int) length;
            int i = 0;
            int text_start = 0;
            while (i < n) {
                if (text[i] != '<') {
                    i++;
                    continue;
                }
                emit_text (text.substring (text_start, i - text_start));
                if (i + 3 < n && text[i + 1] == '!' && text[i + 2] == '-' && text[i + 3] == '-') {
                    int close = text.index_of ("-->", i + 4);
                    if (close < 0 || close + 3 > n)
                        throw new MarkupError.PARSE ("Unterminated comment");
                    emit_passthrough (text.substring (i, close + 3 - i));
                    advance (text, i, close + 3);
                    i = close + 3;
                    text_start = i;
                    continue;
                }
                if (i + 8 < n && text.substring (i, 9) == "<![CDATA[") {
                    int close = text.index_of ("]]>", i + 9);
                    if (close < 0 || close + 3 > n)
                        throw new MarkupError.PARSE ("Unterminated CDATA section");
                    string body = text.substring (i + 9, close - (i + 9));
                    if ((parse_flags & MarkupParseFlags.TREAT_CDATA_AS_TEXT) != 0)
                        emit_text (body);
                    else
                        emit_passthrough (body);
                    advance (text, i, close + 3);
                    i = close + 3;
                    text_start = i;
                    continue;
                }
                if (i + 1 < n && (text[i + 1] == '?' || text[i + 1] == '!')) {
                    int close = text.index_of_char ('>', i + 2);
                    if (close < 0)
                        throw new MarkupError.PARSE ("Unterminated declaration");
                    emit_passthrough (text.substring (i, close + 1 - i));
                    advance (text, i, close + 1);
                    i = close + 1;
                    text_start = i;
                    continue;
                }
                // Element start or end tag.
                bool is_end = (i + 1 < n && text[i + 1] == '/');
                int j = i + (is_end ? 2 : 1);
                int name_end = j;
                string name = read_name (text, j, out name_end);
                if (name.length == 0)
                    throw new MarkupError.PARSE ("Empty element name");
                j = name_end;
                if (is_end) {
                    j = skip_space (text, j);
                    if (j >= n || text[j] != '>')
                        throw new MarkupError.PARSE (@"Malformed end tag '</$name'");
                    if (stack.length == 0)
                        throw new MarkupError.PARSE (@"Unexpected end tag '</$name>'");
                    string open = stack[stack.length - 1];
                    if (open != name)
                        throw new MarkupError.PARSE (@"Mismatched end tag '</$name>', expected '</$open>'");
                    stack.remove_index (stack.length - 1);
                    advance (text, i, j + 1);
                    parser.end_element (this, name);
                    i = j + 1;
                    text_start = i;
                    continue;
                }
                var attr_names = new GenericArray<string> ();
                var attr_values = new GenericArray<string> ();
                bool empty = false;
                while (true) {
                    j = skip_space (text, j);
                    if (j >= n)
                        throw new MarkupError.PARSE (@"Unterminated start tag '<$name'");
                    if (text[j] == '>') {
                        j++;
                        break;
                    }
                    if (text[j] == '/' && j + 1 < n && text[j + 1] == '>') {
                        empty = true;
                        j += 2;
                        break;
                    }
                    int an_end = j;
                    string an = read_name (text, j, out an_end);
                    if (an.length == 0)
                        throw new MarkupError.PARSE (@"Malformed attribute in '<$name'");
                    j = skip_space (text, an_end);
                    if (j >= n || text[j] != '=')
                        throw new MarkupError.PARSE (@"Attribute '$an' has no value");
                    j = skip_space (text, j + 1);
                    if (j >= n || (text[j] != '"' && text[j] != '\''))
                        throw new MarkupError.PARSE (@"Attribute '$an' value is not quoted");
                    char quote = text[j];
                    j++;
                    int vstart = j;
                    while (j < n && text[j] != quote)
                        j++;
                    if (j >= n)
                        throw new MarkupError.PARSE (@"Unterminated value for attribute '$an'");
                    attr_names.add (an);
                    attr_values.add (Markup.unescape_text (text.substring (vstart, j - vstart)));
                    j++;
                }
                var names = new string[attr_names.length];
                var values = new string[attr_values.length];
                for (int k = 0; k < attr_names.length; k++) {
                    names[k] = attr_names[k];
                    values[k] = attr_values[k];
                }
                stack.add (name);
                advance (text, i, j);
                parser.start_element (this, name, names, values);
                if (empty) {
                    stack.remove_index (stack.length - 1);
                    parser.end_element (this, name);
                }
                i = j;
                text_start = i;
            }
            emit_text (text.substring (text_start, n - text_start));
            advance (text, text_start, n);
        }

        public void end_parse () throws MarkupError {
            if (stack.length > 0)
                throw new MarkupError.PARSE (@"Unclosed element '<$(stack[stack.length - 1])>'");
        }
    }
}
