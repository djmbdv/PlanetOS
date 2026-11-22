// Pure-Vala GLib.Regex & GLib.MatchInfo with memoized backtracking (ReDoS-safe).
using Planet;

namespace GLib {

    public errordomain RegexError {
        COMPILE,
        MATCH
    }

    public enum RegexCompileFlags {
        DEFAULT = 0,
        CASELESS = 1,
        MULTILINE = 2,
        DOTALL = 4,
        ANCHORED = 16,
        RAW = 2048,
        OPTIMIZE = 8192
    }

    public enum RegexMatchFlags {
        DEFAULT = 0,
        ANCHORED = 16,
        NOTBOL = 128,
        NOTEOL = 256,
        NOTEMPTY = 1024
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
        private int subject_len;
        private RegexMatchFlags m_flags;
        private bool matched = false;
        private int m_start = 0;
        private int m_end = 0;

        internal MatchInfo (Regex re, string subject, int subject_len, RegexMatchFlags flags,
                            bool matched, int start_pos, int end_pos) {
            this.re = re;
            this.subject = subject;
            this.subject_len = subject_len;
            this.m_flags = flags;
            this.matched = matched;
            this.m_start = start_pos;
            this.m_end = end_pos;
        }

        public Regex get_regex () {
            return re;
        }

        public string get_string () {
            return subject;
        }

        public bool matches () {
            return matched;
        }

        public int get_match_count () {
            return matched ? 1 : 0;
        }

        public bool is_partial_match () {
            return false;
        }

        public string? fetch (int match_num = 0) {
            if (!matched || match_num != 0)
                return null;
            if (m_end < m_start || m_start < 0 || m_end > subject_len)
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

        public string[] fetch_all () {
            if (!matched)
                return new string[0];
            string? s = fetch (0);
            if (s == null)
                return new string[0];
            string[] res = { s };
            return res;
        }

        public bool next () {
            if (!matched)
                return false;
            int from = (m_end > m_start) ? m_end : (m_start + 1);
            if (from > subject_len) {
                matched = false;
                return false;
            }
            int ns = -1;
            int nl = 0;
            if (re.find_from (subject, subject_len, from, m_flags, out ns, out nl)) {
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
        private ReNode unused_node = new ReNode (ReKind.UNUSED);
        private bool has_first_ch = false;
        private uint8 first_ch = 0;
        private string pattern_str;
        private RegexCompileFlags c_flags;
        private RegexMatchFlags default_m_flags;

        private const int MAX_MEMO_CELLS = 262144;

        private static uint8 to_lower_ascii (uint8 c) {
            if (c >= 'A' && c <= 'Z')
                return (uint8) (c + 32);
            return c;
        }

        private bool char_eq (uint8 a, uint8 b) {
            if (a == b)
                return true;
            if ((c_flags & RegexCompileFlags.CASELESS) != 0)
                return to_lower_ascii (a) == to_lower_ascii (b);
            return false;
        }

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

        private bool re_matchdot (uint8 c) {
            if ((c_flags & RegexCompileFlags.DOTALL) != 0)
                return true;
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
            if (c == '-' || idx + 2 >= ccl_buf.length)
                return false;
            uint8 a = ccl_buf[idx];
            if (a == 0 || a == '-')
                return false;
            if (ccl_buf[idx + 1] != '-')
                return false;
            uint8 b = ccl_buf[idx + 2];
            if (b == 0)
                return false;
            if ((c_flags & RegexCompileFlags.CASELESS) != 0) {
                uint8 lc = to_lower_ascii (c);
                uint8 la = to_lower_ascii (a);
                uint8 lb = to_lower_ascii (b);
                if (la <= lb && lc >= la && lc <= lb)
                    return true;
            }
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
                        if (!re_ismetachar (ccl_buf[idx]) && char_eq (c, ccl_buf[idx]))
                            return true;
                    }
                } else if (char_eq (c, ccl_buf[idx])) {
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
                case ReKind.CHAR:           return char_eq (p.ch, c);
                default:                    return false;
            }
        }

        private bool is_bol (string text, int ti, RegexMatchFlags mf) {
            if (ti == 0)
                return (mf & RegexMatchFlags.NOTBOL) == 0;
            if ((c_flags & RegexCompileFlags.MULTILINE) != 0)
                return (uint8) text[ti - 1] == '\n';
            return false;
        }

        private bool is_eol (string text, int tlen, int ti, RegexMatchFlags mf) {
            if (ti == tlen)
                return (mf & RegexMatchFlags.NOTEOL) == 0;
            if ((c_flags & RegexCompileFlags.MULTILINE) != 0)
                return (uint8) text[ti] == '\n';
            return false;
        }

        private bool match_star (ReNode p, int pat_idx, string text, int tlen, int t_idx,
                                 RegexMatchFlags mf, uint8[]? fail_memo, int stride, ref int matchlen) {
            int prelen = matchlen;
            int cur = t_idx;
            while (cur < tlen && match_one (p, (uint8) text[cur])) {
                cur++;
                matchlen++;
            }
            while (cur >= t_idx) {
                if (match_pattern (pat_idx, text, tlen, cur, mf, fail_memo, stride, ref matchlen))
                    return true;
                cur--;
                matchlen--;
            }
            matchlen = prelen;
            return false;
        }

        private bool match_plus (ReNode p, int pat_idx, string text, int tlen, int t_idx,
                                 RegexMatchFlags mf, uint8[]? fail_memo, int stride, ref int matchlen) {
            int prelen = matchlen;
            int cur = t_idx;
            while (cur < tlen && match_one (p, (uint8) text[cur])) {
                cur++;
                matchlen++;
            }
            while (cur > t_idx) {
                if (match_pattern (pat_idx, text, tlen, cur, mf, fail_memo, stride, ref matchlen))
                    return true;
                cur--;
                matchlen--;
            }
            matchlen = prelen;
            return false;
        }

        private bool match_question (ReNode p, int pat_idx, string text, int tlen, int t_idx,
                                     RegexMatchFlags mf, uint8[]? fail_memo, int stride, ref int matchlen) {
            if (p.kind == ReKind.UNUSED)
                return true;
            // Greedy '?' per PCRE/GLib.Regex: try 1 match first, then fall back to 0.
            if (t_idx < tlen && match_one (p, (uint8) text[t_idx])) {
                matchlen++;
                if (match_pattern (pat_idx, text, tlen, t_idx + 1, mf, fail_memo, stride, ref matchlen))
                    return true;
                matchlen--;
            }
            return match_pattern (pat_idx, text, tlen, t_idx, mf, fail_memo, stride, ref matchlen);
        }

        private bool match_pattern (int pat_idx, string text, int tlen, int t_idx,
                                    RegexMatchFlags mf, uint8[]? fail_memo, int stride, ref int matchlen) {
            int pre = matchlen;
            int pi = pat_idx;
            int ti = t_idx;
            if (fail_memo != null) {
                int cell = pi * stride + ti;
                if (cell >= 0 && cell < fail_memo.length && fail_memo[cell] != 0)
                    return false;
            }
            while (true) {
                ReNode p0 = nodes[pi];
                ReNode p1 = (pi + 1 < nodes.length) ? nodes[pi + 1] : unused_node;
                if (p0.kind == ReKind.UNUSED)
                    return true;
                if (p0.kind == ReKind.BEGIN) {
                    if (!is_bol (text, ti, mf)) {
                        if (fail_memo != null)
                            fail_memo[pat_idx * stride + t_idx] = 1;
                        matchlen = pre;
                        return false;
                    }
                    pi++;
                    continue;
                }
                if (p0.kind == ReKind.END) {
                    if (!is_eol (text, tlen, ti, mf)) {
                        if (fail_memo != null)
                            fail_memo[pat_idx * stride + t_idx] = 1;
                        matchlen = pre;
                        return false;
                    }
                    pi++;
                    continue;
                }
                bool matched_q = false;
                if (p1.kind == ReKind.QUESTIONMARK)
                    matched_q = match_question (p0, pi + 2, text, tlen, ti, mf, fail_memo, stride, ref matchlen);
                else if (p1.kind == ReKind.STAR)
                    matched_q = match_star (p0, pi + 2, text, tlen, ti, mf, fail_memo, stride, ref matchlen);
                else if (p1.kind == ReKind.PLUS)
                    matched_q = match_plus (p0, pi + 2, text, tlen, ti, mf, fail_memo, stride, ref matchlen);
                if (p1.kind == ReKind.QUESTIONMARK || p1.kind == ReKind.STAR || p1.kind == ReKind.PLUS) {
                    if (!matched_q && fail_memo != null)
                        fail_memo[pat_idx * stride + t_idx] = 1;
                    return matched_q;
                }
                if (ti < tlen && match_one (p0, (uint8) text[ti])) {
                    matchlen++;
                    pi++;
                    ti++;
                } else {
                    if (fail_memo != null)
                        fail_memo[pat_idx * stride + t_idx] = 1;
                    matchlen = pre;
                    return false;
                }
            }
        }

        public Regex (string pattern,
                      RegexCompileFlags compile_options = RegexCompileFlags.DEFAULT,
                      RegexMatchFlags match_options = RegexMatchFlags.DEFAULT) throws RegexError {
            pattern_str = pattern;
            c_flags = compile_options;
            default_m_flags = match_options;
            nodes = new GenericArray<ReNode> ();
            ccl_buf = new GenericArray<uint8> ();
            ccl_buf.add (0);

            int plen = pattern.length;
            int i = 0;
            while (i < plen) {
                uint8 c = (uint8) pattern[i];
                if (c == '^') {
                    nodes.add (new ReNode (ReKind.BEGIN));
                } else if (c == '$') {
                    nodes.add (new ReNode (ReKind.END));
                } else if (c == '.') {
                    nodes.add (new ReNode (ReKind.DOT));
                } else if (c == '*') {
                    if (nodes.length == 0)
                        throw new RegexError.COMPILE ("unexpected quantifier '*'");
                    ReKind prev = nodes[nodes.length - 1].kind;
                    if (prev == ReKind.STAR || prev == ReKind.PLUS || prev == ReKind.QUESTIONMARK
                        || prev == ReKind.BEGIN || prev == ReKind.END)
                        throw new RegexError.COMPILE ("unexpected quantifier '*'");
                    nodes.add (new ReNode (ReKind.STAR));
                } else if (c == '+') {
                    if (nodes.length == 0)
                        throw new RegexError.COMPILE ("unexpected quantifier '+'");
                    ReKind prev = nodes[nodes.length - 1].kind;
                    if (prev == ReKind.STAR || prev == ReKind.PLUS || prev == ReKind.QUESTIONMARK
                        || prev == ReKind.BEGIN || prev == ReKind.END)
                        throw new RegexError.COMPILE ("unexpected quantifier '+'");
                    nodes.add (new ReNode (ReKind.PLUS));
                } else if (c == '?') {
                    if (nodes.length == 0)
                        throw new RegexError.COMPILE ("unexpected quantifier '?'");
                    ReKind prev = nodes[nodes.length - 1].kind;
                    if (prev == ReKind.STAR || prev == ReKind.PLUS || prev == ReKind.QUESTIONMARK
                        || prev == ReKind.BEGIN || prev == ReKind.END)
                        throw new RegexError.COMPILE ("unexpected quantifier '?'");
                    nodes.add (new ReNode (ReKind.QUESTIONMARK));
                } else if (c == '\\') {
                    i++;
                    if (i >= plen)
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
                    if (i + 1 < plen && pattern[i + 1] == '^') {
                        rk = ReKind.INV_CHAR_CLASS;
                        i++;
                    }
                    int off = ccl_buf.length;
                    bool closed = false;
                    while (i + 1 < plen) {
                        i++;
                        uint8 cc = (uint8) pattern[i];
                        if (cc == ']') {
                            closed = true;
                            break;
                        }
                        if (cc == '\\' && i + 1 < plen) {
                            ccl_buf.add (cc);
                            i++;
                            ccl_buf.add ((uint8) pattern[i]);
                        } else {
                            ccl_buf.add (cc);
                        }
                    }
                    if (!closed)
                        throw new RegexError.COMPILE ("unterminated character class '['");
                    if (ccl_buf.length == off)
                        throw new RegexError.COMPILE ("empty character class '[]'");
                    ccl_buf.add (0);
                    nodes.add (new ReNode (rk, 0, off));
                } else {
                    nodes.add (new ReNode (ReKind.CHAR, c));
                }
                i++;
            }
            nodes.add (unused_node);
            if ((c_flags & RegexCompileFlags.CASELESS) == 0 && nodes.length >= 2 && nodes[0].kind == ReKind.CHAR) {
                ReKind k1 = nodes[1].kind;
                if (k1 != ReKind.STAR && k1 != ReKind.QUESTIONMARK) {
                    has_first_ch = true;
                    first_ch = nodes[0].ch;
                }
            }
        }

        public string get_pattern () {
            return pattern_str;
        }

        public RegexCompileFlags get_compile_flags () {
            return c_flags;
        }

        public RegexMatchFlags get_match_flags () {
            return default_m_flags;
        }

        public int get_capture_count () {
            return 0;
        }

        public static string escape_string (string str, int length = -1) {
            int slen = (length < 0 || length > str.length) ? str.length : length;
            var sb = new StringBuilder ();
            for (int i = 0; i < slen; i++) {
                uint8 c = (uint8) str[i];
                if (c == '\\' || c == '.' || c == '^' || c == '$' || c == '*'
                    || c == '+' || c == '?' || c == '(' || c == ')' || c == '['
                    || c == ']' || c == '{' || c == '}' || c == '|') {
                    sb.append_c ('\\');
                }
                sb.append_c ((char) c);
            }
            return sb.str;
        }

        internal bool find_from (string text, int tlen, int start_at, RegexMatchFlags mf,
                                   out int found_idx, out int found_len) {
            found_idx = -1;
            found_len = 0;
            if (nodes.length == 0 || start_at < 0 || start_at > tlen)
                return false;
            int stride = tlen + 1;
            uint8[]? fail_memo = null;
            int cells = nodes.length * stride;
            if (cells > 0 && cells <= MAX_MEMO_CELLS)
                fail_memo = new uint8[cells];
            bool anchored = ((c_flags & RegexCompileFlags.ANCHORED) != 0)
                || ((mf & RegexMatchFlags.ANCHORED) != 0);
            bool notempty = (mf & RegexMatchFlags.NOTEMPTY) != 0;

            if (anchored || (nodes[0].kind == ReKind.BEGIN && (c_flags & RegexCompileFlags.MULTILINE) == 0)) {
                int pi = (nodes[0].kind == ReKind.BEGIN && !is_bol (text, start_at, mf)) ? -1 : 0;
                if (pi < 0)
                    return false;
                int ml = 0;
                if (match_pattern (0, text, tlen, start_at, mf, fail_memo, stride, ref ml)) {
                    if (notempty && ml == 0)
                        return false;
                    found_idx = start_at;
                    found_len = ml;
                    return true;
                }
                return false;
            }

            for (int pos = start_at; pos <= tlen; pos++) {
                if (has_first_ch) {
                    while (pos < tlen && (uint8) text[pos] != first_ch)
                        pos++;
                    if (pos >= tlen)
                        return false;
                }
                int ml = 0;
                if (match_pattern (0, text, tlen, pos, mf, fail_memo, stride, ref ml)) {
                    if (notempty && ml == 0)
                        continue;
                    if (pos == tlen && ml == 0 && start_at < tlen)
                        return false;
                    found_idx = pos;
                    found_len = ml;
                    return true;
                }
            }
            return false;
        }

        public bool match (string str, out MatchInfo? match_info) {
            int tlen = str.length;
            int idx = -1;
            int ml = 0;
            bool ok = find_from (str, tlen, 0, default_m_flags, out idx, out ml);
            match_info = new MatchInfo (this, str, tlen, default_m_flags, ok, idx, ok ? (idx + ml) : 0);
            return ok;
        }

        public bool match_full (string str, int string_len, int start_position,
                                RegexMatchFlags match_options, out MatchInfo? match_info) throws RegexError {
            int slen = str.length;
            int tlen = (string_len < 0) ? slen : string_len;
            if (tlen > slen)
                tlen = slen;
            if (start_position < 0 || start_position > tlen) {
                match_info = new MatchInfo (this, str, tlen, match_options, false, -1, 0);
                throw new RegexError.MATCH ("invalid start_position");
            }
            RegexMatchFlags mf = default_m_flags | match_options;
            int idx = -1;
            int ml = 0;
            bool ok = find_from (str, tlen, start_position, mf, out idx, out ml);
            match_info = new MatchInfo (this, str, tlen, mf, ok, idx, ok ? (idx + ml) : 0);
            return ok;
        }

        public static bool match_simple (string pattern, string str,
                                         RegexCompileFlags compile_options = RegexCompileFlags.DEFAULT,
                                         RegexMatchFlags match_options = RegexMatchFlags.DEFAULT) {
            try {
                var r = new Regex (pattern, compile_options, match_options);
                MatchInfo? mi = null;
                return r.match (str, out mi);
            } catch (RegexError e) {
                return false;
            }
        }

        public string replace (string str, string replacement) {
            int tlen = str.length;
            int first_idx = -1;
            int first_ml = 0;
            if (!find_from (str, tlen, 0, default_m_flags, out first_idx, out first_ml))
                return str;
            var sb = new StringBuilder ("");
            int pos = 0;
            int idx = first_idx;
            int ml = first_ml;
            while (true) {
                if (idx > pos)
                    sb.append (str.substring (pos, idx - pos));
                sb.append (replacement);
                if (ml == 0) {
                    if (idx < tlen)
                        sb.append (str.substring (idx, 1));
                    pos = idx + 1;
                } else {
                    pos = idx + ml;
                }
                if (pos > tlen || !find_from (str, tlen, pos, default_m_flags, out idx, out ml)) {
                    if (pos < tlen)
                        sb.append (str.substring (pos));
                    break;
                }
            }
            return sb.str;
        }

        public string replace_literal (string str, int string_len, int start_position,
                                       string replacement,
                                       RegexMatchFlags match_options = RegexMatchFlags.DEFAULT) throws RegexError {
            int slen = str.length;
            int tlen = (string_len < 0) ? slen : string_len;
            if (tlen > slen)
                tlen = slen;
            if (start_position < 0 || start_position > tlen)
                throw new RegexError.MATCH ("invalid start_position");
            RegexMatchFlags mf = default_m_flags | match_options;
            int first_idx = -1;
            int first_ml = 0;
            if (!find_from (str, tlen, start_position, mf, out first_idx, out first_ml))
                return (tlen == slen) ? str : str.substring (0, tlen);
            var sb = new StringBuilder ("");
            int pos = 0;
            int idx = first_idx;
            int ml = first_ml;
            while (true) {
                if (idx > pos)
                    sb.append (str.substring (pos, idx - pos));
                sb.append (replacement);
                if (ml == 0) {
                    if (idx < tlen)
                        sb.append (str.substring (idx, 1));
                    pos = idx + 1;
                } else {
                    pos = idx + ml;
                }
                if (pos > tlen || !find_from (str, tlen, pos, mf, out idx, out ml)) {
                    if (pos < tlen)
                        sb.append (str.substring (pos, tlen - pos));
                    break;
                }
            }
            return sb.str;
        }

        public string[] split (string str, RegexMatchFlags match_options = RegexMatchFlags.DEFAULT) {
            int tlen = str.length;
            if (tlen == 0)
                return new string[0];
            RegexMatchFlags mf = default_m_flags | match_options;
            var parts = new GenericArray<string> ();
            int pos = 0;
            int idx = -1;
            int ml = 0;
            while (pos <= tlen && find_from (str, tlen, pos, mf, out idx, out ml)) {
                parts.add (str.substring (pos, idx - pos));
                if (ml == 0) {
                    if (idx < tlen)
                        parts.add (str.substring (idx, 1));
                    pos = idx + 1;
                } else {
                    pos = idx + ml;
                }
            }
            if (pos <= tlen)
                parts.add (str.substring (pos, tlen - pos));
            var res = new string[parts.length];
            for (int i = 0; i < parts.length; i++)
                res[i] = parts[i];
            return res;
        }

        public static string[] split_simple (string pattern, string str,
                                             RegexCompileFlags compile_options = RegexCompileFlags.DEFAULT,
                                             RegexMatchFlags match_options = RegexMatchFlags.DEFAULT) {
            try {
                var r = new Regex (pattern, compile_options, match_options);
                return r.split (str, match_options);
            } catch (RegexError e) {
                return new string[0];
            }
        }
    }
}
