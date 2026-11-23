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
            var tokens = new GenericArray<string> ();
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
            if (tokens.length == 0) {
                argv = new string[0];
                throw new ShellError.EMPTY_STRING ("Text was empty");
            }
            var res = new string[tokens.length];
            for (int k = 0; k < tokens.length; k++)
                res[k] = tokens[k];
            argv = res;
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
}
