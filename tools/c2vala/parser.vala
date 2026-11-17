// Recursive-descent C99 parser for c2vala.

using Planc;

namespace C2Vala {

    public class TypedefEntry : Object {
        public string name;
        public CType ctype;

        public TypedefEntry (string name, CType ctype) {
            this.name = name;
            this.ctype = ctype;
        }
    }

    public class CParser : Object {
        private GenericArray<CTok> toks;
        private int pos = 0;
        private GenericArray<TypedefEntry> typedefs = new GenericArray<TypedefEntry> ();
        private GenericArray<string> enum_tags = new GenericArray<string> ();
        private GenericArray<string> struct_tags = new GenericArray<string> ();
        private GenericArray<string> union_tags = new GenericArray<string> ();

        public CParser (GenericArray<CTok> toks) {
            this.toks = toks;
            // Standard C99 / stdint / stddef typedefs
            add_typedef ("size_t", CType.scalar ("size_t"));
            add_typedef ("ssize_t", CType.scalar ("ssize_t"));
            add_typedef ("int8_t", CType.scalar ("int8"));
            add_typedef ("uint8_t", CType.scalar ("uint8"));
            add_typedef ("int16_t", CType.scalar ("int16"));
            add_typedef ("uint16_t", CType.scalar ("uint16"));
            add_typedef ("int32_t", CType.scalar ("int32"));
            add_typedef ("uint32_t", CType.scalar ("uint32"));
            add_typedef ("int64_t", CType.scalar ("int64"));
            add_typedef ("uint64_t", CType.scalar ("uint64"));
            add_typedef ("bool", CType.scalar ("bool"));
            add_typedef ("va_list", CType.scalar ("int"));
            add_typedef ("FILE", new CType (CTypeKind.STRUCT, "FILE"));
        }

        private void add_typedef (string name, CType ct) {
            for (int i = 0; i < typedefs.length; i++) {
                if (typedefs[i].name == name) {
                    typedefs[i].ctype = ct;
                    return;
                }
            }
            typedefs.add (new TypedefEntry (name, ct));
        }

        private TypedefEntry? find_typedef (string name) {
            for (int i = 0; i < typedefs.length; i++) {
                if (typedefs[i].name == name)
                    return typedefs[i];
            }
            return null;
        }

        private CTok cur () {
            if (pos < toks.length)
                return toks[pos];
            return toks[toks.length - 1];
        }

        private CTok peek (int offset = 1) {
            int idx = pos + offset;
            if (idx < toks.length)
                return toks[idx];
            return toks[toks.length - 1];
        }

        private bool at (TokKind k) {
            return cur ().kind == k;
        }

        private bool at_ident (string s) {
            return cur ().kind == TokKind.IDENT && cur ().text == s;
        }

        private CTok advance () {
            var t = cur ();
            if (pos < toks.length - 1)
                pos++;
            return t;
        }

        private CTok expect (TokKind k, string msg) throws RefuseError {
            if (!at (k)) {
                var t = cur ();
                throw new RefuseError.FAILED (@"$(t.file):$(t.line): expected $msg, got '$(t.text)'");
            }
            return advance ();
        }

        private void refuse (CTok t, string msg) throws RefuseError {
            throw new RefuseError.FAILED (@"$(t.file):$(t.line): $msg");
        }

        private static bool is_type_kw (string s) {
            return s == "void" || s == "char" || s == "short" || s == "int" || s == "long"
                || s == "float" || s == "double" || s == "signed" || s == "unsigned"
                || s == "_Bool" || s == "const" || s == "volatile" || s == "restrict"
                || s == "struct" || s == "union" || s == "enum"
                || s == "static" || s == "extern" || s == "inline" || s == "typedef";
        }

        private bool is_type_start (int offset = 0) {
            var t = peek (offset);
            if (t.kind != TokKind.IDENT)
                return false;
            if (is_type_kw (t.text))
                return true;
            return find_typedef (t.text) != null;
        }

        public TranslationUnit parse_tu () throws RefuseError {
            var tu = new TranslationUnit ();
            while (!at (TokKind.EOF)) {
                if (at (TokKind.SEMI)) {
                    advance ();
                    continue;
                }
                parse_top_decl (tu);
            }
            return tu;
        }

        private void parse_top_decl (TranslationUnit tu) throws RefuseError {
            var start_tok = cur ();
            bool is_typedef = false;
            bool has_inline = false;
            bool has_static = false;
            bool has_extern = false;

            while (at (TokKind.IDENT)) {
                string kw = cur ().text;
                if (kw == "typedef") { is_typedef = true; advance (); }
                else if (kw == "static") { has_static = true; advance (); }
                else if (kw == "extern") { has_extern = true; advance (); }
                else if (kw == "inline") { has_inline = true; advance (); }
                else break;
            }
            // Suppress unused warnings
            if (has_inline && has_static && has_extern) {}

            CType base_t = parse_base_type (tu, is_typedef);

            if (at (TokKind.SEMI)) {
                advance ();
                return;
            }

            // Parse declarator(s)
            while (true) {
                CType decl_t = base_t.clone_type ();
                string name = "";
                bool is_func = false;
                bool is_varargs = false;
                var params = new GenericArray<ParamDef> ();

                parse_declarator (ref decl_t, out name, out is_func, params, out is_varargs);

                if (is_typedef) {
                    if (decl_t.kind == CTypeKind.FUNC_PTR)
                        refuse (start_tok, "function pointers are not supported");
                    if (decl_t.kind == CTypeKind.ARRAY)
                        refuse (start_tok, "array typedefs are not supported");
                    if (name != "") {
                        // If typedef struct/enum had an anonymous tag, rename it to typedef name
                        if (decl_t.kind == CTypeKind.STRUCT && decl_t.name.has_prefix ("__anon_")) {
                            for (int i = 0; i < tu.structs.length; i++) {
                                if (tu.structs[i].name == decl_t.name)
                                    tu.structs[i].name = name;
                            }
                            for (int i = 0; i < tu.top_order.length; i++) {
                                if (tu.top_order[i] == decl_t.name)
                                    tu.top_order[i] = name;
                            }
                            decl_t.name = name;
                        } else if (decl_t.kind == CTypeKind.ENUM && decl_t.name.has_prefix ("__anon_")) {
                            for (int i = 0; i < tu.enums.length; i++) {
                                if (tu.enums[i].name == decl_t.name)
                                    tu.enums[i].name = name;
                            }
                            for (int i = 0; i < tu.top_order.length; i++) {
                                if (tu.top_order[i] == decl_t.name)
                                    tu.top_order[i] = name;
                            }
                            decl_t.name = name;
                        }
                        add_typedef (name, decl_t);
                    }
                    if (at (TokKind.COMMA)) {
                        advance ();
                        continue;
                    }
                    expect (TokKind.SEMI, "';'");
                    return;
                }

                if (is_func && at (TokKind.LBRACE)) {
                    var fn = new FuncDef (name, decl_t, start_tok.file, start_tok.line);
                    fn.params = params;
                    fn.is_varargs = is_varargs;
                    fn.body = parse_block ();
                    tu.funcs.add (fn);
                    tu.top_order.add (name);
                    tu.top_kinds.add ("func");
                    return;
                }

                if (is_func) {
                    // Function prototype: skip
                    if (at (TokKind.COMMA)) {
                        advance ();
                        continue;
                    }
                    expect (TokKind.SEMI, "';'");
                    return;
                }

                // Global variable declaration -> record for refusal
                if (at (TokKind.ASSIGN)) {
                    advance ();
                    parse_expr_or_init ();
                }
                if (tu.refused_global_reason == null) {
                    tu.refused_global_file = start_tok.file;
                    tu.refused_global_line = start_tok.line;
                    tu.refused_global_reason = "global variables are not supported";
                }
                if (at (TokKind.COMMA)) {
                    advance ();
                    continue;
                }
                expect (TokKind.SEMI, "';'");
                return;
            }
        }

        private CType parse_base_type (TranslationUnit? tu, bool in_typedef = false) throws RefuseError {
            var start_tok = cur ();
            bool is_const = false;
            bool is_unsigned = false;
            bool is_signed = false;
            bool is_short = false;
            int long_count = 0;
            string? base_kw = null;

            while (at (TokKind.IDENT)) {
                string kw = cur ().text;
                if (kw == "const") { is_const = true; advance (); continue; }
                if (kw == "volatile" || kw == "restrict" || kw == "static" || kw == "extern" || kw == "inline") {
                    advance ();
                    continue;
                }
                if (kw == "unsigned") { is_unsigned = true; advance (); continue; }
                if (kw == "signed") { is_signed = true; advance (); continue; }
                if (kw == "short") { is_short = true; advance (); continue; }
                if (kw == "long") { long_count++; advance (); continue; }
                if (kw == "void" || kw == "char" || kw == "int" || kw == "float" || kw == "double" || kw == "_Bool") {
                    base_kw = kw;
                    advance ();
                    break;
                }
                if (kw == "enum") {
                    advance ();
                    var ct = parse_enum_spec (tu, start_tok);
                    ct.is_const = is_const;
                    return ct;
                }
                if (kw == "struct") {
                    advance ();
                    var ct = parse_struct_spec (tu, start_tok);
                    ct.is_const = is_const;
                    return ct;
                }
                if (kw == "union") {
                    advance ();
                    var ct = parse_struct_spec (tu, start_tok, true);
                    ct.is_const = is_const;
                    return ct;
                }
                var td = find_typedef (kw);
                if (td != null && base_kw == null && !is_unsigned && !is_signed && !is_short && long_count == 0) {
                    advance ();
                    var ct = td.ctype.clone_type ();
                    if (is_const)
                        ct.is_const = true;
                    return ct;
                }
                break;
            }

            // Consume trailing const/volatile
            while (at_ident ("const") || at_ident ("volatile") || at_ident ("restrict")) {
                if (cur ().text == "const")
                    is_const = true;
                advance ();
            }

            string scalar = "int";
            if (base_kw == "void") scalar = "void";
            else if (base_kw == "_Bool") scalar = "bool";
            else if (base_kw == "float") scalar = "float";
            else if (base_kw == "double") scalar = "double";
            else if (base_kw == "char") {
                if (is_unsigned) scalar = "uchar";
                else if (is_signed) scalar = "int8";
                else scalar = "char";
            } else if (is_short) {
                scalar = is_unsigned ? "uint16" : "int16";
            } else if (long_count >= 2) {
                scalar = is_unsigned ? "uint64" : "int64";
            } else if (long_count == 1) {
                scalar = is_unsigned ? "uint64" : "int64";
            } else if (is_unsigned) {
                scalar = "uint32";
            } else if (base_kw == "int" || is_signed) {
                scalar = "int";
            } else {
                refuse (start_tok, @"unknown type '$(start_tok.text)'");
            }

            var res = CType.scalar (scalar);
            res.is_const = is_const;
            return res;
        }

        private int anon_counter = 0;

        private CType parse_enum_spec (TranslationUnit? tu, CTok start_tok) throws RefuseError {
            string tag = "";
            if (at (TokKind.IDENT)) {
                tag = advance ().text;
            }
            if (at (TokKind.LBRACE)) {
                advance ();
                if (tag == "") {
                    anon_counter++;
                    tag = @"__anon_enum_$anon_counter";
                }
                enum_tags.add (tag);
                var ed = new EnumDef (tag, start_tok.file, start_tok.line);
                while (!at (TokKind.RBRACE) && !at (TokKind.EOF)) {
                    var mtok = expect (TokKind.IDENT, "enum member");
                    CExpr? init_e = null;
                    if (at (TokKind.ASSIGN)) {
                        advance ();
                        init_e = parse_assign ();
                    }
                    ed.members.add (new EnumMember (mtok.text, init_e, mtok.file, mtok.line));
                    if (at (TokKind.COMMA))
                        advance ();
                    else
                        break;
                }
                expect (TokKind.RBRACE, "'}'");
                if (tu != null) {
                    tu.enums.add (ed);
                    tu.top_order.add (tag);
                    tu.top_kinds.add ("enum");
                }
                return new CType (CTypeKind.ENUM, tag);
            }
            if (tag == "")
                refuse (start_tok, "anonymous enum");
            return new CType (CTypeKind.ENUM, tag);
        }

        private CType parse_struct_spec (TranslationUnit? tu, CTok start_tok, bool is_union = false) throws RefuseError {
            string tag = "";
            if (at (TokKind.IDENT)) {
                tag = advance ().text;
            }
            if (at (TokKind.LBRACE)) {
                advance ();
                if (tag == "") {
                    anon_counter++;
                    tag = is_union ? @"__anon_union_$anon_counter" : @"__anon_struct_$anon_counter";
                }
                if (is_union)
                    union_tags.add (tag);
                else
                    struct_tags.add (tag);
                var sd = new StructDef (tag, start_tok.file, start_tok.line);
                sd.is_union = is_union;
                while (!at (TokKind.RBRACE) && !at (TokKind.EOF)) {
                    var ft = cur ();
                    var fbase = parse_base_type (tu);
                    while (true) {
                        var ftype = fbase.clone_type ();
                        string fname = "";
                        bool is_fn = false;
                        bool is_va = false;
                        var fparams = new GenericArray<ParamDef> ();
                        parse_declarator (ref ftype, out fname, out is_fn, fparams, out is_va);
                        if (at (TokKind.COLON))
                            refuse (cur (), "bitfields are not supported");
                        if (ftype.kind == CTypeKind.FUNC_PTR)
                            refuse (ft, "function pointers are not supported");
                        if (fname == "")
                            refuse (ft, "anonymous struct member");
                        sd.fields.add (new StructField (fname, ftype, ft.file, ft.line));
                        if (at (TokKind.COMMA)) {
                            advance ();
                            continue;
                        }
                        break;
                    }
                    expect (TokKind.SEMI, "';'");
                }
                expect (TokKind.RBRACE, "'}'");
                if (tu != null) {
                    tu.structs.add (sd);
                    tu.top_order.add (tag);
                    tu.top_kinds.add ("struct");
                }
                return new CType (is_union ? CTypeKind.UNION : CTypeKind.STRUCT, tag);
            }
            if (tag == "")
                refuse (start_tok, is_union ? "anonymous union" : "anonymous struct");
            return new CType (is_union ? CTypeKind.UNION : CTypeKind.STRUCT, tag);
        }

        private void parse_union_spec (CTok start_tok) throws RefuseError {
            if (at (TokKind.IDENT))
                advance ();
            if (at (TokKind.LBRACE)) {
                advance ();
                int depth = 1;
                while (depth > 0 && !at (TokKind.EOF)) {
                    if (at (TokKind.LBRACE)) depth++;
                    else if (at (TokKind.RBRACE)) depth--;
                    advance ();
                }
            }
        }

        private void parse_declarator (ref CType ctype, out string name, out bool is_func,
                                       GenericArray<ParamDef> params, out bool is_varargs) throws RefuseError {
            is_func = false;
            is_varargs = false;
            name = "";

            while (at (TokKind.STAR)) {
                advance ();
                bool ptr_const = false;
                while (at_ident ("const") || at_ident ("volatile") || at_ident ("restrict")) {
                    if (cur ().text == "const")
                        ptr_const = true;
                    advance ();
                }
                ctype = CType.make_ptr (ctype, ptr_const);
            }

            // Function pointer declarator: (*name)(...)
            if (at (TokKind.LPAREN) && peek (1).kind == TokKind.STAR) {
                advance (); // (
                advance (); // *
                if (at (TokKind.IDENT))
                    name = advance ().text;
                expect (TokKind.RPAREN, "')'");
                if (at (TokKind.LPAREN)) {
                    advance ();
                    int depth = 1;
                    while (depth > 0 && !at (TokKind.EOF)) {
                        if (at (TokKind.LPAREN)) depth++;
                        else if (at (TokKind.RPAREN)) depth--;
                        advance ();
                    }
                }
                ctype = new CType (CTypeKind.FUNC_PTR, name);
                return;
            }

            if (at (TokKind.IDENT)) {
                name = advance ().text;
            }

            // Array suffixes: [N]
            while (at (TokKind.LBRACKET)) {
                advance ();
                CExpr? len_e = null;
                if (!at (TokKind.RBRACKET))
                    len_e = parse_assign ();
                expect (TokKind.RBRACKET, "']'");
                ctype = CType.make_array (ctype, len_e);
            }

            // Function parameter list: (params)
            if (at (TokKind.LPAREN)) {
                is_func = true;
                advance ();
                if (!at (TokKind.RPAREN)) {
                    if (at_ident ("void") && peek (1).kind == TokKind.RPAREN) {
                        advance ();
                    } else {
                        while (true) {
                            if (at (TokKind.ELLIPSIS)) {
                                advance ();
                                is_varargs = true;
                                break;
                            }
                            var ptok = cur ();
                            var pbase = parse_base_type (null);
                            string pname = "";
                            bool p_fn = false;
                            bool p_va = false;
                            var sub_p = new GenericArray<ParamDef> ();
                            parse_declarator (ref pbase, out pname, out p_fn, sub_p, out p_va);
                            if (pbase.kind == CTypeKind.FUNC_PTR)
                                refuse (ptok, "function pointers are not supported");
                            // Array parameter `T a[]` decays to pointer `T *a`
                            if (pbase.kind == CTypeKind.ARRAY && pbase.inner != null)
                                pbase = CType.make_ptr (pbase.inner);
                            params.add (new ParamDef (pname, pbase, ptok.file, ptok.line));
                            if (at (TokKind.COMMA)) {
                                advance ();
                                continue;
                            }
                            break;
                        }
                    }
                }
                expect (TokKind.RPAREN, "')'");
            }
        }

        // ---- Statements ----

        private StmtBlock parse_block () throws RefuseError {
            var tok = expect (TokKind.LBRACE, "'{'");
            var blk = new StmtBlock ();
            blk.file = tok.file;
            blk.line = tok.line;
            while (!at (TokKind.RBRACE) && !at (TokKind.EOF)) {
                parse_block_item (blk.stmts);
            }
            expect (TokKind.RBRACE, "'}'");
            return blk;
        }

        private void parse_block_item (GenericArray<CStmt> out_stmts) throws RefuseError {
            if (is_type_start (0)) {
                parse_local_decls (out_stmts);
                return;
            }
            out_stmts.add (parse_stmt ());
        }

        private void parse_local_decls (GenericArray<CStmt> out_stmts) throws RefuseError {
            var start_tok = cur ();
            var base_t = parse_base_type (null);
            while (true) {
                var dt = base_t.clone_type ();
                string name = "";
                bool is_fn = false;
                bool is_va = false;
                var dummy_p = new GenericArray<ParamDef> ();
                parse_declarator (ref dt, out name, out is_fn, dummy_p, out is_va);
                if (dt.kind == CTypeKind.FUNC_PTR)
                    refuse (start_tok, "function pointers are not supported");
                CExpr? init_e = null;
                if (at (TokKind.ASSIGN)) {
                    advance ();
                    init_e = parse_expr_or_init ();
                }
                var d = new StmtDecl ();
                d.file = start_tok.file;
                d.line = start_tok.line;
                d.name = name;
                d.ctype = dt;
                d.init = init_e;
                out_stmts.add (d);

                if (at (TokKind.COMMA)) {
                    advance ();
                    continue;
                }
                break;
            }
            expect (TokKind.SEMI, "';'");
        }

        private CStmt parse_stmt () throws RefuseError {
            var t = cur ();
            if (at (TokKind.LBRACE))
                return parse_block ();

            if (at (TokKind.SEMI)) {
                advance ();
                var s = new StmtExpr ();
                s.file = t.file;
                s.line = t.line;
                return s;
            }

            // Label: `ident : stmt`
            if (t.kind == TokKind.IDENT && peek (1).kind == TokKind.COLON) {
                string lbl = advance ().text;
                advance (); // :
                var ls = new StmtLabel ();
                ls.file = t.file;
                ls.line = t.line;
                ls.label = lbl;
                ls.stmt = parse_stmt ();
                return ls;
            }

            if (at_ident ("if")) {
                advance ();
                expect (TokKind.LPAREN, "'('");
                var cond = parse_expr ();
                expect (TokKind.RPAREN, "')'");
                var then_b = parse_stmt ();
                CStmt? else_b = null;
                if (at_ident ("else")) {
                    advance ();
                    else_b = parse_stmt ();
                }
                var s = new StmtIf ();
                s.file = t.file;
                s.line = t.line;
                s.cond = cond;
                s.then_branch = then_b;
                s.else_branch = else_b;
                return s;
            }

            if (at_ident ("while")) {
                advance ();
                expect (TokKind.LPAREN, "'('");
                var cond = parse_expr ();
                expect (TokKind.RPAREN, "')'");
                var body = parse_stmt ();
                var s = new StmtWhile ();
                s.file = t.file;
                s.line = t.line;
                s.cond = cond;
                s.body = body;
                s.is_do = false;
                return s;
            }

            if (at_ident ("do")) {
                advance ();
                var body = parse_stmt ();
                expect (TokKind.IDENT, "'while'");
                expect (TokKind.LPAREN, "'('");
                var cond = parse_expr ();
                expect (TokKind.RPAREN, "')'");
                expect (TokKind.SEMI, "';'");
                var s = new StmtWhile ();
                s.file = t.file;
                s.line = t.line;
                s.cond = cond;
                s.body = body;
                s.is_do = true;
                return s;
            }

            if (at_ident ("for")) {
                advance ();
                expect (TokKind.LPAREN, "'('");
                var s = new StmtFor ();
                s.file = t.file;
                s.line = t.line;
                if (!at (TokKind.SEMI)) {
                    if (is_type_start (0)) {
                        var decls = new GenericArray<CStmt> ();
                        parse_local_decls (decls);
                        if (decls.length > 0)
                            s.init_decl = decls[0];
                    } else {
                        s.init_expr = parse_expr ();
                        expect (TokKind.SEMI, "';'");
                    }
                } else {
                    advance ();
                }
                if (!at (TokKind.SEMI))
                    s.cond = parse_expr ();
                expect (TokKind.SEMI, "';'");
                if (!at (TokKind.RPAREN))
                    s.next = parse_expr ();
                expect (TokKind.RPAREN, "')'");
                s.body = parse_stmt ();
                return s;
            }

            if (at_ident ("switch")) {
                advance ();
                expect (TokKind.LPAREN, "'('");
                var cond = parse_expr ();
                expect (TokKind.RPAREN, "')'");
                expect (TokKind.LBRACE, "'{'");
                var sw = new StmtSwitch ();
                sw.file = t.file;
                sw.line = t.line;
                sw.cond = cond;
                while (!at (TokKind.RBRACE) && !at (TokKind.EOF)) {
                    if (at_ident ("case")) {
                        var ct = advance ();
                        var ce = parse_expr ();
                        expect (TokKind.COLON, "':'");
                        var sc = new SwitchCase ();
                        sc.file = ct.file;
                        sc.line = ct.line;
                        sc.is_default = false;
                        sc.expr = ce;
                        while (!at (TokKind.RBRACE) && !at_ident ("case") && !at_ident ("default") && !at (TokKind.EOF)) {
                            parse_block_item (sc.stmts);
                        }
                        sw.cases.add (sc);
                    } else if (at_ident ("default")) {
                        var dt = advance ();
                        expect (TokKind.COLON, "':'");
                        var sc = new SwitchCase ();
                        sc.file = dt.file;
                        sc.line = dt.line;
                        sc.is_default = true;
                        while (!at (TokKind.RBRACE) && !at_ident ("case") && !at_ident ("default") && !at (TokKind.EOF)) {
                            parse_block_item (sc.stmts);
                        }
                        sw.cases.add (sc);
                    } else {
                        refuse (cur (), "statement directly inside a switch");
                    }
                }
                expect (TokKind.RBRACE, "'}'");
                return sw;
            }

            if (at_ident ("break")) {
                advance ();
                expect (TokKind.SEMI, "';'");
                var s = new StmtBreak ();
                s.file = t.file;
                s.line = t.line;
                return s;
            }

            if (at_ident ("continue")) {
                advance ();
                expect (TokKind.SEMI, "';'");
                var s = new StmtContinue ();
                s.file = t.file;
                s.line = t.line;
                return s;
            }

            if (at_ident ("return")) {
                advance ();
                var s = new StmtReturn ();
                s.file = t.file;
                s.line = t.line;
                if (!at (TokKind.SEMI))
                    s.expr = parse_expr ();
                expect (TokKind.SEMI, "';'");
                return s;
            }

            if (at_ident ("goto")) {
                advance ();
                var lt = expect (TokKind.IDENT, "label name");
                expect (TokKind.SEMI, "';'");
                var s = new StmtGoto ();
                s.file = t.file;
                s.line = t.line;
                s.label = lt.text;
                return s;
            }

            var e = parse_expr ();
            expect (TokKind.SEMI, "';'");
            var es = new StmtExpr ();
            es.file = t.file;
            es.line = t.line;
            es.expr = e;
            return es;
        }

        // ---- Expressions ----

        private CExpr parse_expr_or_init () throws RefuseError {
            if (at (TokKind.LBRACE)) {
                var t = advance ();
                var il = new ExprInitList ();
                il.file = t.file;
                il.line = t.line;
                while (!at (TokKind.RBRACE) && !at (TokKind.EOF)) {
                    il.items.add (parse_expr_or_init ());
                    if (at (TokKind.COMMA))
                        advance ();
                    else
                        break;
                }
                expect (TokKind.RBRACE, "'}'");
                return il;
            }
            return parse_assign ();
        }

        private CExpr parse_expr () throws RefuseError {
            return parse_assign ();
        }

        private CExpr parse_assign () throws RefuseError {
            var left = parse_ternary ();
            var t = cur ();
            string? op = null;
            if (t.kind == TokKind.ASSIGN) op = "=";
            else if (t.kind == TokKind.ADD_ASSIGN) op = "+=";
            else if (t.kind == TokKind.SUB_ASSIGN) op = "-=";
            else if (t.kind == TokKind.MUL_ASSIGN) op = "*=";
            else if (t.kind == TokKind.DIV_ASSIGN) op = "/=";
            else if (t.kind == TokKind.MOD_ASSIGN) op = "%=";
            else if (t.kind == TokKind.AND_ASSIGN) op = "&=";
            else if (t.kind == TokKind.OR_ASSIGN) op = "|=";
            else if (t.kind == TokKind.XOR_ASSIGN) op = "^=";
            else if (t.kind == TokKind.LSHIFT_ASSIGN) op = "<<=";
            else if (t.kind == TokKind.RSHIFT_ASSIGN) op = ">>=";

            if (op != null) {
                advance ();
                var right = parse_assign ();
                var a = new ExprAssign ();
                a.file = t.file;
                a.line = t.line;
                a.op = op;
                a.lvalue = left;
                a.rvalue = right;
                return a;
            }
            return left;
        }

        private CExpr parse_ternary () throws RefuseError {
            var c = parse_lor ();
            if (at (TokKind.QUESTION)) {
                var t = advance ();
                var tr = parse_expr ();
                expect (TokKind.COLON, "':'");
                var fa = parse_ternary ();
                var q = new ExprTernary ();
                q.file = t.file;
                q.line = t.line;
                q.cond = c;
                q.if_true = tr;
                q.if_false = fa;
                return q;
            }
            return c;
        }

        private CExpr parse_lor () throws RefuseError {
            var e = parse_land ();
            while (at (TokKind.OROR)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = "||";
                b.left = e; b.right = parse_land ();
                e = b;
            }
            return e;
        }

        private CExpr parse_land () throws RefuseError {
            var e = parse_bor ();
            while (at (TokKind.ANDAND)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = "&&";
                b.left = e; b.right = parse_bor ();
                e = b;
            }
            return e;
        }

        private CExpr parse_bor () throws RefuseError {
            var e = parse_bxor ();
            while (at (TokKind.PIPE)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = "|";
                b.left = e; b.right = parse_bxor ();
                e = b;
            }
            return e;
        }

        private CExpr parse_bxor () throws RefuseError {
            var e = parse_band ();
            while (at (TokKind.CARET)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = "^";
                b.left = e; b.right = parse_band ();
                e = b;
            }
            return e;
        }

        private CExpr parse_band () throws RefuseError {
            var e = parse_eq ();
            while (at (TokKind.AMP)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = "&";
                b.left = e; b.right = parse_eq ();
                e = b;
            }
            return e;
        }

        private CExpr parse_eq () throws RefuseError {
            var e = parse_rel ();
            while (at (TokKind.EQ) || at (TokKind.NE)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = t.text;
                b.left = e; b.right = parse_rel ();
                e = b;
            }
            return e;
        }

        private CExpr parse_rel () throws RefuseError {
            var e = parse_shift ();
            while (at (TokKind.LT) || at (TokKind.LE) || at (TokKind.GT) || at (TokKind.GE)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = t.text;
                b.left = e; b.right = parse_shift ();
                e = b;
            }
            return e;
        }

        private CExpr parse_shift () throws RefuseError {
            var e = parse_add ();
            while (at (TokKind.LSHIFT) || at (TokKind.RSHIFT)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = t.text;
                b.left = e; b.right = parse_add ();
                e = b;
            }
            return e;
        }

        private CExpr parse_add () throws RefuseError {
            var e = parse_mul ();
            while (at (TokKind.PLUS) || at (TokKind.MINUS)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = t.text;
                b.left = e; b.right = parse_mul ();
                e = b;
            }
            return e;
        }

        private CExpr parse_mul () throws RefuseError {
            var e = parse_cast ();
            while (at (TokKind.STAR) || at (TokKind.SLASH) || at (TokKind.PERCENT)) {
                var t = advance ();
                var b = new ExprBinary ();
                b.file = t.file; b.line = t.line; b.op = t.text;
                b.left = e; b.right = parse_cast ();
                e = b;
            }
            return e;
        }

        private CExpr parse_cast () throws RefuseError {
            if (at (TokKind.LPAREN) && is_type_start (1)) {
                var t = advance (); // (
                var ct = parse_type_name ();
                expect (TokKind.RPAREN, "')'");
                var inner = parse_cast ();
                var ce = new ExprCast ();
                ce.file = t.file;
                ce.line = t.line;
                ce.target_type = ct;
                ce.expr = inner;
                return ce;
            }
            return parse_unary ();
        }

        private CType parse_type_name () throws RefuseError {
            var base_t = parse_base_type (null);
            while (at (TokKind.STAR)) {
                advance ();
                bool pc = false;
                while (at_ident ("const") || at_ident ("volatile")) {
                    if (cur ().text == "const") pc = true;
                    advance ();
                }
                base_t = CType.make_ptr (base_t, pc);
            }
            return base_t;
        }

        private CExpr parse_unary () throws RefuseError {
            var t = cur ();
            if (at_ident ("sizeof")) {
                advance ();
                if (at (TokKind.LPAREN) && is_type_start (1)) {
                    advance ();
                    var ct = parse_type_name ();
                    expect (TokKind.RPAREN, "')'");
                    var st = new ExprSizeofType ();
                    st.file = t.file; st.line = t.line;
                    st.target_type = ct;
                    return st;
                }
                var se = new ExprSizeofExpr ();
                se.file = t.file; se.line = t.line;
                se.expr = parse_unary ();
                return se;
            }
            if (at (TokKind.PLUSPLUS) || at (TokKind.MINUSMINUS) || at (TokKind.AMP)
                || at (TokKind.STAR) || at (TokKind.PLUS) || at (TokKind.MINUS)
                || at (TokKind.TILDE) || at (TokKind.BANG)) {
                advance ();
                var u = new ExprUnary ();
                u.file = t.file; u.line = t.line;
                u.op = t.text;
                u.operand = parse_cast ();
                u.is_post = false;
                return u;
            }
            return parse_postfix ();
        }

        private CExpr parse_postfix () throws RefuseError {
            var e = parse_primary ();
            while (true) {
                var t = cur ();
                if (at (TokKind.LBRACKET)) {
                    advance ();
                    var idx = parse_expr ();
                    expect (TokKind.RBRACKET, "']'");
                    var ix = new ExprIndex ();
                    ix.file = t.file; ix.line = t.line;
                    ix.array = e; ix.index = idx;
                    e = ix;
                } else if (at (TokKind.LPAREN)) {
                    advance ();
                    var call = new ExprCall ();
                    call.file = t.file; call.line = t.line;
                    call.callee = e;
                    if (!at (TokKind.RPAREN)) {
                        while (true) {
                            call.args.add (parse_assign ());
                            if (at (TokKind.COMMA))
                                advance ();
                            else
                                break;
                        }
                    }
                    expect (TokKind.RPAREN, "')'");
                    e = call;
                } else if (at (TokKind.DOT) || at (TokKind.ARROW)) {
                    bool is_arr = t.kind == TokKind.ARROW;
                    advance ();
                    var ft = expect (TokKind.IDENT, "field name");
                    var mem = new ExprMember ();
                    mem.file = t.file; mem.line = t.line;
                    mem.obj = e; mem.field = ft.text; mem.is_arrow = is_arr;
                    e = mem;
                } else if (at (TokKind.PLUSPLUS) || at (TokKind.MINUSMINUS)) {
                    advance ();
                    var u = new ExprUnary ();
                    u.file = t.file; u.line = t.line;
                    u.op = t.text; u.operand = e; u.is_post = true;
                    e = u;
                } else {
                    break;
                }
            }
            return e;
        }

        private CExpr parse_primary () throws RefuseError {
            var t = cur ();
            if (t.kind == TokKind.INT_LIT) {
                advance ();
                var e = new ExprInt ();
                e.file = t.file; e.line = t.line; e.raw = t.text;
                e.val = Preprocessor.parse_int_lit (t.text);
                e.is_unsigned = t.text.index_of ("u") >= 0 || t.text.index_of ("U") >= 0;
                return e;
            }
            if (t.kind == TokKind.FLOAT_LIT) {
                advance ();
                var e = new ExprFloat ();
                e.file = t.file; e.line = t.line; e.raw = t.text;
                e.is_float = t.text.has_suffix ("f") || t.text.has_suffix ("F");
                return e;
            }
            if (t.kind == TokKind.CHAR_LIT) {
                advance ();
                var e = new ExprChar ();
                e.file = t.file; e.line = t.line; e.raw = t.text;
                e.val = eval_char_lit (t.text);
                return e;
            }
            if (t.kind == TokKind.STR_LIT) {
                advance ();
                var e = new ExprStr ();
                e.file = t.file; e.line = t.line; e.raw = t.text;
                return e;
            }
            if (t.kind == TokKind.IDENT) {
                advance ();
                var e = new ExprIdent ();
                e.file = t.file; e.line = t.line; e.name = t.text;
                return e;
            }
            if (t.kind == TokKind.LPAREN) {
                advance ();
                var e = parse_expr ();
                expect (TokKind.RPAREN, "')'");
                return e;
            }
            refuse (t, @"unexpected token '$(t.text)'");
            throw new RefuseError.FAILED ("unreachable");
        }

        private static int64 eval_char_lit (string raw) {
            if (raw.length < 3)
                return 0;
            if (raw[1] != '\\')
                return (int64) raw[1];
            if (raw.length < 4)
                return 0;
            uint8 esc = raw[2];
            if (esc == 'n') return 10;
            if (esc == 't') return 9;
            if (esc == 'r') return 13;
            if (esc == '0') return 0;
            if (esc == '\\') return 92;
            if (esc == '\'') return 39;
            if (esc == '"') return 34;
            return (int64) esc;
        }
    }
}
