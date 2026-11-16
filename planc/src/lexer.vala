// Lexical analysis for the Planc dialect.
//
// Works on bytes, not code points: sources are UTF-8 and string literals are
// copied verbatim, so there is nothing to decode. Identifiers and numeric
// literals are ASCII by definition of the dialect.
//
// Every token carries a position because a diagnostic without one is useless
// (TC-08).

namespace Planc {

    public enum TokenKind {
        IDENTIFIER,
        STRING,
        TEMPLATE_STRING,
        INTEGER,
        FLOAT,
        LBRACE,
        RBRACE,
        LPAREN,
        RPAREN,
        LBRACKET,    // [
        RBRACKET,    // ]
        SEMICOLON,
        COMMA,
        DOT,         // .
        COLON,       // :
        QUESTION,    // ?
        QUESTION_QUESTION, // ??
        ARROW,       // =>
        ASSIGN,      // =
        PLUS,        // +
        MINUS,       // -
        PLUSPLUS,    // ++
        MINUSMINUS,  // --
        PLUSEQ,      // +=
        MINUSEQ,     // -=
        STAREQ,      // *=
        SLASHEQ,     // /=
        PERCENTEQ,   // %=
        AMPEQ,       // &=
        PIPEEQ,      // |=
        CARETEQ,     // ^=
        SHLEQ,       // <<=
        SHREQ,       // >>=
        STAR,        // *
        SLASH,       // /
        PERCENT,     // %
        NOT,         // !
        TILDE,       // ~
        AMP,         // &
        PIPE,        // |
        CARET,       // ^
        SHL,         // <<
        SHR,         // >>
        LT,          // <
        GT,          // >
        LE,          // <=
        GE,          // >=
        EQ,          // ==
        NE,          // !=
        ANDAND,      // &&
        OROR,        // ||
        EOF
    }

    public struct Token {
        public TokenKind kind;
        public string text;
        public int line;
        public int column;
    }

    public errordomain LexError {
        UNEXPECTED_CHARACTER,
        UNTERMINATED_STRING,
        UNKNOWN_ESCAPE
    }

    public class Lexer : Object {

        private string source;
        private int src_len = 0;
        private int pos = 0;
        private int line = 1;
        private int column = 1;

        public Lexer (string source) {
            this.source = source;
            this.src_len = source.length;
        }

        public Lexer clone_state () {
            var cp = new Lexer (source);
            cp.pos = pos;
            cp.line = line;
            cp.column = column;
            return cp;
        }

        private uint8 current () {
            return pos < src_len ? source[pos] : 0;
        }

        private uint8 peek (int distance) {
            var p = pos + distance;
            return p < src_len ? source[p] : 0;
        }

        private void advance () {
            if (pos >= src_len)
                return;
            if (source[pos] == '\n') {
                line++;
                column = 1;
            } else {
                column++;
            }
            pos++;
        }

        private static bool is_letter (uint8 c) {
            return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }

        private static bool is_digit (uint8 c) {
            return c >= '0' && c <= '9';
        }

        private static bool is_hex_digit (uint8 c) {
            return is_digit (c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        }

        private static uint64 hex_val (uint8 c) {
            if (c >= '0' && c <= '9') return (uint64) (c - '0');
            if (c >= 'a' && c <= 'f') return (uint64) (10 + c - 'a');
            return (uint64) (10 + c - 'A');
        }

        private Token scan_char_literal (int l, int c) throws LexError {
            advance (); // skip opening '\''
            if (pos >= src_len)
                throw new LexError.UNTERMINATED_STRING (@"unterminated character literal at $l:$c");
            uint8 val = current ();
            if (val == '\'')
                throw new LexError.UNEXPECTED_CHARACTER (@"empty character literal at $l:$c");
            if (val == '\\') {
                advance ();
                if (pos >= src_len)
                    throw new LexError.UNTERMINATED_STRING (@"unterminated character literal at $l:$c");
                var e = current ();
                switch (e) {
                    case 'n':  val = '\n'; break;
                    case 't':  val = '\t'; break;
                    case 'r':  val = '\r'; break;
                    case '\\': val = '\\'; break;
                    case '\'': val = '\''; break;
                    case '"':  val = '"'; break;
                    case '0':  val = '\0'; break;
                    default:
                        throw new LexError.UNKNOWN_ESCAPE (@"unknown escape at $l:$c");
                }
            }
            advance ();
            if (pos >= src_len || current () != '\'')
                throw new LexError.UNTERMINATED_STRING (@"unterminated character literal at $l:$c");
            advance ();
            return Token () {
                kind = TokenKind.INTEGER,
                text = ((int) val).to_string (),
                line = l, column = c
            };
        }

        private Token scan_number_literal (int l, int c) throws LexError {
            if (current () == '0' && (peek (1) == 'x' || peek (1) == 'X')) {
                uint64 val = 0;
                advance ();
                advance ();
                int digits = 0;
                while (pos < src_len) {
                    var cur = current ();
                    if (cur == '_') { advance (); continue; }
                    if (!is_hex_digit (cur)) break;
                    val = val * 16 + hex_val (cur);
                    digits++;
                    advance ();
                }
                if (digits == 0)
                    throw new LexError.UNEXPECTED_CHARACTER (@"invalid hexadecimal literal at $l:$c");
                while (pos < src_len
                       && (current () == 'u' || current () == 'U'
                           || current () == 'l' || current () == 'L')) {
                    advance ();
                }
                return Token () {
                    kind = TokenKind.INTEGER,
                    text = ((int64) val).to_string (),
                    line = l, column = c
                };
            }
            if (current () == '0' && (peek (1) == 'b' || peek (1) == 'B')) {
                uint64 val = 0;
                advance ();
                advance ();
                int digits = 0;
                while (pos < src_len) {
                    var cur = current ();
                    if (cur == '_') { advance (); continue; }
                    if (cur != '0' && cur != '1') break;
                    val = val * 2 + (uint64) (cur - '0');
                    digits++;
                    advance ();
                }
                if (digits == 0)
                    throw new LexError.UNEXPECTED_CHARACTER (@"invalid binary literal at $l:$c");
                while (pos < src_len
                       && (current () == 'u' || current () == 'U'
                           || current () == 'l' || current () == 'L')) {
                    advance ();
                }
                return Token () {
                    kind = TokenKind.INTEGER,
                    text = ((int64) val).to_string (),
                    line = l, column = c
                };
            }

            var sb = new StrBuilder ();
            uint64 val = 0;
            bool is_float = false;
            while (pos < src_len) {
                var cur = current ();
                if (cur == '_') { advance (); continue; }
                if (!is_digit (cur)) break;
                val = val * 10 + (uint64) (cur - '0');
                sb.append_c ((char) cur);
                advance ();
            }
            if (pos < src_len && current () == '.' && is_digit (peek (1))) {
                is_float = true;
                sb.append_c ('.');
                advance ();
                while (pos < src_len) {
                    var cur = current ();
                    if (cur == '_') { advance (); continue; }
                    if (!is_digit (cur)) break;
                    sb.append_c ((char) cur);
                    advance ();
                }
            }
            if (pos < src_len && (current () == 'e' || current () == 'E')) {
                is_float = true;
                sb.append_c ('e');
                advance ();
                if (pos < src_len && (current () == '+' || current () == '-')) {
                    sb.append_c ((char) current ());
                    advance ();
                }
                int exp_digits = 0;
                while (pos < src_len) {
                    var cur = current ();
                    if (cur == '_') { advance (); continue; }
                    if (!is_digit (cur)) break;
                    sb.append_c ((char) cur);
                    exp_digits++;
                    advance ();
                }
                if (exp_digits == 0)
                    throw new LexError.UNEXPECTED_CHARACTER (@"invalid float exponent at $l:$c");
            }
            if (pos < src_len && (current () == 'f' || current () == 'F')) {
                is_float = true;
                sb.append_c ('f');
                advance ();
            } else if (is_float && pos < src_len && (current () == 'd' || current () == 'D')) {
                advance ();
            }
            if (is_float) {
                return Token () {
                    kind = TokenKind.FLOAT,
                    text = sb.str,
                    line = l, column = c
                };
            }
            while (pos < src_len
                   && (current () == 'u' || current () == 'U'
                       || current () == 'l' || current () == 'L')) {
                advance ();
            }
            return Token () {
                kind = TokenKind.INTEGER,
                text = ((int64) val).to_string (),
                line = l, column = c
            };
        }

        public Token next () throws LexError {
            skip_whitespace ();

            var l = line;
            var c = column;

            if (pos >= src_len)
                return Token () { kind = TokenKind.EOF, text = "", line = l, column = c };

            var ch = current ();

            if (is_letter (ch)) {
                var start = pos;
                while (pos < src_len && (is_letter (current ()) || is_digit (current ())))
                    advance ();
                return Token () {
                    kind = TokenKind.IDENTIFIER,
                    text = source[start:pos],
                    line = l, column = c
                };
            }

            if (is_digit (ch))
                return scan_number_literal (l, c);

            if (ch == '\'')
                return scan_char_literal (l, c);

            if (ch == '?' && peek (1) == '?') {
                advance ();
                advance ();
                return two_char (TokenKind.QUESTION_QUESTION, l, c);
            }

            if (ch == '"') {
                advance ();
                return Token () {
                    kind = TokenKind.STRING,
                    text = scan_string_body (l, c, false),
                    line = l, column = c
                };
            }

            if (ch == '@' && peek (1) == '"') {
                advance ();
                advance ();
                return Token () {
                    kind = TokenKind.TEMPLATE_STRING,
                    text = scan_string_body (l, c, true),
                    line = l, column = c
                };
            }

            // Multi-character operators first: <<= >>= == => != <= >= << >> && || ++ -- += -= *= /= %= &= |= ^=
            if (ch == '=' || ch == '!' || ch == '<' || ch == '>'
                || ch == '&' || ch == '|' || ch == '+' || ch == '-'
                || ch == '*' || ch == '/' || ch == '%' || ch == '^') {
                var n = peek (1);
                if (ch == '<' && n == '<' && peek (2) == '=') { advance (); advance (); advance (); return three_char (TokenKind.SHLEQ, l, c); }
                if (ch == '>' && n == '>' && peek (2) == '=') { advance (); advance (); advance (); return three_char (TokenKind.SHREQ, l, c); }
                if (ch == '=' && n == '=') { advance (); advance (); return two_char (TokenKind.EQ, l, c); }
                if (ch == '=' && n == '>') { advance (); advance (); return two_char (TokenKind.ARROW, l, c); }
                if (ch == '!' && n == '=') { advance (); advance (); return two_char (TokenKind.NE, l, c); }
                if (ch == '<' && n == '=') { advance (); advance (); return two_char (TokenKind.LE, l, c); }
                if (ch == '>' && n == '=') { advance (); advance (); return two_char (TokenKind.GE, l, c); }
                if (ch == '<' && n == '<') { advance (); advance (); return two_char (TokenKind.SHL, l, c); }
                if (ch == '>' && n == '>') { advance (); advance (); return two_char (TokenKind.SHR, l, c); }
                if (ch == '&' && n == '&') { advance (); advance (); return two_char (TokenKind.ANDAND, l, c); }
                if (ch == '|' && n == '|') { advance (); advance (); return two_char (TokenKind.OROR, l, c); }
                if (ch == '+' && n == '+') { advance (); advance (); return two_char (TokenKind.PLUSPLUS, l, c); }
                if (ch == '-' && n == '-') { advance (); advance (); return two_char (TokenKind.MINUSMINUS, l, c); }
                if (ch == '+' && n == '=') { advance (); advance (); return two_char (TokenKind.PLUSEQ, l, c); }
                if (ch == '-' && n == '=') { advance (); advance (); return two_char (TokenKind.MINUSEQ, l, c); }
                if (ch == '*' && n == '=') { advance (); advance (); return two_char (TokenKind.STAREQ, l, c); }
                if (ch == '/' && n == '=') { advance (); advance (); return two_char (TokenKind.SLASHEQ, l, c); }
                if (ch == '%' && n == '=') { advance (); advance (); return two_char (TokenKind.PERCENTEQ, l, c); }
                if (ch == '&' && n == '=') { advance (); advance (); return two_char (TokenKind.AMPEQ, l, c); }
                if (ch == '|' && n == '=') { advance (); advance (); return two_char (TokenKind.PIPEEQ, l, c); }
                if (ch == '^' && n == '=') { advance (); advance (); return two_char (TokenKind.CARETEQ, l, c); }
                if (ch == '=') { advance (); return Token () { kind = TokenKind.ASSIGN, text = "=", line = l, column = c }; }
                if (ch == '!') { advance (); return Token () { kind = TokenKind.NOT, text = "!", line = l, column = c }; }
                if (ch == '<') { advance (); return Token () { kind = TokenKind.LT, text = "<", line = l, column = c }; }
                if (ch == '>') { advance (); return Token () { kind = TokenKind.GT, text = ">", line = l, column = c }; }
                if (ch == '&') { advance (); return Token () { kind = TokenKind.AMP, text = "&", line = l, column = c }; }
                if (ch == '|') { advance (); return Token () { kind = TokenKind.PIPE, text = "|", line = l, column = c }; }
                if (ch == '+') { advance (); return Token () { kind = TokenKind.PLUS, text = "+", line = l, column = c }; }
                if (ch == '-') { advance (); return Token () { kind = TokenKind.MINUS, text = "-", line = l, column = c }; }
                if (ch == '*') { advance (); return Token () { kind = TokenKind.STAR, text = "*", line = l, column = c }; }
                if (ch == '/') { advance (); return Token () { kind = TokenKind.SLASH, text = "/", line = l, column = c }; }
                if (ch == '%') { advance (); return Token () { kind = TokenKind.PERCENT, text = "%", line = l, column = c }; }
                if (ch == '^') { advance (); return Token () { kind = TokenKind.CARET, text = "^", line = l, column = c }; }
            }

            TokenKind kind;
            switch (ch) {
                case '{': kind = TokenKind.LBRACE; break;
                case '}': kind = TokenKind.RBRACE; break;
                case '(': kind = TokenKind.LPAREN; break;
                case ')': kind = TokenKind.RPAREN; break;
                case '[': kind = TokenKind.LBRACKET; break;
                case ']': kind = TokenKind.RBRACKET; break;
                case ';': kind = TokenKind.SEMICOLON; break;
                case ',': kind = TokenKind.COMMA; break;
                case '.': kind = TokenKind.DOT; break;
                case ':': kind = TokenKind.COLON; break;
                case '?': kind = TokenKind.QUESTION; break;
                case '~': kind = TokenKind.TILDE; break;
                default:
                    throw new LexError.UNEXPECTED_CHARACTER (
                        @"unexpected character 0x$(Host.hex_u8 (ch)) at $l:$c");
            }
            advance ();
            return Token () {
                kind = kind, text = source[pos - 1:pos], line = l, column = c
            };
        }

        private string scan_string_body (int l, int c, bool is_template = false) throws LexError {
            var sb = new StrBuilder ();
            int interp_depth = 0;
            bool in_inner_str = false;
            while (true) {
                if (pos >= src_len)
                    throw new LexError.UNTERMINATED_STRING (
                        @"unterminated string at $l:$c");
                var x = current ();
                if (interp_depth > 0) {
                    if (in_inner_str) {
                        if (x == '\\' && pos + 1 < src_len) {
                            sb.append_c ('\\');
                            sb.append_c ((char) peek (1));
                            advance ();
                            advance ();
                            continue;
                        }
                        if (x == '"')
                            in_inner_str = false;
                        sb.append_c ((char) x);
                        advance ();
                        continue;
                    }
                    if (x == '"') {
                        in_inner_str = true;
                        sb.append_c ('"');
                        advance ();
                        continue;
                    }
                    if (x == '\'') {
                        sb.append_c ('\'');
                        advance ();
                        if (pos < src_len && current () == '\\') {
                            sb.append_c ('\\');
                            advance ();
                        }
                        if (pos < src_len) {
                            sb.append_c ((char) current ());
                            advance ();
                        }
                        if (pos < src_len && current () == '\'') {
                            sb.append_c ('\'');
                            advance ();
                        }
                        continue;
                    }
                    if (x == '(')
                        interp_depth++;
                    else if (x == ')')
                        interp_depth--;
                    sb.append_c ((char) x);
                    advance ();
                    continue;
                }
                if (x == '"') {
                    advance ();
                    break;
                }
                if (is_template && x == '$') {
                    var nxt = peek (1);
                    if (nxt == '$') {
                        sb.append_c ('$');
                        sb.append_c ('$');
                        advance ();
                        advance ();
                        continue;
                    }
                    if (nxt == '(') {
                        sb.append_c ('$');
                        sb.append_c ('(');
                        advance ();
                        advance ();
                        interp_depth = 1;
                        continue;
                    }
                }
                if (x == '\\') {
                    advance ();
                    var e = current ();
                    switch (e) {
                        case 'n':  sb.append_c ('\n'); break;
                        case 't':  sb.append_c ('\t'); break;
                        case 'r':  sb.append_c ('\r'); break;
                        case '\\': sb.append_c ('\\'); break;
                        case '"':  sb.append_c ('"'); break;
                        case '0':  sb.append_c ('\0'); break;
                        case 'x': {
                            advance ();
                            uint32 v = 0;
                            for (int hi = 0; hi < 2; hi++) {
                                if (pos >= src_len)
                                    throw new LexError.UNKNOWN_ESCAPE (@"truncated \\x escape at $l:$c");
                                uint8 hc = current ();
                                uint32 d = 0;
                                if (hc >= '0' && hc <= '9') d = hc - '0';
                                else if (hc >= 'a' && hc <= 'f') d = 10 + hc - 'a';
                                else if (hc >= 'A' && hc <= 'F') d = 10 + hc - 'A';
                                else throw new LexError.UNKNOWN_ESCAPE (@"invalid hex in \\x escape at $l:$c");
                                v = (v << 4) | d;
                                advance ();
                            }
                            sb.append_c ((char) (uint8) v);
                            continue;
                        }
                        case 'u':
                        case 'U': {
                            int digits = (e == 'u') ? 4 : 8;
                            advance ();
                            uint32 cp = 0;
                            for (int hi = 0; hi < digits; hi++) {
                                if (pos >= src_len)
                                    throw new LexError.UNKNOWN_ESCAPE (@"truncated unicode escape at $l:$c");
                                uint8 hc = current ();
                                uint32 d = 0;
                                if (hc >= '0' && hc <= '9') d = hc - '0';
                                else if (hc >= 'a' && hc <= 'f') d = 10 + hc - 'a';
                                else if (hc >= 'A' && hc <= 'F') d = 10 + hc - 'A';
                                else throw new LexError.UNKNOWN_ESCAPE (@"invalid hex in unicode escape at $l:$c");
                                cp = (cp << 4) | d;
                                advance ();
                            }
                            if (cp <= 0x7F) {
                                sb.append_c ((char) (uint8) cp);
                            } else if (cp <= 0x7FF) {
                                sb.append_c ((char) (uint8) (0xC0 | (cp >> 6)));
                                sb.append_c ((char) (uint8) (0x80 | (cp & 0x3F)));
                            } else if (cp <= 0xFFFF) {
                                sb.append_c ((char) (uint8) (0xE0 | (cp >> 12)));
                                sb.append_c ((char) (uint8) (0x80 | ((cp >> 6) & 0x3F)));
                                sb.append_c ((char) (uint8) (0x80 | (cp & 0x3F)));
                            } else if (cp <= 0x10FFFF) {
                                sb.append_c ((char) (uint8) (0xF0 | (cp >> 18)));
                                sb.append_c ((char) (uint8) (0x80 | ((cp >> 12) & 0x3F)));
                                sb.append_c ((char) (uint8) (0x80 | ((cp >> 6) & 0x3F)));
                                sb.append_c ((char) (uint8) (0x80 | (cp & 0x3F)));
                            } else {
                                throw new LexError.UNKNOWN_ESCAPE (@"unicode codepoint out of range at $l:$c");
                            }
                            continue;
                        }
                        default:
                            throw new LexError.UNKNOWN_ESCAPE (
                                @"unknown escape at $l:$c");
                    }
                    advance ();
                    continue;
                }
                sb.append_c ((char) x);
                advance ();
            }
            return sb.str;
        }

        private Token two_char (TokenKind kind, int l, int c) {
            return Token () { kind = kind, text = source[pos - 2:pos], line = l, column = c };
        }

        private Token three_char (TokenKind kind, int l, int c) {
            return Token () { kind = kind, text = source[pos - 3:pos], line = l, column = c };
        }

        private void skip_whitespace () throws LexError {
            while (pos < src_len) {
                var c = current ();
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                    advance ();
                    continue;
                }
                if (c == '/' && peek (1) == '/') {
                    while (pos < src_len && current () != '\n')
                        advance ();
                    continue;
                }
                if (c == '/' && peek (1) == '*') {
                    var cl = line;
                    var cc = column;
                    advance ();
                    advance ();
                    bool closed = false;
                    while (pos < src_len) {
                        if (current () == '*' && peek (1) == '/') {
                            advance ();
                            advance ();
                            closed = true;
                            break;
                        }
                        advance ();
                    }
                    if (!closed) {
                        throw new LexError.UNEXPECTED_CHARACTER (
                            @"unterminated block comment at $cl:$cc");
                    }
                    continue;
                }
                break;
            }
        }
    }
}
