// C99 lexer for c2vala.

using Planc;

namespace C2Vala {

    public enum TokKind {
        EOF,
        IDENT,
        INT_LIT,
        FLOAT_LIT,
        CHAR_LIT,
        STR_LIT,
        LPAREN,
        RPAREN,
        LBRACE,
        RBRACE,
        LBRACKET,
        RBRACKET,
        SEMI,
        COMMA,
        DOT,
        ARROW,
        COLON,
        QUESTION,
        ELLIPSIS,
        PLUS,
        MINUS,
        STAR,
        SLASH,
        PERCENT,
        PLUSPLUS,
        MINUSMINUS,
        AMP,
        PIPE,
        CARET,
        TILDE,
        BANG,
        LSHIFT,
        RSHIFT,
        EQ,
        NE,
        LT,
        LE,
        GT,
        GE,
        ANDAND,
        OROR,
        ASSIGN,
        ADD_ASSIGN,
        SUB_ASSIGN,
        MUL_ASSIGN,
        DIV_ASSIGN,
        MOD_ASSIGN,
        AND_ASSIGN,
        OR_ASSIGN,
        XOR_ASSIGN,
        LSHIFT_ASSIGN,
        RSHIFT_ASSIGN
    }

    public class CTok : Object {
        public TokKind kind;
        public string text;
        public string file;
        public int line;

        public CTok (TokKind kind, string text, string file, int line) {
            this.kind = kind;
            this.text = text;
            this.file = file;
            this.line = line;
        }
    }

    public class CLexer : Object {
        private static bool is_ident_start (uint8 c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        }

        private static bool is_ident_char (uint8 c) {
            return is_ident_start (c) || (c >= '0' && c <= '9');
        }

        private static bool is_digit (uint8 c) {
            return c >= '0' && c <= '9';
        }

        private static bool is_hex_digit (uint8 c) {
            return is_digit (c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        }

        public static GenericArray<CTok> tokenize (GenericArray<PreLine> lines) throws RefuseError {
            var raw_toks = new GenericArray<CTok> ();

            for (int li = 0; li < lines.length; li++) {
                var pl = lines[li];
                string s = pl.text;
                string f = pl.file;
                int ln = pl.line;
                int i = 0;

                while (i < s.length) {
                    uint8 c = s[i];
                    if (c == ' ' || c == '\t' || c == '\r' || c == 11 || c == 12) {
                        i++;
                        continue;
                    }

                    // String literal
                    if (c == '"') {
                        int start = i;
                        bool closed = false;
                        i++;
                        while (i < s.length) {
                            uint8 sc = s[i];
                            i++;
                            if (sc == '\\' && i < s.length) {
                                i++;
                            } else if (sc == '"') {
                                closed = true;
                                break;
                            }
                        }
                        if (!closed)
                            throw new RefuseError.FAILED (@"$f:$ln: unterminated string literal");
                        raw_toks.add (new CTok (TokKind.STR_LIT, s.substring (start, i - start), f, ln));
                        continue;
                    }

                    // Char literal
                    if (c == '\'') {
                        int start = i;
                        bool closed = false;
                        i++;
                        while (i < s.length) {
                            uint8 sc = s[i];
                            i++;
                            if (sc == '\\' && i < s.length) {
                                i++;
                            } else if (sc == '\'') {
                                closed = true;
                                break;
                            }
                        }
                        if (!closed)
                            throw new RefuseError.FAILED (@"$f:$ln: unterminated character literal");
                        raw_toks.add (new CTok (TokKind.CHAR_LIT, s.substring (start, i - start), f, ln));
                        continue;
                    }

                    // Identifier / keyword
                    if (is_ident_start (c)) {
                        int start = i;
                        while (i < s.length && is_ident_char (s[i]))
                            i++;
                        raw_toks.add (new CTok (TokKind.IDENT, s.substring (start, i - start), f, ln));
                        continue;
                    }

                    // Number literal
                    if (is_digit (c) || (c == '.' && i + 1 < s.length && is_digit (s[i + 1]))) {
                        int start = i;
                        bool is_float = false;
                        if (c == '0' && i + 1 < s.length && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
                            i += 2;
                            while (i < s.length && is_hex_digit (s[i]))
                                i++;
                            if (i < s.length && s[i] == '.') {
                                is_float = true;
                                i++;
                                while (i < s.length && is_hex_digit (s[i]))
                                    i++;
                            }
                            if (i < s.length && (s[i] == 'p' || s[i] == 'P')) {
                                is_float = true;
                                i++;
                                if (i < s.length && (s[i] == '+' || s[i] == '-'))
                                    i++;
                                while (i < s.length && is_digit (s[i]))
                                    i++;
                            }
                        } else if (c == '0' && i + 1 < s.length && (s[i + 1] == 'b' || s[i + 1] == 'B')) {
                            i += 2;
                            while (i < s.length && (s[i] == '0' || s[i] == '1'))
                                i++;
                        } else {
                            while (i < s.length && is_digit (s[i]))
                                i++;
                            if (i < s.length && s[i] == '.') {
                                is_float = true;
                                i++;
                                while (i < s.length && is_digit (s[i]))
                                    i++;
                            }
                            if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
                                is_float = true;
                                i++;
                                if (i < s.length && (s[i] == '+' || s[i] == '-'))
                                    i++;
                                while (i < s.length && is_digit (s[i]))
                                    i++;
                            }
                        }
                        // Suffixes (u, l, f)
                        while (i < s.length && (s[i] == 'u' || s[i] == 'U' || s[i] == 'l' || s[i] == 'L' || s[i] == 'f' || s[i] == 'F')) {
                            if (s[i] == 'f' || s[i] == 'F')
                                is_float = true;
                            i++;
                        }
                        raw_toks.add (new CTok (is_float ? TokKind.FLOAT_LIT : TokKind.INT_LIT,
                                                s.substring (start, i - start), f, ln));
                        continue;
                    }

                    // 3-char operators
                    if (i + 2 < s.length) {
                        string s3 = s.substring (i, 3);
                        if (s3 == "<<=") { raw_toks.add (new CTok (TokKind.LSHIFT_ASSIGN, s3, f, ln)); i += 3; continue; }
                        if (s3 == ">>=") { raw_toks.add (new CTok (TokKind.RSHIFT_ASSIGN, s3, f, ln)); i += 3; continue; }
                        if (s3 == "...") { raw_toks.add (new CTok (TokKind.ELLIPSIS, s3, f, ln)); i += 3; continue; }
                    }

                    // 2-char operators
                    if (i + 1 < s.length) {
                        string s2 = s.substring (i, 2);
                        TokKind k2 = TokKind.EOF;
                        if (s2 == "->") k2 = TokKind.ARROW;
                        else if (s2 == "++") k2 = TokKind.PLUSPLUS;
                        else if (s2 == "--") k2 = TokKind.MINUSMINUS;
                        else if (s2 == "<<") k2 = TokKind.LSHIFT;
                        else if (s2 == ">>") k2 = TokKind.RSHIFT;
                        else if (s2 == "==") k2 = TokKind.EQ;
                        else if (s2 == "!=") k2 = TokKind.NE;
                        else if (s2 == "<=") k2 = TokKind.LE;
                        else if (s2 == ">=") k2 = TokKind.GE;
                        else if (s2 == "&&") k2 = TokKind.ANDAND;
                        else if (s2 == "||") k2 = TokKind.OROR;
                        else if (s2 == "+=") k2 = TokKind.ADD_ASSIGN;
                        else if (s2 == "-=") k2 = TokKind.SUB_ASSIGN;
                        else if (s2 == "*=") k2 = TokKind.MUL_ASSIGN;
                        else if (s2 == "/=") k2 = TokKind.DIV_ASSIGN;
                        else if (s2 == "%=") k2 = TokKind.MOD_ASSIGN;
                        else if (s2 == "&=") k2 = TokKind.AND_ASSIGN;
                        else if (s2 == "|=") k2 = TokKind.OR_ASSIGN;
                        else if (s2 == "^=") k2 = TokKind.XOR_ASSIGN;
                        if (k2 != TokKind.EOF) {
                            raw_toks.add (new CTok (k2, s2, f, ln));
                            i += 2;
                            continue;
                        }
                    }

                    // 1-char punctuation/operators
                    TokKind k1 = TokKind.EOF;
                    if (c == '(') k1 = TokKind.LPAREN;
                    else if (c == ')') k1 = TokKind.RPAREN;
                    else if (c == '{') k1 = TokKind.LBRACE;
                    else if (c == '}') k1 = TokKind.RBRACE;
                    else if (c == '[') k1 = TokKind.LBRACKET;
                    else if (c == ']') k1 = TokKind.RBRACKET;
                    else if (c == ';') k1 = TokKind.SEMI;
                    else if (c == ',') k1 = TokKind.COMMA;
                    else if (c == '.') k1 = TokKind.DOT;
                    else if (c == ':') k1 = TokKind.COLON;
                    else if (c == '?') k1 = TokKind.QUESTION;
                    else if (c == '+') k1 = TokKind.PLUS;
                    else if (c == '-') k1 = TokKind.MINUS;
                    else if (c == '*') k1 = TokKind.STAR;
                    else if (c == '/') k1 = TokKind.SLASH;
                    else if (c == '%') k1 = TokKind.PERCENT;
                    else if (c == '&') k1 = TokKind.AMP;
                    else if (c == '|') k1 = TokKind.PIPE;
                    else if (c == '^') k1 = TokKind.CARET;
                    else if (c == '~') k1 = TokKind.TILDE;
                    else if (c == '!') k1 = TokKind.BANG;
                    else if (c == '<') k1 = TokKind.LT;
                    else if (c == '>') k1 = TokKind.GT;
                    else if (c == '=') k1 = TokKind.ASSIGN;

                    if (k1 != TokKind.EOF) {
                        raw_toks.add (new CTok (k1, s.substring (i, 1), f, ln));
                        i++;
                        continue;
                    }

                    throw new RefuseError.FAILED (@"$f:$ln: unexpected character '$(s.substring (i, 1))'");
                }
            }

            // Merge adjacent string literals ("a" "b" -> "ab")
            var toks = new GenericArray<CTok> ();
            for (int i = 0; i < raw_toks.length; i++) {
                var t = raw_toks[i];
                if (t.kind == TokKind.STR_LIT) {
                    var sb = new StrBuilder ();
                    if (t.text.length >= 2)
                        sb.append (t.text.substring (1, t.text.length - 2));
                    while (i + 1 < raw_toks.length && raw_toks[i + 1].kind == TokKind.STR_LIT) {
                        i++;
                        var nxt = raw_toks[i];
                        if (nxt.text.length >= 2)
                            sb.append (nxt.text.substring (1, nxt.text.length - 2));
                    }
                    toks.add (new CTok (TokKind.STR_LIT, "\"" + sb.str + "\"", t.file, t.line));
                } else {
                    toks.add (t);
                }
            }

            string last_file = lines.length > 0 ? lines[lines.length - 1].file : "<input>";
            int last_line = lines.length > 0 ? lines[lines.length - 1].line : 1;
            toks.add (new CTok (TokKind.EOF, "", last_file, last_line));
            return toks;
        }
    }
}
