// Data models for the c2vala translator.

using Planc;

namespace C2Vala {

    // Builder emitted for a C compound literal `(T){ .a = x }` (see
    // Translator.ensure_lit_helper).
    public class LitHelper : Object {
        public string name;
        public CType ctype;
        public GenericArray<string> fields = new GenericArray<string> ();
        public GenericArray<string> vtypes = new GenericArray<string> ();
    }

    public class ReportEntry : Object {
        public string name;
        public bool ok;
        public string reason;

        public ReportEntry (string name, bool ok, string reason = "") {
            this.name = name;
            this.ok = ok;
            this.reason = reason;
        }
    }

    public class LocalInfo : Object {
        public string name;
        public CType ctype;
        public bool is_array = false;
        public bool is_param = false;
        public bool has_ptr_arith = false;
        public bool has_addr_taken = false;
        public bool is_field_ref = false;
        public bool is_native_ptr = false;

        public LocalInfo (string name, CType ctype, bool is_param = false) {
            this.name = name;
            this.ctype = ctype;
            this.is_param = is_param;
        }
    }

    public class FuncSig : Object {
        public string name;
        public CType ret_type;
        public bool ret_is_array = false;
        public bool is_extern = false;
        public bool is_varargs = false;
        public GenericArray<CType> param_types = new GenericArray<CType> ();
        public GenericArray<bool> param_is_array = new GenericArray<bool> ();

        public FuncSig (string name, CType ret_type) {
            this.name = name;
            this.ret_type = ret_type;
        }
    }

    public class GotoPlan : Object {
        public string label;
        public string flag_name;
        public bool is_general = false;
        public int target_idx = -1;
        public StmtIf? hoisted_if = null;
        public StmtBlock? hoisted_block = null;
        public int hoisted_label_idx = 0;
        public CStmt? loop_continue_stmt = null;
        public StmtSwitch? switch_case_sw = null;
        public int switch_case_idx = -1;
        public StmtBlock? nested_target_block = null;
        public int nested_label_idx = 0;
        public int top_stmt_idx = -1;

        public GotoPlan (string label, string flag_name, bool is_general = false, int target_idx = -1) {
            this.label = label;
            this.flag_name = flag_name;
            this.is_general = is_general;
            this.target_idx = target_idx;
        }
    }
}
