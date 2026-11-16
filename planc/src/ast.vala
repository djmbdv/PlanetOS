// AST nodes for the Planc dialect.
//
// Slice 7 adds: `foreach`, `switch`/`case`/`default`, string slicing `s[start:end]`,
// ternary `?:`, null-coalescing `??`, integer width aliases (`uint8`..`uint64`,
// `size_t`, `char`), hex/binary/char literals, `const`, `static`, and `struct`/`enum` methods.

namespace Planc {

    public enum ValaType {
        VOID,
        INT,
        BOOL,
        STRING,
        ENUM,
        STRUCT,
        ARRAY,
        CLASS,
        ERROR,
        NULL;

        public string label () {
            switch (this) {
                case VOID:   return "void";
                case INT:    return "int";
                case BOOL:   return "bool";
                case STRING: return "string";
                case ENUM:   return "enum";
                case STRUCT: return "struct";
                case ARRAY:  return "array";
                case CLASS:  return "class";
                case ERROR:  return "Error";
                case NULL:   return "null";
                default:     return "?";
            }
        }
    }

    // ------------------------------------------------------------------
    // Expressions. Every node carries a position because a semantic error
    // without one is useless (TC-08).
    // ------------------------------------------------------------------

    public abstract class Expr : Object {
        public int line { get; set; }
        public int column { get; set; }
        public int ref_temp_slot { get; set; default = -1; }
    }

    public class IntLiteral : Expr {
        public int64 value { get; set; }
    }

    public class BoolLiteral : Expr {
        public bool value { get; set; }
    }

    public class StringLiteral : Expr {
        public string value { get; set; }
    }

    public class TemplateExpr : Expr {
        public GenericArray<Expr> parts { get; private set; }

        public TemplateExpr () {
            parts = new GenericArray<Expr> ();
        }
    }

    public class MemberAccessExpr : Expr {
        public Expr target { get; set; }
        public string member { get; set; }
        public int temp_slot { get; set; default = -1; }
    }

    public class IndexExpr : Expr {
        public Expr target { get; set; }
        public Expr index { get; set; }
    }

    public class ArrayNewExpr : Expr {
        public ValaType elem_type { get; set; }
        public string elem_type_name { get; set; default = ""; }
        public Expr length_expr { get; set; }
    }

    public class ArrayLiteralExpr : Expr {
        public GenericArray<Expr> elements { get; private set; }
        public ValaType elem_type { get; set; default = ValaType.INT; }
        public string elem_type_name { get; set; default = ""; }

        public ArrayLiteralExpr () {
            elements = new GenericArray<Expr> ();
        }
    }

    public class StructLiteral : Expr {
        public string struct_name { get; set; }
        public GenericArray<string> field_names { get; private set; }
        public GenericArray<Expr> field_values { get; private set; }
        public int temp_slot { get; set; default = -1; }

        public StructLiteral () {
            field_names = new GenericArray<string> ();
            field_values = new GenericArray<Expr> ();
        }
    }

    public class VarRef : Expr {
        public string name { get; set; }
    }

    public class UnaryExpr : Expr {
        public string op { get; set; }      // - ! ~
        public Expr operand { get; set; }
    }

    public class BinaryExpr : Expr {
        public string op { get; set; }      // + - * / % << >> & | ^ < > <= >= == != && ||
        public Expr left { get; set; }
        public Expr right { get; set; }
    }

    public class CallExpr : Expr {
        public string callee { get; set; }
        public GenericArray<Expr> args { get; private set; }
        public int temp_slot { get; set; default = -1; }

        public CallExpr () {
            args = new GenericArray<Expr> ();
        }
    }

    public class NullLiteral : Expr {
    }

    public class ClassNewExpr : Expr {
        public string class_name { get; set; }
        public GenericArray<Expr> args { get; private set; }
        public GenericArray<string> init_names { get; private set; }
        public GenericArray<Expr> init_values { get; private set; }

        public ClassNewExpr () {
            args = new GenericArray<Expr> ();
            init_names = new GenericArray<string> ();
            init_values = new GenericArray<Expr> ();
        }
    }

    public class MethodCallExpr : Expr {
        public Expr? target { get; set; }
        public bool is_base_call { get; set; default = false; }
        public string method_name { get; set; }
        public GenericArray<Expr> args { get; private set; }
        public int temp_slot { get; set; default = -1; }

        public MethodCallExpr () {
            args = new GenericArray<Expr> ();
        }
    }

    public class TypeCheckExpr : Expr {
        public string op { get; set; }   // "is", "as", "cast"
        public Expr operand { get; set; }
        public ValaType target_type { get; set; default = ValaType.CLASS; }
        public string target_type_name { get; set; default = ""; }
    }

    public class SliceExpr : Expr {
        public Expr target { get; set; }
        public Expr start { get; set; }
        public Expr end { get; set; }
    }

    public class TernaryExpr : Expr {
        public Expr condition { get; set; }
        public Expr then_expr { get; set; }
        public Expr else_expr { get; set; }
    }

    public class CoalesceExpr : Expr {
        public Expr left { get; set; }
        public Expr right { get; set; }
    }

    // ------------------------------------------------------------------
    // Statements.
    // ------------------------------------------------------------------

    public abstract class Statement : Object {
        public int line { get; set; }
        public int column { get; set; }
    }

    public class PrintStatement : Statement {
        public Expr value { get; set; }
    }

    public class ExitStatement : Statement {
        public Expr value { get; set; }
    }

    public class ReturnStatement : Statement {
        public Expr? value { get; set; }    // null: bare `return;`
    }

    public class VarDeclStatement : Statement {
        public ValaType decl_type { get; set; default = ValaType.INT; }
        public string decl_type_name { get; set; default = ""; }
        public bool infer_type { get; set; default = false; }
        public string name { get; set; }
        public Expr? init { get; set; }     // null: zero/empty-initialized
    }

    public class AssignStatement : Statement {
        public string name { get; set; }
        public Expr value { get; set; }
    }

    public class FieldAssignStatement : Statement {
        public Expr target { get; set; }    // VarRef or MemberAccessExpr
        public string field_name { get; set; }
        public string op { get; set; default = "="; }   // = += -=
        public Expr value { get; set; }
    }

    public class IndexAssignStatement : Statement {
        public Expr target { get; set; }
        public Expr index { get; set; }
        public string op { get; set; default = "="; }   // = += -=
        public Expr value { get; set; }
    }

    // An expression evaluated for its effect, usually a call.
    public class ExprStatement : Statement {
        public Expr expr { get; set; }
    }

    public class BlockStatement : Statement {
        public GenericArray<Statement> statements { get; private set; }

        public BlockStatement () {
            statements = new GenericArray<Statement> ();
        }
    }

    public class IfStatement : Statement {
        public Expr condition { get; set; }
        public Statement then_body { get; set; }
        public Statement? else_body { get; set; }
    }

    public class WhileStatement : Statement {
        public Expr condition { get; set; }
        public Statement body { get; set; }
    }

    public class ForStatement : Statement {
        public Statement? init { get; set; }
        public Expr? condition { get; set; }
        public Statement? step { get; set; }
        public Statement body { get; set; }
    }

    public class BreakStatement : Statement {
    }

    public class ContinueStatement : Statement {
    }

    public class ForeachStatement : Statement {
        public ValaType elem_type { get; set; default = ValaType.INT; }
        public string elem_type_name { get; set; default = ""; }
        public bool infer_type { get; set; default = false; }
        public string var_name { get; set; }
        public Expr collection { get; set; }
        public Statement body { get; set; }
    }

    public class SwitchCase : Object {
        public GenericArray<Expr> values { get; private set; }
        public GenericArray<Statement> body { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public SwitchCase () {
            values = new GenericArray<Expr> ();
            body = new GenericArray<Statement> ();
        }
    }

    public class SwitchStatement : Statement {
        public Expr target { get; set; }
        public GenericArray<SwitchCase> cases { get; private set; }
        public GenericArray<Statement> default_body { get; private set; }
        public bool has_default { get; set; default = false; }

        public SwitchStatement () {
            cases = new GenericArray<SwitchCase> ();
            default_body = new GenericArray<Statement> ();
        }
    }

    // ------------------------------------------------------------------
    // Type declarations, functions and program.
    // ------------------------------------------------------------------

    public class EnumMember : Object {
        public string name { get; set; }
        public int64 value { get; set; }
    }

    public class EnumDecl : Object {
        public string name { get; set; }
        public bool is_defined { get; set; default = false; }
        public GenericArray<EnumMember> members { get; private set; }
        public GenericArray<Function> methods { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public EnumDecl () {
            members = new GenericArray<EnumMember> ();
            methods = new GenericArray<Function> ();
        }

        public unowned EnumMember? find_member (string mname) {
            foreach (unowned var m in members) {
                if (m.name == mname)
                    return m;
            }
            return null;
        }

        public unowned Function? find_method (string mname) {
            foreach (unowned var m in methods) {
                if (m.name == mname || m.method_name == mname)
                    return m;
            }
            return null;
        }
    }

    public class StructField : Object {
        public ValaType field_type { get; set; }
        public string type_name { get; set; default = ""; }
        public string name { get; set; }
        public int line { get; set; }
        public int column { get; set; }
    }

    public class StructDecl : Object {
        public string name { get; set; }
        public bool is_defined { get; set; default = false; }
        public GenericArray<StructField> fields { get; private set; }
        public GenericArray<Function> methods { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public StructDecl () {
            fields = new GenericArray<StructField> ();
            methods = new GenericArray<Function> ();
        }

        public unowned StructField? find_field (string fname) {
            foreach (unowned var f in fields) {
                if (f.name == fname)
                    return f;
            }
            return null;
        }

        public unowned Function? find_method (string mname) {
            foreach (unowned var m in methods) {
                if (m.name == mname || m.method_name == mname)
                    return m;
            }
            return null;
        }
    }

    public class Param : Object {
        public ValaType param_type { get; set; }
        public string type_name { get; set; default = ""; }
        public string name { get; set; }
        public bool unmanaged { get; set; default = false; }
        public bool is_ref { get; set; default = false; }
        public bool is_out { get; set; default = false; }
        public int line { get; set; }
        public int column { get; set; }
    }

    public class Function : Object {
        public string name { get; set; }
        public string method_name { get; set; default = ""; }
        public ValaType return_type { get; set; default = ValaType.VOID; }
        public string return_type_name { get; set; default = ""; }
        public bool is_void {
            get { return return_type == ValaType.VOID; }
        }
        public bool is_virtual { get; set; default = false; }
        public bool is_override { get; set; default = false; }
        public bool is_abstract { get; set; default = false; }
        public bool is_static { get; set; default = false; }
        public bool is_ctor { get; set; default = false; }
        public bool is_dtor { get; set; default = false; }
        public bool has_base_call { get; set; default = false; }
        public GenericArray<Expr> base_args { get; private set; }
        public string owner_class { get; set; default = ""; }
        public int vtable_slot { get; set; default = -1; }
        public GenericArray<string> throws_domains { get; private set; }
        public bool can_throw {
            get { return throws_domains.length > 0; }
        }
        public GenericArray<Param> params { get; private set; }
        public GenericArray<Statement> body { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public Function () {
            params = new GenericArray<Param> ();
            body = new GenericArray<Statement> ();
            base_args = new GenericArray<Expr> ();
            throws_domains = new GenericArray<string> ();
        }
    }

    public class ClassField : Object {
        public ValaType field_type { get; set; }
        public string type_name { get; set; default = ""; }
        public string name { get; set; }
        public Expr? init { get; set; }
        public int line { get; set; }
        public int column { get; set; }
    }

    public class ClassDecl : Object {
        public string name { get; set; }
        public string base_name { get; set; default = ""; }
        public bool is_abstract { get; set; default = false; }
        public bool is_defined { get; set; default = false; }
        public GenericArray<ClassField> fields { get; private set; }
        public GenericArray<Function> methods { get; private set; }
        public Function? ctor { get; set; }
        public Function? dtor { get; set; }
        public int vtable_rodata_offset { get; set; default = -1; }
        public bool needs_finalizer { get; set; default = false; }
        public GenericArray<string> vtable_method_names { get; private set; }
        public GenericArray<string> vtable_impl_symbols { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public ClassDecl () {
            fields = new GenericArray<ClassField> ();
            methods = new GenericArray<Function> ();
            vtable_method_names = new GenericArray<string> ();
            vtable_impl_symbols = new GenericArray<string> ();
        }

        public unowned ClassField? find_own_field (string fname) {
            foreach (unowned var f in fields) {
                if (f.name == fname)
                    return f;
            }
            return null;
        }

        public unowned Function? find_own_method (string mname) {
            foreach (unowned var m in methods) {
                if (m.name == mname || m.method_name == mname)
                    return m;
            }
            return null;
        }
    }

    public class ConstDecl : Object {
        public ValaType const_type { get; set; default = ValaType.INT; }
        public string type_name { get; set; default = ""; }
        public string name { get; set; }
        public string owner_type { get; set; default = ""; }
        public int64 int_value { get; set; }
        public string str_value { get; set; default = ""; }
        public int line { get; set; }
        public int column { get; set; }
    }

    public class ThrowStatement : Statement {
        public string domain_name { get; set; }
        public string code_name { get; set; }
        public Expr message { get; set; }
    }

    public class CatchClause : Object {
        public string domain_name { get; set; }
        public string var_name { get; set; }
        public GenericArray<Statement> body { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public CatchClause () {
            body = new GenericArray<Statement> ();
        }
    }

    public class TryStatement : Statement {
        public GenericArray<Statement> try_body { get; private set; }
        public GenericArray<CatchClause> catches { get; private set; }
        public GenericArray<Statement> finally_body { get; private set; }
        public bool has_finally { get; set; default = false; }

        public TryStatement () {
            try_body = new GenericArray<Statement> ();
            catches = new GenericArray<CatchClause> ();
            finally_body = new GenericArray<Statement> ();
        }
    }

    public class ErrorDomainDecl : Object {
        public string name { get; set; }
        public int domain_id { get; set; }
        public bool is_defined { get; set; default = false; }
        public GenericArray<EnumMember> codes { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public ErrorDomainDecl () {
            codes = new GenericArray<EnumMember> ();
        }

        public unowned EnumMember? find_code (string cname) {
            foreach (unowned var m in codes) {
                if (m.name == cname)
                    return m;
            }
            return null;
        }
    }

    public class Program : Object {
        public GenericArray<Function> functions { get; private set; }
        public GenericArray<GlobalVar> globals { get; private set; }
        public GenericArray<ConstDecl> consts { get; private set; }
        public GenericArray<EnumDecl> enums { get; private set; }
        public GenericArray<StructDecl> structs { get; private set; }
        public GenericArray<ClassDecl> classes { get; private set; }
        public GenericArray<ErrorDomainDecl> error_domains { get; private set; }

        public Program () {
            functions = new GenericArray<Function> ();
            globals = new GenericArray<GlobalVar> ();
            consts = new GenericArray<ConstDecl> ();
            enums = new GenericArray<EnumDecl> ();
            structs = new GenericArray<StructDecl> ();
            classes = new GenericArray<ClassDecl> ();
            error_domains = new GenericArray<ErrorDomainDecl> ();
        }

        public unowned ErrorDomainDecl? find_error_domain (string name) {
            foreach (unowned var d in error_domains) {
                if (d.name == name)
                    return d;
            }
            return null;
        }

        public unowned ConstDecl? find_const (string owner, string cname) {
            foreach (unowned var c in consts) {
                if (c.owner_type == owner && c.name == cname)
                    return c;
            }
            return null;
        }

        public unowned Function? find (string name) {
            foreach (unowned var f in functions) {
                if (f.name == name)
                    return f;
            }
            return null;
        }

        public unowned EnumDecl? find_enum (string name) {
            foreach (unowned var e in enums) {
                if (e.name == name)
                    return e;
            }
            return null;
        }

        public unowned StructDecl? find_struct (string name) {
            foreach (unowned var s in structs) {
                if (s.name == name)
                    return s;
            }
            return null;
        }

        public unowned ClassDecl? find_class (string name) {
            foreach (unowned var c in classes) {
                if (c.name == name)
                    return c;
            }
            return null;
        }
    }

    // A program-level variable. Literal initializers only: there is no
    // constant folding yet, and runtime initialization would need startup
    // code before main.
    public class GlobalVar : Object {
        public ValaType var_type { get; set; default = ValaType.INT; }
        public string var_type_name { get; set; default = ""; }
        public string name { get; set; }
        public int64 value { get; set; }
        public string str_value { get; set; default = ""; }
        public bool initialized { get; set; }   // false: zero (.bss) for int/bool/enum/struct, "" for string
        public int line { get; set; }
        public int column { get; set; }
    }
}
