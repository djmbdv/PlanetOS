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
        private int pos = 0;
        private int line = 1;
        private int column = 1;

        public Lexer (string source) {
            this.source = source;
        }

        public Lexer clone_state () {
            var cp = new Lexer (source);
            cp.pos = pos;
            cp.line = line;
            cp.column = column;
            return cp;
        }

        private uint8 current () {
            return pos < source.length ? source[pos] : 0;
        }

        private uint8 peek (int distance) {
            var p = pos + distance;
            return p < source.length ? source[p] : 0;
        }

        private void advance () {
            if (pos >= source.length)
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
            if (pos >= source.length)
                throw new LexError.UNTERMINATED_STRING (@"unterminated character literal at $l:$c");
            uint8 val = current ();
            if (val == '\'')
                throw new LexError.UNEXPECTED_CHARACTER (@"empty character literal at $l:$c");
            if (val == '\\') {
                advance ();
                if (pos >= source.length)
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
            if (pos >= source.length || current () != '\'')
                throw new LexError.UNTERMINATED_STRING (@"unterminated character literal at $l:$c");
            advance ();
            return Token () {
                kind = TokenKind.INTEGER,
                text = ((int) val).to_string (),
                line = l, column = c
            };
        }

        private Token scan_int_literal (int l, int c) throws LexError {
            uint64 val = 0;
            if (current () == '0' && (peek (1) == 'x' || peek (1) == 'X')) {
                advance ();
                advance ();
                int digits = 0;
                while (pos < source.length) {
                    var cur = current ();
                    if (cur == '_') { advance (); continue; }
                    if (!is_hex_digit (cur)) break;
                    val = val * 16 + hex_val (cur);
                    digits++;
                    advance ();
                }
                if (digits == 0)
                    throw new LexError.UNEXPECTED_CHARACTER (@"invalid hexadecimal literal at $l:$c");
            } else if (current () == '0' && (peek (1) == 'b' || peek (1) == 'B')) {
                advance ();
                advance ();
                int digits = 0;
                while (pos < source.length) {
                    var cur = current ();
                    if (cur == '_') { advance (); continue; }
                    if (cur != '0' && cur != '1') break;
                    val = val * 2 + (uint64) (cur - '0');
                    digits++;
                    advance ();
                }
                if (digits == 0)
                    throw new LexError.UNEXPECTED_CHARACTER (@"invalid binary literal at $l:$c");
            } else {
                while (pos < source.length) {
                    var cur = current ();
                    if (cur == '_') { advance (); continue; }
                    if (!is_digit (cur)) break;
                    val = val * 10 + (uint64) (cur - '0');
                    advance ();
                }
            }
            while (pos < source.length
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

            if (pos >= source.length)
                return Token () { kind = TokenKind.EOF, text = "", line = l, column = c };

            var ch = current ();

            if (is_letter (ch)) {
                var start = pos;
                while (pos < source.length && (is_letter (current ()) || is_digit (current ())))
                    advance ();
                return Token () {
                    kind = TokenKind.IDENTIFIER,
                    text = source[start:pos],
                    line = l, column = c
                };
            }

            if (is_digit (ch))
                return scan_int_literal (l, c);

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
                    text = scan_string_body (l, c),
                    line = l, column = c
                };
            }

            if (ch == '@' && peek (1) == '"') {
                advance ();
                advance ();
                return Token () {
                    kind = TokenKind.TEMPLATE_STRING,
                    text = scan_string_body (l, c),
                    line = l, column = c
                };
            }

            // Multi-character operators first: == != <= >= << >> && || ++ -- += -=
            if (ch == '=' || ch == '!' || ch == '<' || ch == '>'
                || ch == '&' || ch == '|' || ch == '+' || ch == '-') {
                var n = peek (1);
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
                if (ch == '=') { advance (); return Token () { kind = TokenKind.ASSIGN, text = "=", line = l, column = c }; }
                if (ch == '!') { advance (); return Token () { kind = TokenKind.NOT, text = "!", line = l, column = c }; }
                if (ch == '<') { advance (); return Token () { kind = TokenKind.LT, text = "<", line = l, column = c }; }
                if (ch == '>') { advance (); return Token () { kind = TokenKind.GT, text = ">", line = l, column = c }; }
                if (ch == '&') { advance (); return Token () { kind = TokenKind.AMP, text = "&", line = l, column = c }; }
                if (ch == '|') { advance (); return Token () { kind = TokenKind.PIPE, text = "|", line = l, column = c }; }
                if (ch == '+') { advance (); return Token () { kind = TokenKind.PLUS, text = "+", line = l, column = c }; }
                if (ch == '-') { advance (); return Token () { kind = TokenKind.MINUS, text = "-", line = l, column = c }; }
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
                case '*': kind = TokenKind.STAR; break;
                case '/': kind = TokenKind.SLASH; break;
                case '%': kind = TokenKind.PERCENT; break;
                case '^': kind = TokenKind.CARET; break;
                case '~': kind = TokenKind.TILDE; break;
                default:
                    throw new LexError.UNEXPECTED_CHARACTER (
                        @"unexpected character 0x%02x at $l:$c".printf (ch));
            }
            advance ();
            return Token () {
                kind = kind, text = source[pos - 1:pos], line = l, column = c
            };
        }

        private string scan_string_body (int l, int c) throws LexError {
            var sb = new StringBuilder ();
            while (true) {
                if (pos >= source.length)
                    throw new LexError.UNTERMINATED_STRING (
                        @"unterminated string at $l:$c");
                var x = current ();
                if (x == '"') {
                    advance ();
                    break;
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

        private void skip_whitespace () throws LexError {
            while (pos < source.length) {
                var c = current ();
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                    advance ();
                    continue;
                }
                if (c == '/' && peek (1) == '/') {
                    while (pos < source.length && current () != '\n')
                        advance ();
                    continue;
                }
                if (c == '/' && peek (1) == '*') {
                    var cl = line;
                    var cc = column;
                    advance ();
                    advance ();
                    bool closed = false;
                    while (pos < source.length) {
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
