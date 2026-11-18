// AST nodes for the Planc dialect.
//
// Slice 7 adds: `foreach`, `switch`/`case`/`default`, string slicing `s[start:end]`,
// ternary `?:`, null-coalescing `??`, integer width aliases (`uint8`..`uint64`,
// `size_t`, `char`), hex/binary/char literals, `const`, `static`, and `struct`/`enum` methods.

namespace Planc {

    public enum ValaType {
        VOID,
        INT,
        FLOAT,
        DOUBLE,
        BOOL,
        STRING,
        ENUM,
        STRUCT,
        ARRAY,
        CLASS,
        INTERFACE,
        ERROR,
        TYPE_PARAM,
        NULL;

        public string label () {
            switch (this) {
                case VOID:       return "void";
                case INT:        return "int";
                case FLOAT:      return "float";
                case DOUBLE:     return "double";
                case BOOL:       return "bool";
                case STRING:     return "string";
                case ENUM:       return "enum";
                case STRUCT:     return "struct";
                case ARRAY:      return "array";
                case CLASS:      return "class";
                case INTERFACE:  return "interface";
                case ERROR:      return "Error";
                case TYPE_PARAM: return "type_param";
                case NULL:       return "null";
                default:         return "?";
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

    public class FloatLiteral : Expr {
        public uint64 bits { get; set; }
        public bool is_float32 { get; set; }
        public string raw_text { get; set; default = ""; }
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
        public string target_del_type { get; set; default = ""; }
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
        public int temp_slot { get; set; default = -1; }
        public string target_del_type { get; set; default = ""; }
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
        public string ctor_name { get; set; default = ""; }
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

    public class IncDecExpr : Expr {
        public bool is_prefix { get; set; }
        public string op { get; set; }   // "++" or "--"
        public Expr target { get; set; }
    }

    public class YieldExpr : Expr {
        public Expr? value { get; set; default = null; }
    }

    public class LambdaExpr : Expr {
        public GenericArray<string> param_names { get; private set; }
        public GenericArray<Statement> body { get; private set; }
        public Expr? expr_body { get; set; }
        public string delegate_type_name { get; set; default = ""; }
        public string synth_func_name { get; set; default = ""; }
        public int temp_slot { get; set; default = -1; }
        public GenericArray<string> captured_names { get; private set; }
        public GenericArray<ValaType> captured_types { get; private set; }
        public GenericArray<string> captured_type_names { get; private set; }
        public int ref_cap_count { get; set; default = 0; }

        public LambdaExpr () {
            param_names = new GenericArray<string> ();
            body = new GenericArray<Statement> ();
            captured_names = new GenericArray<string> ();
            captured_types = new GenericArray<ValaType> ();
            captured_type_names = new GenericArray<string> ();
        }
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
        public bool is_weak { get; set; default = false; }
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
        public bool is_weak { get; set; default = false; }
        public string name { get; set; }
        public int line { get; set; }
        public int column { get; set; }
    }

    public class StructDecl : Object {
        public string name { get; set; }
        public bool is_defined { get; set; default = false; }
        public bool is_union { get; set; default = false; }
        public bool is_generic_template { get; set; default = false; }
        public bool is_delegate { get; set; default = false; }
        public GenericArray<string> type_params { get; private set; }
        public GenericArray<StructField> fields { get; private set; }
        public GenericArray<Function> methods { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public StructDecl () {
            type_params = new GenericArray<string> ();
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
        public bool is_weak { get; set; default = false; }
        public string name { get; set; }
        public bool unmanaged { get; set; default = false; }
        public bool is_ref { get; set; default = false; }
        public bool is_out { get; set; default = false; }
        public Expr? default_value { get; set; default = null; }
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
        public string ctor_subname { get; set; default = ""; }
        public bool is_dtor { get; set; default = false; }
        public bool has_base_call { get; set; default = false; }
        public bool has_this_call { get; set; default = false; }
        public string this_ctor_subname { get; set; default = ""; }
        public GenericArray<Expr> base_args { get; private set; }
        public string owner_class { get; set; default = ""; }
        public int vtable_slot { get; set; default = -1; }
        public int iface_id { get; set; default = -1; }
        public int iface_slot { get; set; default = -1; }
        public bool has_body { get; set; default = true; }
        public bool is_async { get; set; default = false; }
        public bool is_asm_body { get; set; default = false; }
        public string asm_body { get; set; default = ""; }
        public int asm_line { get; set; default = 0; }
        public int asm_column { get; set; default = 0; }
        public LambdaExpr? from_lambda { get; set; default = null; }
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

    public class SignalDecl : Object {
        public string name { get; set; }
        public ValaType return_type { get; set; default = ValaType.VOID; }
        public string return_type_name { get; set; default = ""; }
        public GenericArray<Param> params { get; private set; }
        public bool is_virtual { get; set; default = false; }
        public Function? default_handler { get; set; default = null; }
        public string handler_delegate_name { get; set; default = ""; }
        public int slot_index { get; set; default = -1; }
        public int line { get; set; }
        public int column { get; set; }

        public SignalDecl () {
            params = new GenericArray<Param> ();
        }
    }

    public class ClassField : Object {
        public ValaType field_type { get; set; }
        public string type_name { get; set; default = ""; }
        public bool is_weak { get; set; default = false; }
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
        public bool is_union { get; set; default = false; }
        public bool is_generic_template { get; set; default = false; }
        public GenericArray<string> type_params { get; private set; }
        public GenericArray<string> iface_names { get; private set; }
        public GenericArray<ClassField> fields { get; private set; }
        public GenericArray<Function> methods { get; private set; }
        public GenericArray<SignalDecl> signals { get; private set; }
        public GenericArray<Function> named_ctors { get; private set; }
        public Function? ctor { get; set; }
        public Function? dtor { get; set; }
        public int vtable_rodata_offset { get; set; default = -1; }
        public int itable_rodata_offset { get; set; default = -1; }
        public bool needs_finalizer { get; set; default = false; }
        public GenericArray<string> vtable_method_names { get; private set; }
        public GenericArray<string> vtable_impl_symbols { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public ClassDecl () {
            type_params = new GenericArray<string> ();
            iface_names = new GenericArray<string> ();
            fields = new GenericArray<ClassField> ();
            methods = new GenericArray<Function> ();
            signals = new GenericArray<SignalDecl> ();
            named_ctors = new GenericArray<Function> ();
            vtable_method_names = new GenericArray<string> ();
            vtable_impl_symbols = new GenericArray<string> ();
        }

        public unowned Function? find_own_named_ctor (string sub) {
            foreach (unowned var c in named_ctors) {
                if (c.ctor_subname == sub)
                    return c;
            }
            return null;
        }

        public unowned ClassField? find_own_field (string fname) {
            foreach (unowned var f in fields) {
                if (f.name == fname)
                    return f;
            }
            return null;
        }

        public unowned SignalDecl? find_own_signal (string sname) {
            foreach (unowned var s in signals) {
                if (s.name == sname)
                    return s;
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
        public bool is_weak { get; set; default = false; }
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

    public class InterfaceDecl : Object {
        public string name { get; set; }
        public int iface_id { get; set; }
        public bool is_defined { get; set; default = false; }
        public GenericArray<string> prereq_names { get; private set; }
        public GenericArray<Function> methods { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public InterfaceDecl () {
            prereq_names = new GenericArray<string> ();
            methods = new GenericArray<Function> ();
        }

        public unowned Function? find_own_method (string mname) {
            foreach (unowned var m in methods) {
                if (m.name == mname || m.method_name == mname)
                    return m;
            }
            return null;
        }
    }

    public class DelegateDecl : Object {
        public string name { get; set; }
        public bool is_defined { get; set; default = false; }
        public ValaType return_type { get; set; default = ValaType.VOID; }
        public string return_type_name { get; set; default = ""; }
        public GenericArray<Param> params { get; private set; }
        public GenericArray<string> throws_domains { get; private set; }
        public int line { get; set; }
        public int column { get; set; }

        public DelegateDecl () {
            params = new GenericArray<Param> ();
            throws_domains = new GenericArray<string> ();
        }
    }

    public class GenericInstantiation : Object {
        public string template_name { get; set; }
        public string mangled_name { get; set; }
        public bool is_struct { get; set; default = false; }
        public bool has_type_param { get; set; default = false; }
        public GenericArray<ValaType> arg_types { get; private set; }
        public GenericArray<string> arg_type_names { get; private set; }

        public GenericInstantiation () {
            arg_types = new GenericArray<ValaType> ();
            arg_type_names = new GenericArray<string> ();
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
        public GenericArray<InterfaceDecl> interfaces { get; private set; }
        public GenericArray<DelegateDecl> delegates { get; private set; }
        public GenericArray<GenericInstantiation> instantiations { get; private set; }

        public Program () {
            functions = new GenericArray<Function> ();
            globals = new GenericArray<GlobalVar> ();
            consts = new GenericArray<ConstDecl> ();
            enums = new GenericArray<EnumDecl> ();
            structs = new GenericArray<StructDecl> ();
            classes = new GenericArray<ClassDecl> ();
            error_domains = new GenericArray<ErrorDomainDecl> ();
            interfaces = new GenericArray<InterfaceDecl> ();
            delegates = new GenericArray<DelegateDecl> ();
            instantiations = new GenericArray<GenericInstantiation> ();
        }

        public unowned ErrorDomainDecl? find_error_domain (string name) {
            foreach (unowned var d in error_domains) {
                if (d.name == name)
                    return d;
            }
            return null;
        }

        public unowned InterfaceDecl? find_interface (string name) {
            foreach (unowned var itf in interfaces) {
                if (itf.name == name)
                    return itf;
            }
            return null;
        }

        public unowned DelegateDecl? find_delegate (string name) {
            foreach (unowned var d in delegates) {
                if (d.name == name)
                    return d;
            }
            return null;
        }

        public void register_delegate_struct (string name) {
            if (find_struct (name) != null)
                return;
            var sd = new StructDecl () {
                name = name,
                is_defined = true,
                is_delegate = true
            };
            sd.fields.add (new StructField () {
                field_type = ValaType.INT,
                type_name = "",
                name = "#code"
            });
            sd.fields.add (new StructField () {
                field_type = ValaType.STRING,
                type_name = "string?",
                name = "#env"
            });
            structs.add (sd);
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

        public unowned GenericInstantiation? find_instantiation_by_mangled (string mangled) {
            foreach (unowned var gi in instantiations) {
                if (gi.mangled_name == mangled)
                    return gi;
            }
            return null;
        }

        private static string sanitize_ident (string s) {
            var sb = new StrBuilder ();
            for (int i = 0; i < s.length; i++) {
                var ch = (char) s[i];
                if (ch == '?')
                    sb.append ("_q");
                else if (ch == '.' || ch == '<' || ch == '>' || ch == ',' || ch == '[' || ch == ']')
                    sb.append_c ('_');
                else
                    sb.append_c (ch);
            }
            return sb.str;
        }

        private static string mangle_type_arg (ValaType t, string tname) {
            if (t == ValaType.ARRAY)
                return "arr_" + sanitize_ident (tname);
            if (t == ValaType.STRING)
                return (tname == "?" || tname == "string?") ? "string_q" : "string";
            if (t == ValaType.ERROR) {
                if (tname == "" || tname == "Error")
                    return "Error";
                if (tname == "?" || tname == "Error?")
                    return "Error_q";
                return sanitize_ident (tname);
            }
            if (tname != "")
                return sanitize_ident (tname);
            return t.label ();
        }

        private static string strip_q_str (string s) {
            return s.has_suffix ("?") ? s[0:s.length - 1] : s;
        }

        public string request_instantiation (string template_name, bool is_struct,
                                             GenericArray<ValaType> arg_types,
                                             GenericArray<string> arg_type_names) {
            bool has_tp = false;
            for (int i = 0; i < arg_types.length; i++) {
                if (arg_types[i] == ValaType.TYPE_PARAM) {
                    has_tp = true;
                    break;
                }
                var bare = strip_q_str (arg_type_names[i]);
                unowned var sub = (bare != "") ? find_instantiation_by_mangled (bare) : null;
                if (sub != null && sub.has_type_param) {
                    has_tp = true;
                    break;
                }
            }

            if (!has_tp) {
                var sb = new StrBuilder (template_name);
                for (int i = 0; i < arg_types.length; i++) {
                    sb.append ("__");
                    sb.append (mangle_type_arg (arg_types[i], arg_type_names[i]));
                }
                var mangled = sb.str;
                foreach (unowned var existing in instantiations) {
                    if (existing.mangled_name == mangled)
                        return mangled;
                }
                var gi = new GenericInstantiation () {
                    template_name = template_name,
                    mangled_name = mangled,
                    is_struct = is_struct,
                    has_type_param = false
                };
                for (int i = 0; i < arg_types.length; i++) {
                    gi.arg_types.add (arg_types[i]);
                    gi.arg_type_names.add (arg_type_names[i]);
                }
                instantiations.add (gi);
                return mangled;
            }

            // Parameterized reference inside a generic template: reuse matching key if identical.
            foreach (unowned var existing in instantiations) {
                if (existing.has_type_param && existing.template_name == template_name
                    && existing.is_struct == is_struct
                    && existing.arg_types.length == arg_types.length) {
                    bool same = true;
                    for (int i = 0; i < arg_types.length; i++) {
                        if (existing.arg_types[i] != arg_types[i]
                            || existing.arg_type_names[i] != arg_type_names[i]) {
                            same = false;
                            break;
                        }
                    }
                    if (same)
                        return existing.mangled_name;
                }
            }
            var tpl_mangled = @"$(template_name)__@tpl_$(instantiations.length)";
            var pgi = new GenericInstantiation () {
                template_name = template_name,
                mangled_name = tpl_mangled,
                is_struct = is_struct,
                has_type_param = true
            };
            for (int i = 0; i < arg_types.length; i++) {
                pgi.arg_types.add (arg_types[i]);
                pgi.arg_type_names.add (arg_type_names[i]);
            }
            instantiations.add (pgi);
            return tpl_mangled;
        }

        private void substitute_type (ref ValaType t, ref string tname,
                                      GenericArray<string> tparams,
                                      GenericArray<ValaType> targs,
                                      GenericArray<string> targ_names) {
            if (t == ValaType.TYPE_PARAM) {
                bool is_null = tname.has_suffix ("?");
                var bare = strip_q_str (tname);
                for (int i = 0; i < tparams.length; i++) {
                    if (tparams[i] == bare) {
                        t = targs[i];
                        var rname = targ_names[i];
                        if (is_null && (t == ValaType.STRING || t == ValaType.CLASS
                                        || t == ValaType.INTERFACE || t == ValaType.ERROR)) {
                            if (t == ValaType.STRING)
                                rname = "?";
                            else if (t == ValaType.ERROR && rname == "")
                                rname = "?";
                            else if (!rname.has_suffix ("?"))
                                rname = rname + "?";
                        }
                        tname = rname;
                        return;
                    }
                }
                return;
            }
            if (t == ValaType.ARRAY) {
                bool arr_null = tname.has_suffix ("?");
                var bare = strip_q_str (tname);
                for (int i = 0; i < tparams.length; i++) {
                    if (tparams[i] == bare) {
                        var et = targs[i];
                        var en = targ_names[i];
                        string sname;
                        if (et == ValaType.CLASS || et == ValaType.ENUM
                            || et == ValaType.INTERFACE || et == ValaType.ERROR
                            || et == ValaType.STRUCT) {
                            sname = (en != "") ? en : et.label ();
                        } else if (et == ValaType.STRING && en.has_suffix ("?")) {
                            sname = "string?";
                        } else {
                            sname = et.label ();
                        }
                        if (arr_null && !sname.has_suffix ("?"))
                            sname = sname + "?";
                        tname = sname;
                        return;
                    }
                }
                unowned var sub = (bare != "") ? find_instantiation_by_mangled (bare) : null;
                if (sub != null && sub.has_type_param) {
                    var ntypes = new GenericArray<ValaType> ();
                    var nnames = new GenericArray<string> ();
                    for (int j = 0; j < sub.arg_types.length; j++) {
                        var at = sub.arg_types[j];
                        var an = sub.arg_type_names[j];
                        substitute_type (ref at, ref an, tparams, targs, targ_names);
                        ntypes.add (at);
                        nnames.add (an);
                    }
                    var rm = request_instantiation (sub.template_name, sub.is_struct, ntypes, nnames);
                    tname = arr_null ? (rm + "?") : rm;
                }
                return;
            }
            if ((t == ValaType.CLASS || t == ValaType.STRUCT) && tname != "") {
                bool is_null = tname.has_suffix ("?");
                var bare = strip_q_str (tname);
                unowned var sub = find_instantiation_by_mangled (bare);
                if (sub != null && sub.has_type_param) {
                    var ntypes = new GenericArray<ValaType> ();
                    var nnames = new GenericArray<string> ();
                    for (int j = 0; j < sub.arg_types.length; j++) {
                        var at = sub.arg_types[j];
                        var an = sub.arg_type_names[j];
                        substitute_type (ref at, ref an, tparams, targs, targ_names);
                        ntypes.add (at);
                        nnames.add (an);
                    }
                    var rm = request_instantiation (sub.template_name, sub.is_struct, ntypes, nnames);
                    tname = is_null ? (rm + "?") : rm;
                }
            }
        }

        public Expr clone_expr_plain (Expr e) {
            return clone_expr (e, new GenericArray<string> (),
                               new GenericArray<ValaType> (),
                               new GenericArray<string> ());
        }

        private Expr clone_expr (Expr e,
                                 GenericArray<string> tparams,
                                 GenericArray<ValaType> targs,
                                 GenericArray<string> targ_names) {
            if (e is IntLiteral) {
                var o = (IntLiteral) e;
                return new IntLiteral () { value = o.value, line = o.line, column = o.column };
            }
            if (e is FloatLiteral) {
                var o = (FloatLiteral) e;
                return new FloatLiteral () {
                    bits = o.bits, is_float32 = o.is_float32, raw_text = o.raw_text,
                    line = o.line, column = o.column
                };
            }
            if (e is BoolLiteral) {
                var o = (BoolLiteral) e;
                return new BoolLiteral () { value = o.value, line = o.line, column = o.column };
            }
            if (e is StringLiteral) {
                var o = (StringLiteral) e;
                return new StringLiteral () { value = o.value, line = o.line, column = o.column };
            }
            if (e is NullLiteral) {
                return new NullLiteral () { line = e.line, column = e.column };
            }
            if (e is TemplateExpr) {
                var o = (TemplateExpr) e;
                var n = new TemplateExpr () { line = o.line, column = o.column };
                foreach (var p in o.parts)
                    n.parts.add (clone_expr (p, tparams, targs, targ_names));
                return n;
            }
            if (e is MemberAccessExpr) {
                var o = (MemberAccessExpr) e;
                return new MemberAccessExpr () {
                    target = clone_expr (o.target, tparams, targs, targ_names),
                    member = o.member,
                    line = o.line, column = o.column
                };
            }
            if (e is IndexExpr) {
                var o = (IndexExpr) e;
                return new IndexExpr () {
                    target = clone_expr (o.target, tparams, targs, targ_names),
                    index = clone_expr (o.index, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is ArrayNewExpr) {
                var o = (ArrayNewExpr) e;
                var et = o.elem_type;
                var en = o.elem_type_name;
                substitute_type (ref et, ref en, tparams, targs, targ_names);
                return new ArrayNewExpr () {
                    elem_type = et,
                    elem_type_name = en,
                    length_expr = clone_expr (o.length_expr, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is ArrayLiteralExpr) {
                var o = (ArrayLiteralExpr) e;
                var et = o.elem_type;
                var en = o.elem_type_name;
                substitute_type (ref et, ref en, tparams, targs, targ_names);
                var n = new ArrayLiteralExpr () {
                    elem_type = et,
                    elem_type_name = en,
                    line = o.line, column = o.column
                };
                foreach (var el in o.elements)
                    n.elements.add (clone_expr (el, tparams, targs, targ_names));
                return n;
            }
            if (e is StructLiteral) {
                var o = (StructLiteral) e;
                var st = ValaType.STRUCT;
                var sn = o.struct_name;
                substitute_type (ref st, ref sn, tparams, targs, targ_names);
                var n = new StructLiteral () { struct_name = sn, line = o.line, column = o.column };
                for (int i = 0; i < o.field_names.length; i++) {
                    n.field_names.add (o.field_names[i]);
                    n.field_values.add (clone_expr (o.field_values[i], tparams, targs, targ_names));
                }
                return n;
            }
            if (e is VarRef) {
                var o = (VarRef) e;
                return new VarRef () { name = o.name, line = o.line, column = o.column };
            }
            if (e is UnaryExpr) {
                var o = (UnaryExpr) e;
                return new UnaryExpr () {
                    op = o.op,
                    operand = clone_expr (o.operand, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is BinaryExpr) {
                var o = (BinaryExpr) e;
                return new BinaryExpr () {
                    op = o.op,
                    left = clone_expr (o.left, tparams, targs, targ_names),
                    right = clone_expr (o.right, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is CallExpr) {
                var o = (CallExpr) e;
                var n = new CallExpr () { callee = o.callee, line = o.line, column = o.column };
                foreach (var a in o.args)
                    n.args.add (clone_expr (a, tparams, targs, targ_names));
                return n;
            }
            if (e is ClassNewExpr) {
                var o = (ClassNewExpr) e;
                var ct = ValaType.CLASS;
                var cn = o.class_name;
                substitute_type (ref ct, ref cn, tparams, targs, targ_names);
                var n = new ClassNewExpr () {
                    class_name = cn,
                    ctor_name = o.ctor_name,
                    line = o.line, column = o.column
                };
                foreach (var a in o.args)
                    n.args.add (clone_expr (a, tparams, targs, targ_names));
                for (int i = 0; i < o.init_names.length; i++) {
                    n.init_names.add (o.init_names[i]);
                    n.init_values.add (clone_expr (o.init_values[i], tparams, targs, targ_names));
                }
                return n;
            }
            if (e is MethodCallExpr) {
                var o = (MethodCallExpr) e;
                var n = new MethodCallExpr () {
                    target = (o.target != null) ? clone_expr (o.target, tparams, targs, targ_names) : null,
                    is_base_call = o.is_base_call,
                    method_name = o.method_name,
                    line = o.line, column = o.column
                };
                foreach (var a in o.args)
                    n.args.add (clone_expr (a, tparams, targs, targ_names));
                return n;
            }
            if (e is TypeCheckExpr) {
                var o = (TypeCheckExpr) e;
                var tt = o.target_type;
                var tn = o.target_type_name;
                substitute_type (ref tt, ref tn, tparams, targs, targ_names);
                return new TypeCheckExpr () {
                    op = o.op,
                    operand = clone_expr (o.operand, tparams, targs, targ_names),
                    target_type = tt,
                    target_type_name = tn,
                    line = o.line, column = o.column
                };
            }
            if (e is SliceExpr) {
                var o = (SliceExpr) e;
                return new SliceExpr () {
                    target = clone_expr (o.target, tparams, targs, targ_names),
                    start = clone_expr (o.start, tparams, targs, targ_names),
                    end = clone_expr (o.end, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is TernaryExpr) {
                var o = (TernaryExpr) e;
                return new TernaryExpr () {
                    condition = clone_expr (o.condition, tparams, targs, targ_names),
                    then_expr = clone_expr (o.then_expr, tparams, targs, targ_names),
                    else_expr = clone_expr (o.else_expr, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is CoalesceExpr) {
                var o = (CoalesceExpr) e;
                return new CoalesceExpr () {
                    left = clone_expr (o.left, tparams, targs, targ_names),
                    right = clone_expr (o.right, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is IncDecExpr) {
                var o = (IncDecExpr) e;
                return new IncDecExpr () {
                    is_prefix = o.is_prefix,
                    op = o.op,
                    target = clone_expr (o.target, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (e is YieldExpr) {
                var o = (YieldExpr) e;
                return new YieldExpr () {
                    value = (o.value != null) ? clone_expr (o.value, tparams, targs, targ_names) : null,
                    line = o.line, column = o.column
                };
            }
            var lo = (LambdaExpr) e;
            var ln = new LambdaExpr () {
                expr_body = (lo.expr_body != null) ? clone_expr (lo.expr_body, tparams, targs, targ_names) : null,
                line = lo.line, column = lo.column
            };
            foreach (var pn in lo.param_names)
                ln.param_names.add (pn);
            foreach (var bs in lo.body)
                ln.body.add (clone_stmt (bs, tparams, targs, targ_names));
            return ln;
        }

        private Statement clone_stmt (Statement s,
                                      GenericArray<string> tparams,
                                      GenericArray<ValaType> targs,
                                      GenericArray<string> targ_names) {
            if (s is PrintStatement) {
                var o = (PrintStatement) s;
                return new PrintStatement () {
                    value = clone_expr (o.value, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is ExitStatement) {
                var o = (ExitStatement) s;
                return new ExitStatement () {
                    value = clone_expr (o.value, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is ReturnStatement) {
                var o = (ReturnStatement) s;
                return new ReturnStatement () {
                    value = (o.value != null) ? clone_expr (o.value, tparams, targs, targ_names) : null,
                    line = o.line, column = o.column
                };
            }
            if (s is VarDeclStatement) {
                var o = (VarDeclStatement) s;
                var dt = o.decl_type;
                var dn = o.decl_type_name;
                if (!o.infer_type)
                    substitute_type (ref dt, ref dn, tparams, targs, targ_names);
                return new VarDeclStatement () {
                    decl_type = dt,
                    decl_type_name = dn,
                    infer_type = o.infer_type,
                    name = o.name,
                    init = (o.init != null) ? clone_expr (o.init, tparams, targs, targ_names) : null,
                    line = o.line, column = o.column
                };
            }
            if (s is AssignStatement) {
                var o = (AssignStatement) s;
                return new AssignStatement () {
                    name = o.name,
                    value = clone_expr (o.value, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is FieldAssignStatement) {
                var o = (FieldAssignStatement) s;
                return new FieldAssignStatement () {
                    target = clone_expr (o.target, tparams, targs, targ_names),
                    field_name = o.field_name,
                    op = o.op,
                    value = clone_expr (o.value, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is IndexAssignStatement) {
                var o = (IndexAssignStatement) s;
                return new IndexAssignStatement () {
                    target = clone_expr (o.target, tparams, targs, targ_names),
                    index = clone_expr (o.index, tparams, targs, targ_names),
                    op = o.op,
                    value = clone_expr (o.value, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is ExprStatement) {
                var o = (ExprStatement) s;
                return new ExprStatement () {
                    expr = clone_expr (o.expr, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is BlockStatement) {
                var o = (BlockStatement) s;
                var n = new BlockStatement () { line = o.line, column = o.column };
                foreach (var st in o.statements)
                    n.statements.add (clone_stmt (st, tparams, targs, targ_names));
                return n;
            }
            if (s is IfStatement) {
                var o = (IfStatement) s;
                return new IfStatement () {
                    condition = clone_expr (o.condition, tparams, targs, targ_names),
                    then_body = clone_stmt (o.then_body, tparams, targs, targ_names),
                    else_body = (o.else_body != null) ? clone_stmt (o.else_body, tparams, targs, targ_names) : null,
                    line = o.line, column = o.column
                };
            }
            if (s is WhileStatement) {
                var o = (WhileStatement) s;
                return new WhileStatement () {
                    condition = clone_expr (o.condition, tparams, targs, targ_names),
                    body = clone_stmt (o.body, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is ForStatement) {
                var o = (ForStatement) s;
                return new ForStatement () {
                    init = (o.init != null) ? clone_stmt (o.init, tparams, targs, targ_names) : null,
                    condition = (o.condition != null) ? clone_expr (o.condition, tparams, targs, targ_names) : null,
                    step = (o.step != null) ? clone_stmt (o.step, tparams, targs, targ_names) : null,
                    body = clone_stmt (o.body, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is BreakStatement)
                return new BreakStatement () { line = s.line, column = s.column };
            if (s is ContinueStatement)
                return new ContinueStatement () { line = s.line, column = s.column };
            if (s is ForeachStatement) {
                var o = (ForeachStatement) s;
                var et = o.elem_type;
                var en = o.elem_type_name;
                if (!o.infer_type)
                    substitute_type (ref et, ref en, tparams, targs, targ_names);
                return new ForeachStatement () {
                    elem_type = et,
                    elem_type_name = en,
                    infer_type = o.infer_type,
                    var_name = o.var_name,
                    collection = clone_expr (o.collection, tparams, targs, targ_names),
                    body = clone_stmt (o.body, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            if (s is SwitchStatement) {
                var o = (SwitchStatement) s;
                var n = new SwitchStatement () {
                    target = clone_expr (o.target, tparams, targs, targ_names),
                    has_default = o.has_default,
                    line = o.line, column = o.column
                };
                foreach (var sc in o.cases) {
                    var nsc = new SwitchCase () { line = sc.line, column = sc.column };
                    foreach (var v in sc.values)
                        nsc.values.add (clone_expr (v, tparams, targs, targ_names));
                    foreach (var bs in sc.body)
                        nsc.body.add (clone_stmt (bs, tparams, targs, targ_names));
                    n.cases.add (nsc);
                }
                foreach (var ds in o.default_body)
                    n.default_body.add (clone_stmt (ds, tparams, targs, targ_names));
                return n;
            }
            if (s is ThrowStatement) {
                var o = (ThrowStatement) s;
                return new ThrowStatement () {
                    domain_name = o.domain_name,
                    code_name = o.code_name,
                    message = clone_expr (o.message, tparams, targs, targ_names),
                    line = o.line, column = o.column
                };
            }
            var to = (TryStatement) s;
            var tn = new TryStatement () {
                has_finally = to.has_finally,
                line = to.line, column = to.column
            };
            foreach (var st in to.try_body)
                tn.try_body.add (clone_stmt (st, tparams, targs, targ_names));
            foreach (var cc in to.catches) {
                var ncc = new CatchClause () {
                    domain_name = cc.domain_name,
                    var_name = cc.var_name,
                    line = cc.line, column = cc.column
                };
                foreach (var bs in cc.body)
                    ncc.body.add (clone_stmt (bs, tparams, targs, targ_names));
                tn.catches.add (ncc);
            }
            foreach (var fs in to.finally_body)
                tn.finally_body.add (clone_stmt (fs, tparams, targs, targ_names));
            return tn;
        }

        private Function clone_function (Function f, string new_owner,
                                         GenericArray<string> tparams,
                                         GenericArray<ValaType> targs,
                                         GenericArray<string> targ_names) {
            var rt = f.return_type;
            var rn = f.return_type_name;
            substitute_type (ref rt, ref rn, tparams, targs, targ_names);
            var nf = new Function () {
                name = f.name,
                method_name = f.method_name,
                return_type = rt,
                return_type_name = rn,
                is_virtual = f.is_virtual,
                is_override = f.is_override,
                is_abstract = f.is_abstract,
                is_static = f.is_static,
                is_ctor = f.is_ctor,
                ctor_subname = f.ctor_subname,
                is_dtor = f.is_dtor,
                has_base_call = f.has_base_call,
                has_this_call = f.has_this_call,
                this_ctor_subname = f.this_ctor_subname,
                owner_class = new_owner,
                has_body = f.has_body,
                is_async = f.is_async,
                is_asm_body = f.is_asm_body,
                asm_body = f.asm_body,
                asm_line = f.asm_line,
                asm_column = f.asm_column,
                line = f.line, column = f.column
            };
            foreach (var p in f.params) {
                var pt = p.param_type;
                var pn = p.type_name;
                substitute_type (ref pt, ref pn, tparams, targs, targ_names);
                nf.params.add (new Param () {
                    param_type = pt,
                    type_name = pn,
                    name = p.name,
                    unmanaged = p.unmanaged,
                    is_ref = p.is_ref,
                    is_out = p.is_out,
                    default_value = (p.default_value != null) ? clone_expr (p.default_value, tparams, targs, targ_names) : null,
                    line = p.line, column = p.column
                });
            }
            foreach (var td in f.throws_domains)
                nf.throws_domains.add (td);
            foreach (var ba in f.base_args)
                nf.base_args.add (clone_expr (ba, tparams, targs, targ_names));
            foreach (var st in f.body)
                nf.body.add (clone_stmt (st, tparams, targs, targ_names));
            return nf;
        }

        private void synthesize_channel (GenericInstantiation inst) {
            if (find_class (inst.mangled_name) != null)
                return;
            var cd = new ClassDecl () {
                name = inst.mangled_name,
                is_defined = true
            };
            cd.fields.add (new ClassField () {
                field_type = inst.arg_types[0],
                type_name = inst.arg_type_names[0],
                name = "elem"
            });
            classes.add (cd);
        }

        private void synthesize_generic_array (GenericInstantiation inst) {
            if (find_class (inst.mangled_name) != null)
                return;
            var et = inst.arg_types[0];
            var en = inst.arg_type_names[0];
            string arr_elem_name;
            if (et == ValaType.STRING && en.has_suffix ("?"))
                arr_elem_name = "?";
            else if (et == ValaType.CLASS || et == ValaType.ENUM || et == ValaType.INTERFACE
                     || (et == ValaType.ERROR && en != ""))
                arr_elem_name = en;
            else
                arr_elem_name = et.label ();

            var cd = new ClassDecl () {
                name = inst.mangled_name,
                is_defined = true
            };
            cd.fields.add (new ClassField () {
                field_type = ValaType.ARRAY,
                type_name = arr_elem_name,
                name = "data"
            });
            cd.fields.add (new ClassField () {
                field_type = ValaType.INT,
                type_name = "",
                name = "length"
            });

            var ctor = new Function () {
                name = "__ctor",
                return_type = ValaType.VOID,
                is_ctor = true,
                owner_class = inst.mangled_name
            };
            ctor.body.add (new FieldAssignStatement () {
                target = new VarRef () { name = "this" },
                field_name = "data",
                op = "=",
                value = new ArrayNewExpr () {
                    elem_type = et,
                    elem_type_name = en,
                    length_expr = new IntLiteral () { value = 8 }
                }
            });
            ctor.body.add (new FieldAssignStatement () {
                target = new VarRef () { name = "this" },
                field_name = "length",
                op = "=",
                value = new IntLiteral () { value = 0 }
            });
            cd.ctor = ctor;

            var add_m = new Function () {
                name = "add",
                return_type = ValaType.VOID,
                owner_class = inst.mangled_name
            };
            add_m.params.add (new Param () {
                param_type = et,
                type_name = en,
                name = "item"
            });
            var grow_if = new IfStatement () {
                condition = new BinaryExpr () {
                    op = ">=",
                    left = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "length"
                    },
                    right = new MemberAccessExpr () {
                        target = new MemberAccessExpr () {
                            target = new VarRef () { name = "this" },
                            member = "data"
                        },
                        member = "length"
                    }
                }
            };
            var then_blk = new BlockStatement ();
            then_blk.statements.add (new VarDeclStatement () {
                infer_type = true,
                name = "grown",
                init = new ArrayNewExpr () {
                    elem_type = et,
                    elem_type_name = en,
                    length_expr = new BinaryExpr () {
                        op = "*",
                        left = new MemberAccessExpr () {
                            target = new MemberAccessExpr () {
                                target = new VarRef () { name = "this" },
                                member = "data"
                            },
                            member = "length"
                        },
                        right = new IntLiteral () { value = 2 }
                    }
                }
            });
            var copy_loop = new ForStatement () {
                init = new VarDeclStatement () {
                    decl_type = ValaType.INT,
                    name = "i",
                    init = new IntLiteral () { value = 0 }
                },
                condition = new BinaryExpr () {
                    op = "<",
                    left = new VarRef () { name = "i" },
                    right = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "length"
                    }
                },
                step = new AssignStatement () {
                    name = "i",
                    value = new BinaryExpr () {
                        op = "+",
                        left = new VarRef () { name = "i" },
                        right = new IntLiteral () { value = 1 }
                    }
                }
            };
            var copy_body = new BlockStatement ();
            copy_body.statements.add (new IndexAssignStatement () {
                target = new VarRef () { name = "grown" },
                index = new VarRef () { name = "i" },
                op = "=",
                value = new IndexExpr () {
                    target = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "data"
                    },
                    index = new VarRef () { name = "i" }
                }
            });
            copy_loop.body = copy_body;
            then_blk.statements.add (copy_loop);
            then_blk.statements.add (new FieldAssignStatement () {
                target = new VarRef () { name = "this" },
                field_name = "data",
                op = "=",
                value = new VarRef () { name = "grown" }
            });
            grow_if.then_body = then_blk;
            add_m.body.add (grow_if);
            add_m.body.add (new IndexAssignStatement () {
                target = new MemberAccessExpr () {
                    target = new VarRef () { name = "this" },
                    member = "data"
                },
                index = new MemberAccessExpr () {
                    target = new VarRef () { name = "this" },
                    member = "length"
                },
                op = "=",
                value = new VarRef () { name = "item" }
            });
            add_m.body.add (new FieldAssignStatement () {
                target = new VarRef () { name = "this" },
                field_name = "length",
                op = "=",
                value = new BinaryExpr () {
                    op = "+",
                    left = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "length"
                    },
                    right = new IntLiteral () { value = 1 }
                }
            });
            cd.methods.add (add_m);

            var rem_m = new Function () {
                name = "remove_index",
                return_type = ValaType.VOID,
                owner_class = inst.mangled_name
            };
            rem_m.params.add (new Param () {
                param_type = ValaType.INT,
                type_name = "",
                name = "index"
            });
            var rem_loop = new ForStatement () {
                init = new VarDeclStatement () {
                    decl_type = ValaType.INT,
                    name = "i",
                    init = new VarRef () { name = "index" }
                },
                condition = new BinaryExpr () {
                    op = "<",
                    left = new BinaryExpr () {
                        op = "+",
                        left = new VarRef () { name = "i" },
                        right = new IntLiteral () { value = 1 }
                    },
                    right = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "length"
                    }
                },
                step = new AssignStatement () {
                    name = "i",
                    value = new BinaryExpr () {
                        op = "+",
                        left = new VarRef () { name = "i" },
                        right = new IntLiteral () { value = 1 }
                    }
                }
            };
            var rem_body = new BlockStatement ();
            rem_body.statements.add (new IndexAssignStatement () {
                target = new MemberAccessExpr () {
                    target = new VarRef () { name = "this" },
                    member = "data"
                },
                index = new VarRef () { name = "i" },
                op = "=",
                value = new IndexExpr () {
                    target = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "data"
                    },
                    index = new BinaryExpr () {
                        op = "+",
                        left = new VarRef () { name = "i" },
                        right = new IntLiteral () { value = 1 }
                    }
                }
            });
            rem_loop.body = rem_body;
            rem_m.body.add (rem_loop);
            rem_m.body.add (new FieldAssignStatement () {
                target = new VarRef () { name = "this" },
                field_name = "length",
                op = "=",
                value = new BinaryExpr () {
                    op = "-",
                    left = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "length"
                    },
                    right = new IntLiteral () { value = 1 }
                }
            });
            if (et == ValaType.STRING && !en.has_suffix ("?")) {
                rem_m.body.add (new IndexAssignStatement () {
                    target = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "data"
                    },
                    index = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "length"
                    },
                    op = "=",
                    value = new StringLiteral () { value = "" }
                });
            } else if ((et == ValaType.CLASS || et == ValaType.INTERFACE || et == ValaType.ARRAY || et == ValaType.ERROR || et == ValaType.STRING) && en.has_suffix ("?")) {
                rem_m.body.add (new IndexAssignStatement () {
                    target = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "data"
                    },
                    index = new MemberAccessExpr () {
                        target = new VarRef () { name = "this" },
                        member = "length"
                    },
                    op = "=",
                    value = new NullLiteral ()
                });
            }
            cd.methods.add (rem_m);
            classes.add (cd);
        }

        public void monomorphize_all () {
            for (int ii = 0; ii < instantiations.length; ii++) {
                var inst = instantiations[ii];
                if (inst.has_type_param)
                    continue;
                if (inst.template_name == "GenericArray") {
                    if (inst.arg_types.length == 1)
                        synthesize_generic_array (inst);
                    continue;
                }
                if (inst.template_name == "Channel") {
                    if (inst.arg_types.length == 1)
                        synthesize_channel (inst);
                    continue;
                }
                if (inst.is_struct) {
                    unowned var tmpl_sd = find_struct (inst.template_name);
                    if (tmpl_sd == null || tmpl_sd.type_params.length != inst.arg_types.length)
                        continue;
                    if (find_struct (inst.mangled_name) != null)
                        continue;
                    var nsd = new StructDecl () {
                        name = inst.mangled_name,
                        is_defined = tmpl_sd.is_defined,
                        line = tmpl_sd.line,
                        column = tmpl_sd.column
                    };
                    foreach (var fld in tmpl_sd.fields) {
                        var ft = fld.field_type;
                        var fn = fld.type_name;
                        substitute_type (ref ft, ref fn, tmpl_sd.type_params, inst.arg_types, inst.arg_type_names);
                        nsd.fields.add (new StructField () {
                            field_type = ft,
                            type_name = fn,
                            name = fld.name,
                            line = fld.line,
                            column = fld.column
                        });
                    }
                    foreach (var m in tmpl_sd.methods)
                        nsd.methods.add (clone_function (m, inst.mangled_name, tmpl_sd.type_params, inst.arg_types, inst.arg_type_names));
                    structs.add (nsd);
                } else {
                    unowned var tmpl_cd = find_class (inst.template_name);
                    if (tmpl_cd == null || tmpl_cd.type_params.length != inst.arg_types.length)
                        continue;
                    if (find_class (inst.mangled_name) != null)
                        continue;
                    var ncd = new ClassDecl () {
                        name = inst.mangled_name,
                        base_name = tmpl_cd.base_name,
                        is_abstract = tmpl_cd.is_abstract,
                        is_defined = tmpl_cd.is_defined,
                        line = tmpl_cd.line,
                        column = tmpl_cd.column
                    };
                    foreach (var iname in tmpl_cd.iface_names)
                        ncd.iface_names.add (iname);
                    foreach (var fld in tmpl_cd.fields) {
                        var ft = fld.field_type;
                        var fn = fld.type_name;
                        substitute_type (ref ft, ref fn, tmpl_cd.type_params, inst.arg_types, inst.arg_type_names);
                        ncd.fields.add (new ClassField () {
                            field_type = ft,
                            type_name = fn,
                            name = fld.name,
                            is_weak = fld.is_weak,
                            init = (fld.init != null) ? clone_expr (fld.init, tmpl_cd.type_params, inst.arg_types, inst.arg_type_names) : null,
                            line = fld.line,
                            column = fld.column
                        });
                    }
                    foreach (var m in tmpl_cd.methods)
                        ncd.methods.add (clone_function (m, inst.mangled_name, tmpl_cd.type_params, inst.arg_types, inst.arg_type_names));
                    if (tmpl_cd.ctor != null)
                        ncd.ctor = clone_function (tmpl_cd.ctor, inst.mangled_name, tmpl_cd.type_params, inst.arg_types, inst.arg_type_names);
                    foreach (var nc in tmpl_cd.named_ctors)
                        ncd.named_ctors.add (clone_function (nc, inst.mangled_name, tmpl_cd.type_params, inst.arg_types, inst.arg_type_names));
                    if (tmpl_cd.dtor != null)
                        ncd.dtor = clone_function (tmpl_cd.dtor, inst.mangled_name, tmpl_cd.type_params, inst.arg_types, inst.arg_type_names);
                    classes.add (ncd);
                }
            }
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

    // Pure-integer IEEE-754 decimal-to-binary32/binary64 converter so float
    // literal bit patterns are deterministic across stage 0 and self-hosted stages.
    public class Ieee754 : Object {
        private const int64 LIMB_BASE = 268435456; // 2^28
        private const int LIMB_BITS = 28;

        private static int trim_len (int64[] a, int len) {
            while (len > 1 && a[len - 1] == 0)
                len--;
            return len;
        }

        private static int cmp_limbs (int64[] a, int alen, int64[] b, int blen) {
            alen = trim_len (a, alen);
            blen = trim_len (b, blen);
            if (alen != blen)
                return (alen > blen) ? 1 : -1;
            for (int i = alen - 1; i >= 0; i--) {
                if (a[i] != b[i])
                    return (a[i] > b[i]) ? 1 : -1;
            }
            return 0;
        }

        private static int bit_len (int64[] a, int len) {
            len = trim_len (a, len);
            int64 top = a[len - 1];
            if (top == 0)
                return 0;
            int b = (len - 1) * LIMB_BITS;
            while (top > 0) {
                b++;
                top >>= 1;
            }
            return b;
        }

        private static void ensure_cap (ref int64[] a, int need) {
            if (a.length >= need)
                return;
            var nc = a.length * 2;
            while (nc < need)
                nc *= 2;
            var na = new int64[nc];
            for (int i = 0; i < a.length; i++)
                na[i] = a[i];
            a = na;
        }

        private static void mul_add_small (ref int64[] a, ref int len, int64 mul, int64 add) {
            int64 carry = add;
            for (int i = 0; i < len; i++) {
                int64 v = a[i] * mul + carry;
                a[i] = v % LIMB_BASE;
                carry = v / LIMB_BASE;
            }
            while (carry > 0) {
                ensure_cap (ref a, len + 1);
                a[len++] = carry % LIMB_BASE;
                carry /= LIMB_BASE;
            }
        }

        private static void shl_limbs (ref int64[] a, ref int len, int bits) {
            if (bits <= 0)
                return;
            int word_shift = bits / LIMB_BITS;
            int bit_shift = bits % LIMB_BITS;
            int new_len = len + word_shift + 1;
            ensure_cap (ref a, new_len);
            if (word_shift > 0) {
                for (int i = len - 1; i >= 0; i--)
                    a[i + word_shift] = a[i];
                for (int i = 0; i < word_shift; i++)
                    a[i] = 0;
                len += word_shift;
            }
            if (bit_shift > 0) {
                int64 carry = 0;
                int64 mask = LIMB_BASE - 1;
                int rshift = LIMB_BITS - bit_shift;
                for (int i = word_shift; i < len; i++) {
                    int64 cur = a[i];
                    a[i] = ((cur << bit_shift) & mask) | carry;
                    carry = cur >> rshift;
                }
                if (carry > 0) {
                    ensure_cap (ref a, len + 1);
                    a[len++] = carry;
                }
            }
            len = trim_len (a, len);
        }

        private static void sub_limbs (int64[] a, ref int alen, int64[] b, int blen) {
            int64 borrow = 0;
            for (int i = 0; i < alen; i++) {
                int64 bv = (i < blen) ? b[i] : 0;
                int64 diff = a[i] - bv - borrow;
                if (diff < 0) {
                    diff += LIMB_BASE;
                    borrow = 1;
                } else {
                    borrow = 0;
                }
                a[i] = diff;
            }
            alen = trim_len (a, alen);
        }

        private static int64[] clone_limbs (int64[] a, int len, out int out_len) {
            var r = new int64[len + 4];
            for (int i = 0; i < len; i++)
                r[i] = a[i];
            out_len = len;
            return r;
        }

        private static void mul_pow10 (ref int64[] a, ref int len, int exp) {
            while (exp >= 8) {
                mul_add_small (ref a, ref len, 100000000, 0);
                exp -= 8;
            }
            int64 p = 1;
            while (exp > 0) {
                p *= 10;
                exp--;
            }
            if (p > 1)
                mul_add_small (ref a, ref len, p, 0);
        }

        public static uint64 parse_bits (string raw, out bool is_f32) {
            int n = raw.length;
            is_f32 = false;
            if (n > 0 && (raw[n - 1] == 'f' || raw[n - 1] == 'F')) {
                is_f32 = true;
                n--;
            }

            var num = new int64[16];
            int num_len = 1;
            int exp10 = 0;
            bool seen_dot = false;
            int sig_digits = 0;
            int i = 0;
            while (i < n && raw[i] != 'e' && raw[i] != 'E') {
                uint8 ch = raw[i];
                if (ch == '.') {
                    seen_dot = true;
                } else if (ch >= '0' && ch <= '9') {
                    int d = (int) (ch - '0');
                    if (sig_digits > 0 || d != 0) {
                        if (sig_digits < 38) {
                            mul_add_small (ref num, ref num_len, 10, d);
                            sig_digits++;
                            if (seen_dot)
                                exp10--;
                        } else if (!seen_dot) {
                            exp10++;
                        }
                    } else if (seen_dot) {
                        exp10--;
                    }
                }
                i++;
            }
            if (i < n && (raw[i] == 'e' || raw[i] == 'E')) {
                i++;
                bool neg_e = false;
                if (i < n && (raw[i] == '+' || raw[i] == '-')) {
                    neg_e = (raw[i] == '-');
                    i++;
                }
                int ev = 0;
                while (i < n) {
                    uint8 ch = raw[i];
                    if (ch >= '0' && ch <= '9') {
                        if (ev < 100000)
                            ev = ev * 10 + (int) (ch - '0');
                    }
                    i++;
                }
                exp10 += neg_e ? -ev : ev;
            }

            if (sig_digits == 0)
                return 0;

            int p = is_f32 ? 24 : 53;
            int bias = is_f32 ? 127 : 1023;
            int min_exp = is_f32 ? -126 : -1022;
            int max_exp = is_f32 ? 127 : 1023;
            uint64 inf_bits = is_f32 ? (uint64) 0x7F800000 : (uint64) 0x7FF0000000000000;

            int total_exp10 = exp10 + sig_digits;
            if (total_exp10 > (is_f32 ? 42 : 315))
                return inf_bits;
            if (total_exp10 < (is_f32 ? -50 : -330))
                return 0;

            var den = new int64[16];
            den[0] = 1;
            int den_len = 1;
            if (exp10 > 0)
                mul_pow10 (ref num, ref num_len, exp10);
            else if (exp10 < 0)
                mul_pow10 (ref den, ref den_len, -exp10);

            int exp2 = bit_len (num, num_len) - bit_len (den, den_len);
            if (exp2 < min_exp)
                exp2 = min_exp;
            if (exp2 > max_exp + 1)
                return inf_bits;

            int shift = (p - 1) - exp2;
            if (shift > 0)
                shl_limbs (ref num, ref num_len, shift);
            else if (shift < 0)
                shl_limbs (ref den, ref den_len, -shift);

            // Adjust exp2 by at most 1 so 2^(p-1) <= num/den < 2^p (when not subnormal).
            int top_cmp_len = 0;
            var den_p = clone_limbs (den, den_len, out top_cmp_len);
            shl_limbs (ref den_p, ref top_cmp_len, p);
            while (cmp_limbs (num, num_len, den_p, top_cmp_len) >= 0) {
                shl_limbs (ref den, ref den_len, 1);
                shl_limbs (ref den_p, ref top_cmp_len, 1);
                exp2++;
                if (exp2 > max_exp)
                    return inf_bits;
            }
            if (exp2 > min_exp) {
                int lo_len = 0;
                var den_lo = clone_limbs (den, den_len, out lo_len);
                shl_limbs (ref den_lo, ref lo_len, p - 1);
                while (exp2 > min_exp && cmp_limbs (num, num_len, den_lo, lo_len) < 0) {
                    shl_limbs (ref num, ref num_len, 1);
                    exp2--;
                }
            }

            // Long division for `p` quotient bits: num / den < 2^p.
            int64 q = 0;
            for (int bit = p - 1; bit >= 0; bit--) {
                int slen = 0;
                var shifted = clone_limbs (den, den_len, out slen);
                shl_limbs (ref shifted, ref slen, bit);
                if (cmp_limbs (num, num_len, shifted, slen) >= 0) {
                    sub_limbs (num, ref num_len, shifted, slen);
                    q |= ((int64) 1 << bit);
                }
            }

            // Round to nearest, ties to even.
            shl_limbs (ref num, ref num_len, 1);
            int rc = cmp_limbs (num, num_len, den, den_len);
            if (rc > 0 || (rc == 0 && (q & 1) != 0))
                q++;
            int64 limit = ((int64) 1 << p);
            if (q >= limit) {
                q >>= 1;
                exp2++;
            }
            if (exp2 > max_exp)
                return inf_bits;

            int64 norm_bit = ((int64) 1 << (p - 1));
            int64 biased_exp = (q < norm_bit) ? 0 : (int64) (exp2 + bias);
            int64 mant = q & (norm_bit - 1);
            return ((uint64) biased_exp << (p - 1)) | (uint64) mant;
        }
    }
}
