// Pure-Vala GLib.Regex & GLib.MatchInfo based on tiny-regex-c (kokke/tiny-regex-c).
using Planet;

namespace GLib {

    public errordomain RegexError {
        COMPILE,
        MATCH
    }

    private enum ReKind {
        UNUSED,
        DOT,
        BEGIN,
        END,
        QUESTIONMARK,
        STAR,
        PLUS,
        CHAR,
        CHAR_CLASS,
        INV_CHAR_CLASS,
        DIGIT,
        NOT_DIGIT,
        ALPHA,
        NOT_ALPHA,
        WHITESPACE,
        NOT_WHITESPACE
    }

    private class ReNode : Object {
        public ReKind kind = ReKind.UNUSED;
        public uint8 ch = 0;
        public int ccl_off = 0;

        public ReNode (ReKind k = ReKind.UNUSED, uint8 c = 0, int off = 0) {
            kind = k;
            ch = c;
            ccl_off = off;
        }
    }

    public class MatchInfo : Object {
        private Regex re;
        private string subject;
        private bool matched = false;
        private int m_start = 0;
        private int m_end = 0;

        internal MatchInfo (Regex re, string subject, bool matched, int start_pos, int end_pos) {
            this.re = re;
            this.subject = subject;
            this.matched = matched;
            this.m_start = start_pos;
            this.m_end = end_pos;
        }

        public bool matches () {
            return matched;
        }

        public string? fetch (int match_num = 0) {
            if (!matched || match_num != 0)
                return null;
            if (m_end < m_start || m_start < 0 || m_end > subject.length)
                return null;
            return subject.substring (m_start, m_end - m_start);
        }

        public bool fetch_pos (int match_num, out int start_pos, out int end_pos) {
            start_pos = -1;
            end_pos = -1;
            if (!matched || match_num != 0)
                return false;
            start_pos = m_start;
            end_pos = m_end;
            return true;
        }

        public bool next () {
            if (!matched)
                return false;
            int from = (m_end > m_start) ? m_end : (m_start + 1);
            if (from > subject.length) {
                matched = false;
                return false;
            }
            int ns = -1;
            int nl = 0;
            if (re.find_from (subject, from, out ns, out nl)) {
                m_start = ns;
                m_end = ns + nl;
                matched = true;
                return true;
            }
            matched = false;
            return false;
        }
    }

    public class Regex : Object {
        private GenericArray<ReNode> nodes;
        private GenericArray<uint8> ccl_buf;
        private string pattern_str;

        // Character helpers derived from tiny-regex-c (via c2vala).
        private static bool re_isdigit (uint8 c) {
            return c >= '0' && c <= '9';
        }

        private static bool re_isalpha (uint8 c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }

        private static bool re_isspace (uint8 c) {
            return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 12 || c == 11;
        }

        private static bool re_isalphanum (uint8 c) {
            return c == '_' || re_isalpha (c) || re_isdigit (c);
        }

        private static bool re_matchdot (uint8 c) {
            return c != '\n' && c != '\r';
        }

        private static bool re_ismetachar (uint8 c) {
            return c == 's' || c == 'S' || c == 'w' || c == 'W' || c == 'd' || c == 'D';
        }

        private static bool re_matchmetachar (uint8 c, uint8 mc) {
            switch (mc) {
                case 'd': return re_isdigit (c);
                case 'D': return !re_isdigit (c);
                case 'w': return re_isalphanum (c);
                case 'W': return !re_isalphanum (c);
                case 's': return re_isspace (c);
                case 'S': return !re_isspace (c);
                default:  return c == mc;
            }
        }

        private bool match_range (uint8 c, int idx) {
            if (c == '-')
                return false;
            uint8 a = ccl_buf[idx];
            if (a == 0 || a == '-')
                return false;
            if (ccl_buf[idx + 1] != '-')
                return false;
            uint8 b = ccl_buf[idx + 2];
            if (b == 0)
                return false;
            return c >= a && c <= b;
        }

        private bool match_charclass (uint8 c, int off) {
            int idx = off;
            while (idx < ccl_buf.length && ccl_buf[idx] != 0) {
                if (match_range (c, idx))
                    return true;
                if (ccl_buf[idx] == '\\') {
                    idx++;
                    if (idx < ccl_buf.length && ccl_buf[idx] != 0) {
                        if (re_matchmetachar (c, ccl_buf[idx]))
                            return true;
                        if (c == ccl_buf[idx] && !re_ismetachar (c))
                            return true;
                    }
                } else if (c == ccl_buf[idx]) {
                    if (c == '-')
                        return (idx == off) || (ccl_buf[idx + 1] == 0);
                    return true;
                }
                idx++;
            }
            return false;
        }

        private bool match_one (ReNode p, uint8 c) {
            switch (p.kind) {
                case ReKind.DOT:            return re_matchdot (c);
                case ReKind.CHAR_CLASS:     return match_charclass (c, p.ccl_off);
                case ReKind.INV_CHAR_CLASS: return !match_charclass (c, p.ccl_off);
                case ReKind.DIGIT:          return re_isdigit (c);
                case ReKind.NOT_DIGIT:      return !re_isdigit (c);
                case ReKind.ALPHA:          return re_isalphanum (c);
                case ReKind.NOT_ALPHA:      return !re_isalphanum (c);
                case ReKind.WHITESPACE:     return re_isspace (c);
                case ReKind.NOT_WHITESPACE: return !re_isspace (c);
                default:                    return p.ch == c;
            }
        }

        private bool match_star (ReNode p, int pat_idx, string text, int t_idx, ref int matchlen) {
            int prelen = matchlen;
            int cur = t_idx;
            while (cur < text.length && match_one (p, (uint8) text[cur])) {
                cur++;
                matchlen++;
            }
            while (cur >= t_idx) {
                if (match_pattern (pat_idx, text, cur, ref matchlen))
                    return true;
                cur--;
                matchlen--;
            }
            matchlen = prelen;
            return false;
        }

        private bool match_plus (ReNode p, int pat_idx, string text, int t_idx, ref int matchlen) {
            int prelen = matchlen;
            int cur = t_idx;
            while (cur < text.length && match_one (p, (uint8) text[cur])) {
                cur++;
                matchlen++;
            }
            while (cur > t_idx) {
                if (match_pattern (pat_idx, text, cur, ref matchlen))
                    return true;
                cur--;
                matchlen--;
            }
            matchlen = prelen;
            return false;
        }

        private bool match_question (ReNode p, int pat_idx, string text, int t_idx, ref int matchlen) {
            if (p.kind == ReKind.UNUSED)
                return true;
            if (match_pattern (pat_idx, text, t_idx, ref matchlen))
                return true;
            if (t_idx < text.length && match_one (p, (uint8) text[t_idx])) {
                if (match_pattern (pat_idx, text, t_idx + 1, ref matchlen)) {
                    matchlen++;
                    return true;
                }
            }
            return false;
        }

        private bool match_pattern (int pat_idx, string text, int t_idx, ref int matchlen) {
            int pre = matchlen;
            int pi = pat_idx;
            int ti = t_idx;
            while (true) {
                ReNode p0 = nodes[pi];
                ReNode p1 = (pi + 1 < nodes.length) ? nodes[pi + 1] : new ReNode (ReKind.UNUSED);
                if (p0.kind == ReKind.UNUSED)
                    return true;
                if (p1.kind == ReKind.QUESTIONMARK)
                    return match_question (p0, pi + 2, text, ti, ref matchlen);
                if (p1.kind == ReKind.STAR)
                    return match_star (p0, pi + 2, text, ti, ref matchlen);
                if (p1.kind == ReKind.PLUS)
                    return match_plus (p0, pi + 2, text, ti, ref matchlen);
                if (p0.kind == ReKind.END && p1.kind == ReKind.UNUSED)
                    return ti == text.length;
                if (ti < text.length && match_one (p0, (uint8) text[ti])) {
                    matchlen++;
                    pi++;
                    ti++;
                } else {
                    matchlen = pre;
                    return false;
                }
            }
        }

        public Regex (string pattern) throws RegexError {
            pattern_str = pattern;
            nodes = new GenericArray<ReNode> ();
            ccl_buf = new GenericArray<uint8> ();
            ccl_buf.add (0);

            int i = 0;
            while (i < pattern.length) {
                uint8 c = (uint8) pattern[i];
                if (c == '^') {
                    nodes.add (new ReNode (ReKind.BEGIN));
                } else if (c == '$') {
                    nodes.add (new ReNode (ReKind.END));
                } else if (c == '.') {
                    nodes.add (new ReNode (ReKind.DOT));
                } else if (c == '*') {
                    if (nodes.length == 0)
                        throw new RegexError.COMPILE ("unexpected '*' at start of pattern");
                    nodes.add (new ReNode (ReKind.STAR));
                } else if (c == '+') {
                    if (nodes.length == 0)
                        throw new RegexError.COMPILE ("unexpected '+' at start of pattern");
                    nodes.add (new ReNode (ReKind.PLUS));
                } else if (c == '?') {
                    if (nodes.length == 0)
                        throw new RegexError.COMPILE ("unexpected '?' at start of pattern");
                    nodes.add (new ReNode (ReKind.QUESTIONMARK));
                } else if (c == '\\') {
                    i++;
                    if (i >= pattern.length)
                        throw new RegexError.COMPILE ("trailing backslash in pattern");
                    uint8 ec = (uint8) pattern[i];
                    if (ec == 'd') nodes.add (new ReNode (ReKind.DIGIT));
                    else if (ec == 'D') nodes.add (new ReNode (ReKind.NOT_DIGIT));
                    else if (ec == 'w') nodes.add (new ReNode (ReKind.ALPHA));
                    else if (ec == 'W') nodes.add (new ReNode (ReKind.NOT_ALPHA));
                    else if (ec == 's') nodes.add (new ReNode (ReKind.WHITESPACE));
                    else if (ec == 'S') nodes.add (new ReNode (ReKind.NOT_WHITESPACE));
                    else nodes.add (new ReNode (ReKind.CHAR, ec));
                } else if (c == '[') {
                    ReKind rk = ReKind.CHAR_CLASS;
                    if (i + 1 < pattern.length && pattern[i + 1] == '^') {
                        rk = ReKind.INV_CHAR_CLASS;
                        i++;
                    }
                    int off = ccl_buf.length;
                    bool closed = false;
                    while (i + 1 < pattern.length) {
                        i++;
                        uint8 cc = (uint8) pattern[i];
                        if (cc == ']') {
                            closed = true;
                            break;
                        }
                        if (cc == '\\' && i + 1 < pattern.length) {
                            ccl_buf.add (cc);
                            i++;
                            ccl_buf.add ((uint8) pattern[i]);
                        } else {
                            ccl_buf.add (cc);
                        }
                    }
                    if (!closed)
                        throw new RegexError.COMPILE ("unterminated character class '['");
                    ccl_buf.add (0);
                    nodes.add (new ReNode (rk, 0, off));
                } else {
                    nodes.add (new ReNode (ReKind.CHAR, c));
                }
                i++;
            }
            nodes.add (new ReNode (ReKind.UNUSED));
        }

        public string get_pattern () {
            return pattern_str;
        }

        internal bool find_from (string text, int start_at, out int found_idx, out int found_len) {
            found_idx = -1;
            found_len = 0;
            if (nodes.length == 0)
                return false;
            if (nodes[0].kind == ReKind.BEGIN) {
                if (start_at != 0)
                    return false;
                int ml = 0;
                if (match_pattern (1, text, 0, ref ml)) {
                    found_idx = 0;
                    found_len = ml;
                    return true;
                }
                return false;
            }
            for (int pos = start_at; pos <= text.length; pos++) {
                int ml = 0;
                if (match_pattern (0, text, pos, ref ml)) {
                    if (pos == text.length && ml == 0)
                        return false;
                    found_idx = pos;
                    found_len = ml;
                    return true;
                }
            }
            return false;
        }

        public bool match (string str, out MatchInfo? match_info) {
            int idx = -1;
            int ml = 0;
            bool ok = find_from (str, 0, out idx, out ml);
            match_info = new MatchInfo (this, str, ok, idx, ok ? (idx + ml) : 0);
            return ok;
        }

        public static bool match_simple (string pattern, string str) {
            try {
                var r = new Regex (pattern);
                MatchInfo mi;
                return r.match (str, out mi);
            } catch (RegexError e) {
                return false;
            }
        }

        public string replace (string str, string replacement) {
            var sb = new StringBuilder ("");
            int pos = 0;
            while (pos <= str.length) {
                int idx = -1;
                int ml = 0;
                if (!find_from (str, pos, out idx, out ml)) {
                    if (pos < str.length)
                        sb.append (str.substring (pos));
                    break;
                }
                if (idx > pos)
                    sb.append (str.substring (pos, idx - pos));
                sb.append (replacement);
                if (ml == 0) {
                    if (idx < str.length)
                        sb.append (str.substring (idx, 1));
                    pos = idx + 1;
                } else {
                    pos = idx + ml;
                }
            }
            return sb.str;
        }
    }
}
