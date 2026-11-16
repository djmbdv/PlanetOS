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

    public class Parser : Object {

        private Lexer lexer;
        private Token current;
        private Program program;

        private string source_text;

        private static bool is_int_type_name (string text) {
            return text == "int" || text == "int64" || text == "int32"
                || text == "int16" || text == "int8"
                || text == "uint64" || text == "uint32" || text == "uint16"
                || text == "uint8" || text == "size_t" || text == "ssize_t"
                || text == "char" || text == "uchar";
        }

        private static bool is_reserved (string text) {
            return is_int_type_name (text) || text == "bool" || text == "string"
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
                || text == "while" || text == "for" || text == "foreach" || text == "in"
                || text == "switch" || text == "case" || text == "default"
                || text == "break" || text == "continue"
                || text == "enum" || text == "struct" || text == "class";
        }

        private void parse_type_suffix (ref ValaType t, ref string tname)
                throws ParseError, LexError {
            if (current.kind == TokenKind.LBRACKET) {
                if (t == ValaType.VOID || t == ValaType.STRUCT || t == ValaType.ARRAY)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"unsupported array element type at $(current.line):$(current.column)");
                advance ();
                expect (TokenKind.RBRACKET, "']'");
                tname = (t == ValaType.ENUM || t == ValaType.CLASS || t == ValaType.ERROR) ? tname : t.label ();
                t = ValaType.ARRAY;
            }
            if (current.kind == TokenKind.QUESTION) {
                if (t != ValaType.CLASS && t != ValaType.STRING && t != ValaType.ARRAY && t != ValaType.ERROR)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"only reference types can be nullable ('?') at $(current.line):$(current.column)");
                advance ();
                tname = tname + "?";
            }
        }

        private bool parse_type (string text, out ValaType t, out string tname) {
            tname = "";
            if (text == "void") {
                t = ValaType.VOID;
                return true;
            }
            if (is_int_type_name (text)) {
                t = ValaType.INT;
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
            if (program.find_error_domain (text) != null) {
                t = ValaType.ERROR;
                tname = text;
                return true;
            }
            if (program.find_enum (text) != null) {
                t = ValaType.ENUM;
                tname = text;
                return true;
            }
            if (program.find_struct (text) != null) {
                t = ValaType.STRUCT;
                tname = text;
                return true;
            }
            if (program.find_class (text) != null) {
                t = ValaType.CLASS;
                tname = text;
                return true;
            }
            t = ValaType.VOID;
            return false;
        }

        public Parser (string source) {
            source_text = source;
            lexer = new Lexer (source);
            program = new Program ();
        }

        public Parser.with_program (string source, Program existing) {
            source_text = source;
            lexer = new Lexer (source);
            program = existing;
        }

        public static void prescan_types (string source, Program prog) throws LexError {
            var lx = new Lexer (source);
            var prev_kind = TokenKind.EOF;
            while (true) {
                var tok = lx.next ();
                if (tok.kind == TokenKind.EOF)
                    break;
                if (tok.kind == TokenKind.IDENTIFIER && prev_kind != TokenKind.DOT
                    && (tok.text == "enum" || tok.text == "struct"
                        || tok.text == "class" || tok.text == "errordomain")) {
                    var kind_kw = tok.text;
                    var nt = lx.next ();
                    if (nt.kind == TokenKind.EOF)
                        break;
                    if (nt.kind == TokenKind.IDENTIFIER && !is_reserved (nt.text)) {
                        var tname = nt.text;
                        bool exists = prog.find_enum (tname) != null
                                   || prog.find_struct (tname) != null
                                   || prog.find_class (tname) != null
                                   || prog.find_error_domain (tname) != null;
                        if (!exists) {
                            if (kind_kw == "enum") {
                                prog.enums.add (new EnumDecl () {
                                    name = tname, line = nt.line, column = nt.column
                                });
                            } else if (kind_kw == "struct") {
                                prog.structs.add (new StructDecl () {
                                    name = tname, line = nt.line, column = nt.column
                                });
                            } else if (kind_kw == "class") {
                                prog.classes.add (new ClassDecl () {
                                    name = tname, line = nt.line, column = nt.column
                                });
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

        private void advance () throws ParseError, LexError {
            current = lexer.next ();
        }

        private void expect (TokenKind expected, string what) throws ParseError, LexError {
            if (current.kind != expected)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected $what at $(current.line):$(current.column)");
            advance ();
        }

        public void parse_unit () throws ParseError, LexError {
            advance ();
            while (current.kind != TokenKind.EOF)
                parse_top_level ();
        }

        public Program parse_program () throws ParseError, LexError {
            prescan_types (source_text, program);
            parse_unit ();

            if (program.find ("main") == null)
                throw new ParseError.MISSING_MAIN ("the program does not define main");

            return program;
        }

        private bool has_other_top_name (string name, string except_kind) {
            return program.find (name) != null
                || find_global (program, name) != null
                || program.find_const ("", name) != null
                || (except_kind != "enum" && program.find_enum (name) != null)
                || (except_kind != "struct" && program.find_struct (name) != null)
                || (except_kind != "class" && program.find_class (name) != null)
                || (except_kind != "errordomain" && program.find_error_domain (name) != null);
        }

        private bool has_top_name (string name) {
            return has_other_top_name (name, "");
        }

        private static bool is_visibility_modifier (string text) {
            return text == "public" || text == "private"
                || text == "internal" || text == "protected";
        }

        private void skip_ownership_modifiers () throws ParseError, LexError {
            while (current.kind == TokenKind.IDENTIFIER
                   && (current.text == "unowned" || current.text == "owned")) {
                advance ();
            }
        }

        private void parse_const_decl (string owner_type) throws ParseError, LexError {
            var cl = current.line;
            var cc = current.column;
            advance (); // 'const'
            ValaType ct = ValaType.VOID;
            string ct_name = "";
            if (current.kind != TokenKind.IDENTIFIER
                || !parse_type (current.text, out ct, out ct_name)
                || ct == ValaType.VOID || ct == ValaType.STRUCT || ct == ValaType.ARRAY || ct == ValaType.CLASS) {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unsupported const type at $(current.line):$(current.column)");
            }
            advance ();
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected constant name at $(current.line):$(current.column)");
            if (is_reserved (current.text))
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
                cd.int_value = parse_signed_int_literal ("const int initializer must be an integer literal");
            } else if (ct == ValaType.BOOL) {
                if (current.kind == TokenKind.IDENTIFIER && current.text == "true") {
                    cd.int_value = 1;
                    advance ();
                } else if (current.kind == TokenKind.IDENTIFIER && current.text == "false") {
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
                unowned var ed = program.find_enum (ename);
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

        private void parse_top_level () throws ParseError, LexError {
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected a declaration at $(current.line):$(current.column)");

            while (current.kind == TokenKind.IDENTIFIER && is_visibility_modifier (current.text))
                advance ();

            if (current.kind == TokenKind.IDENTIFIER && current.text == "using") {
                advance ();
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected namespace name after 'using' at $(current.line):$(current.column)");
                advance ();
                while (current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected identifier after '.' at $(current.line):$(current.column)");
                    advance ();
                }
                expect (TokenKind.SEMICOLON, "';'");
                return;
            }

            if (current.kind == TokenKind.IDENTIFIER && current.text == "namespace") {
                advance ();
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected namespace name at $(current.line):$(current.column)");
                advance ();
                while (current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected identifier after '.' at $(current.line):$(current.column)");
                    advance ();
                }
                expect (TokenKind.LBRACE, "'{'");
                while (current.kind != TokenKind.RBRACE) {
                    if (current.kind == TokenKind.EOF)
                        throw new ParseError.UNEXPECTED_TOKEN ("unterminated namespace declaration");
                    parse_top_level ();
                }
                expect (TokenKind.RBRACE, "'}'");
                return;
            }

            if (current.kind == TokenKind.IDENTIFIER && current.text == "errordomain") {
                parse_errordomain ();
                return;
            }

            if (current.kind == TokenKind.IDENTIFIER && current.text == "const") {
                parse_const_decl ("");
                return;
            }

            bool is_abstract = false;
            bool is_static = false;
            while (current.kind == TokenKind.IDENTIFIER
                   && (current.text == "abstract" || current.text == "static")) {
                if (current.text == "abstract") is_abstract = true;
                else is_static = true;
                advance ();
            }

            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected a declaration at $(current.line):$(current.column)");

            if (current.text == "class") {
                if (is_static)
                    throw new ParseError.UNEXPECTED_TOKEN (@"top-level class cannot be 'static' at $(current.line):$(current.column)");
                parse_class (is_abstract);
                return;
            }
            if (is_abstract) {
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'abstract' is only valid on classes at $(current.line):$(current.column)");
            }
            if (current.text == "enum") {
                parse_enum ();
                return;
            }
            if (current.text == "struct") {
                parse_struct ();
                return;
            }

            skip_ownership_modifiers ();

            ValaType decl_type = ValaType.VOID;
            string type_name = "";
            if (!parse_type (current.text, out decl_type, out type_name)) {
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
            if (is_reserved (current.text))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot be used as a name at $(current.line):$(current.column)");
            var name = current.text;
            advance ();

            if (current.kind == TokenKind.LPAREN) {
                var f = parse_function_rest (decl_type, type_name, name, type_line, type_column);
                f.is_static = is_static;
                if (has_top_name (name))
                    throw new ParseError.DUPLICATE_FUNCTION (
                        @"duplicate name: $name at $(f.line):$(f.column)");
                program.functions.add (f);
                return;
            }

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
                } else if (decl_type == ValaType.BOOL) {
                    if (current.kind == TokenKind.IDENTIFIER && current.text == "true") {
                        g.value = 1;
                        advance ();
                    } else if (current.kind == TokenKind.IDENTIFIER && current.text == "false") {
                        g.value = 0;
                        advance ();
                    } else {
                        g.value = parse_signed_int_literal ("a global bool initializer must be 'true', 'false', or an integer literal");
                    }
                    g.initialized = true;
                } else if (decl_type == ValaType.ENUM) {
                    if (current.kind == TokenKind.IDENTIFIER) {
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
                        unowned var ed = program.find_enum (ename);
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

        private void parse_throws_clause (GenericArray<string> dst) throws ParseError, LexError {
            if (current.kind == TokenKind.IDENTIFIER && current.text == "throws") {
                advance ();
                while (true) {
                    if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
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

        private void parse_errordomain () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'errordomain'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected errordomain name at $(current.line):$(current.column)");
            if (is_reserved (current.text))
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
                if (is_reserved (current.text))
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

        private void parse_enum () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'enum'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected enum name at $(current.line):$(current.column)");
            if (is_reserved (current.text))
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
                if (is_reserved (current.text))
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
                    next_val = parse_signed_int_literal ("enum member value must be an integer literal");
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
                    while (current.kind == TokenKind.IDENTIFIER && is_visibility_modifier (current.text))
                        advance ();
                    bool is_static = false;
                    if (current.kind == TokenKind.IDENTIFIER && current.text == "static") {
                        is_static = true;
                        advance ();
                    }
                    skip_ownership_modifiers ();
                    var ml = current.line;
                    var mc = current.column;
                    ValaType rt = ValaType.VOID;
                    string rt_name = "";
                    if (current.kind != TokenKind.IDENTIFIER || !parse_type (current.text, out rt, out rt_name))
                        throw new ParseError.UNEXPECTED_TOKEN (@"expected method return type in enum '$name' at $ml:$mc");
                    advance ();
                    parse_type_suffix (ref rt, ref rt_name);
                    if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
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
                while (current.kind == TokenKind.IDENTIFIER && is_visibility_modifier (current.text))
                    advance ();
                skip_ownership_modifiers ();
                if (current.kind == TokenKind.IDENTIFIER && current.text == "default") {
                    if (!is_class)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"'default' initializer is not supported in struct property '$mname' at $(current.line):$(current.column)");
                    advance ();
                    expect (TokenKind.ASSIGN, "'='");
                    default_init = parse_expr ();
                    expect (TokenKind.SEMICOLON, "';'");
                } else if (current.kind == TokenKind.IDENTIFIER && current.text == "get") {
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
                } else if (current.kind == TokenKind.IDENTIFIER
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

        private void parse_struct () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'struct'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected struct name at $(current.line):$(current.column)");
            if (is_reserved (current.text))
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
                sd_existing = new StructDecl () { name = name };
                program.structs.add (sd_existing);
            }
            sd_existing.is_defined = true;
            sd_existing.line = l;
            sd_existing.column = c;
            var sd = sd_existing;
            expect (TokenKind.LBRACE, "'{'");
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN ("unterminated struct declaration");
                while (current.kind == TokenKind.IDENTIFIER && is_visibility_modifier (current.text))
                    advance ();
                if (current.kind == TokenKind.IDENTIFIER && current.text == "const") {
                    parse_const_decl (sd.name);
                    continue;
                }
                bool is_static = false;
                if (current.kind == TokenKind.IDENTIFIER && current.text == "static") {
                    is_static = true;
                    advance ();
                }
                skip_ownership_modifiers ();
                ValaType ft = ValaType.VOID;
                string ft_name = "";
                if (current.kind != TokenKind.IDENTIFIER
                    || !parse_type (current.text, out ft, out ft_name)) {
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
                if (is_reserved (current.text))
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
        }

        private void parse_arg_list (GenericArray<Expr> dst) throws ParseError, LexError {
            if (current.kind != TokenKind.RPAREN) {
                while (true) {
                    if (current.kind == TokenKind.IDENTIFIER
                        && (current.text == "ref" || current.text == "out")) {
                        advance ();
                    }
                    dst.add (parse_expr ());
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
                    bool is_ref = false;
                    bool is_out = false;
                    if (current.kind == TokenKind.IDENTIFIER && current.text == "ref") {
                        is_ref = true;
                        advance ();
                    } else if (current.kind == TokenKind.IDENTIFIER && current.text == "out") {
                        is_out = true;
                        advance ();
                    }
                    skip_ownership_modifiers ();
                    ValaType pt = ValaType.VOID;
                    string pt_name = "";
                    if (current.kind != TokenKind.IDENTIFIER
                        || !parse_type (current.text, out pt, out pt_name)
                        || pt == ValaType.VOID) {
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected a parameter type in parameter list at $(current.line):$(current.column)");
                    }
                    advance ();
                    parse_type_suffix (ref pt, ref pt_name);
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected a parameter name at $(current.line):$(current.column)");
                    if (is_reserved (current.text))
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
                    plist.add (p);
                    advance ();
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
                body.add (parse_statement ());
            }
            expect (TokenKind.RBRACE, "'}'");
        }

        private void parse_class (bool is_abstract) throws ParseError, LexError {
            var l = current.line;
            var c = current.column;
            advance (); // 'class'
            if (current.kind != TokenKind.IDENTIFIER)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"expected class name at $(current.line):$(current.column)");
            if (is_reserved (current.text))
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"'$(current.text)' is a keyword and cannot name a class at $(current.line):$(current.column)");
            var name = current.text;
            advance ();
            if (has_other_top_name (name, "class"))
                throw new ParseError.DUPLICATE_FUNCTION (
                    @"duplicate name: $name at $l:$c");

            var base_name = "";
            if (current.kind == TokenKind.COLON) {
                advance ();
                if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected base class name after ':' at $(current.line):$(current.column)");
                base_name = current.text;
                if (base_name == "Object" && program.find_class ("Object") == null)
                    base_name = "";
                advance ();
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
            cd_existing.base_name = base_name;
            cd_existing.is_abstract = is_abstract;
            cd_existing.is_defined = true;
            cd_existing.line = l;
            cd_existing.column = c;
            var cd = cd_existing;

            expect (TokenKind.LBRACE, "'{'");
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN (@"unterminated class '$name'");
                while (current.kind == TokenKind.IDENTIFIER && is_visibility_modifier (current.text))
                    advance ();

                if (current.kind == TokenKind.IDENTIFIER && current.text == "const") {
                    parse_const_decl (cd.name);
                    continue;
                }

                bool is_virtual = false;
                bool is_override = false;
                bool is_abstract_m = false;
                bool is_static_m = false;
                while (current.kind == TokenKind.IDENTIFIER
                       && (current.text == "virtual" || current.text == "override"
                           || current.text == "abstract" || current.text == "static")) {
                    if (current.text == "virtual") is_virtual = true;
                    else if (current.text == "override") is_override = true;
                    else if (current.text == "abstract") is_abstract_m = true;
                    else is_static_m = true;
                    advance ();
                }

                // Destructor: `~ClassName () { ... }`
                if (current.kind == TokenKind.TILDE) {
                    var dl = current.line;
                    var dc = current.column;
                    if (is_virtual || is_override || is_abstract_m || is_static_m)
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

                skip_ownership_modifiers ();

                var ml = current.line;
                var mc = current.column;
                ValaType ft = ValaType.VOID;
                string ft_name = "";

                if (!is_virtual && !is_override && !is_abstract_m && !is_static_m && current.text == cd.name) {
                    advance ();
                    if (current.kind == TokenKind.LPAREN) {
                        var plist = parse_param_list ();
                        if (cd.ctor != null)
                            throw new ParseError.DUPLICATE_FUNCTION (
                                @"duplicate constructor in class '$(cd.name)' at $ml:$mc");
                        var ctor = new Function () {
                            name = "__ctor",
                            return_type = ValaType.VOID,
                            is_ctor = true,
                            owner_class = cd.name,
                            line = ml,
                            column = mc
                        };
                        foreach (var p in plist)
                            ctor.params.add (p);
                        parse_throws_clause (ctor.throws_domains);
                        if (current.kind == TokenKind.COLON) {
                            advance ();
                            if (current.kind != TokenKind.IDENTIFIER || current.text != "base")
                                throw new ParseError.UNEXPECTED_TOKEN (
                                    @"expected 'base(...)' after ':' at $(current.line):$(current.column)");
                            advance ();
                            expect (TokenKind.LPAREN, "'('");
                            ctor.has_base_call = true;
                            parse_arg_list (ctor.base_args);
                            expect (TokenKind.RPAREN, "')'");
                        }
                        parse_block_into (ctor.body);
                        cd.ctor = ctor;
                        continue;
                    }
                    ft = ValaType.CLASS;
                    ft_name = cd.name;
                    parse_type_suffix (ref ft, ref ft_name);
                } else {
                    if (!parse_type (current.text, out ft, out ft_name))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"unknown member type '$(current.text)' in class '$(cd.name)' at $ml:$mc");
                    advance ();
                    parse_type_suffix (ref ft, ref ft_name);
                }

                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected member name in class '$(cd.name)' at $(current.line):$(current.column)");
                if (is_reserved (current.text))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword and cannot name a member at $(current.line):$(current.column)");
                var mname = current.text;
                var mem_l = current.line;
                var mem_c = current.column;
                advance ();

                if (current.kind == TokenKind.LPAREN) {
                    if (is_abstract_m && !cd.is_abstract)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"abstract method '$(mname)' requires an abstract class at $mem_l:$mem_c");
                    if (is_static_m && (is_virtual || is_override || is_abstract_m))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"static method '$(mname)' cannot be virtual, override, or abstract at $mem_l:$mem_c");
                    var plist = parse_param_list ();
                    var mfn = new Function () {
                        name = mname,
                        return_type = ft,
                        return_type_name = ft_name,
                        is_virtual = is_virtual,
                        is_override = is_override,
                        is_abstract = is_abstract_m,
                        is_static = is_static_m,
                        owner_class = cd.name,
                        line = mem_l,
                        column = mem_c
                    };
                    foreach (var p in plist)
                        mfn.params.add (p);
                    parse_throws_clause (mfn.throws_domains);
                    if (is_abstract_m) {
                        expect (TokenKind.SEMICOLON, "';'");
                    } else {
                        parse_block_into (mfn.body);
                    }
                    if (cd.find_own_method (mname) != null || cd.find_own_field (mname) != null)
                        throw new ParseError.DUPLICATE_FUNCTION (
                            @"duplicate member '$mname' in class '$(cd.name)' at $mem_l:$mem_c");
                    cd.methods.add (mfn);
                } else if (current.kind == TokenKind.LBRACE) {
                    if (is_static_m || ft == ValaType.VOID)
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
                    if (is_virtual || is_override || is_abstract_m || is_static_m)
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
                        name = mname,
                        init = finit,
                        line = mem_l,
                        column = mem_c
                    });
                }
            }
            expect (TokenKind.RBRACE, "'}'");
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
                                              string name, int l, int c)
                throws ParseError, LexError {
            var f = new Function () {
                name = name,
                return_type = return_type,
                return_type_name = return_type_name
            };
            f.line = l;
            f.column = c;

            var plist = parse_param_list ();
            foreach (var p in plist)
                f.params.add (p);
            parse_throws_clause (f.throws_domains);
            parse_block_into (f.body);
            return f;
        }

        private GenericArray<Statement> parse_block () throws ParseError, LexError {
            expect (TokenKind.LBRACE, "'{'");
            var stmts = new GenericArray<Statement> ();
            while (current.kind != TokenKind.RBRACE) {
                if (current.kind == TokenKind.EOF)
                    throw new ParseError.UNEXPECTED_TOKEN ("unterminated block");
                stmts.add (parse_statement ());
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

            if (current.kind == TokenKind.IDENTIFIER) {
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
                if (name == "if") {
                    advance ();
                    expect (TokenKind.LPAREN, "'('");
                    var cond = parse_expr ();
                    expect (TokenKind.RPAREN, "')'");
                    var then_body = parse_statement ();
                    Statement? else_body = null;
                    if (current.kind == TokenKind.IDENTIFIER && current.text == "else") {
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
                    skip_ownership_modifiers ();
                    bool infer_v = false;
                    ValaType vt = ValaType.VOID;
                    string vt_name = "";
                    if (current.kind == TokenKind.IDENTIFIER && current.text == "var") {
                        infer_v = true;
                        advance ();
                    } else {
                        if (current.kind != TokenKind.IDENTIFIER || !parse_type (current.text, out vt, out vt_name))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected element type or 'var' in foreach at $(current.line):$(current.column)");
                        advance ();
                        parse_type_suffix (ref vt, ref vt_name);
                    }
                    if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected variable name in foreach at $(current.line):$(current.column)");
                    var vname = current.text;
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER || current.text != "in")
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
                        if (current.kind == TokenKind.IDENTIFIER && current.text == "case") {
                            var sc = new SwitchCase () { line = current.line, column = current.column };
                            while (current.kind == TokenKind.IDENTIFIER && current.text == "case") {
                                advance ();
                                sc.values.add (parse_expr ());
                                expect (TokenKind.COLON, "':'");
                            }
                            while (current.kind != TokenKind.RBRACE
                                   && !(current.kind == TokenKind.IDENTIFIER
                                        && (current.text == "case" || current.text == "default"))) {
                                if (current.kind == TokenKind.EOF)
                                    throw new ParseError.UNEXPECTED_TOKEN (@"unterminated switch case at $(sc.line):$(sc.column)");
                                sc.body.add (parse_statement ());
                            }
                            sw.cases.add (sc);
                        } else if (current.kind == TokenKind.IDENTIFIER && current.text == "default") {
                            if (sw.has_default)
                                throw new ParseError.UNEXPECTED_TOKEN (@"duplicate 'default' in switch at $(current.line):$(current.column)");
                            advance ();
                            expect (TokenKind.COLON, "':'");
                            sw.has_default = true;
                            while (current.kind != TokenKind.RBRACE
                                   && !(current.kind == TokenKind.IDENTIFIER
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
                if (name == "throw") {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER || current.text != "new")
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected 'new Domain.CODE(...)' after 'throw' at $(current.line):$(current.column)");
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected error domain after 'throw new' at $(current.line):$(current.column)");
                    var dname = current.text;
                    advance ();
                    expect (TokenKind.DOT, "'.'");
                    if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
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
                    while (current.kind == TokenKind.IDENTIFIER && current.text == "catch") {
                        var cl = current.line;
                        var cc_col = current.column;
                        advance ();
                        expect (TokenKind.LPAREN, "'('");
                        if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
                            throw new ParseError.UNEXPECTED_TOKEN (
                                @"expected error domain in 'catch' at $(current.line):$(current.column)");
                        var dname = current.text;
                        advance ();
                        if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
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
                    if (current.kind == TokenKind.IDENTIFIER && current.text == "finally") {
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

        private Statement parse_simple_statement_no_semi () throws ParseError, LexError {
            if (current.kind != TokenKind.IDENTIFIER
                || current.text == "true" || current.text == "false"
                || current.text == "null" || current.text == "new") {
                var e = parse_expr ();
                var s = new ExprStatement () { expr = e };
                s.line = e.line;
                s.column = e.column;
                return s;
            }

            var l = current.line;
            var c = current.column;
            var name = current.text;
            advance ();

            bool had_ownership = false;
            if (name == "unowned" || name == "owned") {
                had_ownership = true;
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected type after '$name' at $(current.line):$(current.column)");
                name = current.text;
                l = current.line;
                c = current.column;
                advance ();
            }

            ValaType dt = ValaType.VOID;
            string dt_name = "";
            bool is_builtin_var = (is_int_type_name (name) || name == "bool" || name == "string" || name == "var");
            bool is_named_type = !is_builtin_var && parse_type (name, out dt, out dt_name)
                                 && dt != ValaType.VOID
                                 && (current.kind == TokenKind.IDENTIFIER
                                     || (dt == ValaType.CLASS && current.kind == TokenKind.QUESTION)
                                     || (dt != ValaType.STRUCT && current.kind == TokenKind.LBRACKET));

            if (is_builtin_var || is_named_type) {
                if (is_int_type_name (name)) dt = ValaType.INT;
                else if (name == "bool") dt = ValaType.BOOL;
                else if (name == "string") dt = ValaType.STRING;
                if (name != "var")
                    parse_type_suffix (ref dt, ref dt_name);
                if (current.kind != TokenKind.IDENTIFIER)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected a variable name at $(current.line):$(current.column)");
                if (is_reserved (current.text))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword and cannot name a variable at $(current.line):$(current.column)");
                var vname = current.text;
                advance ();
                if (name == "var" && current.kind != TokenKind.ASSIGN)
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
                    infer_type = (name == "var"),
                    name = vname,
                    init = init
                };
                decl.line = l;
                decl.column = c;
                return decl;
            }

            if (had_ownership)
                throw new ParseError.UNEXPECTED_TOKEN (
                    @"unknown type '$name' after ownership qualifier at $l:$c");

            Expr atom;
            if (name == "this") {
                var v = new VarRef () { name = "this" };
                v.line = l;
                v.column = c;
                atom = v;
            } else if (name == "base") {
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
                if (is_reserved (name)) {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"unexpected keyword '$name' at $l:$c");
                }

                if (current.kind == TokenKind.ASSIGN) {
                    advance ();
                    var a = new AssignStatement () { name = name, value = parse_expr () };
                    a.line = l;
                    a.column = c;
                    return a;
                }
                if (current.kind == TokenKind.PLUSEQ || current.kind == TokenKind.MINUSEQ) {
                    var op = (current.kind == TokenKind.PLUSEQ) ? "+" : "-";
                    advance ();
                    var vref = new VarRef () { name = name };
                    vref.line = l;
                    vref.column = c;
                    var bin = new BinaryExpr () { op = op, left = vref, right = parse_expr () };
                    bin.line = l;
                    bin.column = c;
                    var a = new AssignStatement () { name = name, value = bin };
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

                if (current.kind == TokenKind.LPAREN) {
                    if (program.find_struct (name) != null)
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
                if (current.kind == TokenKind.ASSIGN) {
                    advance ();
                    var fa = new FieldAssignStatement () {
                        target = m.target,
                        field_name = m.member,
                        op = "=",
                        value = parse_expr ()
                    };
                    fa.line = l;
                    fa.column = c;
                    return fa;
                }
                if (current.kind == TokenKind.PLUSEQ || current.kind == TokenKind.MINUSEQ) {
                    var op = (current.kind == TokenKind.PLUSEQ) ? "+" : "-";
                    advance ();
                    var fa = new FieldAssignStatement () {
                        target = m.target,
                        field_name = m.member,
                        op = op,
                        value = parse_expr ()
                    };
                    fa.line = l;
                    fa.column = c;
                    return fa;
                }
                if (current.kind == TokenKind.PLUSPLUS || current.kind == TokenKind.MINUSMINUS) {
                    var op = (current.kind == TokenKind.PLUSPLUS) ? "+" : "-";
                    advance ();
                    var one = new IntLiteral () { value = 1 };
                    one.line = l;
                    one.column = c;
                    var fa = new FieldAssignStatement () {
                        target = m.target,
                        field_name = m.member,
                        op = op,
                        value = one
                    };
                    fa.line = l;
                    fa.column = c;
                    return fa;
                }
            }
            if (post is IndexExpr) {
                var ix = (IndexExpr) post;
                if (current.kind == TokenKind.ASSIGN) {
                    advance ();
                    var ia = new IndexAssignStatement () {
                        target = ix.target,
                        index = ix.index,
                        op = "=",
                        value = parse_expr ()
                    };
                    ia.line = l;
                    ia.column = c;
                    return ia;
                }
                if (current.kind == TokenKind.PLUSEQ || current.kind == TokenKind.MINUSEQ) {
                    var op = (current.kind == TokenKind.PLUSEQ) ? "+" : "-";
                    advance ();
                    var ia = new IndexAssignStatement () {
                        target = ix.target,
                        index = ix.index,
                        op = op,
                        value = parse_expr ()
                    };
                    ia.line = l;
                    ia.column = c;
                    return ia;
                }
                if (current.kind == TokenKind.PLUSPLUS || current.kind == TokenKind.MINUSMINUS) {
                    var op = (current.kind == TokenKind.PLUSPLUS) ? "+" : "-";
                    advance ();
                    var one = new IntLiteral () { value = 1 };
                    one.line = l;
                    one.column = c;
                    var ia = new IndexAssignStatement () {
                        target = ix.target,
                        index = ix.index,
                        op = op,
                        value = one
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
            while (current.kind == TokenKind.IDENTIFIER
                   && (current.text == "is" || current.text == "as")) {
                var op = current.text;
                var l = left.line;
                var c = left.column;
                advance ();
                ValaType tt = ValaType.VOID;
                string tt_name = "";
                if (current.kind != TokenKind.IDENTIFIER
                    || !parse_type (current.text, out tt, out tt_name)
                    || (tt != ValaType.CLASS && !(op == "is" && tt == ValaType.ERROR && tt_name != ""))) {
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"expected class or error domain after '$op' at $(current.line):$(current.column)");
                }
                advance ();
                if (tt == ValaType.CLASS && current.kind == TokenKind.QUESTION)
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
            return parse_postfix (parse_primary ());
        }

        private Expr parse_postfix (Expr expr) throws ParseError, LexError {
            var e = expr;
            while (current.kind == TokenKind.DOT || current.kind == TokenKind.LBRACKET) {
                var l = current.line;
                var c = current.column;
                if (current.kind == TokenKind.DOT) {
                    advance ();
                    if (current.kind != TokenKind.IDENTIFIER)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected member name after '.' at $(current.line):$(current.column)");
                    var member = current.text;
                    advance ();
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

        private Expr parse_primary () throws ParseError, LexError {
            var l = current.line;
            var c = current.column;

            if (current.kind == TokenKind.INTEGER) {
                var e = new IntLiteral () { value = int64.parse (current.text) };
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

            if (current.kind == TokenKind.LPAREN) {
                advance ();
                if (current.kind == TokenKind.IDENTIFIER && program.find_class (current.text) != null) {
                    var tname = current.text;
                    advance ();
                    if (current.kind == TokenKind.QUESTION) {
                        tname = tname + "?";
                        advance ();
                    }
                    expect (TokenKind.RPAREN, "')'");
                    var tc = new TypeCheckExpr () {
                        op = "cast",
                        operand = parse_unary (),
                        target_type = ValaType.CLASS,
                        target_type_name = tname
                    };
                    tc.line = l;
                    tc.column = c;
                    return tc;
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
                if (current.text == "true" || current.text == "false") {
                    var b = new BoolLiteral () { value = (current.text == "true") };
                    b.line = l;
                    b.column = c;
                    advance ();
                    return b;
                }
                if (current.text == "null") {
                    advance ();
                    var nl = new NullLiteral ();
                    nl.line = l;
                    nl.column = c;
                    return nl;
                }
                if (current.text == "this") {
                    advance ();
                    var vr = new VarRef () { name = "this" };
                    vr.line = l;
                    vr.column = c;
                    return vr;
                }
                if (current.text == "base") {
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
                if (current.text == "new") {
                    advance ();
                    ValaType et = ValaType.VOID;
                    string et_name = "";
                    if (current.kind != TokenKind.IDENTIFIER
                        || !parse_type (current.text, out et, out et_name)
                        || et == ValaType.VOID || et == ValaType.STRUCT) {
                        throw new ParseError.UNEXPECTED_TOKEN (
                            @"expected class or array element type after 'new' at $(current.line):$(current.column)");
                    }
                    advance ();
                    if (et == ValaType.CLASS && current.kind == TokenKind.LPAREN) {
                        advance ();
                        var cn = new ClassNewExpr () { class_name = et_name };
                        parse_arg_list (cn.args);
                        expect (TokenKind.RPAREN, "')'");
                        if (current.kind == TokenKind.LBRACE) {
                            advance ();
                            while (current.kind != TokenKind.RBRACE) {
                                if (current.kind != TokenKind.IDENTIFIER || is_reserved (current.text))
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
                    expect (TokenKind.LBRACKET, "'['");
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
                if (is_reserved (current.text))
                    throw new ParseError.UNEXPECTED_TOKEN (
                        @"'$(current.text)' is a keyword, not a value at $l:$c");
                var name = current.text;
                advance ();
                if (current.kind == TokenKind.LPAREN) {
                    if (program.find_struct (name) != null)
                        return parse_struct_literal_rest (name, l, c);
                    return parse_call_rest (name, l, c);
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
                    if (is_reserved (current.text))
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

        private Expr parse_template (Token tok) throws ParseError, LexError {
            var tpl = new TemplateExpr ();
            tpl.line = tok.line;
            tpl.column = tok.column;

            var s = tok.text;
            var n = s.length;
            var lit = new StringBuilder ();
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

                if (lit.len > 0) {
                    var sl = new StringLiteral () { value = lit.str };
                    sl.line = tok.line;
                    sl.column = tok.column;
                    tpl.parts.add (sl);
                    lit = new StringBuilder ();
                }

                if (i + 1 >= n)
                    throw new ParseError.UNEXPECTED_TOKEN (
                        "dangling '$' in template string at %d:%d".printf (tok.line, tok.column));

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
                            else if (x == '(')
                                depth++;
                            else if (x == ')')
                                depth--;
                        }
                        j++;
                    }
                    if (depth != 0)
                        throw new ParseError.UNEXPECTED_TOKEN (
                            "unterminated '$(' in template string at %d:%d".printf (tok.line, tok.column));
                    var inner = s[i + 2 : j - 1];
                    if (inner.strip () == "")
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
                        "invalid '$' interpolation in template string at %d:%d".printf (tok.line, tok.column));
                }
            }

            if (lit.len > 0) {
                var sl = new StringLiteral () { value = lit.str };
                sl.line = tok.line;
                sl.column = tok.column;
                tpl.parts.add (sl);
            }

            return tpl;
        }

        // Parses `name(...)` with the identifier already consumed.
        private Expr parse_call_rest (string name, int l, int c)
                throws ParseError, LexError {
            advance (); // '('
            var call = new CallExpr () { callee = name };
            parse_arg_list (call.args);
            expect (TokenKind.RPAREN, "')'");
            call.line = l;
            call.column = c;
            return call;
        }
    }
}
