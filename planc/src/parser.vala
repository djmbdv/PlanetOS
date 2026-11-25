// Recursive-descent parser for the Planc dialect.
//
// Grammar of slice 4:
//
//     program    := (enum_decl | struct_decl | function | global)*
//     enum_decl  := ('public'|'private'|'internal')? 'enum' IDENT '{' enum_members '}'
//     struct_decl:= ('public'|'private'|'internal')? 'struct' IDENT '{' field* '}'
//     global     := ('public'|'private'|'internal')? var_type IDENT ('=' literal)? ';'
//     function   := ('public'|'private'|'internal')? type IDENT '(' params? ')' block
//     type       := 'int' | 'bool' | 'string' | 'void' | IDENT
//     params     := var_type IDENT (',' var_type IDENT)*
//     block      := '{' statement* '}'
//     statement  := 'print' '(' expr ')' ';'
//                 | 'exit' '(' expr ')' ';'
//                 | 'return' expr? ';'
//                 | 'break' ';'
//                 | 'continue' ';'
//                 | 'if' '(' expr ')' stmt ('else' stmt)?
//                 | 'while' '(' expr ')' stmt
//                 | 'for' '(' simple_stmt? ';' expr? ';' simple_stmt? ')' stmt
//                 | simple_stmt ';'
//                 | block
//     expr       := lor
//     lor        := land ('||' land)*
//     land       := bor ('&&' bor)*
//     bor        := bxor ('|' bxor)*
//     bxor       := band ('^' band)*
//     band       := cmp ('&' cmp)*
//     cmp        := shift (('<' | '>' | '<=' | '>=' | '==' | '!=') shift)?
//     shift      := add (('<<' | '>>') add)*
//     add        := mul (('+' | '-') mul)*
//     mul        := unary (('*' | '/' | '%') unary)*
//     unary      := ('-' | '!' | '~') unary | postfix
//     postfix    := primary ('.' IDENT | '[' expr ']')*
//     primary    := INTEGER | STRING | TEMPLATE_STRING | 'true' | 'false'
//                 | IDENT | IDENT '(' args ')'
//                 | STRUCT '(' ')' ('{' (IDENT '=' expr (',' ...)* ','?)? '}')?
//                 | '(' expr ')'

namespace Planc {

    public errordomain ParseError {
        UNEXPECTED_TOKEN,
        DUPLICATE_FUNCTION,
        MISSING_MAIN
    }

    public class ParseChunk : Object {
        public int file_idx = 0;
        public int start_pos = 0;
        public int end_pos = 0;
        public int start_line = 1;
        public int start_col = 1;
        public Program? result = null;
        public string err_kind = "";
        public string err_msg = "";
    }

    public sealed class Parser : Object {

        private Lexer lexer;
        private Token current;
        private Program program;
        private Program types_prog;
        private int pending_gt = 0;
        private GenericArray<string> current_type_params = new GenericArray<string> ();
        private GenericArray<string> alias_names = new GenericArray<string> ();
        private GenericArray<ValaType> alias_types = new GenericArray<ValaType> ();
        private GenericArray<string> alias_tnames = new GenericArray<string> ();
        private GenericArray<string> unit_usings = new GenericArray<string> ();
        private GenericArray<string> ns_stack = new GenericArray<string> ();

        private int find_type_alias (string name) {
            for (int i = 0; i < alias_names.length; i++) {
                if (alias_names[i] == name) return i;
            }
            return -1;
        }

        private string last_parsed_type_token = "";

        private string source_text;

        private static bool is_int_type_name (string text) {
            return text == "int" || text == "int64" || text == "int32"
                || text == "int16" || text == "int8"
                || text == "uint" || text == "uint64" || text == "uint32" || text == "uint16" || text == "unichar"
                || text == "uint8" || text == "size_t" || text == "ssize_t"
                || text == "uintptr_t" || text == "uintptr" || text == "intptr_t" || text == "intptr" || text == "ptrdiff_t"
                || text == "short" || text == "ushort" || text == "long" || text == "ulong"
                || text == "char" || text == "uchar";
        }

        private static bool is_fp_type_name (string text) {
            return text == "float" || text == "double";
        }

        private bool is_sizeof_type_name (string text) {
            for (int i = 0; i < current_type_params.length; i++) {
                if (current_type_params[i] == text)
                    return true;
            }
            if (is_int_type_name (text) || is_fp_type_name (text))
                return true;
            if (text == "bool" || text == "string" || text == "void")
            if (text == "bool" || text == "string" || text == "void"
                || text == "Error" || text == "va_list"
                || text == "GenericArray" || text == "Channel"
                || text == "Mutex" || text == "Node")
                return true;
            if (find_type_alias (text) >= 0)
                return true;
            return types_prog.find_class (text) != null
                || types_prog.find_struct (text) != null
                || types_prog.find_enum (text) != null
                || types_prog.find_interface (text) != null
                || types_prog.find_delegate (text) != null
                || types_prog.find_error_domain (text) != null;
        }

        private static bool is_reserved (string text) {            return is_int_type_name (text) || is_fp_type_name (text) || text == "bool" || text == "string"
                || text == "var" || text == "void" || text == "new"
                || text == "null" || text == "this" || text == "base"
                || text == "is" || text == "as"
                || text == "virtual" || text == "override" || text == "abstract"
                || text == "const" || text == "static"
                || text == "owned" || text == "unowned"
                || text == "ref" || text == "out"
                || text == "errordomain" || text == "throws" || text == "throw"
                || text == "try" || text == "catch" || text == "finally"
                || text == "namespace" || text == "using"
                || text == "true" || text == "false"
                || text == "return" || text == "if" || text == "else"
                || text == "while" || text == "do" || text == "for" || text == "foreach" || text == "in"
                || text == "switch" || text == "case" || text == "default"
                || text == "break" || text == "continue"
                || text == "enum" || text == "struct" || text == "union" || text == "class"
                || text == "interface" || text == "delegate"
                || text == "sealed" || text == "sizeof" || text == "lock"
                || text == "async" || text == "yield";
        }

        private static bool is_tok_kw (Token tok, string kw) {
            return tok.kind == TokenKind.IDENTIFIER && !tok.is_escaped && tok.text == kw;
        }

        private static bool is_tok_reserved (Token tok) {
            return !tok.is_escaped && is_reserved (tok.text);
        }

        private void consume_gt () throws ParseError, LexError {
            if (pending_gt > 0) {
                pending_gt--;
                return;
            }
            if (current.kind == TokenKind.GT) {
                advance ();
                return;
            }
            if (current.kind == TokenKind.SHR) {
                pending_gt++;
                advance ();
                return;
            }
            throw new ParseError.UNEXPECTED_TOKEN (
                @"expected '>' in generic type arguments at $(current.line):$(current.column)");
        }

        private void parse_generic_type_args (ref ValaType t, ref string tname)
                throws ParseError, LexError {
            if ((t != ValaType.CLASS && t != ValaType.STRUCT && t != ValaType.INTERFACE)
                || current.kind != TokenKind.LT)
                return;
            bool is_del_tmpl = false;
            if (t == ValaType.CLASS && tname != "GenericArray" && tname != "Channel" && tname != "Node") {
                unowned var cd = types_prog.find_class (tname);
                if (cd == null || !cd.is_generic_template)
                    return;
            } else if (t == ValaType.STRUCT) {
                unowned var sd = types_prog.find_struct (tname);
                if (sd != null && sd.is_generic_template) {
                    // generic struct
                } else {
                    unowned var dd = types_prog.find_delegate (tname);
                    if (dd == null || !dd.is_generic_template)
                        return;
                    is_del_tmpl = true;
                }
            } else if (t == ValaType.INTERFACE) {
                unowned var it = types_prog.find_interface (tname);
                if (it == null || !it.is_generic_template)
                    return;
            }

            var tl = current.line;
            var tc = current.column;
            advance (); // '<'
            var atypes = new GenericArray<ValaType> ();
            var anames = new GenericArray<string> ();
            while (true) {
                parse_ownership_weak ();
                ValaType at = ValaType.VOID;
                string an = "";
                if (current.kind != TokenKind.IDENTIFIER
                    || !parse_type (current.text, out at, out an, current.is_escaped)
                    || at == ValaType.VOID) {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected type argument in generic type '$tname' at $(current.line):$(current.column)");
                }
                advance ();
                parse_type_suffix (ref at, ref an);
                atypes.add (at);
                anames.add (an);
                if (pending_gt == 0 && current.kind == TokenKind.COMMA) {
                    advance ();
                    continue;
                }
                consume_gt ();
                break;
            }

            int expected_arity = -1;
            if (tname == "GenericArray" || tname == "Channel" || tname == "Node") {
                expected_arity = 1;
            } else if (t == ValaType.CLASS) {
                unowned var cd = types_prog.find_class (tname);
                if (cd != null && (cd.is_defined || cd.type_params.length > 0))
                    expected_arity = cd.type_params.length;
            } else if (t == ValaType.INTERFACE) {
                unowned var it = types_prog.find_interface (tname);
                if (it != null && (it.is_defined || it.type_params.length > 0))
                    expected_arity = it.type_params.length;
            } else if (is_del_tmpl) {
                unowned var dd = types_prog.find_delegate (tname);
                if (dd != null && (dd.is_defined || dd.type_params.length > 0))
                    expected_arity = dd.type_params.length;
            } else {
                unowned var sd = types_prog.find_struct (tname);
                if (sd != null && (sd.is_defined || sd.type_params.length > 0))
                    expected_arity = sd.type_params.length;
            }
            if (expected_arity >= 0 && atypes.length != expected_arity) {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"generic type '$tname' expects $expected_arity type argument(s), got $(atypes.length) at $tl:$tc");
            }

            tname = program.request_instantiation (tname, t == ValaType.STRUCT, atypes, anames,
                                                   t == ValaType.INTERFACE, is_del_tmpl);
        }

        private void parse_type_suffix (ref ValaType t, ref string tname)
                throws ParseError, LexError {
            if (pending_gt == 0 && (t == ValaType.CLASS || t == ValaType.STRUCT || t == ValaType.INTERFACE)
                && current.kind == TokenKind.LT) {
                parse_generic_type_args (ref t, ref tname);
            }
            if (pending_gt > 0)
                return;
            if (current.kind == TokenKind.QUESTION) {
                bool allow_del = (t == ValaType.STRUCT && types_prog.find_delegate (tname) != null);
                if (t != ValaType.CLASS && t != ValaType.INTERFACE && t != ValaType.STRING
                    && t != ValaType.TYPE_PARAM && !allow_del)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"only reference types can be nullable ('?') at $(current.line):$(current.column)");
                advance ();
                tname = tname + "?";
            }
            while (current.kind == TokenKind.LBRACKET) {
                if (t == ValaType.VOID)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"unsupported array element type at $(current.line):$(current.column)");
                advance ();
                expect (TokenKind.RBRACKET, "']'");
                if (t == ValaType.ARRAY) {
                    tname = tname + "[]";
                    continue;
                }
                if (t == ValaType.INT) {
                    if (last_parsed_type_token == "uint8" || last_parsed_type_token == "uchar"
                        || last_parsed_type_token == "char")
                        tname = "uint8";
                    else if (last_parsed_type_token == "int8")
                        tname = "int8";
                    else if (is_int_type_name (last_parsed_type_token))
                        tname = last_parsed_type_token;
                    else
                        tname = t.label ();
                } else {
                    tname = (t == ValaType.ENUM || t == ValaType.CLASS || t == ValaType.INTERFACE
                             || t == ValaType.ERROR || t == ValaType.TYPE_PARAM
                             || t == ValaType.STRUCT) ? tname : t.label ();
                }
                t = ValaType.ARRAY;
            }
            while (current.kind == TokenKind.STAR) {
                advance ();
                string inner_pn;
                if (t == ValaType.POINTER) {
                    inner_pn = tname;
                } else if (t == ValaType.INT) {
                    inner_pn = is_int_type_name (last_parsed_type_token) ? last_parsed_type_token : t.label ();
                } else if (tname != "") {
                    inner_pn = tname;
                } else {
                    inner_pn = t.label ();
                }
                tname = "ptr:" + inner_pn;
                t = ValaType.POINTER;
            }
            if (current.kind == TokenKind.QUESTION) {
                bool allow_del = (t == ValaType.STRUCT && types_prog.find_delegate (tname) != null);
                if (t != ValaType.CLASS && t != ValaType.INTERFACE && t != ValaType.STRING
                    && t != ValaType.ARRAY && t != ValaType.ERROR && t != ValaType.TYPE_PARAM
                    && !allow_del)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"only reference types can be nullable ('?') at $(current.line):$(current.column)");
                advance ();
                tname = tname + "?";
            }
        }

        private bool parse_type (string text, out ValaType t, out string tname, bool is_escaped = false) {
            tname = "";
            last_parsed_type_token = is_escaped ? "" : text;
            for (int i = 0; i < current_type_params.length; i++) {
                if (current_type_params[i] == text) {
                    t = ValaType.TYPE_PARAM;
                    tname = text;
                    return true;
                }
            }
            if (!is_escaped) {
                if (text == "void") {
                    t = ValaType.VOID;
                    return true;
                }
                if (is_int_type_name (text)) {
                    t = ValaType.INT;
                    tname = text;
                    return true;
                }
                if (text == "float") {
                    t = ValaType.FLOAT;
                    return true;
                }
                if (text == "double") {
                    t = ValaType.DOUBLE;
                    return true;
                }
                if (text == "va_list") {
                    t = ValaType.ARRAY;
                    tname = "uint64";
                    return true;
                }
                if (text == "bool") {
                    t = ValaType.BOOL;
                    return true;
                }
                if (text == "string") {
                    t = ValaType.STRING;
                    return true;
                }
                if (text == "Error") {
                    t = ValaType.ERROR;
                    return true;
                }
                if (text == "GenericArray" || text == "Channel" || text == "Mutex" || text == "Node") {
                    t = ValaType.CLASS;
                    tname = text;
                    return true;
                }
            }
            if (!is_escaped) {
                int ai = find_type_alias (text);
                if (ai >= 0) {
                    t = alias_types[ai];
                    tname = alias_tnames[ai];
                    return true;
                }
            }
            if (types_prog.find_error_domain (text) != null) {
                t = ValaType.ERROR;
                tname = text;
                return true;
            }
            if (types_prog.find_enum (text) != null) {
                t = ValaType.ENUM;
                tname = text;
                return true;
            }
            if (types_prog.find_interface (text) != null) {
                t = ValaType.INTERFACE;
                tname = text;
                return true;
            }
            if (types_prog.find_struct (text) != null) {
                t = ValaType.STRUCT;
                tname = text;
                return true;
            }
            if (types_prog.find_class (text) != null) {
                t = ValaType.CLASS;
                tname = text;
                return true;
            }
            t = ValaType.VOID;
            return false;
        }

        private bool parse_type_with_ns (out ValaType t, out string tname) throws ParseError, LexError {
            t = ValaType.VOID;
            tname = "";
            if (current.kind != TokenKind.IDENTIFIER)
                return false;
            var saved_lx = lexer.clone_state ();
            var saved_cur = current;
            var raw = current.text;
            var esc = current.is_escaped;
            advance ();
            if (!esc && types_prog.has_namespace (raw) && current.kind == TokenKind.DOT) {
                string ns_acc = raw;
                while (types_prog.has_namespace (ns_acc) && current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER) {
                        lexer = saved_lx;
                        current = saved_cur;
                        return false;
                    }
                    raw = current.text;
                    esc = current.is_escaped;
                    advance ();
                    if (!esc && types_prog.has_namespace (@"$ns_acc.$raw") && current.kind == TokenKind.DOT) {
                        ns_acc = @"$ns_acc.$raw";
                        continue;
                    }
                    break;
                }
            }
            if (!parse_type (raw, out t, out tname, esc)) {
                lexer = saved_lx;
                current = saved_cur;
                return false;
            }
            return true;
        }

        public Parser (string source) {
            source_text = source;
            lexer = new Lexer (source);
            program = new Program ();
            types_prog = program;
        }

        public Parser.with_program (string source, Program existing) {
            source_text = source;
            lexer = new Lexer (source);
            program = existing;
            types_prog = existing;
        }

        public Parser.for_chunk (string source, int start_pos, int end_pos, int start_line, int start_col,
                                 Program shared_types, Program out_prog) {
            source_text = source;
            lexer = new Lexer (source);
            lexer.set_range (start_pos, end_pos, start_line, start_col);
            types_prog = shared_types;
            program = out_prog;
        }

        public static void split_chunks (string src, int file_idx, int target_bytes,
                                         GenericArray<ParseChunk> out_chunks) {
            int n = src.length;
            if (n == 0)
                return;
            if (target_bytes <= 0 || n < target_bytes) {
                out_chunks.add (new ParseChunk () {
                    file_idx = file_idx, start_pos = 0, end_pos = n, start_line = 1, start_col = 1
                });
                return;
            }
            int line = 1;
            int col = 1;
            int chunk_start = 0;
            int chunk_line = 1;
            int chunk_col = 1;
            int brace_depth = 0;
            int paren_depth = 0;
            int bracket_depth = 0;
            int i = 0;
            while (i < n) {
                uint8 c = src[i];
                // Skip line comment
                if (c == '/' && i + 1 < n && src[i + 1] == '/') {
                    while (i < n && src[i] != '\n') {
                        i++;
                        col++;
                    }
                    continue;
                }
                // Skip block comment
                if (c == '/' && i + 1 < n && src[i + 1] == '*') {
                    i += 2;
                    col += 2;
                    while (i < n) {
                        if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
                            i += 2;
                            col += 2;
                            break;
                        }
                        if (src[i] == '\n') { line++; col = 1; }
                        else col++;
                        i++;
                    }
                    continue;
                }
                // Skip verbatim string
                if (c == '"' && i + 2 < n && src[i + 1] == '"' && src[i + 2] == '"') {
                    i += 3;
                    col += 3;
                    while (i < n) {
                        if (src[i] == '"' && i + 2 < n && src[i + 1] == '"' && src[i + 2] == '"') {
                            i += 3;
                            col += 3;
                            break;
                        }
                        if (src[i] == '\n') { line++; col = 1; }
                        else col++;
                        i++;
                    }
                    continue;
                }
                // Skip string literal
                if (c == '"') {
                    i++;
                    col++;
                    while (i < n) {
                        if (src[i] == '\\' && i + 1 < n) {
                            if (src[i + 1] == '\n') { line++; col = 1; }
                            else col += 2;
                            i += 2;
                            continue;
                        }
                        if (src[i] == '"') {
                            i++;
                            col++;
                            break;
                        }
                        if (src[i] == '\n') { line++; col = 1; }
                        else col++;
                        i++;
                    }
                    continue;
                }
                // Skip char literal
                if (c == '\'') {
                    i++;
                    col++;
                    while (i < n) {
                        if (src[i] == '\\' && i + 1 < n) {
                            i += 2;
                            col += 2;
                            continue;
                        }
                        if (src[i] == '\'') {
                            i++;
                            col++;
                            break;
                        }
                        if (src[i] == '\n') { line++; col = 1; }
                        else col++;
                        i++;
                    }
                    continue;
                }
                if (c == '{') brace_depth++;
                else if (c == '}' && brace_depth > 0) brace_depth--;
                else if (c == '(') paren_depth++;
                else if (c == ')' && paren_depth > 0) paren_depth--;
                else if (c == '[') bracket_depth++;
                else if (c == ']' && bracket_depth > 0) bracket_depth--;

                if (c == '\n') { line++; col = 1; }
                else col++;
                i++;

                if ((c == ';' || c == '}') && brace_depth == 0 && paren_depth == 0 && bracket_depth == 0) {
                    if (i - chunk_start >= target_bytes) {
                        out_chunks.add (new ParseChunk () {
                            file_idx = file_idx,
                            start_pos = chunk_start,
                            end_pos = i,
                            start_line = chunk_line,
                            start_col = chunk_col
                        });
                        chunk_start = i;
                        chunk_line = line;
                        chunk_col = col;
                    }
                }
            }
            if (chunk_start < n) {
                out_chunks.add (new ParseChunk () {
                    file_idx = file_idx,
                    start_pos = chunk_start,
                    end_pos = n,
                    start_line = chunk_line,
                    start_col = chunk_col
                });
            }
        }

        public static void prescan_types (string source, Program prog) throws LexError {
            var lx = new Lexer (source);
            var prev_kind = TokenKind.EOF;
            while (true) {
                var tok = lx.next ();
                if (tok.kind == TokenKind.EOF)
                    break;
                if (tok.kind == TokenKind.IDENTIFIER && !tok.is_escaped && prev_kind != TokenKind.DOT
                    && tok.text == "namespace") {
                    var nt = lx.next ();
                    if (nt.kind == TokenKind.IDENTIFIER) {
                        string ns_full = nt.text;
                        while (true) {
                            var nxt = lx.next ();
                            if (nxt.kind != TokenKind.DOT) {
                                prev_kind = nxt.kind;
                                break;
                            }
                            var seg = lx.next ();
                            if (seg.kind != TokenKind.IDENTIFIER) {
                                prev_kind = seg.kind;
                                break;
                            }
                            ns_full = @"$ns_full.$(seg.text)";
                        }
                        prog.register_namespace (ns_full);
                    }
                    continue;
                }
                if (tok.kind == TokenKind.IDENTIFIER && !tok.is_escaped && prev_kind != TokenKind.DOT
                    && (tok.text == "enum" || tok.text == "struct" || tok.text == "union"
                        || tok.text == "class" || tok.text == "errordomain"
                        || tok.text == "interface" || tok.text == "delegate")) {
                    var kind_kw = tok.text;
                    if (kind_kw == "delegate") {
                        string last_id = "";
                        bool last_esc = false;
                        int last_l = tok.line;
                        int last_c = tok.column;
                        var dd_tparams = new GenericArray<string> ();
                        bool dd_is_generic = false;
                        while (true) {
                            var dt = lx.next ();
                            if (dt.kind == TokenKind.EOF || dt.kind == TokenKind.SEMICOLON
                                || dt.kind == TokenKind.LBRACE) {
                                prev_kind = dt.kind;
                                break;
                            }
                            if (dt.kind == TokenKind.LT && last_id != "" && dd_tparams.length == 0) {
                                dd_is_generic = true;
                                while (true) {
                                    var tp = lx.next ();
                                    if (tp.kind == TokenKind.IDENTIFIER && !is_tok_reserved (tp))
                                        dd_tparams.add (tp.text);
                                    else
                                        break;
                                    var sep = lx.next ();
                                    if (sep.kind == TokenKind.COMMA)
                                        continue;
                                    break;
                                }
                                continue;
                            }
                            if (dt.kind == TokenKind.LPAREN) {
                                if (last_id != "" && (!is_reserved (last_id) || last_esc)
                                    && prog.find_delegate (last_id) == null) {
                                    var dd = new DelegateDecl () {
                                        name = last_id,
                                        is_generic_template = dd_is_generic,
                                        line = last_l,
                                        column = last_c
                                    };
                                    for (int ti = 0; ti < dd_tparams.length; ti++)
                                        dd.type_params.add (dd_tparams[ti]);
                                    prog.delegates.add (dd);
                                    prog.register_delegate_struct (last_id);
                                }
                                prev_kind = dt.kind;
                                break;
                            }
                            if (dt.kind == TokenKind.IDENTIFIER) {
                                last_id = dt.text;
                                last_esc = dt.is_escaped;
                                last_l = dt.line;
                                last_c = dt.column;
                            }
                        }
                        continue;
                    }
                    var nt = lx.next ();
                    if (nt.kind == TokenKind.EOF)
                        break;
                    if (nt.kind == TokenKind.IDENTIFIER && !is_tok_reserved (nt)) {
                        var tname = nt.text;
                        bool exists = prog.find_enum (tname) != null
                                   || prog.find_struct (tname) != null
                                   || prog.find_class (tname) != null
                                   || prog.find_interface (tname) != null
                                   || prog.find_delegate (tname) != null
                                   || prog.find_error_domain (tname) != null;
                        if (!exists) {
                            if (kind_kw == "enum") {
                                prog.enums.add (new EnumDecl () {
                                    name = tname, line = nt.line, column = nt.column
                                });
                            } else if (kind_kw == "struct" || kind_kw == "union") {
                                var sd = new StructDecl () {
                                    name = tname,
                                    is_union = (kind_kw == "union"),
                                    line = nt.line, column = nt.column
                                };
                                var plx = lx.clone_state ();
                                var pt = plx.next ();
                                if (pt.kind == TokenKind.LT) {
                                    sd.is_generic_template = true;
                                    while (true) {
                                        var tp = plx.next ();
                                        if (tp.kind == TokenKind.IDENTIFIER && !is_tok_reserved (tp))
                                            sd.type_params.add (tp.text);
                                        else
                                            break;
                                        var sep = plx.next ();
                                        if (sep.kind == TokenKind.COMMA)
                                            continue;
                                        break;
                                    }
                                    lx = plx;
                                }
                                prog.structs.add (sd);
                            } else if (kind_kw == "class") {
                                var cd = new ClassDecl () {
                                    name = tname, line = nt.line, column = nt.column
                                };
                                var plx = lx.clone_state ();
                                var pt = plx.next ();
                                if (pt.kind == TokenKind.LT) {
                                    cd.is_generic_template = true;
                                    while (true) {
                                        var tp = plx.next ();
                                        if (tp.kind == TokenKind.IDENTIFIER && !is_tok_reserved (tp))
                                            cd.type_params.add (tp.text);
                                        else
                                            break;
                                        var sep = plx.next ();
                                        if (sep.kind == TokenKind.COMMA)
                                            continue;
                                        break;
                                    }
                                    lx = plx;
                                }
                                prog.classes.add (cd);
                            } else if (kind_kw == "interface") {
                                var itf = new InterfaceDecl () {
                                    name = tname,
                                    iface_id = InterfaceDecl.compute_iface_id (tname),
                                    line = nt.line,
                                    column = nt.column
                                };
                                var plx = lx.clone_state ();
                                var pt = plx.next ();
                                if (pt.kind == TokenKind.LT) {
                                    itf.is_generic_template = true;
                                    while (true) {
                                        var tp = plx.next ();
                                        if (tp.kind == TokenKind.IDENTIFIER && !is_tok_reserved (tp))
                                            itf.type_params.add (tp.text);
                                        else
                                            break;
                                        var sep = plx.next ();
                                        if (sep.kind == TokenKind.COMMA)
                                            continue;
                                        break;
                                    }
                                    lx = plx;
                                }
                                prog.interfaces.add (itf);
                            } else {
                                prog.error_domains.add (new ErrorDomainDecl () {
                                    name = tname,
                                    domain_id = prog.error_domains.length + 1,
                                    line = nt.line,
                                    column = nt.column
                                });
                            }
                        }
                    }
                    prev_kind = nt.kind;
                    continue;
                }
                prev_kind = tok.kind;
            }
        }

        private int brace_depth = 0;
        private bool have_current = false;

        private void advance () throws ParseError, LexError {
            if (have_current) {
                if (current.kind == TokenKind.LBRACE)
                    brace_depth++;
                else if (current.kind == TokenKind.RBRACE && brace_depth > 0)
                    brace_depth--;
            }
            current = lexer.next ();
            have_current = true;
        }

        private void expect (TokenKind expected, string what) throws ParseError, LexError {
            if (current.kind != expected)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected $what at $(current.line):$(current.column)");
            advance ();
        }

        public bool recover { get; set; default = true; }
        private bool at_least_one_error = false;

        public void parse_unit () throws ParseError, LexError {
            advance ();
            while (current.kind != TokenKind.EOF) {
                // Stray separators left behind by recovery are not errors.
                if (current.kind == TokenKind.SEMICOLON) {
                    advance ();
                    continue;
                }
                if (current.kind == TokenKind.RBRACE && brace_depth == 0) {
                    Diagnostics.add (Diagnostics.current_file, current.line, current.column,
                                     "syntax error", "unexpected '}'");
                    if (!advance_recovering ())
                        return;
                    at_least_one_error = true;
                    continue;
                }
                int start_depth = brace_depth;
                int line_before = current.line;
                int col_before = current.column;
                try {
                    parse_top_level ();
                } catch (ParseError e) {
                    if (!recover)
                        throw new ParseError.UNEXPECTED_TOKEN (e.message);
                    Diagnostics.add (Diagnostics.current_file, current.line, current.column,
                                     "syntax error", e.message);
                    if (Diagnostics.is_full ())
                        return;
                    if (!resync_top_level (start_depth))
                        return;
                    at_least_one_error = true;
                } catch (LexError e) {
                    if (!recover)
                        throw new LexError.UNEXPECTED_CHARACTER (e.message);
                    Diagnostics.add (Diagnostics.current_file, lexer.cur_line (), lexer.cur_column (),
                                     "lexical error", e.message);
                    if (Diagnostics.is_full ())
                        return;
                    lexer.skip_one_char ();
                    if (!advance_recovering ())
                        return;
                    at_least_one_error = true;
                }
                // A malformed declaration must never loop forever: if nothing
                // moved, consume one token.
                if (current.line == line_before && current.column == col_before
                    && current.kind != TokenKind.EOF) {
                    if (!advance_recovering ())
                        return;
                }
            }
        }

        public bool had_errors () {
            return at_least_one_error || Diagnostics.count () > 0;
        }

        // Fetches the next token, reporting (and skipping over) lexical errors.
        private bool advance_recovering () throws ParseError {
            int guard = 0;
            while (guard < 4096) {
                guard++;
                try {
                    advance ();
                    return true;
                } catch (LexError e) {
                    Diagnostics.add (Diagnostics.current_file, lexer.cur_line (), lexer.cur_column (),
                                     "lexical error", e.message);
                    if (Diagnostics.is_full ())
                        return false;
                    if (lexer.at_eof ())
                        return false;
                    lexer.skip_one_char ();
                }
            }
            return false;
        }

        // Panic-mode recovery for top-level declarations: skip tokens until the
        // broken declaration is closed, either by the `;` of a declaration at
        // the starting brace depth or by the `}` that ends the block it opened.
        private bool resync_top_level (int start_depth) throws ParseError {
            int guard = 0;
            while (current.kind != TokenKind.EOF && guard < 1000000) {
                guard++;
                if (brace_depth == start_depth && current.kind == TokenKind.SEMICOLON) {
                    advance_recovering ();
                    return current.kind != TokenKind.EOF;
                }
                bool closing = (current.kind == TokenKind.RBRACE);
                if (!advance_recovering ())
                    return false;
                if (closing && brace_depth == start_depth)
                    return current.kind != TokenKind.EOF;
                if (brace_depth < start_depth)
                    return current.kind != TokenKind.EOF;
            }
            return false;
        }

        public Program parse_program () throws ParseError, LexError {
            prescan_types (source_text, program);
            parse_unit ();

            if (program.find ("main") == null)
                throw new ParseError.MISSING_MAIN ("the program does not define main");

            return program;
        }

        private bool has_other_top_name (string name, string except_kind) {
            unowned var sd = types_prog.find_struct (name);
            bool struct_conflict = (sd != null) && (except_kind != "struct")
                                   && !(except_kind == "delegate" && sd.is_delegate);
            bool del_conflict = (types_prog.find_delegate (name) != null)
                                && (except_kind != "delegate");
            return program.find (name) != null
                || find_global (program, name) != null
                || program.find_const ("", name) != null
                || (except_kind != "enum" && types_prog.find_enum (name) != null)
                || struct_conflict
                || del_conflict
                || (except_kind != "interface" && types_prog.find_interface (name) != null)
                || (except_kind != "class" && types_prog.find_class (name) != null)
                || (except_kind != "errordomain" && types_prog.find_error_domain (name) != null);
        }

        private bool has_top_name (string name) {
            return has_other_top_name (name, "");
        }

        private static bool is_visibility_modifier (string text) {
            return text == "public" || text == "private"
                || text == "internal" || text == "protected";
        }

        private void skip_ownership_modifiers () throws ParseError, LexError {
            while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                   && (current.text == "unowned" || current.text == "owned" || current.text == "weak")) {
                advance ();
            }
        }

        private bool parse_ownership (out bool is_unowned) throws ParseError, LexError {
            bool is_weak = false;
            is_unowned = false;
            while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                   && (current.text == "unowned" || current.text == "owned" || current.text == "weak")) {
                if (current.text == "weak") {
                    is_weak = true;
                    is_unowned = false;
                } else if (current.text == "unowned") {
                    is_unowned = true;
                } else if (current.text == "owned") {
                    is_unowned = false;
                }
                advance ();
            }
            return is_weak;
        }

        private bool parse_ownership_weak () throws ParseError, LexError {
            bool dummy = false;
            return parse_ownership (out dummy);
        }

        private void parse_const_decl (string owner_type) throws ParseError, LexError {
            var cl = current.line;
            var cc = current.column;
            advance (); // 'const'
            ValaType ct = ValaType.VOID;
            string ct_name = "";
            if (current.kind != TokenKind.IDENTIFIER
                || !parse_type (current.text, out ct, out ct_name, current.is_escaped)
                || ct == ValaType.VOID || ct == ValaType.STRUCT || ct == ValaType.ARRAY || ct == ValaType.CLASS) {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unsupported const type at $(current.line):$(current.column)");
            }
            advance ();
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected constant name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name a constant at $(current.line):$(current.column)");
            var cname = current.text;
            advance ();
            expect (TokenKind.ASSIGN, "'='");

            var cd = new ConstDecl () {
                const_type = ct,
                type_name = ct_name,
                name = cname,
                owner_type = owner_type,
                line = cl,
                column = cc
            };
            if (ct == ValaType.INT) {
                cd.int_value = parse_const_int_expr ("const int initializer must be a constant integer expression", owner_type);
            } else if (ct == ValaType.FLOAT || ct == ValaType.DOUBLE) {
                cd.int_value = parse_signed_fp_bits (ct == ValaType.FLOAT, "const float/double initializer must be a numeric literal");
            } else if (ct == ValaType.BOOL) {
                if (is_tok_kw (current, "true")) {
                    cd.int_value = 1;
                    advance ();
                } else if (is_tok_kw (current, "false")) {
                    cd.int_value = 0;
                    advance ();
                } else {
                    cd.int_value = parse_signed_int_literal ("const bool initializer must be 'true' or 'false'");
                }
            } else if (ct == ValaType.STRING) {
                if (current.kind != TokenKind.STRING)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"const string initializer must be a string literal at $(current.line):$(current.column)");
                cd.str_value = current.text;
                advance ();
            } else if (ct == ValaType.ENUM) {
                var el = current.line;
                var ec = current.column;
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (@"expected enum member for const at $el:$ec");
                var ename = current.text;
                advance ();
                expect (TokenKind.DOT, "'.'");
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (@"expected enum member name at $(current.line):$(current.column)");
                var mname = current.text;
                advance ();
                unowned var ed = types_prog.find_enum (ename);
                unowned var mem = (ed != null && ename == ct_name) ? ed.find_member (mname) : null;
                if (mem == null)
                    throw new ParseError.UNEXPECTED_TOKEN (@"unknown enum member '$(ename).$(mname)' at $el:$ec");
                cd.int_value = mem.value;
            }
            expect (TokenKind.SEMICOLON, "';'");
            if (program.find_const (owner_type, cname) != null
                || (owner_type == "" && has_top_name (cname))) {
                throw new ParseError.DUPLICATE_FUNCTION (@"duplicate constant name '$cname' at $cl:$cc");
            }
            program.consts.add (cd);
        }

        private void parse_attributes (out string? asm_body, out int asm_line, out int asm_col,
                                       out bool compact_attr, out bool simple_type_attr,
                                       out bool arena_attr)
                throws ParseError, LexError {
            asm_body = null;
            asm_line = 0;
            asm_col = 0;
            compact_attr = false;
            simple_type_attr = false;
            arena_attr = false;
            while (current.kind == TokenKind.LBRACKET) {
                advance (); // '['
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected attribute name at $(current.line):$(current.column)");
                var attr_name = current.text;
                var al = current.line;
                var ac = current.column;
                advance ();
                if (attr_name == "Compact")
                    compact_attr = true;
                else if (attr_name == "SimpleType")
                    simple_type_attr = true;
                else if (attr_name == "Arena")
                    arena_attr = true;
                if (attr_name == "AsmBody") {
                    expect (TokenKind.LPAREN, "'('");
                    if (current.kind != TokenKind.STRING && current.kind != TokenKind.TEMPLATE_STRING)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"[AsmBody] expects a string literal at $(current.line):$(current.column)");
                    asm_body = current.text;
                    asm_line = current.line;
                    asm_col = current.column;
                    advance ();
                    expect (TokenKind.RPAREN, "')'");
                } else if (current.kind == TokenKind.LPAREN) {
                    advance ();
                    int depth = 1;
                    while (depth > 0 && current.kind != TokenKind.EOF) {
                        if (current.kind == TokenKind.LPAREN) depth++;
                        else if (current.kind == TokenKind.RPAREN) depth--;
                        advance ();
                    }
                    if (depth != 0)
                        throw new ParseError.UNEXPECTED_TOKEN (@"unterminated attribute '[$attr_name]' at $al:$ac");
                }
                expect (TokenKind.RBRACKET, "']'");
            }
        }

        private void parse_top_level () throws ParseError, LexError {
            string? asm_body = null;
            int asm_line = 0;
            int asm_col = 0;
            bool compact_attr = false;
            bool simple_type_attr = false;
            bool arena_attr = false;
            parse_attributes (out asm_body, out asm_line, out asm_col, out compact_attr, out simple_type_attr, out arena_attr);

            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected a declaration at $(current.line):$(current.column)");

            while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped && is_visibility_modifier (current.text))
                advance ();

            if (is_tok_kw (current, "using")) {
                advance ();
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected namespace name after 'using' at $(current.line):$(current.column)");
                string u_name = current.text;
                advance ();
                while (current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected identifier after '.' at $(current.line):$(current.column)");
                    u_name = @"$u_name.$(current.text)";
                    advance ();
                }
                expect (TokenKind.SEMICOLON, "';'");
                program.register_namespace (u_name);
                unit_usings.add (u_name);
                return;
            }

            if (is_tok_kw (current, "namespace")) {
                advance ();
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected namespace name at $(current.line):$(current.column)");
                string ns_name = current.text;
                advance ();
                while (current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected identifier after '.' at $(current.line):$(current.column)");
                    ns_name = @"$ns_name.$(current.text)";
                    advance ();
                }
                program.register_namespace (ns_name);
                ns_stack.add (ns_name);
                expect (TokenKind.LBRACE, "'{'");
                while (current.kind != TokenKind.RBRACE) {
                    if (current.kind == TokenKind.EOF)
                        throw new ParseError.UNEXPECTED_TOKEN ("unterminated namespace declaration");
                    parse_top_level ();
                }
                expect (TokenKind.RBRACE, "'}'");
                if (ns_stack.length > 0)
                    ns_stack.remove_index (ns_stack.length - 1);
                return;
            }

            if (is_tok_kw (current, "errordomain")) {
                parse_errordomain ();
                return;
            }

            if (is_tok_kw (current, "interface")) {
                parse_interface ();
                return;
            }

            if (is_tok_kw (current, "delegate")) {
                parse_delegate ();
                return;
            }

            if (is_tok_kw (current, "const")) {
                parse_const_decl ("");
                return;
            }

            if (is_tok_kw (current, "type")) {
                advance (); // 'type'
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected type alias name after 'type' at $(current.line):$(current.column)");
                string aname = current.text;
                advance ();
                expect (TokenKind.ASSIGN, "'='");
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected type name after '=' at $(current.line):$(current.column)");
                ValaType at;
                string at_name;
                if (!parse_type (current.text, out at, out at_name, current.is_escaped))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"unknown target type '$(current.text)' at $(current.line):$(current.column)");
                advance ();
                parse_type_suffix (ref at, ref at_name);
                expect (TokenKind.SEMICOLON, "';'");
                int prev_ai = find_type_alias (aname);
                if (prev_ai >= 0) {
                    alias_types[prev_ai] = at;
                    alias_tnames[prev_ai] = at_name;
                } else {
                    alias_names.add (aname);
                    alias_types.add (at);
                    alias_tnames.add (at_name);
                }
                return;
            }

            bool is_abstract = false;
            bool is_sealed = false;
            bool is_static = false;
            bool is_extern = false;
            bool is_async = false;
            while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                   && (current.text == "abstract" || current.text == "static"
                       || current.text == "extern" || current.text == "async"
                       || current.text == "sealed")) {
                if (current.text == "abstract") is_abstract = true;
                else if (current.text == "sealed") is_sealed = true;
                else if (current.text == "static") is_static = true;
                else if (current.text == "extern") is_extern = true;
                else is_async = true;
                advance ();
            }

            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected a declaration at $(current.line):$(current.column)");

            if (is_tok_kw (current, "class")) {
                if (is_static || is_async)
                    throw new ParseError.UNEXPECTED_TOKEN (@"top-level class cannot be 'static' or 'async' at $(current.line):$(current.column)");
                parse_class (is_abstract, is_sealed, compact_attr);
                return;
            }
            if (is_sealed) {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'sealed' is only valid on classes at $(current.line):$(current.column)");
            }
            if (is_abstract) {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'abstract' is only valid on classes at $(current.line):$(current.column)");
            }
            if (is_tok_kw (current, "enum")) {
                if (is_async)
                    throw new ParseError.UNEXPECTED_TOKEN (@"enum cannot be 'async' at $(current.line):$(current.column)");
                parse_enum ();
                return;
            }
            if (is_tok_kw (current, "struct") || is_tok_kw (current, "union")) {
                if (is_async)
                    throw new ParseError.UNEXPECTED_TOKEN (@"$(current.text) cannot be 'async' at $(current.line):$(current.column)");
                parse_struct (simple_type_attr);
                return;
            }

            skip_ownership_modifiers ();

            // `T name<T> (...)` uses `T` in the return type, so the type
            // parameters must be known before the return type is parsed.
            var saved_type_params = current_type_params;
            {
                var look = lexer.clone_state ();
                var t2 = look.next ();
                if (t2.kind == TokenKind.IDENTIFIER) {
                    var t3 = look.next ();
                    if (t3.kind == TokenKind.LT) {
                        var gens = new GenericArray<string> ();
                        foreach (var tpx in saved_type_params)
                            gens.add (tpx);
                        while (true) {
                            var tk = look.next ();
                            if (tk.kind == TokenKind.IDENTIFIER)
                                gens.add (tk.text);
                            else if (tk.kind == TokenKind.GT || tk.kind == TokenKind.SHR)
                                break;
                            else if (tk.kind == TokenKind.EOF)
                                break;
                        }
                        current_type_params = gens;
                    }
                }
            }

            ValaType decl_type = ValaType.VOID;
            string type_name = "";
            if (!parse_type (current.text, out decl_type, out type_name, current.is_escaped)) {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unknown type '$(current.text)' at $(current.line):$(current.column)");
            }

            var type_line = current.line;
            var type_column = current.column;
            advance ();
            parse_type_suffix (ref decl_type, ref type_name);

            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected a name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot be used as a name at $(current.line):$(current.column)");
            var name = current.text;
            advance ();

            if (current.kind == TokenKind.LPAREN
                || (current.kind == TokenKind.LT && current_type_params.length > saved_type_params.length)) {
                if (is_async && (is_extern || asm_body != null || name == "main"))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'async' is not valid on extern, [AsmBody], or 'main' function '$name' at $(type_line):$(type_column)");
                var f = parse_function_rest (decl_type, type_name, name, type_line, type_column, asm_body, asm_line, asm_col, is_extern);
                current_type_params = saved_type_params;
                f.is_static = is_static;
                f.is_async = is_async;
                f.is_arena = arena_attr;
                if (has_top_name (name))
                    throw new ParseError.DUPLICATE_FUNCTION (
                        @"duplicate name: $name at $(f.line):$(f.column)");
                program.functions.add (f);
                return;
            }
            if (is_async)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'async' is only valid on functions at $(type_line):$(type_column)");
            if (asm_body != null)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"[AsmBody] is only valid on functions at $asm_line:$asm_col");
            current_type_params = saved_type_params;

            if (decl_type == ValaType.VOID)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'void' is only valid for functions at $(type_line):$(type_column)");

            var g = new GlobalVar () {
                var_type = decl_type,
                var_type_name = type_name,
                name = name
            };
            g.line = type_line;
            g.column = type_column;
            if (current.kind == TokenKind.ASSIGN) {
                advance ();
                if (decl_type == ValaType.INT) {
                    g.value = parse_signed_int_literal ("a global initializer must be an integer literal");
                    g.initialized = true;
                } else if (decl_type == ValaType.FLOAT || decl_type == ValaType.DOUBLE) {
                    g.value = parse_signed_fp_bits (decl_type == ValaType.FLOAT, "a global float/double initializer must be a numeric literal");
                    g.initialized = true;
                } else if (decl_type == ValaType.BOOL) {
                    if (is_tok_kw (current, "true")) {
                        g.value = 1;
                        advance ();
                    } else if (is_tok_kw (current, "false")) {
                        g.value = 0;
                        advance ();
                    } else {
                        g.value = parse_signed_int_literal ("a global bool initializer must be 'true', 'false', or an integer literal");
                    }
                    g.initialized = true;
                } else if (decl_type == ValaType.ENUM) {
                    if (current.kind == TokenKind.IDENTIFIER || (current.text == "void" && !current.is_escaped)) {
                        var el = current.line;
                        var ec = current.column;
                        var ename = current.text;
                        advance ();
                        expect (TokenKind.DOT, "'.'");
                        if (current.kind != TokenKind.IDENTIFIER)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected enum member name at $(current.line):$(current.column)");
                        var mname = current.text;
                        advance ();
                        if (ename != type_name)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected enum '$(type_name)', got '$(ename)' at $el:$ec");
                        unowned var ed = types_prog.find_enum (ename);
                        unowned var mem = (ed != null) ? ed.find_member (mname) : null;
                        if (mem == null)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"unknown enum member '$(ename).$(mname)' at $el:$ec");
                        g.value = mem.value;
                    } else {
                        g.value = parse_signed_int_literal ("a global enum initializer must be an enum member or integer literal");
                    }
                    g.initialized = true;
                } else if (decl_type == ValaType.STRING) {
                    if (current.kind != TokenKind.STRING)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"a global string initializer must be a string literal at $(current.line):$(current.column)");
                    g.str_value = current.text;
                    g.initialized = true;
                    advance ();
                } else if (decl_type == ValaType.ARRAY || decl_type == ValaType.CLASS
                           || decl_type == ValaType.INTERFACE || decl_type == ValaType.STRUCT) {
                    g.init_expr = parse_expr ();
                } else {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"global $(decl_type.label ()) initializers are not supported at $(current.line):$(current.column)");
                }
            }
            expect (TokenKind.SEMICOLON, "';'");
            if (has_top_name (name))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $(g.line):$(g.column)");
            program.globals.add (g);
        }

        private int64 parse_const_atom (string msg, string owner_type = "") throws ParseError, LexError {
            if (is_tok_kw (current, "sizeof")) {
                advance ();
                expect (TokenKind.LPAREN, "'('");
                ValaType tt = ValaType.VOID;
                string tn = "";
                if (!parse_type_with_ns (out tt, out tn))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected a type in constant sizeof at $(current.line):$(current.column)");
                parse_type_suffix (ref tt, ref tn);
                expect (TokenKind.RPAREN, "')'");
                return types_prog.sizeof_bytes (tt, tn);
            }
            if (current.kind == TokenKind.LPAREN) {
                advance ();
                var inner = parse_const_int_expr (msg, owner_type);
                expect (TokenKind.RPAREN, "')'");
                return inner;
            }
            if (current.kind == TokenKind.IDENTIFIER && !is_tok_reserved (current)) {
                var id_l = current.line;
                var id_c = current.column;
                var name = current.text;
                advance ();
                if (current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (@"expected member name after '.' at $(current.line):$(current.column)");
                    var mem = current.text;
                    advance ();
                    unowned var cdecl = program.find_const (name, mem);
                    if (cdecl != null && (cdecl.const_type == ValaType.INT || cdecl.const_type == ValaType.ENUM))
                        return cdecl.int_value;
                    unowned var ed = types_prog.find_enum (name);
                    unowned var em = (ed != null) ? ed.find_member (mem) : null;
                    if (em != null)
                        return em.value;
                    throw new ParseError.UNEXPECTED_TOKEN (@"unknown constant '$(name).$(mem)' at $id_l:$id_c");
                }
                unowned var cdecl = program.find_const (owner_type, name);
                if (cdecl == null && owner_type != "")
                    cdecl = program.find_const ("", name);
                if (cdecl != null && (cdecl.const_type == ValaType.INT || cdecl.const_type == ValaType.ENUM))
                    return cdecl.int_value;
                throw new ParseError.UNEXPECTED_TOKEN (@"unknown constant '$(name)' at $id_l:$id_c");
            }
            if (current.kind != TokenKind.INTEGER)
                throw new ParseError.UNEXPECTED_TOKEN (@"$msg at $(current.line):$(current.column)");
            var v = int64.parse (current.text);
            advance ();
            return v;
        }

        private int64 parse_const_unary (string msg, string owner_type = "") throws ParseError, LexError {
            if (current.kind == TokenKind.MINUS) {
                advance ();
                return -parse_const_unary (msg, owner_type);
            }
            if (current.kind == TokenKind.PLUS) {
                advance ();
                return parse_const_unary (msg, owner_type);
            }
            if (current.kind == TokenKind.TILDE) {
                advance ();
                return ~parse_const_unary (msg, owner_type);
            }
            return parse_const_atom (msg, owner_type);
        }

        private int64 parse_const_mul (string msg, string owner_type = "") throws ParseError, LexError {
            var v = parse_const_unary (msg, owner_type);
            while (current.kind == TokenKind.STAR || current.kind == TokenKind.SLASH || current.kind == TokenKind.PERCENT) {
                var k = current.kind;
                var op_l = current.line;
                var op_c = current.column;
                advance ();
                var rhs = parse_const_unary (msg, owner_type);
                if (k == TokenKind.STAR) {
                    v = v * rhs;
                } else {
                    if (rhs == 0)
                        throw new ParseError.UNEXPECTED_TOKEN (@"division by zero in constant expression at $op_l:$op_c");
                    if (v == int64.MIN && rhs == -1)
                        throw new ParseError.UNEXPECTED_TOKEN (@"signed overflow in constant division at $op_l:$op_c");
                    v = (k == TokenKind.SLASH) ? (v / rhs) : (v % rhs);
                }
            }
            return v;
        }

        private int64 parse_const_add (string msg, string owner_type = "") throws ParseError, LexError {
            var v = parse_const_mul (msg, owner_type);
            while (current.kind == TokenKind.PLUS || current.kind == TokenKind.MINUS) {
                var k = current.kind;
                advance ();
                var rhs = parse_const_mul (msg, owner_type);
                v = (k == TokenKind.PLUS) ? (v + rhs) : (v - rhs);
            }
            return v;
        }

        private int64 parse_const_shift (string msg, string owner_type = "") throws ParseError, LexError {
            var v = parse_const_add (msg, owner_type);
            while (current.kind == TokenKind.SHL || current.kind == TokenKind.SHR) {
                var k = current.kind;
                var op_l = current.line;
                var op_c = current.column;
                advance ();
                var rhs = parse_const_add (msg, owner_type);
                if (rhs < 0 || rhs >= 64)
                    throw new ParseError.UNEXPECTED_TOKEN (@"shift count out of range in constant expression at $op_l:$op_c");
                v = (k == TokenKind.SHL) ? (v << rhs) : (v >> rhs);
            }
            return v;
        }

        private int64 parse_const_and (string msg, string owner_type = "") throws ParseError, LexError {
            var v = parse_const_shift (msg, owner_type);
            while (current.kind == TokenKind.AMP) {
                advance ();
                var rhs = parse_const_shift (msg, owner_type);
                v = v & rhs;
            }
            return v;
        }

        private int64 parse_const_xor (string msg, string owner_type = "") throws ParseError, LexError {
            var v = parse_const_and (msg, owner_type);
            while (current.kind == TokenKind.CARET) {
                advance ();
                var rhs = parse_const_and (msg, owner_type);
                v = v ^ rhs;
            }
            return v;
        }

        private int64 parse_const_int_expr (string msg, string owner_type = "") throws ParseError, LexError {
            var v = parse_const_xor (msg, owner_type);
            while (current.kind == TokenKind.PIPE) {
                advance ();
                var rhs = parse_const_xor (msg, owner_type);
                v = v | rhs;
            }
            return v;
        }

        private int64 parse_signed_int_literal (string msg) throws ParseError, LexError {
            bool negated = false;
            if (current.kind == TokenKind.MINUS) {
                negated = true;
                advance ();
            }
            if (current.kind != TokenKind.INTEGER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"$msg at $(current.line):$(current.column)");
            var v = int64.parse (current.text);
            if (negated)
                v = -v;
            advance ();
            return v;
        }

        private int64 parse_signed_fp_bits (bool as_f32, string msg) throws ParseError, LexError {
            bool negated = false;
            if (current.kind == TokenKind.MINUS) {
                negated = true;
                advance ();
            }
            if (current.kind != TokenKind.FLOAT && current.kind != TokenKind.INTEGER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"$msg at $(current.line):$(current.column)");
            var raw = current.text;
            if (as_f32 && !raw.has_suffix ("f") && !raw.has_suffix ("F"))
                raw = raw + "f";
            else if (!as_f32 && (raw.has_suffix ("f") || raw.has_suffix ("F")))
                raw = raw.substring (0, raw.length - 1);
            bool unused = false;
            uint64 bits = Ieee754.parse_bits (raw, out unused);
            if (negated)
                bits ^= as_f32 ? (uint64) 0x80000000 : (uint64) 0x8000000000000000;
            advance ();
            return (int64) bits;
        }

        private void parse_throws_clause (GenericArray<string> dst) throws ParseError, LexError {
            if (is_tok_kw (current, "throws")) {
                advance ();
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected error domain name after 'throws' at $(current.line):$(current.column)");
                    dst.add (current.text);
                    advance ();
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
            }
        }

        private void parse_interface () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'interface'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected interface name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name an interface at $(current.line):$(current.column)");
            var name = current.text;
            advance ();
            if (has_other_top_name (name, "interface"))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $l:$c");
            InterfaceDecl? existing = null;
            foreach (var itf in program.interfaces) {
                if (itf.name == name) {
                    if (itf.is_defined)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate name: $name at $l:$c");
                    existing = itf;
                    break;
                }
            }
            if (existing == null) {
                existing = new InterfaceDecl () {
                    name = name,
                    iface_id = InterfaceDecl.compute_iface_id (name)
                };
                program.interfaces.add (existing);
            }
            existing.is_defined = true;
            existing.line = l;
            existing.column = c;

            var iface_saved_tp = current_type_params;
            if (current.kind == TokenKind.LT) {
                advance ();
                var itp = new GenericArray<string> ();
                foreach (var tp in iface_saved_tp)
                    itp.add (tp);
                bool add_tp = (existing.type_params.length == 0);
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected type parameter name in interface '$name' at $(current.line):$(current.column)");
                    if (add_tp)
                        existing.type_params.add (current.text);
                    itp.add (current.text);
                    advance ();
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                consume_gt ();
                existing.is_generic_template = true;
                current_type_params = itp;
            }

            if (current.kind == TokenKind.COLON) {
                advance ();
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected prerequisite interface name after ':' at $(current.line):$(current.column)");
                    string pname = current.text;
                    advance ();
                    if (pname != "Object" || types_prog.find_interface ("Object") != null) {
                        if (current.kind == TokenKind.LT) {
                            ValaType pt = ValaType.INTERFACE;
                            parse_generic_type_args (ref pt, ref pname);
                        }
                        existing.prereq_names.add (pname);
                    }
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
            }

            expect (TokenKind.LBRACE, "'{'");
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN (@"unterminated interface '$name'");
                while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped && is_visibility_modifier (current.text))
                    advance ();
                bool is_abs = false;
                bool is_virt = false;
                bool is_static_if = false;
                bool is_signal_if = false;
                while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                       && (current.text == "abstract" || current.text == "virtual"
                           || current.text == "static" || current.text == "signal")) {
                    if (current.text == "abstract") is_abs = true;
                    else if (current.text == "static") is_static_if = true;
                    else if (current.text == "signal") is_signal_if = true;
                    else is_virt = true;
                    advance ();
                }

                // `signal void name (params);` lowers to a SignalDecl plus the
                // abstract accessor that tells each implementor its slot.
                if (is_signal_if) {
                    if (is_abs || is_static_if)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"interface signal is neither abstract nor static at $(current.line):$(current.column)");
                    ValaType sret = ValaType.VOID;
                    string sret_name = "";
                    if (current.kind != TokenKind.IDENTIFIER || !parse_type (current.text, out sret, out sret_name, current.is_escaped))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected signal return type in interface '$name' at $(current.line):$(current.column)");
                    var sl = current.line;
                    var sc = current.column;
                    advance ();
                    parse_type_suffix (ref sret, ref sret_name);
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected signal name in interface '$name' at $(current.line):$(current.column)");
                    var sname = current.text;
                    advance ();
                    if (existing.find_own_signal (sname) != null || existing.find_own_method (sname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate signal '$sname' in interface '$name' at $sl:$sc");
                    var plist = parse_param_list ();
                    expect (TokenKind.SEMICOLON, "';'");
                    var del_name = @"__sig_del_$(name)_$(sname)";
                    var sd = new SignalDecl () {
                        name = sname,
                        return_type = sret,
                        return_type_name = sret_name,
                        is_virtual = is_virt,
                        handler_delegate_name = del_name,
                        iface_name = name,
                        line = sl,
                        column = sc
                    };
                    foreach (var p in plist)
                        sd.params.add (p);
                    var dd = new DelegateDecl () {
                        name = del_name,
                        return_type = sret,
                        return_type_name = sret_name,
                        line = sl,
                        column = sc
                    };
                    dd.params.add (new Param () {
                        param_type = ValaType.INTERFACE,
                        type_name = name,
                        name = "sender",
                        line = sl,
                        column = sc
                    });
                    foreach (var p in plist)
                        dd.params.add (p);
                    program.delegates.add (dd);
                    existing.signals.add (sd);
                    var acc = new Function () {
                        name = "__sigslot_" + sname,
                        method_name = "__sigslot_" + sname,
                        return_type = ValaType.INT,
                        has_body = false,
                        is_abstract = true,
                        owner_class = name,
                        line = sl,
                        column = sc
                    };
                    existing.methods.add (acc);
                    continue;
                }
                parse_ownership_weak ();
                var ml = current.line;
                var mc = current.column;
                ValaType rt = ValaType.VOID;
                string rt_name = "";
                if (!parse_type_with_ns (out rt, out rt_name))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"unknown member type '$(current.text)' in interface '$name' at $ml:$mc");
                parse_type_suffix (ref rt, ref rt_name);
                if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected member name in interface '$name' at $(current.line):$(current.column)");
                var mname = current.text;
                var mem_l = current.line;
                var mem_c = current.column;
                advance ();

                if (current.kind == TokenKind.LPAREN) {
                    var plist = parse_param_list ();
                    var mfn = new Function () {
                        name = mname,
                        method_name = mname,
                        return_type = rt,
                        return_type_name = rt_name,
                        is_abstract = is_abs,
                        is_virtual = is_virt,
                        is_static = is_static_if,
                        owner_class = name,
                        line = mem_l,
                        column = mem_c
                    };
                    foreach (var p in plist)
                        mfn.params.add (p);
                    parse_throws_clause (mfn.throws_domains);
                    if (current.kind == TokenKind.SEMICOLON) {
                        advance ();
                        if (is_static_if)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"static interface method '$mname' requires a body at $mem_l:$mem_c");
                        mfn.has_body = false;
                        mfn.is_abstract = true;
                    } else if (current.kind == TokenKind.LBRACE) {
                        if (is_abs)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"abstract interface method '$mname' cannot have a body at $mem_l:$mem_c");
                        parse_block_into (mfn.body);
                        mfn.has_body = true;
                        if (!is_static_if)
                            mfn.is_virtual = true;
                    } else {
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected ';' or '{' after interface method '$mname' at $(current.line):$(current.column)");
                    }
                    if (existing.find_own_method (mname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate method '$mname' in interface '$name' at $mem_l:$mem_c");
                    existing.methods.add (mfn);
                } else if (current.kind == TokenKind.LBRACE) {
                    bool use_plain = false;
                    Expr? def_init = null;
                    var syn = new GenericArray<Function> ();
                    bool add_back = false;
                    parse_property_block (name, true, is_virt, false, !is_virt || is_abs,
                                          rt, rt_name, mname, mem_l, mem_c,
                                          out use_plain, out def_init, syn, out add_back);
                    foreach (var sm in syn) {
                        sm.method_name = sm.name;
                        sm.has_body = !sm.is_abstract;
                        existing.methods.add (sm);
                    }
                } else {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected '(' or '{' in interface member '$mname' at $(current.line):$(current.column)");
                }
            }
            expect (TokenKind.RBRACE, "'}'");
            current_type_params = iface_saved_tp;
        }

        private void parse_delegate () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'delegate'
            skip_ownership_modifiers ();
            ValaType rt = ValaType.VOID;
            string rt_name = "";
            string deferred_rt = "";
            bool deferred_rt_q = false;
            if (current.kind == TokenKind.IDENTIFIER && parse_type (current.text, out rt, out rt_name, current.is_escaped)) {
                advance ();
                parse_type_suffix (ref rt, ref rt_name);
            } else if (current.kind == TokenKind.IDENTIFIER && !is_tok_reserved (current)) {
                deferred_rt = current.text;
                advance ();
                if (current.kind == TokenKind.QUESTION) {
                    deferred_rt_q = true;
                    advance ();
                }
            } else {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected return type in delegate declaration at $(current.line):$(current.column)");
            }
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected delegate name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name a delegate at $(current.line):$(current.column)");
            var name = current.text;
            advance ();
            var parsed_tparams = new GenericArray<string> ();
            if (current.kind == TokenKind.LT) {
                advance ();
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected type parameter name in delegate '$name' at $(current.line):$(current.column)");
                    foreach (var prev_tp in parsed_tparams) {
                        if (prev_tp == current.text)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"duplicate type parameter '$(current.text)' in delegate '$name' at $(current.line):$(current.column)");
                    }
                    parsed_tparams.add (current.text);
                    advance ();
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                expect (TokenKind.GT, "'>'");
            }
            if (deferred_rt != "") {
                bool found_tp = false;
                for (int i = 0; i < parsed_tparams.length; i++) {
                    if (parsed_tparams[i] == deferred_rt) {
                        found_tp = true;
                        break;
                    }
                }
                if (!found_tp)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected return type in delegate declaration at $l:$c");
                rt = ValaType.TYPE_PARAM;
                rt_name = deferred_rt_q ? (deferred_rt + "?") : deferred_rt;
            }
            if (has_other_top_name (name, "delegate"))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $l:$c");
            DelegateDecl? existing = null;
            foreach (var d in program.delegates) {
                if (d.name == name) {
                    if (d.is_defined)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate name: $name at $l:$c");
                    existing = d;
                    break;
                }
            }
            if (existing == null) {
                existing = new DelegateDecl () { name = name };
                program.delegates.add (existing);
            }
            existing.is_defined = true;
            existing.return_type = rt;
            existing.return_type_name = rt_name;
            existing.line = l;
            existing.column = c;
            var saved_tp = new GenericArray<string> ();
            for (int i = 0; i < current_type_params.length; i++)
                saved_tp.add (current_type_params[i]);
            if (parsed_tparams.length > 0) {
                existing.is_generic_template = true;
                bool add_tp = (existing.type_params.length == 0);
                foreach (var tp in parsed_tparams) {
                    if (add_tp)
                        existing.type_params.add (tp);
                    current_type_params.add (tp);
                }
            }
            var plist = parse_param_list ();
            foreach (var p in plist)
                existing.params.add (p);
            parse_throws_clause (existing.throws_domains);
            current_type_params = saved_tp;
            expect (TokenKind.SEMICOLON, "';'");
            program.register_delegate_struct (name);
        }

        private void parse_errordomain () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'errordomain'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected errordomain name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name an errordomain at $(current.line):$(current.column)");
            var name = current.text;
            advance ();
            if (has_other_top_name (name, "errordomain"))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $l:$c");
            ErrorDomainDecl? existing = null;
            foreach (var d in program.error_domains) {
                if (d.name == name) {
                    if (d.is_defined)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate name: $name at $l:$c");
                    existing = d;
                    break;
                }
            }
            if (existing == null) {
                existing = new ErrorDomainDecl () {
                    name = name,
                    domain_id = program.error_domains.length + 1
                };
                program.error_domains.add (existing);
            }
            existing.is_defined = true;
            existing.line = l;
            existing.column = c;

            expect (TokenKind.LBRACE, "'{'");
            int64 next_val = 0;
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected error code name at $(current.line):$(current.column)");
                if (is_tok_reserved (current))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword and cannot name an error code at $(current.line):$(current.column)");
                var cname = current.text;
                var cl = current.line;
                var cc = current.column;
                advance ();
                if (existing.find_code (cname) != null)
                    throw new ParseError.DUPLICATE_FUNCTION (
                        @"duplicate error code '$cname' in '$name' at $cl:$cc");
                if (current.kind == TokenKind.ASSIGN) {
                    advance ();
                    next_val = parse_signed_int_literal ("error code value must be an integer literal");
                }
                existing.codes.add (new EnumMember () { name = cname, value = next_val });
                next_val++;
                if (current.kind == TokenKind.COMMA) {
                    advance ();
                    continue;
                }
                break;
            }
            if (existing.codes.length == 0)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"errordomain '$name' must have at least one code at $(current.line):$(current.column)");
            expect (TokenKind.RBRACE, "'}'");
        }

        private int64 eval_enum_const_expr (Expr e, EnumDecl cur_enum) throws ParseError {
            if (e is IntLiteral)
                return ((IntLiteral) e).value;
            if (e is BoolLiteral)
                return ((BoolLiteral) e).value ? 1 : 0;
            if (e is VarRef) {
                var vname = ((VarRef) e).name;
                unowned var em = cur_enum.find_member (vname);
                if (em != null)
                    return em.value;
                foreach (var c in program.consts) {
                    if (c.name == vname && (c.const_type == ValaType.INT || c.const_type == ValaType.BOOL))
                        return c.int_value;
                }
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unknown constant '$vname' in enum initializer at $(e.line):$(e.column)");
            }
            if (e is MemberAccessExpr) {
                var ma = (MemberAccessExpr) e;
                if (ma.target is VarRef) {
                    var ename = ((VarRef) ma.target).name;
                    if (ename == cur_enum.name) {
                        unowned var em = cur_enum.find_member (ma.member);
                        if (em != null)
                            return em.value;
                    }
                    foreach (var en in program.enums) {
                        if (en.name == ename) {
                            unowned var em = en.find_member (ma.member);
                            if (em != null)
                                return em.value;
                        }
                    }
                }
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unknown enum member '$(ma.member)' in enum initializer at $(e.line):$(e.column)");
            }
            if (e is UnaryExpr) {
                var u = (UnaryExpr) e;
                int64 v = eval_enum_const_expr (u.operand, cur_enum);
                if (u.op == "-") return -v;
                if (u.op == "+") return v;
                if (u.op == "~") return ~v;
                if (u.op == "!") return (v == 0) ? 1 : 0;
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unsupported unary operator '$(u.op)' in enum initializer at $(e.line):$(e.column)");
            }
            if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                int64 l = eval_enum_const_expr (b.left, cur_enum);
                int64 r = eval_enum_const_expr (b.right, cur_enum);
                switch (b.op) {
                    case "<<":
                        if (r < 0 || r >= 64)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"shift count out of range in enum initializer at $(e.line):$(e.column)");
                        return l << r;
                    case ">>":
                        if (r < 0 || r >= 64)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"shift count out of range in enum initializer at $(e.line):$(e.column)");
                        return l >> r;
                    case "|":  return l | r;
                    case "&":  return l & r;
                    case "^":  return l ^ r;
                    case "+":  return l + r;
                    case "-":  return l - r;
                    case "*":  return l * r;
                    case "/":
                        if (r == 0 || (l == int64.MIN && r == -1))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"invalid division in enum initializer at $(e.line):$(e.column)");
                        return l / r;
                    case "%":
                        if (r == 0 || (l == int64.MIN && r == -1))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"invalid modulo in enum initializer at $(e.line):$(e.column)");
                        return l % r;
                    default:
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"unsupported operator '$(b.op)' in enum initializer at $(e.line):$(e.column)");
                }
            }
            throw new ParseError.UNEXPECTED_TOKEN (
                @"enum member value must be a constant integer expression at $(e.line):$(e.column)");
        }

        private void parse_enum () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'enum'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected enum name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name an enum at $(current.line):$(current.column)");
            var name = current.text;
            advance ();
            if (has_other_top_name (name, "enum"))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $l:$c");
            EnumDecl? ed_existing = null;
            foreach (var e in program.enums) {
                if (e.name == name) {
                    if (e.is_defined)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate name: $name at $l:$c");
                    ed_existing = e;
                    break;
                }
            }
            if (ed_existing == null) {
                ed_existing = new EnumDecl () { name = name };
                program.enums.add (ed_existing);
            }
            ed_existing.is_defined = true;
            ed_existing.line = l;
            ed_existing.column = c;
            var ed = ed_existing;

            expect (TokenKind.LBRACE, "'{'");
            int64 next_val = 0;
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected enum member name at $(current.line):$(current.column)");
                if (is_tok_reserved (current))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword and cannot name an enum member at $(current.line):$(current.column)");
                var mname = current.text;
                var ml = current.line;
                var mc = current.column;
                advance ();
                if (ed.find_member (mname) != null)
                    throw new ParseError.DUPLICATE_FUNCTION (
                        @"duplicate enum member '$mname' at $ml:$mc");
                if (current.kind == TokenKind.ASSIGN) {
                    advance ();
                    next_val = eval_enum_const_expr (parse_expr (), (!) ed);
                }
                ed.members.add (new EnumMember () { name = mname, value = next_val });
                next_val++;
                if (current.kind == TokenKind.COMMA) {
                    advance ();
                    continue;
                }
                break;
            }
            if (ed.members.length == 0)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"enum '$name' must have at least one member at $(current.line):$(current.column)");

            if (current.kind == TokenKind.SEMICOLON) {
                advance ();
                while (current.kind != TokenKind.RBRACE) {
                    if (current.kind == TokenKind.EOF)
                        throw new ParseError.UNEXPECTED_TOKEN (@"unterminated enum '$name'");
                    while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped && is_visibility_modifier (current.text))
                        advance ();
                    bool is_static = false;
                    if (is_tok_kw (current, "static")) {
                        is_static = true;
                        advance ();
                    }
                    parse_ownership_weak ();
                    var ml = current.line;
                    var mc = current.column;
                    ValaType rt = ValaType.VOID;
                    string rt_name = "";
                    if (current.kind != TokenKind.IDENTIFIER || !parse_type (current.text, out rt, out rt_name, current.is_escaped))
                        throw new ParseError.UNEXPECTED_TOKEN (@"expected method return type in enum '$name' at $ml:$mc");
                    advance ();
                    parse_type_suffix (ref rt, ref rt_name);
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (@"expected method name in enum '$name' at $(current.line):$(current.column)");
                    var mname = current.text;
                    advance ();
                    var plist = parse_param_list ();
                    var mfn = new Function () {
                        name = mname,
                        return_type = rt,
                        return_type_name = rt_name,
                        is_static = is_static,
                        owner_class = ed.name,
                        line = ml,
                        column = mc
                    };
                    parse_throws_clause (mfn.throws_domains);
                    foreach (var p in plist)
                        mfn.params.add (p);
                    parse_block_into (mfn.body);
                    if (ed.find_method (mname) != null || ed.find_member (mname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (@"duplicate method '$mname' in enum '$name' at $ml:$mc");
                    ed.methods.add (mfn);
                }
            }
            expect (TokenKind.RBRACE, "'}'");
        }

        private void parse_property_block (
            string owner_name, bool is_class, bool is_virtual, bool is_override, bool is_abstract_m,
            ValaType ft, string ft_name, string mname, int mem_l, int mem_c,
            out bool use_plain_field, out Expr? default_init,
            GenericArray<Function> syn_methods, out bool add_backing_field
        ) throws ParseError, LexError {
            default_init = null;
            add_backing_field = false;
            expect (TokenKind.LBRACE, "'{'");

            bool has_get = false;
            bool has_set = false;
            bool custom_get = false;
            bool custom_set = false;
            var get_body = new GenericArray<Statement> ();
            var set_body = new GenericArray<Statement> ();

            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN (@"unterminated property '$mname' at $mem_l:$mem_c");
                while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped && is_visibility_modifier (current.text))
                    advance ();
                parse_ownership_weak ();
                if (is_tok_kw (current, "default")) {
                    if (!is_class)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"'default' initializer is not supported in struct property '$mname' at $(current.line):$(current.column)");
                    advance ();
                    expect (TokenKind.ASSIGN, "'='");
                    default_init = parse_expr ();
                    expect (TokenKind.SEMICOLON, "';'");
                } else if (is_tok_kw (current, "get")) {
                    if (has_get)
                        throw new ParseError.UNEXPECTED_TOKEN (@"duplicate 'get' in property '$mname' at $(current.line):$(current.column)");
                    has_get = true;
                    advance ();
                    if (current.kind == TokenKind.LBRACE) {
                        custom_get = true;
                        parse_block_into (get_body);
                    } else {
                        expect (TokenKind.SEMICOLON, "';'");
                    }
                } else if (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                           && (current.text == "set" || current.text == "construct")) {
                    if (has_set)
                        throw new ParseError.UNEXPECTED_TOKEN (@"duplicate 'set' in property '$mname' at $(current.line):$(current.column)");
                    has_set = true;
                    advance ();
                    if (current.kind == TokenKind.LBRACE) {
                        custom_set = true;
                        parse_block_into (set_body);
                    } else {
                        expect (TokenKind.SEMICOLON, "';'");
                    }
                } else {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected 'get', 'set', or 'default' in property '$mname' at $(current.line):$(current.column)");
                }
            }
            expect (TokenKind.RBRACE, "'}'");
            if (!has_get && !has_set)
                throw new ParseError.UNEXPECTED_TOKEN (@"property '$mname' must declare 'get' or 'set' at $mem_l:$mem_c");
            if (is_abstract_m && (custom_get || custom_set))
                throw new ParseError.UNEXPECTED_TOKEN (@"abstract property '$mname' cannot have accessor bodies at $mem_l:$mem_c");

            use_plain_field = !custom_get && !custom_set && !is_virtual && !is_override && !is_abstract_m;
            if (use_plain_field)
                return;

            string back_name = @"#prop_$(mname)";
            if (!is_abstract_m && ((has_get && !custom_get) || (has_set && !custom_set)))
                add_backing_field = true;

            if (has_get) {
                var gf = new Function () {
                    name = @"get_$(mname)",
                    return_type = ft,
                    return_type_name = ft_name,
                    is_virtual = is_virtual,
                    is_override = is_override,
                    is_abstract = is_abstract_m,
                    owner_class = owner_name,
                    line = mem_l,
                    column = mem_c
                };
                if (custom_get) {
                    foreach (var st in get_body)
                        gf.body.add (st);
                } else if (!is_abstract_m) {
                    var rs = new ReturnStatement () {
                        value = new VarRef () { name = back_name, line = mem_l, column = mem_c },
                        line = mem_l,
                        column = mem_c
                    };
                    gf.body.add (rs);
                }
                syn_methods.add (gf);
            }
            if (has_set) {
                var sf = new Function () {
                    name = @"set_$(mname)",
                    return_type = ValaType.VOID,
                    is_virtual = is_virtual,
                    is_override = is_override,
                    is_abstract = is_abstract_m,
                    owner_class = owner_name,
                    line = mem_l,
                    column = mem_c
                };
                sf.params.add (new Param () {
                    param_type = ft,
                    type_name = ft_name,
                    name = "value",
                    line = mem_l,
                    column = mem_c
                });
                if (custom_set) {
                    foreach (var st in set_body)
                        sf.body.add (st);
                } else if (!is_abstract_m) {
                    var asg = new AssignStatement () {
                        name = back_name,
                        value = new VarRef () { name = "value", line = mem_l, column = mem_c },
                        line = mem_l,
                        column = mem_c
                    };
                    sf.body.add (asg);
                }
                syn_methods.add (sf);
            }
        }

        private void parse_struct (bool is_simple_type = false) throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            bool is_union_kw = is_tok_kw (current, "union");
            advance (); // 'struct' or 'union'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected struct name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name a struct at $(current.line):$(current.column)");
            var name = current.text;
            advance ();
            if (has_other_top_name (name, "struct"))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $l:$c");
            StructDecl? sd_existing = null;
            foreach (var s in program.structs) {
                if (s.name == name) {
                    if (s.is_defined)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate name: $name at $l:$c");
                    sd_existing = s;
                    break;
                }
            }
            if (sd_existing == null) {
                sd_existing = new StructDecl () { name = name, is_union = is_union_kw, is_simple_type = is_simple_type };
                program.structs.add (sd_existing);
            } else {
                if (is_union_kw)
                    sd_existing.is_union = true;
                if (is_simple_type)
                    sd_existing.is_simple_type = true;
            }
            if (current.kind == TokenKind.LT) {
                advance ();
                while (sd_existing.type_params.length > 0)
                    sd_existing.type_params.remove_index (sd_existing.type_params.length - 1);
                sd_existing.is_generic_template = true;
                current_type_params = new GenericArray<string> ();
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected type parameter name in struct '$name' at $(current.line):$(current.column)");
                    sd_existing.type_params.add (current.text);
                    current_type_params.add (current.text);
                    advance ();
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                expect (TokenKind.GT, "'>'");
            }
            sd_existing.is_defined = true;
            sd_existing.line = l;
            sd_existing.column = c;
            var sd = sd_existing;
            expect (TokenKind.LBRACE, "'{'");
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN ("unterminated struct declaration");
                while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped && is_visibility_modifier (current.text))
                    advance ();
                if (is_tok_kw (current, "const")) {
                    parse_const_decl (sd.name);
                    continue;
                }
                bool is_static = false;
                if (is_tok_kw (current, "static")) {
                    is_static = true;
                    advance ();
                }
                parse_ownership_weak ();
                ValaType ft = ValaType.VOID;
                string ft_name = "";
                if (current.kind != TokenKind.IDENTIFIER
                    || !parse_type (current.text, out ft, out ft_name, current.is_escaped)) {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected field or method type in struct '$name' at $(current.line):$(current.column)");
                }
                var fl = current.line;
                var fc = current.column;
                advance ();
                parse_type_suffix (ref ft, ref ft_name);
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected member name at $(current.line):$(current.column)");
                if (is_tok_reserved (current))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword and cannot name a member at $(current.line):$(current.column)");
                var fname = current.text;
                advance ();
                if (current.kind == TokenKind.LPAREN) {
                    var plist = parse_param_list ();
                    var mfn = new Function () {
                        name = fname,
                        return_type = ft,
                        return_type_name = ft_name,
                        is_static = is_static,
                        owner_class = sd.name,
                        line = fl,
                        column = fc
                    };
                    parse_throws_clause (mfn.throws_domains);
                    foreach (var p in plist)
                        mfn.params.add (p);
                    parse_block_into (mfn.body);
                    if (sd.find_method (fname) != null || sd.find_field (fname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (@"duplicate member '$fname' in struct '$name' at $fl:$fc");
                    sd.methods.add (mfn);
                } else if (current.kind == TokenKind.LBRACE) {
                    if (is_static || ft == ValaType.VOID)
                        throw new ParseError.UNEXPECTED_TOKEN (@"invalid property '$fname' in struct '$name' at $fl:$fc");
                    if (sd.find_field (fname) != null || sd.find_method (fname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate member '$fname' in struct '$name' at $fl:$fc");
                    bool use_plain = false;
                    Expr? dummy_def = null;
                    var syn = new GenericArray<Function> ();
                    bool add_back = false;
                    parse_property_block (sd.name, false, false, false, false,
                                          ft, ft_name, fname, fl, fc,
                                          out use_plain, out dummy_def, syn, out add_back);
                    if (use_plain) {
                        sd.fields.add (new StructField () {
                            field_type = ft,
                            type_name = ft_name,
                            name = fname,
                            line = fl,
                            column = fc
                        });
                    } else {
                        if (add_back) {
                            sd.fields.add (new StructField () {
                                field_type = ft,
                                type_name = ft_name,
                                name = @"#prop_$(fname)",
                                line = fl,
                                column = fc
                            });
                        }
                        foreach (var sm in syn)
                            sd.methods.add (sm);
                    }
                } else {
                    if (is_static || ft == ValaType.VOID)
                        throw new ParseError.UNEXPECTED_TOKEN (@"invalid field '$fname' in struct '$name' at $fl:$fc");
                    if (sd.find_field (fname) != null || sd.find_method (fname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate field '$fname' in struct '$name' at $fl:$fc");
                    expect (TokenKind.SEMICOLON, "';'");
                    sd.fields.add (new StructField () {
                        field_type = ft,
                        type_name = ft_name,
                        name = fname,
                        line = fl,
                        column = fc
                    });
                }
            }
            expect (TokenKind.RBRACE, "'}'");
            current_type_params = new GenericArray<string> ();
        }

        private void parse_arg_list (GenericArray<Expr> dst) throws ParseError, LexError {
            if (current.kind != TokenKind.RPAREN) {
                while (true) {
                    bool is_out = false;
                    if (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                        && (current.text == "ref" || current.text == "out")) {
                        is_out = (current.text == "out");
                        advance ();
                    }
                    var arg_e = parse_expr ();
                    if (is_out)
                        arg_e.is_out_arg = true;
                    dst.add (arg_e);
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
            }
        }

        private GenericArray<Param> parse_param_list () throws ParseError, LexError {
            var plist = new GenericArray<Param> ();
            expect (TokenKind.LPAREN, "'('");
            if (current.kind != TokenKind.RPAREN) {
                while (true) {
                    if (current.kind == TokenKind.ELLIPSIS) {
                        var vl = current.line;
                        var vc = current.column;
                        advance ();
                        var vp = new Param () {
                            param_type = ValaType.ARRAY,
                            type_name = "uint64",
                            name = "__planc_va_list",
                            line = vl,
                            column = vc
                        };
                        plist.add (vp);
                        break;
                    }
                    bool is_ref = false;
                    bool is_out = false;
                    if (is_tok_kw (current, "ref")) {
                        is_ref = true;
                        advance ();
                    } else if (is_tok_kw (current, "out")) {
                        is_out = true;
                        advance ();
                    }
                    parse_ownership_weak ();
                    ValaType pt = ValaType.VOID;
                    string pt_name = "";
                    if (!parse_type_with_ns (out pt, out pt_name) || pt == ValaType.VOID) {
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected a parameter type in parameter list at $(current.line):$(current.column)");
                    }
                    parse_type_suffix (ref pt, ref pt_name);
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected a parameter name at $(current.line):$(current.column)");
                    if (is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"'$(current.text)' is a keyword and cannot name a parameter at $(current.line):$(current.column)");
                    var p = new Param () {
                        param_type = pt,
                        type_name = pt_name,
                        name = current.text,
                        is_ref = is_ref,
                        is_out = is_out,
                        line = current.line,
                        column = current.column
                    };
                    advance ();
                    if (current.kind == TokenKind.ASSIGN) {
                        if (is_ref || is_out)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"'ref'/'out' parameter '$(p.name)' cannot have a default value at $(current.line):$(current.column)");
                        advance ();
                        p.default_value = parse_expr ();
                    }
                    plist.add (p);
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                for (int i = 0; i < plist.length; i++) {
                    for (int j = i + 1; j < plist.length; j++) {
                        if (plist[i].name == plist[j].name)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"duplicate parameter: $(plist[j].name) at $(current.line):$(current.column)");
                    }
                }
            }
            expect (TokenKind.RPAREN, "')'");
            return plist;
        }

        private void parse_block_into (GenericArray<Statement> body) throws ParseError, LexError {
            expect (TokenKind.LBRACE, "'{'");
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN ("unterminated block body");
                var st = parse_statement ();
                if (st is BlockStatement && !((BlockStatement) st).scoped) {
                    foreach (var inner in ((BlockStatement) st).statements)
                        body.add (inner);
                } else {
                    body.add (st);
                }
            }
            expect (TokenKind.RBRACE, "'}'");
        }

        private void parse_class (bool is_abstract, bool is_sealed = false, bool is_compact = false) throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'class'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected class name at $(current.line):$(current.column)");
            if (is_tok_reserved (current))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name a class at $(current.line):$(current.column)");
            var name = current.text;
            advance ();
            if (has_other_top_name (name, "class"))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $l:$c");

            var parsed_tparams = new GenericArray<string> ();
            bool is_tmpl = false;
            if (current.kind == TokenKind.LT) {
                is_tmpl = true;
                advance ();
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected type parameter name in class '$name' at $(current.line):$(current.column)");
                    parsed_tparams.add (current.text);
                    advance ();
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                expect (TokenKind.GT, "'>'");
            }

            if (is_tmpl) {
                current_type_params = new GenericArray<string> ();
                foreach (var tp in parsed_tparams)
                    current_type_params.add (tp);
            }

            var base_name = "";
            var parsed_ifaces = new GenericArray<string> ();
            if (current.kind == TokenKind.COLON) {
                advance ();
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected base class or interface name after ':' at $(current.line):$(current.column)");
                    var bt = current.text;
                    advance ();
                    unowned var itf_b = types_prog.find_interface (bt);
                    if (itf_b != null) {
                        ValaType it = ValaType.INTERFACE;
                        string itn = itf_b.name;
                        parse_generic_type_args (ref it, ref itn);
                        parsed_ifaces.add (itn);
                    } else if (bt == "Object" && types_prog.find_class ("Object") == null) {
                        // Implicit GLib.Object base in Vala sources.
                    } else {
                        ValaType bt2 = ValaType.CLASS;
                        string bn = bt;
                        parse_generic_type_args (ref bt2, ref bn);
                        if (base_name != "")
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"class '$name' cannot inherit multiple base classes at $(current.line):$(current.column)");
                        base_name = bn;
                    }
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
            }

            ClassDecl? cd_existing = null;
            foreach (var citem in program.classes) {
                if (citem.name == name) {
                    if (citem.is_defined)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate name: $name at $l:$c");
                    cd_existing = citem;
                    break;
                }
            }
            if (cd_existing == null) {
                cd_existing = new ClassDecl () { name = name };
                program.classes.add (cd_existing);
            }
            if (is_tmpl) {
                cd_existing.is_generic_template = true;
                while (cd_existing.type_params.length > 0)
                    cd_existing.type_params.remove_index (cd_existing.type_params.length - 1);
                foreach (var tp in parsed_tparams)
                    cd_existing.type_params.add (tp);
            }
            foreach (var iname in parsed_ifaces)
                cd_existing.iface_names.add (iname);
            if (is_compact) {
                if (base_name != "")
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"[Compact] class '$(cd_existing.name)' cannot have a base class at $l:$c");
                if (parsed_ifaces.length > 0)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"[Compact] class '$(cd_existing.name)' cannot implement interfaces: it has no vtable at $l:$c");
                cd_existing.is_compact = true;
            } else if (base_name == "") {
                base_name = "Object";
            }
            cd_existing.base_name = base_name;
            cd_existing.is_abstract = is_abstract;
            cd_existing.is_sealed = is_sealed;
            cd_existing.is_defined = true;
            cd_existing.line = l;
            cd_existing.column = c;
            var cd = cd_existing;

            expect (TokenKind.LBRACE, "'{'");
            var member_base_tp = current_type_params;
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN (@"unterminated class '$name'");
                current_type_params = member_base_tp;
                string? m_asm = null;
                int m_asm_l = 0;
                int m_asm_c = 0;
                bool m_compact = false;
                bool m_simple_type = false;
                bool m_arena = false;
                parse_attributes (out m_asm, out m_asm_l, out m_asm_c, out m_compact, out m_simple_type, out m_arena);
                while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped && is_visibility_modifier (current.text))
                    advance ();

                if (is_tok_kw (current, "const")) {
                    parse_const_decl (cd.name);
                    continue;
                }
                if (is_tok_kw (current, "struct") || is_tok_kw (current, "union")) {
                    var saved_tp = current_type_params;
                    current_type_params = new GenericArray<string> ();
                    parse_struct (m_simple_type);
                    current_type_params = saved_tp;
                    continue;
                }
                if (is_tok_kw (current, "enum")) {
                    parse_enum ();
                    continue;
                }
                if (is_tok_kw (current, "delegate")) {
                    var saved_tp = current_type_params;
                    current_type_params = new GenericArray<string> ();
                    parse_delegate ();
                    current_type_params = saved_tp;
                    continue;
                }

                bool is_virtual = false;
                bool is_override = false;
                bool is_abstract_m = false;
                bool is_static_m = false;
                bool is_extern_m = false;
                bool is_signal = false;
                bool is_async_m = false;
                while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                       && (current.text == "virtual" || current.text == "override"
                           || current.text == "abstract" || current.text == "static"
                           || current.text == "extern" || current.text == "signal"
                           || current.text == "async")) {
                    if (current.text == "virtual") is_virtual = true;
                    else if (current.text == "override") is_override = true;
                    else if (current.text == "abstract") is_abstract_m = true;
                    else if (current.text == "static") is_static_m = true;
                    else if (current.text == "extern") is_extern_m = true;
                    else if (current.text == "async") is_async_m = true;
                    else is_signal = true;
                    advance ();
                }

                if (is_signal) {
                    if (is_static_m || is_override || is_abstract_m || is_extern_m || is_async_m)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"signal cannot be static, override, abstract, extern, or async at $(current.line):$(current.column)");
                    ValaType sret = ValaType.VOID;
                    string sret_name = "";
                    if (current.kind != TokenKind.IDENTIFIER || !parse_type (current.text, out sret, out sret_name, current.is_escaped))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected signal return type in class '$(cd.name)' at $(current.line):$(current.column)");
                    var sl = current.line;
                    var sc = current.column;
                    advance ();
                    parse_type_suffix (ref sret, ref sret_name);
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected signal name in class '$(cd.name)' at $(current.line):$(current.column)");
                    var sname = current.text;
                    advance ();
                    var plist = parse_param_list ();
                    var del_name = @"__sig_del_$(cd.name)_$(sname)";
                    var sd = new SignalDecl () {
                        name = sname,
                        return_type = sret,
                        return_type_name = sret_name,
                        is_virtual = is_virtual,
                        handler_delegate_name = del_name,
                        line = sl,
                        column = sc
                    };
                    foreach (var p in plist)
                        sd.params.add (p);
                    if (current.kind == TokenKind.SEMICOLON) {
                        advance ();
                    } else {
                        var dfn = new Function () {
                            name = @"$(cd.name)__sig_def_$(sname)",
                            method_name = sname,
                            return_type = sret,
                            return_type_name = sret_name,
                            owner_class = cd.name,
                            line = sl,
                            column = sc
                        };
                        dfn.params.add (new Param () {
                            param_type = ValaType.CLASS,
                            type_name = cd.name,
                            name = "this",
                            line = sl,
                            column = sc
                        });
                        foreach (var p in plist)
                            dfn.params.add (p);
                        parse_block_into (dfn.body);
                        sd.default_handler = dfn;
                        program.functions.add (dfn);
                    }
                    if (cd.find_own_signal (sname) != null || cd.find_own_method (sname) != null || cd.find_own_field (sname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate member '$sname' in class '$(cd.name)' at $sl:$sc");
                    var dd = new DelegateDecl () {
                        name = del_name,
                        return_type = sret,
                        return_type_name = sret_name,
                        line = sl,
                        column = sc
                    };
                    dd.params.add (new Param () {
                        param_type = ValaType.CLASS,
                        type_name = cd.name,
                        name = "sender",
                        line = sl,
                        column = sc
                    });
                    foreach (var p in plist)
                        dd.params.add (p);
                    program.delegates.add (dd);
                    cd.signals.add (sd);
                    continue;
                }

                // Destructor: `~ClassName () { ... }`
                if (current.kind == TokenKind.TILDE) {
                    var dl = current.line;
                    var dc = current.column;
                    if (is_virtual || is_override || is_abstract_m || is_static_m || is_async_m)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"destructor cannot have modifiers at $dl:$dc");
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER || current.text != cd.name)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected '~$(cd.name)' for destructor at $(current.line):$(current.column)");
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    expect (TokenKind.RPAREN, "')'");
                    if (cd.dtor != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate destructor in class '$(cd.name)' at $dl:$dc");
                    var dtor = new Function () {
                        name = "__dtor",
                        return_type = ValaType.VOID,
                        is_dtor = true,
                        owner_class = cd.name,
                        line = dl,
                        column = dc
                    };
                    parse_block_into (dtor.body);
                    cd.dtor = dtor;
                    continue;
                }

                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected member declaration in class '$(cd.name)' at $(current.line):$(current.column)");

                bool mem_is_unowned = false;
                bool mem_is_weak = parse_ownership (out mem_is_unowned);

                var ml = current.line;
                var mc = current.column;
                ValaType ft = ValaType.VOID;
                string ft_name = "";
                var member_tps = new GenericArray<string> ();

                if (!is_virtual && !is_override && !is_abstract_m && !is_static_m && !is_async_m && current.text == cd.name) {
                    advance ();
                    string ctor_sub = "";
                    bool saw_dot = false;
                    if (current.kind == TokenKind.DOT) {
                        saw_dot = true;
                        advance ();
                        if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected named constructor name after '.' in class '$(cd.name)' at $(current.line):$(current.column)");
                        ctor_sub = current.text;
                        advance ();
                    }
                    if (saw_dot || current.kind == TokenKind.LPAREN) {
                        var plist = parse_param_list ();
                        if (ctor_sub == "" && cd.ctor != null)
                            throw new ParseError.DUPLICATE_FUNCTION (
                                @"duplicate constructor in class '$(cd.name)' at $ml:$mc");
                        if (ctor_sub != "" && cd.find_own_named_ctor (ctor_sub) != null)
                            throw new ParseError.DUPLICATE_FUNCTION (
                                @"duplicate constructor '$(cd.name).$ctor_sub' at $ml:$mc");
                        var ctor = new Function () {
                            name = (ctor_sub == "") ? "__ctor" : @"__ctor_$ctor_sub",
                            return_type = ValaType.VOID,
                            is_ctor = true,
                            ctor_subname = ctor_sub,
                            owner_class = cd.name,
                            line = ml,
                            column = mc
                        };
                        foreach (var p in plist)
                            ctor.params.add (p);
                        parse_throws_clause (ctor.throws_domains);
                        if (current.kind == TokenKind.COLON) {
                            advance ();
                            if (is_tok_kw (current, "base")) {
                                advance ();
                                expect (TokenKind.LPAREN, "'('");
                                ctor.has_base_call = true;
                                parse_arg_list (ctor.base_args);
                                expect (TokenKind.RPAREN, "')'");
                            } else if (is_tok_kw (current, "this")) {
                                advance ();
                                ctor.has_this_call = true;
                                if (current.kind == TokenKind.DOT) {
                                    advance ();
                                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                                        throw new ParseError.UNEXPECTED_TOKEN (
                                            @"expected constructor name after 'this.' at $(current.line):$(current.column)");
                                    ctor.this_ctor_subname = current.text;
                                    advance ();
                                }
                                expect (TokenKind.LPAREN, "'('");
                                parse_arg_list (ctor.base_args);
                                expect (TokenKind.RPAREN, "')'");
                            } else {
                                throw new ParseError.UNEXPECTED_TOKEN (
                                    @"expected 'base(...)' or 'this(...)' after ':' at $(current.line):$(current.column)");
                            }
                        }
                        parse_block_into (ctor.body);
                        if (ctor.body.length > 0 && ctor.body[0] is CtorChainStatement) {
                            var ch = (CtorChainStatement) ctor.body[0];
                            if (ctor.has_base_call || ctor.has_this_call)
                                throw new ParseError.UNEXPECTED_TOKEN (
                                    @"duplicate constructor chaining at $(ch.line):$(ch.column)");
                            if (ch.is_this) {
                                ctor.has_this_call = true;
                                ctor.this_ctor_subname = ch.subname;
                            } else {
                                ctor.has_base_call = true;
                            }
                            foreach (var ca in ch.args)
                                ctor.base_args.add (ca);
                            ctor.body.remove_index (0);
                        }
                        if (ctor_sub == "")
                            cd.ctor = ctor;
                        else
                            cd.named_ctors.add (ctor);
                        continue;
                    }
                    ft = ValaType.CLASS;
                    ft_name = cd.name;
                    parse_type_suffix (ref ft, ref ft_name);
                } else {
                    // `T name<T> (...)` needs its type parameters before the
                    // return type is parsed.
                    {
                        var look = lexer.clone_state ();
                        var t2 = look.next ();
                        if (t2.kind == TokenKind.IDENTIFIER) {
                            var t3 = look.next ();
                            if (t3.kind == TokenKind.LT) {
                                var gens = new GenericArray<string> ();
                                foreach (var tpx in member_base_tp)
                                    gens.add (tpx);
                                while (true) {
                                    var tk = look.next ();
                                    if (tk.kind == TokenKind.IDENTIFIER)
                                        gens.add (tk.text);
                                    else if (tk.kind == TokenKind.GT || tk.kind == TokenKind.SHR)
                                        break;
                                    else if (tk.kind == TokenKind.EOF)
                                        break;
                                }
                                current_type_params = gens;
                            }
                        }
                    }
                    if (!parse_type_with_ns (out ft, out ft_name))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"unknown member type '$(current.text)' in class '$(cd.name)' at $ml:$mc");
                    parse_type_suffix (ref ft, ref ft_name);
                }

                // Indexer: `public T this [I i] { get { } set { } }` lowers to
                // the methods `get_item (i)` and `set_item (i, value)`.
                if (is_tok_kw (current, "this")) {
                    advance ();
                    expect (TokenKind.LBRACKET, "'['");
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected index type in indexer at $(current.line):$(current.column)");
                    ValaType idx_t = ValaType.VOID;
                    string idx_tn = "";
                    if (!parse_type (current.text, out idx_t, out idx_tn, current.is_escaped))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"unknown index type '$(current.text)' in indexer at $(current.line):$(current.column)");
                    var idx_l = current.line;
                    var idx_c = current.column;
                    advance ();
                    parse_type_suffix (ref idx_t, ref idx_tn);
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected index parameter name in indexer at $(current.line):$(current.column)");
                    var idx_name = current.text;
                    advance ();
                    expect (TokenKind.RBRACKET, "']'");
                    if (current.kind != TokenKind.LBRACE)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected '{' in indexer at $(current.line):$(current.column)");
                    bool ix_plain = false;
                    Expr? ix_def = null;
                    var ix_syn = new GenericArray<Function> ();
                    bool ix_add_back = false;
                    parse_property_block (cd.name, true, is_virtual, is_override, is_abstract_m,
                                          ft, ft_name, "item", ml, mc,
                                          out ix_plain, out ix_def, ix_syn, out ix_add_back);
                    if (ix_plain || ix_add_back) {
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"indexer in class '$(cd.name)' requires explicit 'get' and 'set' bodies at $ml:$mc");
                    }
                    foreach (var sm in ix_syn) {
                        var ip = new Param () {
                            param_type = idx_t,
                            type_name = idx_tn,
                            name = idx_name,
                            line = idx_l,
                            column = idx_c
                        };
                        if (sm.name.has_prefix ("set_")) {
                            var old = new GenericArray<Param> ();
                            foreach (var pp in sm.params)
                                old.add (pp);
                            while (sm.params.length > 0)
                                sm.params.remove_index (sm.params.length - 1);
                            sm.params.add (ip);
                            foreach (var pp in old)
                                sm.params.add (pp);
                        } else {
                            sm.params.add (ip);
                        }
                        cd.methods.add (sm);
                    }
                    continue;
                }

                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected member name in class '$(cd.name)' at $(current.line):$(current.column)");
                if (is_tok_reserved (current))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword and cannot name a member at $(current.line):$(current.column)");
                var mname = current.text;
                var mem_l = current.line;
                var mem_c = current.column;
                advance ();

                if (current.kind == TokenKind.LT && current_type_params.length > member_base_tp.length) {
                    advance ();
                    while (true) {
                        if (current.kind != TokenKind.IDENTIFIER)
                            break;
                        member_tps.add (current.text);
                        advance ();
                        if (current.kind == TokenKind.COMMA) {
                            advance ();
                            continue;
                        }
                        break;
                    }
                    consume_gt ();
                }

                if (current.kind == TokenKind.LPAREN) {
                    if (is_abstract_m && !cd.is_abstract)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"abstract method '$(mname)' requires an abstract class at $mem_l:$mem_c");
                    if (is_static_m && (is_virtual || is_override || is_abstract_m))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"static method '$(mname)' cannot be virtual, override, or abstract at $mem_l:$mem_c");
                    if (is_async_m && (is_abstract_m || is_extern_m || m_asm != null))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"'async' method '$(mname)' cannot be abstract, extern, or [AsmBody] at $mem_l:$mem_c");
                    var plist = parse_param_list ();
                    var mfn = new Function () {
                        name = mname,
                        return_type = ft,
                        return_type_name = ft_name,
                        is_virtual = is_virtual,
                        is_override = is_override,
                        is_abstract = is_abstract_m,
                        is_static = is_static_m,
                        is_async = is_async_m,
                        owner_class = cd.name,
                        line = mem_l,
                        column = mem_c
                    };
                    if (member_tps.length > 0) {
                        mfn.is_generic_template = true;
                        foreach (var mtp in member_tps)
                            mfn.type_params.add (mtp);
                    }
                    foreach (var p in plist)
                        mfn.params.add (p);
                    parse_throws_clause (mfn.throws_domains);
                    if (m_asm != null) {
                        mfn.is_asm_body = true;
                        mfn.asm_body = m_asm;
                        mfn.asm_line = m_asm_l;
                        mfn.asm_column = m_asm_c;
                        mfn.has_body = false;
                        if (current.kind == TokenKind.SEMICOLON) {
                            advance ();
                        } else {
                            expect (TokenKind.LBRACE, "'{' or ';'");
                            expect (TokenKind.RBRACE, "'}'");
                        }
                    } else if (is_abstract_m || is_extern_m) {
                        mfn.has_body = false;
                        expect (TokenKind.SEMICOLON, "';'");
                    } else {
                        parse_block_into (mfn.body);
                    }
                    if (cd.find_own_method (mname) != null || cd.find_own_field (mname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate member '$mname' in class '$(cd.name)' at $mem_l:$mem_c");
                    cd.methods.add (mfn);
                } else if (current.kind == TokenKind.LBRACE) {
                    if (is_static_m || is_async_m || ft == ValaType.VOID)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"invalid property '$mname' in class '$(cd.name)' at $mem_l:$mem_c");
                    if (is_abstract_m && !cd.is_abstract)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"abstract property '$mname' requires an abstract class at $mem_l:$mem_c");
                    if (cd.find_own_field (mname) != null || cd.find_own_method (mname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate member '$mname' in class '$(cd.name)' at $mem_l:$mem_c");
                    bool use_plain = false;
                    Expr? def_init = null;
                    var syn = new GenericArray<Function> ();
                    bool add_back = false;
                    parse_property_block (cd.name, true, is_virtual, is_override, is_abstract_m,
                                          ft, ft_name, mname, mem_l, mem_c,
                                          out use_plain, out def_init, syn, out add_back);
                    if (use_plain) {
                        cd.fields.add (new ClassField () {
                            field_type = ft,
                            type_name = ft_name,
                            name = mname,
                            init = def_init,
                            line = mem_l,
                            column = mem_c
                        });
                    } else {
                        if (add_back) {
                            cd.fields.add (new ClassField () {
                                field_type = ft,
                                type_name = ft_name,
                                name = @"#prop_$(mname)",
                                init = def_init,
                                line = mem_l,
                                column = mem_c
                            });
                        }
                        foreach (var sm in syn)
                            cd.methods.add (sm);
                    }
                } else {
                    if (is_virtual || is_override || is_abstract_m || is_async_m)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"field '$mname' cannot have method modifiers at $mem_l:$mem_c");
                    if (ft == ValaType.VOID)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"field '$mname' cannot have type 'void' at $mem_l:$mem_c");
                    Expr? finit = null;
                    if (current.kind == TokenKind.ASSIGN) {
                        advance ();
                        finit = parse_expr ();
                    }
                    expect (TokenKind.SEMICOLON, "';'");
                    if (cd.find_own_field (mname) != null || cd.find_own_method (mname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate member '$mname' in class '$(cd.name)' at $mem_l:$mem_c");
                    cd.fields.add (new ClassField () {
                        field_type = ft,
                        type_name = ft_name,
                        is_weak = mem_is_weak,
                        is_unowned = mem_is_unowned,
                        is_static = is_static_m,
                        name = mname,
                        init = finit,
                        line = mem_l,
                        column = mem_c
                    });
                }
            }
            expect (TokenKind.RBRACE, "'}'");
            current_type_params = new GenericArray<string> ();
        }

        private unowned GlobalVar? find_global (Program program, string name) {
            foreach (unowned var g in program.globals) {
                if (g.name == name)
                    return g;
            }
            return null;
        }

        // Parses the rest of a function whose type and name were consumed.
        private Function parse_function_rest (ValaType return_type, string return_type_name,
                                              string name, int l, int c,
                                              string? asm_body = null, int asm_l = 0, int asm_c = 0,
                                              bool is_extern = false)
                throws ParseError, LexError {
            var f = new Function () {
                name = name,
                return_type = return_type,
                return_type_name = return_type_name
            };
            f.line = l;
            f.column = c;

            var saved_tparams = current_type_params;
            if (current.kind == TokenKind.LT) {
                advance ();
                var fn_tparams = new GenericArray<string> ();
                foreach (var tp in saved_tparams)
                    fn_tparams.add (tp);
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected type parameter name in function '$name' at $(current.line):$(current.column)");
                    f.type_params.add (current.text);
                    fn_tparams.add (current.text);
                    advance ();
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                consume_gt ();
                f.is_generic_template = true;
                current_type_params = fn_tparams;
            }

            var plist = parse_param_list ();
            foreach (var p in plist)
                f.params.add (p);
            parse_throws_clause (f.throws_domains);
            if (asm_body != null) {
                f.is_asm_body = true;
                f.asm_body = asm_body;
                f.asm_line = asm_l;
                f.asm_column = asm_c;
                f.has_body = false;
                if (current.kind == TokenKind.SEMICOLON) {
                    advance ();
                } else {
                    expect (TokenKind.LBRACE, "'{' or ';'");
                    expect (TokenKind.RBRACE, "'}'");
                }
            } else if (is_extern) {
                f.has_body = false;
                expect (TokenKind.SEMICOLON, "';'");
            } else {
                parse_block_into (f.body);
            }
            current_type_params = saved_tparams;
            return f;
        }

        private GenericArray<Statement> parse_block () throws ParseError, LexError {
            expect (TokenKind.LBRACE, "'{'");
            var stmts = new GenericArray<Statement> ();
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN ("unterminated block");
                var st = parse_statement ();
                if (st is BlockStatement && !((BlockStatement) st).scoped) {
                    foreach (var inner in ((BlockStatement) st).statements)
                        stmts.add (inner);
                } else {
                    stmts.add (st);
                }
            }
            expect (TokenKind.RBRACE, "'}'");
            return stmts;
        }

        private Statement parse_statement () throws ParseError, LexError {
            if (current.kind == TokenKind.LBRACE) {
                var b = new BlockStatement ();
                b.line = current.line;
                b.column = current.column;
                var stmts = parse_block ();
                for (int i = 0; i < stmts.length; i++)
                    b.statements.add (stmts[i]);
                return b;
            }

            if (current.kind == TokenKind.IDENTIFIER && !current.is_escaped) {
                var l = current.line;
                var c = current.column;
                var name = current.text;

                if (name == "print") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var v = parse_expr ();
                    var s = new PrintStatement () { value = v };
                    s.line = l;
                    s.column = c;
                    expect (TokenKind.RPAREN, "')'");
                    expect (TokenKind.SEMICOLON, "';'");
                    return s;
                }
                if (name == "exit") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var v = parse_expr ();
                    var s = new ExitStatement () { value = v };
                    s.line = l;
                    s.column = c;
                    expect (TokenKind.RPAREN, "')'");
                    expect (TokenKind.SEMICOLON, "';'");
                    return s;
                }
                if (name == "assert") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var cond = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    expect (TokenKind.SEMICOLON, "';'");
                    var not_cond = new UnaryExpr ();
                    not_cond.op = "!";
                    not_cond.operand = cond;
                    not_cond.line = l;
                    not_cond.column = c;
                    var msg = new StringLiteral ();
                    msg.value = @"assertion failed at $l:$c\n";
                    msg.line = l;
                    msg.column = c;
                    var pr = new PrintStatement ();
                    pr.value = msg;
                    pr.line = l;
                    pr.column = c;
                    var code_lit = new IntLiteral ();
                    code_lit.value = 134;
                    code_lit.line = l;
                    code_lit.column = c;
                    var ex = new ExitStatement ();
                    ex.value = code_lit;
                    ex.line = l;
                    ex.column = c;
                    var blk = new BlockStatement ();
                    blk.statements.add (pr);
                    blk.statements.add (ex);
                    blk.line = l;
                    blk.column = c;
                    var ifs = new IfStatement ();
                    ifs.condition = not_cond;
                    ifs.then_body = blk;
                    ifs.else_body = null;
                    ifs.line = l;
                    ifs.column = c;
                    return ifs;
                }
                if (name == "return") {
                    advance ();
                    Expr? v = null;
                    if (current.kind != TokenKind.SEMICOLON)
                        v = parse_expr ();
                    var s = new ReturnStatement () { value = v };
                    s.line = l;
                    s.column = c;
                    expect (TokenKind.SEMICOLON, "';'");
                    return s;
                }
                if (name == "break") {
                    advance ();
                    var s = new BreakStatement ();
                    s.line = l;
                    s.column = c;
                    expect (TokenKind.SEMICOLON, "';'");
                    return s;
                }
                if (name == "continue") {
                    advance ();
                    var s = new ContinueStatement ();
                    s.line = l;
                    s.column = c;
                    expect (TokenKind.SEMICOLON, "';'");
                    return s;
                }
                if (name == "yield") {
                    advance ();
                    Expr? v = null;
                    if (current.kind != TokenKind.SEMICOLON)
                        v = parse_expr ();
                    var ye = new YieldExpr () { value = v };
                    ye.line = l;
                    ye.column = c;
                    var s = new ExprStatement () { expr = ye };
                    s.line = l;
                    s.column = c;
                    expect (TokenKind.SEMICOLON, "';'");
                    return s;
                }
                if (name == "if") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var cond = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    var then_body = parse_statement ();
                    Statement? else_body = null;
                    if (is_tok_kw (current, "else")) {
                        advance ();
                        else_body = parse_statement ();
                    }
                    var i = new IfStatement () {
                        condition = cond,
                        then_body = then_body,
                        else_body = else_body
                    };
                    i.line = l;
                    i.column = c;
                    return i;
                }
                if (name == "while") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var cond = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    var body = parse_statement ();
                    var w = new WhileStatement () { condition = cond, body = body };
                    w.line = l;
                    w.column = c;
                    return w;
                }
                if (name == "do") {
                    advance ();
                    var body = parse_statement ();
                    if (!is_tok_kw (current, "while"))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected 'while' after 'do' body at $(current.line):$(current.column)");
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var cond = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    expect (TokenKind.SEMICOLON, "';'");
                    var dw = new DoWhileStatement () { body = body, condition = cond };
                    dw.line = l;
                    dw.column = c;
                    return dw;
                }
                if (name == "for") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    Statement? init = null;
                    if (current.kind != TokenKind.SEMICOLON)
                        init = parse_simple_statement_no_semi ();
                    expect (TokenKind.SEMICOLON, "';'");
                    Expr? cond = null;
                    if (current.kind != TokenKind.SEMICOLON)
                        cond = parse_expr ();
                    expect (TokenKind.SEMICOLON, "';'");
                    Statement? step = null;
                    if (current.kind != TokenKind.RPAREN)
                        step = parse_simple_statement_no_semi ();
                    expect (TokenKind.RPAREN, "')'");
                    var body = parse_statement ();
                    var fs = new ForStatement () {
                        init = init,
                        condition = cond,
                        step = step,
                        body = body
                    };
                    fs.line = l;
                    fs.column = c;
                    return fs;
                }
                if (name == "foreach") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    bool fe_unowned = false;
                    parse_ownership (out fe_unowned);
                    bool infer_v = false;
                    ValaType vt = ValaType.VOID;
                    string vt_name = "";
                    if (is_tok_kw (current, "var")) {
                        infer_v = true;
                        advance ();
                    } else {
                        if (current.kind != TokenKind.IDENTIFIER || !parse_type (current.text, out vt, out vt_name, current.is_escaped))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected element type or 'var' in foreach at $(current.line):$(current.column)");
                        advance ();
                        parse_type_suffix (ref vt, ref vt_name);
                    }
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected variable name in foreach at $(current.line):$(current.column)");
                    var vname = current.text;
                    advance ();
                    if (!is_tok_kw (current, "in"))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected 'in' in foreach at $(current.line):$(current.column)");
                    advance ();
                    var col_expr = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    var body = parse_statement ();
                    var fe = new ForeachStatement () {
                        elem_type = vt,
                        elem_type_name = vt_name,
                        infer_type = infer_v,
                        is_unowned = fe_unowned,
                        var_name = vname,
                        collection = col_expr,
                        body = body
                    };
                    fe.line = l;
                    fe.column = c;
                    return fe;
                }
                if (name == "switch") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var target = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    expect (TokenKind.LBRACE, "'{'");
                    var sw = new SwitchStatement () { target = target };
                    sw.line = l;
                    sw.column = c;
                    while (current.kind != TokenKind.RBRACE) {
                        if (current.kind == TokenKind.EOF)
                            throw new ParseError.UNEXPECTED_TOKEN (@"unterminated switch at $l:$c");
                        if (is_tok_kw (current, "case")) {
                            var sc = new SwitchCase () { line = current.line, column = current.column };
                            while (is_tok_kw (current, "case")) {
                                advance ();
                                while (true) {
                                    sc.values.add (parse_expr ());
                                    if (current.kind == TokenKind.COMMA) {
                                        advance ();
                                        continue;
                                    }
                                    break;
                                }
                                expect (TokenKind.COLON, "':'");
                            }
                            while (current.kind != TokenKind.RBRACE
                                   && !(current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                                        && (current.text == "case" || current.text == "default"))) {
                                if (current.kind == TokenKind.EOF)
                                    throw new ParseError.UNEXPECTED_TOKEN (@"unterminated switch case at $(sc.line):$(sc.column)");
                                sc.body.add (parse_statement ());
                            }
                            sw.cases.add (sc);
                        } else if (is_tok_kw (current, "default")) {
                            if (sw.has_default)
                                throw new ParseError.UNEXPECTED_TOKEN (@"duplicate 'default' in switch at $(current.line):$(current.column)");
                            advance ();
                            expect (TokenKind.COLON, "':'");
                            sw.has_default = true;
                            while (current.kind != TokenKind.RBRACE
                                   && !(current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                                        && (current.text == "case" || current.text == "default"))) {
                                if (current.kind == TokenKind.EOF)
                                    throw new ParseError.UNEXPECTED_TOKEN (@"unterminated switch default at $l:$c");
                                sw.default_body.add (parse_statement ());
                            }
                        } else {
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected 'case' or 'default' in switch at $(current.line):$(current.column)");
                        }
                    }
                    expect (TokenKind.RBRACE, "'}'");
                    return sw;
                }
                if (name == "lock") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var lk_target = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    var lk_body = parse_statement ();
                    var lk = new LockStatement () {
                        target = lk_target,
                        body = lk_body
                    };
                    lk.line = l;
                    lk.column = c;
                    return lk;
                }
                if (name == "throw") {
                    advance ();
                    if (!is_tok_kw (current, "new"))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected 'new Domain.CODE(...)' after 'throw' at $(current.line):$(current.column)");
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected error domain after 'throw new' at $(current.line):$(current.column)");
                    var dname = current.text;
                    advance ();
                    expect (TokenKind.DOT, "'.'");
                    if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected error code after '$(dname).' at $(current.line):$(current.column)");
                    var cname = current.text;
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var msg = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    expect (TokenKind.SEMICOLON, "';'");
                    var ts = new ThrowStatement () {
                        domain_name = dname,
                        code_name = cname,
                        message = msg
                    };
                    ts.line = l;
                    ts.column = c;
                    return ts;
                }
                if (name == "try") {
                    advance ();
                    var tr = new TryStatement ();
                    tr.line = l;
                    tr.column = c;
                    parse_block_into (tr.try_body);
                    while (is_tok_kw (current, "catch")) {
                        var cl = current.line;
                        var cc_col = current.column;
                        advance ();
                        expect (TokenKind.LPAREN, "'('");
                        if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected error domain in 'catch' at $(current.line):$(current.column)");
                        var dname = current.text;
                        advance ();
                        if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected variable name in 'catch' at $(current.line):$(current.column)");
                        var vname = current.text;
                        advance ();
                        expect (TokenKind.RPAREN, "')'");
                        var clause = new CatchClause () {
                            domain_name = dname,
                            var_name = vname,
                            line = cl,
                            column = cc_col
                        };
                        parse_block_into (clause.body);
                        tr.catches.add (clause);
                    }
                    if (is_tok_kw (current, "finally")) {
                        advance ();
                        tr.has_finally = true;
                        parse_block_into (tr.finally_body);
                    }
                    if (tr.catches.length == 0 && !tr.has_finally)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"'try' block must have at least one 'catch' or 'finally' at $l:$c");
                    return tr;
                }
                if (name == "else") {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'else' without a matching 'if' at $l:$c");
                }
            }

            var s = parse_simple_statement_no_semi ();
            expect (TokenKind.SEMICOLON, "';'");
            return s;
        }

        private bool match_assign_op (out string op) throws ParseError, LexError {
            op = "";
            switch (current.kind) {
                case TokenKind.ASSIGN:    op = "="; break;
                case TokenKind.PLUSEQ:    op = "+"; break;
                case TokenKind.MINUSEQ:   op = "-"; break;
                case TokenKind.STAREQ:    op = "*"; break;
                case TokenKind.SLASHEQ:   op = "/"; break;
                case TokenKind.PERCENTEQ: op = "%"; break;
                case TokenKind.AMPEQ:     op = "&"; break;
                case TokenKind.PIPEEQ:    op = "|"; break;
                case TokenKind.CARETEQ:   op = "^"; break;
                case TokenKind.SHLEQ:     op = "<<"; break;
                case TokenKind.SHREQ:     op = ">>"; break;
                default: return false;
            }
            advance ();
            return true;
        }

        private Statement parse_simple_statement_no_semi () throws ParseError, LexError {
            if ((current.kind != TokenKind.IDENTIFIER && !(current.text == "void" && !current.is_escaped))
                || (!current.is_escaped
                    && (current.text == "true" || current.text == "false"
                        || current.text == "null" || current.text == "new"))) {
                    var e = parse_expr ();
                string op = "";
                if (e is DerefExpr && match_assign_op (out op)) {
                    var de = (DerefExpr) e;
                    var da = new DerefAssignStatement () {
                        target = de.target,
                        op = op,
                        value = parse_expr ()
                    };
                    da.line = e.line;
                    da.column = e.column;
                    return da;
                }
                if (e is MemberAccessExpr && match_assign_op (out op)) {
                    var m = (MemberAccessExpr) e;
                    var fa = new FieldAssignStatement () {
                        target = m.target,
                        field_name = m.member,
                        op = op,
                        value = parse_expr ()
                    };
                    fa.line = e.line;
                    fa.column = e.column;
                    return fa;
                }
                if (e is IndexExpr && match_assign_op (out op)) {
                    var ix = (IndexExpr) e;
                    var ia = new IndexAssignStatement () {
                        target = ix.target,
                        index = ix.index,
                        op = op,
                        value = parse_expr ()
                    };
                    ia.line = e.line;
                    ia.column = e.column;
                    return ia;
                }
                var s = new ExprStatement () { expr = e };
                s.line = e.line;
                s.column = e.column;
                return s;
            }

            var l = current.line;
            var c = current.column;
            var name = current.text;
            var escaped = current.is_escaped;
            advance ();

            bool had_ownership = false;
            bool var_is_weak = false;
            bool var_is_unowned = false;
            if (!escaped && (name == "unowned" || name == "owned" || name == "weak")) {
                had_ownership = true;
                var_is_weak = (name == "weak");
                var_is_unowned = (name == "unowned");
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected type after '$name' at $(current.line):$(current.column)");
                name = current.text;
                escaped = current.is_escaped;
                l = current.line;
                c = current.column;
                advance ();
            }

            ValaType dt = ValaType.VOID;
            string dt_name = "";
            if (!escaped && types_prog.has_namespace (name) && current.kind == TokenKind.DOT) {
                var saved_lx = lexer.clone_state ();
                var saved_cur = current;
                string ns_acc = name;
                bool matched_ns_type = false;
                while (types_prog.has_namespace (ns_acc) && current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        break;
                    var seg = current.text;
                    var seg_esc = current.is_escaped;
                    advance ();
                    if (!seg_esc && types_prog.has_namespace (@"$ns_acc.$seg") && current.kind == TokenKind.DOT) {
                        ns_acc = @"$ns_acc.$seg";
                        continue;
                    }
                    name = seg;
                    escaped = seg_esc;
                    matched_ns_type = true;
                    break;
                }
                if (!matched_ns_type) {
                    lexer = saved_lx;
                    current = saved_cur;
                }
            }
            bool is_builtin_var = !escaped && (is_int_type_name (name) || is_fp_type_name (name) || name == "bool" || name == "string" || name == "var");
            bool is_named_type = !is_builtin_var && parse_type (name, out dt, out dt_name, escaped)
                                 && (dt != ValaType.VOID || current.kind == TokenKind.STAR)
                                 && (current.kind == TokenKind.IDENTIFIER
                                     || ((dt == ValaType.CLASS || dt == ValaType.INTERFACE
                                          || dt == ValaType.ERROR || dt == ValaType.TYPE_PARAM
                                          || (dt == ValaType.STRUCT && types_prog.find_delegate (dt_name) != null))
                                         && current.kind == TokenKind.QUESTION)
                                     || ((dt == ValaType.CLASS || dt == ValaType.STRUCT || dt == ValaType.INTERFACE)
                                         && current.kind == TokenKind.LT)
                                     || (current.kind == TokenKind.LBRACKET && lexer.clone_state ().next ().kind == TokenKind.RBRACKET)
                                     || current.kind == TokenKind.STAR);

            if (is_builtin_var || is_named_type) {
                if (!escaped && is_int_type_name (name)) {
                    dt = ValaType.INT;
                    dt_name = name;
                    last_parsed_type_token = name;
                } else if (!escaped && name == "float") {
                    dt = ValaType.FLOAT;
                } else if (!escaped && name == "double") {
                    dt = ValaType.DOUBLE;
                } else if (!escaped && name == "bool") {
                    dt = ValaType.BOOL;
                } else if (!escaped && name == "string") {
                    dt = ValaType.STRING;
                }
                if (escaped || name != "var")
                    parse_type_suffix (ref dt, ref dt_name);
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected a variable name at $(current.line):$(current.column)");
                if (is_tok_reserved (current))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword and cannot name a variable at $(current.line):$(current.column)");
                var vname = current.text;
                advance ();
                if (!escaped && name == "var" && current.kind != TokenKind.ASSIGN)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'var' declaration requires an initializer at $(current.line):$(current.column)");
                Expr? init = null;
                if (current.kind == TokenKind.ASSIGN) {
                    advance ();
                    init = parse_expr ();
                }
                var decl = new VarDeclStatement () {
                    decl_type = dt,
                    decl_type_name = dt_name,
                    infer_type = (!escaped && name == "var"),
                    is_weak = var_is_weak,
                    is_unowned = var_is_unowned,
                    name = vname,
                    init = init
                };
                decl.line = l;
                decl.column = c;
                if (current.kind == TokenKind.COMMA && (escaped || name != "var")) {
                    var grp = new BlockStatement () { scoped = false, line = l, column = c };
                    grp.statements.add (decl);
                    while (current.kind == TokenKind.COMMA) {
                        advance ();
                        var vl2 = current.line;
                        var vc2 = current.column;
                        if (current.kind != TokenKind.IDENTIFIER)
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected a variable name at $(vl2):$(vc2)");
                        if (is_tok_reserved (current))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"'$(current.text)' is a keyword and cannot name a variable at $(vl2):$(vc2)");
                        var vname2 = current.text;
                        advance ();
                        Expr? init2 = null;
                        if (current.kind == TokenKind.ASSIGN) {
                            advance ();
                            init2 = parse_expr ();
                        }
                        var decl2 = new VarDeclStatement () {
                            decl_type = dt,
                            decl_type_name = dt_name,
                            infer_type = false,
                            is_weak = var_is_weak,
                            is_unowned = var_is_unowned,
                            name = vname2,
                            init = init2
                        };
                        decl2.line = vl2;
                        decl2.column = vc2;
                        grp.statements.add (decl2);
                    }
                    return grp;
                }
                return decl;
            }

            if (had_ownership)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unknown type '$name' after ownership qualifier at $l:$c");

            Expr atom;
            if (!escaped && name == "this") {
                if (current.kind == TokenKind.LPAREN) {
                    advance ();
                    var ch = new CtorChainStatement () { is_this = true, line = l, column = c };
                    parse_arg_list (ch.args);
                    expect (TokenKind.RPAREN, "')'");
                    return ch;
                }
                var v = new VarRef () { name = "this" };
                v.line = l;
                v.column = c;
                atom = v;
            } else if (!escaped && name == "base") {
                if (current.kind == TokenKind.LPAREN) {
                    advance ();
                    var ch = new CtorChainStatement () { is_this = false, line = l, column = c };
                    parse_arg_list (ch.args);
                    expect (TokenKind.RPAREN, "')'");
                    return ch;
                }
                expect (TokenKind.DOT, "'.'");
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected method name after 'base.' at $(current.line):$(current.column)");
                var mname = current.text;
                advance ();
                expect (TokenKind.LPAREN, "'('");
                var mc = new MethodCallExpr () {
                    is_base_call = true,
                    method_name = mname
                };
                parse_arg_list (mc.args);
                expect (TokenKind.RPAREN, "')'");
                mc.line = l;
                mc.column = c;
                atom = mc;
            } else {
                if (!escaped && is_reserved (name)) {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"unexpected keyword '$name' at $l:$c");
                }

                string a_op = "";
                if (match_assign_op (out a_op)) {
                    Expr rhs = parse_expr ();
                    if (a_op != "=") {
                        var vref = new VarRef () { name = name };
                        vref.line = l;
                        vref.column = c;
                        var bin = new BinaryExpr () { op = a_op, left = vref, right = rhs };
                        bin.line = l;
                        bin.column = c;
                        rhs = bin;
                    }
                    var a = new AssignStatement () { name = name, value = rhs };
                    a.line = l;
                    a.column = c;
                    return a;
                }
            if (current.kind == TokenKind.PLUSPLUS || current.kind == TokenKind.MINUSMINUS) {
                    var op = (current.kind == TokenKind.PLUSPLUS) ? "+" : "-";
                    advance ();
                    var vref = new VarRef () { name = name };
                    vref.line = l;
                    vref.column = c;
                    var one = new IntLiteral () { value = 1 };
                    one.line = l;
                    one.column = c;
                    var bin = new BinaryExpr () { op = op, left = vref, right = one };
                    bin.line = l;
                    bin.column = c;
                    var a = new AssignStatement () { name = name, value = bin };
                    a.line = l;
                    a.column = c;
                    return a;
                }

                if (current.kind == TokenKind.LT) {
                    unowned var s_tmpl = types_prog.find_struct (name);
                    if (s_tmpl != null && s_tmpl.is_generic_template) {
                        ValaType st = ValaType.STRUCT;
                        string sn = name;
                        parse_generic_type_args (ref st, ref sn);
                        name = sn;
                    }
                }
                if (current.kind == TokenKind.LPAREN) {
                    if (types_prog.find_struct (name) != null || program.find_instantiation_by_mangled (name) != null)
                        atom = parse_struct_literal_rest (name, l, c);
                    else
                        atom = parse_call_rest (name, l, c);
                } else {
                    var v = new VarRef () { name = name };
                    v.line = l;
                    v.column = c;
                    atom = v;
                }
            }

            var post = parse_postfix (atom);
            if (post is MemberAccessExpr) {
                var m = (MemberAccessExpr) post;
                string fop = "";
                if (match_assign_op (out fop)) {
                    var fa = new FieldAssignStatement () {
                        target = m.target,
                        field_name = m.member,
                        op = fop,
                        value = parse_expr ()
                    };
                    fa.line = l;
                    fa.column = c;
                    return fa;
                }
            }
            if (post is IndexExpr) {
                var ix = (IndexExpr) post;
                string iop = "";
                if (match_assign_op (out iop)) {
                    var ia = new IndexAssignStatement () {
                        target = ix.target,
                        index = ix.index,
                        op = iop,
                        value = parse_expr ()
                    };
                    ia.line = l;
                    ia.column = c;
                    return ia;
                }
            }

            var e = parse_ternary (post);
            var s2 = new ExprStatement () { expr = e };
            s2.line = l;
            s2.column = c;
            return s2;
        }

        // --------------------------------------------------------------

        // Each precedence level forwards an optional `seed`: an already-parsed
        // postfix/primary atom (when an identifier was consumed while
        // dispatching a statement). Threading `seed` down to `parse_mul`
        // preserves full operator precedence across all binary levels.

        private Expr parse_expr () throws ParseError, LexError {
            return parse_ternary (null);
        }

        private Expr parse_ternary (Expr? seed) throws ParseError, LexError {
            var cond = parse_coalesce (seed);
            if (current.kind == TokenKind.QUESTION) {
                var l = cond.line;
                var c = cond.column;
                advance ();
                var then_e = parse_ternary (null);
                expect (TokenKind.COLON, "':'");
                var else_e = parse_ternary (null);
                var te = new TernaryExpr () {
                    condition = cond,
                    then_expr = then_e,
                    else_expr = else_e
                };
                te.line = l;
                te.column = c;
                return te;
            }
            return cond;
        }

        private Expr parse_coalesce (Expr? seed) throws ParseError, LexError {
            var left = parse_lor (seed);
            while (current.kind == TokenKind.QUESTION_QUESTION) {
                var l = left.line;
                var c = left.column;
                advance ();
                var right = parse_lor (null);
                left = new CoalesceExpr () { left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_lor (Expr? seed) throws ParseError, LexError {
            var left = parse_land (seed);
            while (current.kind == TokenKind.OROR) {
                var l = left.line;
                var c = left.column;
                advance ();
                var right = parse_land (null);
                left = new BinaryExpr () { op = "||", left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_land (Expr? seed) throws ParseError, LexError {
            var left = parse_bor (seed);
            while (current.kind == TokenKind.ANDAND) {
                var l = left.line;
                var c = left.column;
                advance ();
                var right = parse_bor (null);
                left = new BinaryExpr () { op = "&&", left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_bor (Expr? seed) throws ParseError, LexError {
            var left = parse_bxor (seed);
            while (current.kind == TokenKind.PIPE) {
                var l = left.line;
                var c = left.column;
                advance ();
                var right = parse_bxor (null);
                left = new BinaryExpr () { op = "|", left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_bxor (Expr? seed) throws ParseError, LexError {
            var left = parse_band (seed);
            while (current.kind == TokenKind.CARET) {
                var l = left.line;
                var c = left.column;
                advance ();
                var right = parse_band (null);
                left = new BinaryExpr () { op = "^", left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_band (Expr? seed) throws ParseError, LexError {
            var left = parse_cmp (seed);
            while (current.kind == TokenKind.AMP) {
                var l = left.line;
                var c = left.column;
                advance ();
                var right = parse_cmp (null);
                left = new BinaryExpr () { op = "&", left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_cmp (Expr? seed) throws ParseError, LexError {
            var left = parse_shift (seed);
            while (current.kind == TokenKind.IDENTIFIER && !current.is_escaped
                   && (current.text == "is" || current.text == "as")) {
                var op = current.text;
                var l = left.line;
                var c = left.column;
                advance ();
                ValaType tt = ValaType.VOID;
                string tt_name = "";
                if (current.kind != TokenKind.IDENTIFIER
                    || !parse_type (current.text, out tt, out tt_name, current.is_escaped)
                    || (tt != ValaType.CLASS && tt != ValaType.INTERFACE
                        && !(op == "is" && tt == ValaType.ERROR && tt_name != ""))) {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected class, interface, or error domain after '$op' at $(current.line):$(current.column)");
                }
                advance ();
                parse_generic_type_args (ref tt, ref tt_name);
                if ((tt == ValaType.CLASS || tt == ValaType.INTERFACE) && current.kind == TokenKind.QUESTION)
                    advance ();
                var tc = new TypeCheckExpr () {
                    op = op,
                    operand = left,
                    target_type = tt,
                    target_type_name = tt_name
                };
                tc.line = l;
                tc.column = c;
                left = tc;
            }
            TokenKind k = current.kind;
            if (k == TokenKind.LT || k == TokenKind.GT || k == TokenKind.LE
                || k == TokenKind.GE || k == TokenKind.EQ || k == TokenKind.NE) {
                var l = left.line;
                var c = left.column;
                var op = current.text;
                advance ();
                var right = parse_shift (null);
                left = new BinaryExpr () { op = op, left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_shift (Expr? seed) throws ParseError, LexError {
            var left = parse_add (seed);
            while (current.kind == TokenKind.SHL || current.kind == TokenKind.SHR) {
                var l = left.line;
                var c = left.column;
                var op = current.text;
                advance ();
                var right = parse_add (null);
                left = new BinaryExpr () { op = op, left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_add (Expr? seed) throws ParseError, LexError {
            var left = parse_mul (seed);
            while (current.kind == TokenKind.PLUS || current.kind == TokenKind.MINUS) {
                var l = left.line;
                var c = left.column;
                var op = current.text;
                advance ();
                var right = parse_mul (null);
                left = new BinaryExpr () { op = op, left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_mul (Expr? seed) throws ParseError, LexError {
            var left = (seed != null) ? seed : parse_unary ();
            while (current.kind == TokenKind.STAR || current.kind == TokenKind.SLASH
                   || current.kind == TokenKind.PERCENT) {
                var l = left.line;
                var c = left.column;
                var op = current.text;
                advance ();
                var right = parse_unary ();
                left = new BinaryExpr () { op = op, left = left, right = right };
                left.line = l;
                left.column = c;
            }
            return left;
        }

        private Expr parse_unary () throws ParseError, LexError {
            if (current.kind == TokenKind.PLUS) {
                advance ();
                return parse_unary ();
            }
            if (current.kind == TokenKind.MINUS || current.kind == TokenKind.NOT
                || current.kind == TokenKind.TILDE) {
                var l = current.line;
                var c = current.column;
                var op = current.text;
                advance ();
                var operand = parse_unary ();
                var e = new UnaryExpr () { op = op, operand = operand };
                e.line = l;
                e.column = c;
                return e;
            }
            if (current.kind == TokenKind.AMP) {
                var l = current.line;
                var c = current.column;
                advance ();
                return new AddrOfExpr () { target = parse_unary (), line = l, column = c };
            }
            if (current.kind == TokenKind.STAR) {
                var l = current.line;
                var c = current.column;
                advance ();
                return new DerefExpr () { target = parse_unary (), line = l, column = c };
            }
            if (current.kind == TokenKind.PLUSPLUS || current.kind == TokenKind.MINUSMINUS) {
                var l = current.line;
                var c = current.column;
                var op = (current.kind == TokenKind.PLUSPLUS) ? "++" : "--";
                advance ();
                var inc = new IncDecExpr () {
                    is_prefix = true,
                    op = op,
                    target = parse_unary (),
                    line = l,
                    column = c
                };
                return inc;
            }
            return parse_postfix (parse_primary ());
        }

        private Expr parse_postfix (Expr expr) throws ParseError, LexError {
            var e = expr;
            while (current.kind == TokenKind.DOT || current.kind == TokenKind.LBRACKET
                   || current.kind == TokenKind.PLUSPLUS || current.kind == TokenKind.MINUSMINUS
                   || current.kind == TokenKind.LPAREN) {
                var l = current.line;
                var c = current.column;
            if (current.kind == TokenKind.PLUSPLUS || current.kind == TokenKind.MINUSMINUS) {
                    var op = (current.kind == TokenKind.PLUSPLUS) ? "++" : "--";
                    advance ();
                    e = new IncDecExpr () {
                        is_prefix = false,
                        op = op,
                        target = e,
                        line = l,
                        column = c
                    };
                    continue;
                }
                if (current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected member name after '.' at $(current.line):$(current.column)");
                    var member = current.text;
                    advance ();
                    if (e is VarRef) {
                        var vr_ns = (VarRef) e;
                        if (types_prog.has_namespace (vr_ns.name) && types_prog.find_class (vr_ns.name) == null) {
                            if (types_prog.has_namespace (@"$(vr_ns.name).$member")) {
                                e = new VarRef () { name = @"$(vr_ns.name).$member", line = l, column = c };
                                continue;
                            }
                            if (current.kind == TokenKind.LPAREN) {
                                advance ();
                                var ce = new CallExpr () { callee = member, line = l, column = c };
                                parse_arg_list (ce.args);
                                expect (TokenKind.RPAREN, "')'");
                                e = ce;
                                continue;
                            }
                            e = new VarRef () { name = member, line = l, column = c };
                            continue;
                        }
                    }
                    if (member == "arg" && current.kind == TokenKind.LT) {
                        advance (); // '<'
                        parse_ownership_weak ();
                        ValaType at = ValaType.VOID;
                        string an = "";
                        if (current.kind != TokenKind.IDENTIFIER
                            || !parse_type (current.text, out at, out an, current.is_escaped)
                            || at == ValaType.VOID) {
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected type argument in 'arg<T>()' at $(current.line):$(current.column)");
                        }
                        advance ();
                        parse_type_suffix (ref at, ref an);
                        consume_gt ();
                        expect (TokenKind.LPAREN, "'('");
                        expect (TokenKind.RPAREN, "')'");
                        var va = new VaArgExpr () {
                            target = e,
                            arg_type = at,
                            arg_type_name = an,
                            line = l,
                            column = c
                        };
                        e = va;
                        continue;
                    }
                    if (current.kind == TokenKind.LPAREN) {
                        advance ();
                        var mc = new MethodCallExpr () { target = e, method_name = member };
                        parse_arg_list (mc.args);
                        expect (TokenKind.RPAREN, "')'");
                        mc.line = l;
                        mc.column = c;
                        e = mc;
                    } else {
                        var acc = new MemberAccessExpr () { target = e, member = member };
                        acc.line = l;
                        acc.column = c;
                        e = acc;
                    }
                } else if (current.kind == TokenKind.LPAREN) {
                    advance ();
                    var mc = new MethodCallExpr () { target = e, method_name = "" };
                    parse_arg_list (mc.args);
                    expect (TokenKind.RPAREN, "')'");
                    mc.line = l;
                    mc.column = c;
                    e = mc;
                } else {
                    advance (); // '['
                    var idx = parse_expr ();
                    if (current.kind == TokenKind.COLON) {
                        advance ();
                        var end_idx = parse_expr ();
                        expect (TokenKind.RBRACKET, "']'");
                        var sl = new SliceExpr () { target = e, start = idx, end = end_idx };
                        sl.line = l;
                        sl.column = c;
                        e = sl;
                    } else {
                        expect (TokenKind.RBRACKET, "']'");
                        var ix = new IndexExpr () { target = e, index = idx };
                        ix.line = l;
                        ix.column = c;
                        e = ix;
                    }
                }
            }
            return e;
        }

        private bool is_lambda_after_lparen () throws ParseError, LexError {
            var saved_lex = lexer.clone_state ();
            var saved_cur = current;
            advance (); // '('
            int depth = 1;
            bool ok = true;
            while (depth > 0) {
                if (current.kind == TokenKind.EOF || current.kind == TokenKind.SEMICOLON
                    || current.kind == TokenKind.LBRACE || current.kind == TokenKind.RBRACE) {
                    ok = false;
                    break;
                }
                if (current.kind == TokenKind.LPAREN)
                    depth++;
                else if (current.kind == TokenKind.RPAREN)
                    depth--;
                advance ();
            }
            bool res = ok && (current.kind == TokenKind.ARROW);
            lexer = saved_lex;
            current = saved_cur;
            return res;
        }

        private Expr parse_lambda_from_lparen (int l, int c) throws ParseError, LexError {
            advance (); // '('
            var lam = new LambdaExpr () { line = l, column = c };
            if (current.kind != TokenKind.RPAREN) {
                while (true) {
                    string last_id = "";
                    bool last_esc = false;
                    int angle_depth = 0;
                    while (current.kind != TokenKind.EOF
                           && !(angle_depth == 0
                                && (current.kind == TokenKind.COMMA || current.kind == TokenKind.RPAREN))) {
                        if (current.kind == TokenKind.LT)
                            angle_depth++;
                        else if (current.kind == TokenKind.GT && angle_depth > 0)
                            angle_depth--;
                        else if (current.kind == TokenKind.SHR && angle_depth > 0)
                            angle_depth = (angle_depth >= 2) ? (angle_depth - 2) : 0;
                        if (current.kind == TokenKind.IDENTIFIER || (current.text == "void" && !current.is_escaped)) {
                            last_id = current.text;
                            last_esc = current.is_escaped;
                        }
                        advance ();
                    }
                    if (last_id == "" || (!last_esc && is_reserved (last_id)))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected lambda parameter name at $(current.line):$(current.column)");
                    lam.param_names.add (last_id);
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
            }
            expect (TokenKind.RPAREN, "')'");
            expect (TokenKind.ARROW, "'=>'");
            if (current.kind == TokenKind.LBRACE)
                parse_block_into (lam.body);
            else
                lam.expr_body = parse_expr ();
            return lam;
        }

        private Expr parse_primary () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;

            if (current.kind == TokenKind.INTEGER) {
                var e = new IntLiteral () {
                    value = int64.parse (current.text),
                    is_unsigned = current.is_unsigned,
                    is_long = current.is_long
                };
                e.line = l;
                e.column = c;
                advance ();
                return e;
            }

            if (current.kind == TokenKind.FLOAT) {
                bool is_f32 = false;
                var bits = Ieee754.parse_bits (current.text, out is_f32);
                var e = new FloatLiteral () {
                    bits = bits,
                    is_float32 = is_f32,
                    raw_text = current.text
                };
                e.line = l;
                e.column = c;
                advance ();
                return e;
            }

            if (current.kind == TokenKind.STRING) {
                var e = new StringLiteral () { value = current.text };
                e.line = l;
                e.column = c;
                advance ();
                return e;
            }

            if (current.kind == TokenKind.TEMPLATE_STRING) {
                var tok = current;
                advance ();
                return parse_template (tok);
            }

            if (is_tok_kw (current, "yield")) {
                advance ();
                var v = parse_unary ();
                var ye = new YieldExpr () { value = v };
                ye.line = l;
                ye.column = c;
                return ye;
            }

            if (current.kind == TokenKind.LPAREN) {
                if (is_lambda_after_lparen ())
                    return parse_lambda_from_lparen (l, c);
                advance ();
                if (current.kind == TokenKind.NOT) {
                    var saved_lex = lexer.clone_state ();
                    var saved_cur = current;
                    advance (); // '!'
                    if (current.kind == TokenKind.RPAREN) {
                        advance (); // ')'
                        var tc = new TypeCheckExpr () {
                            op = "nonnull",
                            operand = parse_unary (),
                            target_type = ValaType.VOID,
                            target_type_name = ""
                        };
                        tc.line = l;
                        tc.column = c;
                        return tc;
                    }
                    lexer = saved_lex;
                    current = saved_cur;
                }
                if (current.kind == TokenKind.IDENTIFIER && !current.is_escaped && current.text == "owned") {
                    var saved_lex = lexer.clone_state ();
                    var saved_cur = current;
                    advance ();
                    if (current.kind == TokenKind.RPAREN) {
                        advance ();
                        return new UnaryExpr () {
                            op = "owned",
                            operand = parse_unary (),
                            line = l,
                            column = c
                        };
                    }
                    lexer = saved_lex;
                    current = saved_cur;
                }
                if (current.kind == TokenKind.IDENTIFIER || (current.text == "void" && !current.is_escaped)) {
                    var saved_lex = lexer.clone_state ();
                    var saved_cur = current;
                    var raw_name = current.text;
                    bool raw_esc = current.is_escaped;
                    ValaType ct = ValaType.VOID;
                    string ct_name = "";
                    if (parse_type (raw_name, out ct, out ct_name, raw_esc)) {
                        advance ();
                        parse_generic_type_args (ref ct, ref ct_name);
                        if (!(current.kind == TokenKind.LBRACKET && lexer.clone_state ().next ().kind != TokenKind.RBRACKET))
                            parse_type_suffix (ref ct, ref ct_name);
                        bool ct_is_del = (ct == ValaType.STRUCT && types_prog.find_delegate (ct_name) != null);
                        if (pending_gt == 0 && current.kind == TokenKind.RPAREN
                            && (ct == ValaType.CLASS || ct == ValaType.INTERFACE || ct == ValaType.ENUM
                                || ct == ValaType.STRING || ct == ValaType.POINTER || ct_is_del
                                || ct == ValaType.INT || ct == ValaType.FLOAT || ct == ValaType.DOUBLE)) {
                            advance (); // ')'
                            if ((ct == ValaType.INT || ct == ValaType.FLOAT || ct == ValaType.DOUBLE) && ct_name == "")
                                ct_name = raw_name;
                            // `(x)` is a cast only when an expression follows.
                            // A name that also happens to be a delegate or
                            // class type (a single letter in translated C,
                            // say) must not swallow the operand, so a failed
                            // parse backtracks to plain grouping.
                            var after_lex = lexer.clone_state ();
                            var after_cur = current;
                            try {
                                var tc = new TypeCheckExpr () {
                                    op = "cast",
                                    operand = parse_unary (),
                                    target_type = ct,
                                    target_type_name = ct_name
                                };
                                tc.line = l;
                                tc.column = c;
                                return tc;
                            } catch (ParseError e) {
                                lexer = after_lex;
                                current = after_cur;
                                pending_gt = 0;
                            }
                        }
                    }
                    pending_gt = 0;
                    lexer = saved_lex;
                    current = saved_cur;
                }
                var e = parse_expr ();
                expect (TokenKind.RPAREN, "')'");
                return e;
            }

            if (current.kind == TokenKind.LBRACE) {
                advance ();
                var arr = new ArrayLiteralExpr ();
                arr.line = l;
                arr.column = c;
                while (current.kind != TokenKind.RBRACE) {
                    arr.elements.add (parse_expr ());
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                if (arr.elements.length == 0)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"empty array literal '{}' is not supported; use 'new T[0]' at $l:$c");
                expect (TokenKind.RBRACE, "'}'");
                return arr;
            }

            if (current.kind == TokenKind.IDENTIFIER) {
                if (!current.is_escaped && (current.text == "true" || current.text == "false")) {
                    var b = new BoolLiteral () { value = (current.text == "true") };
                    b.line = l;
                    b.column = c;
                    advance ();
                    return b;
                }
                if (!current.is_escaped && current.text == "null") {
                    advance ();
                    var nl = new NullLiteral ();
                    nl.line = l;
                    nl.column = c;
                    return nl;
                }
                if (!current.is_escaped && current.text == "this") {
                    advance ();
                    var vr = new VarRef () { name = "this" };
                    vr.line = l;
                    vr.column = c;
                    return vr;
                }
                if (!current.is_escaped && current.text == "base") {
                    advance ();
                    expect (TokenKind.DOT, "'.'");
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected method name after 'base.' at $(current.line):$(current.column)");
                    var mname = current.text;
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var mc = new MethodCallExpr () {
                        is_base_call = true,
                        method_name = mname
                    };
                    parse_arg_list (mc.args);
                    expect (TokenKind.RPAREN, "')'");
                    mc.line = l;
                    mc.column = c;
                    return mc;
                }
                if (!current.is_escaped && current.text == "new") {
                    advance ();
                    ValaType et = ValaType.VOID;
                    string et_name = "";
                    string raw_elem = (current.kind == TokenKind.IDENTIFIER) ? current.text : "";
                    bool raw_elem_esc = (current.kind == TokenKind.IDENTIFIER) && current.is_escaped;
                    if (current.kind == TokenKind.IDENTIFIER && !raw_elem_esc && (types_prog.has_namespace (raw_elem) || raw_elem == "GLib")) {
                        string ns_acc = raw_elem;
                        var saved_lx = lexer.clone_state ();
                        var saved_cur = current;
                        advance ();
                        while ((types_prog.has_namespace (ns_acc) || ns_acc == "GLib") && current.kind == TokenKind.DOT) {
                            advance ();
                            if (current.kind != TokenKind.IDENTIFIER)
                                break;
                            var seg = current.text;
                            var seg_esc = current.is_escaped;
                            if (!seg_esc && types_prog.has_namespace (@"$ns_acc.$seg")) {
                                ns_acc = @"$ns_acc.$seg";
                                advance ();
                                continue;
                            }
                            raw_elem = seg;
                            raw_elem_esc = seg_esc;
                            break;
                        }
                        if (current.kind != TokenKind.IDENTIFIER) {
                            lexer = saved_lx;
                            current = saved_cur;
                        }
                    }
                    if (current.kind != TokenKind.IDENTIFIER
                        || !parse_type (raw_elem, out et, out et_name, raw_elem_esc)
                        || et == ValaType.VOID) {
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected class or array element type after 'new' at $(current.line):$(current.column)");
                    }
                    if (et == ValaType.INT) {
                        if (raw_elem == "uint8" || raw_elem == "uchar" || raw_elem == "char")
                            et_name = "uint8";
                        else if (raw_elem == "int8")
                            et_name = "int8";
                        else
                            et_name = raw_elem;
                    }
                    advance ();
                    parse_generic_type_args (ref et, ref et_name);
                    string sub_ctor = "";
                    bool has_ctor_dot = false;
                    if (et == ValaType.CLASS && current.kind == TokenKind.DOT) {
                        has_ctor_dot = true;
                        advance ();
                        if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected constructor name after '.' at $(current.line):$(current.column)");
                        sub_ctor = current.text;
                        advance ();
                    }
                    if (et == ValaType.CLASS && (has_ctor_dot || current.kind == TokenKind.LPAREN)) {
                        expect (TokenKind.LPAREN, "'('");
                        var cn = new ClassNewExpr () { class_name = et_name, ctor_name = sub_ctor };
                        parse_arg_list (cn.args);
                        expect (TokenKind.RPAREN, "')'");
                        if (current.kind == TokenKind.LBRACE) {
                            advance ();
                            while (current.kind != TokenKind.RBRACE) {
                                if (current.kind != TokenKind.IDENTIFIER || is_tok_reserved (current))
                                    throw new ParseError.UNEXPECTED_TOKEN (
                                        @"expected property or field name in initializer at $(current.line):$(current.column)");
                                var mname = current.text;
                                advance ();
                                expect (TokenKind.ASSIGN, "'='");
                                var mval = parse_expr ();
                                cn.init_names.add (mname);
                                cn.init_values.add (mval);
                                if (current.kind == TokenKind.COMMA) {
                                    advance ();
                                    continue;
                                }
                                break;
                            }
                            expect (TokenKind.RBRACE, "'}'");
                        }
                        cn.line = l;
                        cn.column = c;
                        return cn;
                    }
                    if (current.kind == TokenKind.QUESTION) {
                        advance ();
                        et_name = et_name + "?";
                    }
                    while (true) {
                        expect (TokenKind.LBRACKET, "'['");
                        if (current.kind == TokenKind.RBRACKET) {
                            advance (); // ']'
                            if (current.kind == TokenKind.LBRACKET) {
                                et_name = (et == ValaType.ARRAY)
                                    ? (et_name + "[]")
                                    : ((et == ValaType.ENUM || et == ValaType.CLASS || et == ValaType.INTERFACE
                                        || et == ValaType.ERROR || et == ValaType.TYPE_PARAM
                                        || et == ValaType.STRUCT || is_int_type_name (et_name))
                                       ? et_name : et.label ());
                                et = ValaType.ARRAY;
                                continue;
                            }
                            expect (TokenKind.LBRACE, "'{'");
                            var arr = new ArrayLiteralExpr ();
                            arr.elem_type = et;
                            arr.elem_type_name = et_name;
                            arr.line = l;
                            arr.column = c;
                            while (current.kind != TokenKind.RBRACE) {
                                arr.elements.add (parse_expr ());
                                if (current.kind == TokenKind.COMMA) {
                                    advance ();
                                    continue;
                                }
                                break;
                            }
                            if (arr.elements.length == 0)
                                throw new ParseError.UNEXPECTED_TOKEN (
                                    @"empty array literal '{}' is not supported; use 'new T[0]' at $l:$c");
                            expect (TokenKind.RBRACE, "'}'");
                            return arr;
                        }
                        var len_expr = parse_expr ();
                        expect (TokenKind.RBRACKET, "']'");
                        var an = new ArrayNewExpr () {
                            elem_type = et,
                            elem_type_name = et_name,
                            length_expr = len_expr
                        };
                        an.line = l;
                        an.column = c;
                        return an;
                    }
                }
                if (!current.is_escaped && (is_int_type_name (current.text) || is_fp_type_name (current.text))) {
                    var plx = lexer.clone_state ();
                    var nxt = plx.next ();
                    if (nxt.kind == TokenKind.DOT) {
                        var tname = current.text;
                        advance ();
                        var vr = new VarRef () { name = tname };
                        vr.line = l;
                        vr.column = c;
                        return vr;
                    }
                }
                if (is_tok_kw (current, "sizeof")) {
                    advance (); // 'sizeof'
                    expect (TokenKind.LPAREN, "'('");
                    var se = new SizeofExpr ();
                    se.line = l;
                    se.column = c;
                    var saved_lx = lexer.clone_state ();
                    var saved_cur = current;
                    ValaType tt = ValaType.VOID;
                    string tn = "";
                    if (current.kind == TokenKind.IDENTIFIER && parse_type_with_ns (out tt, out tn)) {
                        parse_type_suffix (ref tt, ref tn);
                        parse_generic_type_args (ref tt, ref tn);
                        if (current.kind == TokenKind.RPAREN) {
                            se.target_type = tt;
                            se.type_name = tn;
                            se.is_type_form = true;
                        } else {
                            lexer = saved_lx;
                            current = saved_cur;
                            se.operand = parse_expr ();
                            se.is_type_form = false;
                        }
                    } else {
                        se.operand = parse_expr ();
                        se.is_type_form = false;
                    }
                    expect (TokenKind.RPAREN, "')'");
                    return se;
                }
                if (is_tok_reserved (current))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword, not a value at $l:$c");
                var name = current.text;
                advance ();
                if (current.kind == TokenKind.ARROW) {
                    advance (); // '=>'
                    var lam = new LambdaExpr () { line = l, column = c };
                    lam.param_names.add (name);
                    if (current.kind == TokenKind.LBRACE)
                        parse_block_into (lam.body);
                    else
                        lam.expr_body = parse_expr ();
                    return lam;
                }
                if (current.kind == TokenKind.LT) {
                    unowned var s_tmpl = types_prog.find_struct (name);
                    unowned var c_tmpl = types_prog.find_class (name);
                    if (s_tmpl != null && s_tmpl.is_generic_template) {
                        ValaType st = ValaType.STRUCT;
                        string sn = name;
                        parse_generic_type_args (ref st, ref sn);
                        name = sn;
                    } else if ((c_tmpl != null && c_tmpl.is_generic_template) || name == "GenericArray" || name == "Channel" || name == "Node") {
                        ValaType ct = ValaType.CLASS;
                        string cn = name;
                        parse_generic_type_args (ref ct, ref cn);
                        name = cn;
                    }
                }
                if (current.kind == TokenKind.LPAREN) {
                    if (types_prog.find_struct (name) != null || program.find_instantiation_by_mangled (name) != null)
                        return parse_struct_literal_rest (name, l, c);
                    return parse_call_rest (name, l, c);
                }
                unowned var gfn = program.find (name);
                if (current.kind == TokenKind.LT && gfn != null && gfn.is_generic_template) {
                    advance ();
                    var type_args = new GenericArray<string> ();
                    while (true) {
                        if (current.kind != TokenKind.IDENTIFIER
                            || (!current.is_escaped && is_reserved (current.text) && !is_sizeof_type_name (current.text)))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected type argument for '$name' at $(current.line):$(current.column)");
                        var ta = current.text;
                        advance ();
                        if (current.kind == TokenKind.QUESTION) {
                            ta = ta + "?";
                            advance ();
                        }
                        while (current.kind == TokenKind.LBRACKET) {
                            advance ();
                            expect (TokenKind.RBRACKET, "']'");
                            ta = ta + "[]";
                        }
                        type_args.add (ta);
                        if (current.kind == TokenKind.COMMA) {
                            advance ();
                            continue;
                        }
                        break;
                    }
                    consume_gt ();
                    return parse_call_rest (name, l, c, type_args);
                }
                var e = new VarRef () { name = name };
                e.line = l;
                e.column = c;
                return e;
            }

            throw new ParseError.UNEXPECTED_TOKEN (
                @"expected an expression at $l:$c");
        }

        private Expr parse_struct_literal_rest (string name, int l, int c)
                throws ParseError, LexError {
            advance (); // '('
            expect (TokenKind.RPAREN, "')'");
            var lit = new StructLiteral () { struct_name = name };
            lit.line = l;
            lit.column = c;
            if (current.kind == TokenKind.LBRACE) {
                advance ();
                while (current.kind != TokenKind.RBRACE) {
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected field name in struct literal at $(current.line):$(current.column)");
                    if (is_tok_reserved (current))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"'$(current.text)' is a keyword and cannot name a field at $(current.line):$(current.column)");
                    var fname = current.text;
                    advance ();
                    expect (TokenKind.ASSIGN, "'='");
                    var fval = parse_expr ();
                    lit.field_names.add (fname);
                    lit.field_values.add (fval);
                    if (current.kind == TokenKind.COMMA) {
                        advance ();
                        continue;
                    }
                    break;
                }
                expect (TokenKind.RBRACE, "'}'");
            }
            return lit;
        }

        private static bool is_ident_start (uint8 c) {
            return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }

        private static bool is_ident_cont (uint8 c) {
            return is_ident_start (c) || (c >= '0' && c <= '9');
        }

        private static void rebase_expr (Expr e, int line, int col) {
            e.line = line;
            e.column = col;
            if (e is UnaryExpr) {
                rebase_expr (((UnaryExpr) e).operand, line, col);
            } else if (e is BinaryExpr) {
                var b = (BinaryExpr) e;
                rebase_expr (b.left, line, col);
                rebase_expr (b.right, line, col);
            } else if (e is CallExpr) {
                foreach (var a in ((CallExpr) e).args)
                    rebase_expr (a, line, col);
            } else if (e is ClassNewExpr) {
                var cne = (ClassNewExpr) e;
                foreach (var a in cne.args)
                    rebase_expr (a, line, col);
                foreach (var iv in cne.init_values)
                    rebase_expr (iv, line, col);
            } else if (e is MethodCallExpr) {
                var mc = (MethodCallExpr) e;
                if (mc.target != null)
                    rebase_expr (mc.target, line, col);
                foreach (var a in mc.args)
                    rebase_expr (a, line, col);
            } else if (e is TypeCheckExpr) {
                rebase_expr (((TypeCheckExpr) e).operand, line, col);
            } else if (e is SliceExpr) {
                var sl = (SliceExpr) e;
                rebase_expr (sl.target, line, col);
                rebase_expr (sl.start, line, col);
                rebase_expr (sl.end, line, col);
            } else if (e is TernaryExpr) {
                var te = (TernaryExpr) e;
                rebase_expr (te.condition, line, col);
                rebase_expr (te.then_expr, line, col);
                rebase_expr (te.else_expr, line, col);
            } else if (e is CoalesceExpr) {
                var ce = (CoalesceExpr) e;
                rebase_expr (ce.left, line, col);
                rebase_expr (ce.right, line, col);
            } else if (e is IncDecExpr) {
                rebase_expr (((IncDecExpr) e).target, line, col);
            } else if (e is MemberAccessExpr) {
                rebase_expr (((MemberAccessExpr) e).target, line, col);
            } else if (e is IndexExpr) {
                var ix = (IndexExpr) e;
                rebase_expr (ix.target, line, col);
                rebase_expr (ix.index, line, col);
            } else if (e is ArrayNewExpr) {
                rebase_expr (((ArrayNewExpr) e).length_expr, line, col);
            } else if (e is ArrayLiteralExpr) {
                foreach (var el in ((ArrayLiteralExpr) e).elements)
                    rebase_expr (el, line, col);
            } else if (e is StructLiteral) {
                foreach (var fv in ((StructLiteral) e).field_values)
                    rebase_expr (fv, line, col);
            } else if (e is TemplateExpr) {
                foreach (var p in ((TemplateExpr) e).parts)
                    rebase_expr (p, line, col);
            } else if (e is LambdaExpr) {
                var lam = (LambdaExpr) e;
                if (lam.expr_body != null)
                    rebase_expr (lam.expr_body, line, col);
            }
        }

        private Expr parse_standalone_expr (int base_line, int base_col)
                throws ParseError, LexError {
            advance ();
            var e = parse_expr ();
            if (current.kind != TokenKind.EOF)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unexpected '$(current.text)' in template interpolation at $base_line:$base_col");
            rebase_expr (e, base_line, base_col);
            return e;
        }

        private static bool is_blank_str (string s) {
            for (int i = 0; i < s.length; i++) {
                var c = s[i];
                if (c != ' ' && c != '\t' && c != '\r' && c != '\n')
                    return false;
            }
            return true;
        }

        private Expr parse_template (Token tok) throws ParseError, LexError {
            var tpl = new TemplateExpr ();
            tpl.line = tok.line;
            tpl.column = tok.column;

            var s = tok.text;
            var n = s.length;
            var lit = new StrBuilder ();
            int i = 0;

            while (i < n) {
                var ch = s[i];
                if (ch != '$') {
                    lit.append_c ((char) ch);
                    i++;
                    continue;
                }

                if (i + 1 < n && s[i + 1] == '$') {
                    lit.append_c ('$');
                    i += 2;
                    continue;
                }

                if (lit.length > 0) {
                    var sl = new StringLiteral () { value = lit.str };
                    sl.line = tok.line;
                    sl.column = tok.column;
                    tpl.parts.add (sl);
                    lit = new StrBuilder ();
                }

                if (i + 1 >= n)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"dangling '$$' in template string at $(tok.line):$(tok.column)");

                if (s[i + 1] == '(') {
                    int j = i + 2;
                    int depth = 1;
                    bool in_str = false;
                    while (j < n && depth > 0) {
                        var x = s[j];
                        if (in_str) {
                            if (x == '\\' && j + 1 < n) {
                                j += 2;
                                continue;
                            }
                            if (x == '"')
                                in_str = false;
                        } else {
                            if (x == '"')
                                in_str = true;
                            else if (x == '\'') {
                                j++;
                                if (j < n && s[j] == '\\')
                                    j++;
                                if (j < n)
                                    j++;
                                if (j < n && s[j] == '\'')
                                    j++;
                                continue;
                            } else if (x == '(')
                                depth++;
                            else if (x == ')')
                                depth--;
                        }
                        j++;
                    }
                    if (depth != 0)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"unterminated '$$(' in template string at $(tok.line):$(tok.column)");
                    var inner = s[i + 2 : j - 1];
                    if (is_blank_str (inner))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"empty interpolation in template string at $(tok.line):$(tok.column)");
                    try {
                        var sub = new Parser.with_program (inner, program);
                        tpl.parts.add (sub.parse_standalone_expr (tok.line, tok.column));
                    } catch (LexError e) {
                        throw new LexError.UNEXPECTED_CHARACTER (
                            @"$(e.message) inside template at $(tok.line):$(tok.column)");
                    } catch (ParseError e) {
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"$(e.message) inside template at $(tok.line):$(tok.column)");
                    }
                    i = j;
                } else if (is_ident_start (s[i + 1])) {
                    int j = i + 1;
                    while (j < n && is_ident_cont (s[j]))
                        j++;
                    var ident = s[i + 1 : j];
                    if (is_reserved (ident))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"'$ident' is a keyword and cannot be interpolated at $(tok.line):$(tok.column)");
                    var v = new VarRef () { name = ident };
                    v.line = tok.line;
                    v.column = tok.column;
                    tpl.parts.add (v);
                    i = j;
                } else {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"invalid '$$' interpolation in template string at $(tok.line):$(tok.column)");
                }
            }

            if (lit.length > 0) {
                var sl = new StringLiteral () { value = lit.str };
                sl.line = tok.line;
                sl.column = tok.column;
                tpl.parts.add (sl);
            }

            return tpl;
        }

        // Parses `name(...)` with the identifier already consumed.
        private Expr parse_call_rest (string name, int l, int c,
                                      GenericArray<string>? type_args = null)
                throws ParseError, LexError {
            advance (); // '('
            var call = new CallExpr () { callee = name };
            if (type_args != null) {
                foreach (var ta in type_args)
                    call.type_arg_names.add (ta);
            }
            parse_arg_list (call.args);
            expect (TokenKind.RPAREN, "')'");
            if (name == "va_list" && call.args.length == 0) {
                var vr = new VarRef () { name = "__planc_va_list" };
                vr.line = l;
                vr.column = c;
                return vr;
            }
            call.line = l;
            call.column = c;
            return call;
        }
    }
}
