// AST and type representation for the pure-Vala C -> Vala translator.

namespace C2Vala {

    public errordomain RefuseError {
        FAILED
    }

    public enum CTypeKind {
        SCALAR,
        ENUM,
        STRUCT,
        PTR,
        ARRAY,
        FUNC_PTR,
        UNION
    }

    public class CType : Object {
        public CTypeKind kind;
        public string name = "";       // scalar kind, enum name, struct name, or union name
        public CType? inner = null;    // for PTR / ARRAY
        public CExpr? array_len = null; // for ARRAY
        public bool is_const = false;

        public CType (CTypeKind kind, string name = "") {
            this.kind = kind;
            this.name = name;
        }

        public static CType scalar (string k) {
            return new CType (CTypeKind.SCALAR, k);
        }

        public static CType make_ptr (CType inner_t, bool is_const = false) {
            var t = new CType (CTypeKind.PTR);
            t.inner = inner_t;
            t.is_const = is_const;
            return t;
        }

        public static CType make_array (CType inner_t, CExpr? len_expr) {
            var t = new CType (CTypeKind.ARRAY);
            t.inner = inner_t;
            t.array_len = len_expr;
            return t;
        }

        public bool is_scalar (string? k = null) {
            if (kind != CTypeKind.SCALAR)
                return false;
            return k == null || name == k;
        }

        public bool is_char_ptr () {
            return kind == CTypeKind.PTR && inner != null && inner.is_scalar ("char");
        }

        public bool is_void_ptr () {
            return kind == CTypeKind.PTR && inner != null && inner.is_scalar ("void");
        }

        public bool is_struct_ptr () {
            return kind == CTypeKind.PTR && inner != null && inner.kind == CTypeKind.STRUCT;
        }

        public CType clone_type () {
            var t = new CType (kind, name);
            t.inner = inner != null ? inner.clone_type () : null;
            t.array_len = array_len;
            t.is_const = is_const;
            return t;
        }
    }

    public class EnumMember : Object {
        public string name;
        public int64 val;
        public bool has_val;
        public CExpr? init_expr;
        public string file;
        public int line;

        public EnumMember (string name, CExpr? init_expr, string file, int line) {
            this.name = name;
            this.init_expr = init_expr;
            this.file = file;
            this.line = line;
        }
    }

    public class EnumDef : Object {
        public string name;
        public GenericArray<EnumMember> members = new GenericArray<EnumMember> ();
        public string file;
        public int line;

        public EnumDef (string name, string file, int line) {
            this.name = name;
            this.file = file;
            this.line = line;
        }
    }

    public class StructField : Object {
        public string name;
        public CType ctype;
        public string file;
        public int line;

        public StructField (string name, CType ctype, string file, int line) {
            this.name = name;
            this.ctype = ctype;
            this.file = file;
            this.line = line;
        }
    }

    public class StructDef : Object {
        public string name;
        public bool is_union = false;
        public GenericArray<StructField> fields = new GenericArray<StructField> ();
        public string file;
        public int line;

        public StructDef (string name, string file, int line) {
            this.name = name;
            this.file = file;
            this.line = line;
        }
    }

    public class ParamDef : Object {
        public string name;
        public CType ctype;
        public string file;
        public int line;

        public ParamDef (string name, CType ctype, string file, int line) {
            this.name = name;
            this.ctype = ctype;
            this.file = file;
            this.line = line;
        }
    }

    public class FuncDef : Object {
        public string name;
        public CType ret_type;
        public GenericArray<ParamDef> params = new GenericArray<ParamDef> ();
        public StmtBlock? body = null;
        public bool is_varargs = false;
        public string file;
        public int line;

        public FuncDef (string name, CType ret_type, string file, int line) {
            this.name = name;
            this.ret_type = ret_type;
            this.file = file;
            this.line = line;
        }
    }

    // ---- Statements ----

    public abstract class CStmt : Object {
        public string file = "";
        public int line = 0;
    }

    public class StmtBlock : CStmt {
        public GenericArray<CStmt> stmts = new GenericArray<CStmt> ();
    }

    public class StmtDecl : CStmt {
        public string name;
        public CType ctype;
        public CExpr? init = null;
    }

    public class StmtIf : CStmt {
        public CExpr cond;
        public CStmt then_branch;
        public CStmt? else_branch = null;
    }

    public class StmtWhile : CStmt {
        public CExpr cond;
        public CStmt body;
        public bool is_do = false;
    }

    public class StmtFor : CStmt {
        public CStmt? init_decl = null;
        public CExpr? init_expr = null;
        public CExpr? cond = null;
        public CExpr? next = null;
        public CStmt body;
    }

    public class SwitchCase : Object {
        public bool is_default = false;
        public CExpr? expr = null;
        public GenericArray<CStmt> stmts = new GenericArray<CStmt> ();
        public string file = "";
        public int line = 0;
    }

    public class StmtSwitch : CStmt {
        public CExpr cond;
        public GenericArray<SwitchCase> cases = new GenericArray<SwitchCase> ();
    }

    public class StmtBreak : CStmt {}
    public class StmtContinue : CStmt {}

    public class StmtReturn : CStmt {
        public CExpr? expr = null;
    }

    public class StmtGoto : CStmt {
        public string label;
    }

    public class StmtLabel : CStmt {
        public string label;
        public CStmt stmt;
    }

    public class StmtExpr : CStmt {
        public CExpr? expr = null;
    }

    // ---- Expressions ----

    public abstract class CExpr : Object {
        public string file = "";
        public int line = 0;
    }

    public class ExprInt : CExpr {
        public string raw;
        public int64 val;
        public bool is_unsigned = false;
    }

    public class ExprFloat : CExpr {
        public string raw;
        public bool is_float = false;
    }

    public class ExprChar : CExpr {
        public string raw;
        public int64 val;
    }

    public class ExprStr : CExpr {
        public string raw; // includes quotes
    }

    public class ExprIdent : CExpr {
        public string name;
    }

    public class ExprUnary : CExpr {
        public string op;
        public CExpr operand;
        public bool is_post = false;
    }

    public class ExprBinary : CExpr {
        public string op;
        public CExpr left;
        public CExpr right;
    }

    public class ExprAssign : CExpr {
        public string op; // "=", "+=", etc.
        public CExpr lvalue;
        public CExpr rvalue;
    }

    public class ExprTernary : CExpr {
        public CExpr cond;
        public CExpr if_true;
        public CExpr if_false;
    }

    public class ExprCall : CExpr {
        public CExpr callee;
        public GenericArray<CExpr> args = new GenericArray<CExpr> ();
    }

    public class ExprCast : CExpr {
        public CType target_type;
        public CExpr expr;
    }

    public class ExprSizeofType : CExpr {
        public CType target_type;
    }

    public class ExprSizeofExpr : CExpr {
        public CExpr expr;
    }

    public class ExprIndex : CExpr {
        public CExpr array;
        public CExpr index;
    }

    public class ExprMember : CExpr {
        public CExpr obj;
        public string field;
        public bool is_arrow;
    }

    public class ExprInitList : CExpr {
        public GenericArray<CExpr> items = new GenericArray<CExpr> ();
    }

    public class GlobalVarDef : Object {
        public string name;
        public CType ctype;
        public CExpr? init = null;
        public string file = "";
        public int line = 0;

        public GlobalVarDef (string name, CType ctype, CExpr? init, string file, int line) {
            this.name = name;
            this.ctype = ctype;
            this.init = init;
            this.file = file;
            this.line = line;
        }
    }

    public class TranslationUnit : Object {
        public GenericArray<EnumDef> enums = new GenericArray<EnumDef> ();
        public GenericArray<StructDef> structs = new GenericArray<StructDef> ();
        public GenericArray<FuncDef> funcs = new GenericArray<FuncDef> ();
        public GenericArray<GlobalVarDef> globals = new GenericArray<GlobalVarDef> ();
        public GenericArray<string> top_order = new GenericArray<string> ();
        public GenericArray<string> top_kinds = new GenericArray<string> ();
        public string? refused_global_file = null;
        public int refused_global_line = 0;
        public string? refused_global_reason = null;
    }
}
