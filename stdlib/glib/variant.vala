// Pure-Vala GLib.VariantType and GLib.Variant (immutable, typed value containers).
using Planet;

namespace GLib {

    public enum VariantClass {
        BOOLEAN = 'b',
        BYTE = 'y',
        INT16 = 'n',
        UINT16 = 'q',
        INT32 = 'i',
        UINT32 = 'u',
        INT64 = 'x',
        UINT64 = 't',
        HANDLE = 'h',
        DOUBLE = 'd',
        STRING = 's',
        OBJECT_PATH = 'o',
        SIGNATURE = 'g',
        VARIANT = 'v',
        MAYBE = 'm',
        ARRAY = 'a',
        TUPLE = '(',
        DICT_ENTRY = '{'
    }

    public class VariantType : Object {
        private string tstr;

        public VariantType (string type_string) {
            if (type_string.length == 0)
                tstr = "*";
            else
                tstr = type_string.substring (0);
        }

        public static VariantType ANY () { return new VariantType ("*"); }
        public static VariantType BOOLEAN () { return new VariantType ("b"); }
        public static VariantType BYTE () { return new VariantType ("y"); }
        public static VariantType INT16 () { return new VariantType ("n"); }
        public static VariantType UINT16 () { return new VariantType ("q"); }
        public static VariantType INT32 () { return new VariantType ("i"); }
        public static VariantType UINT32 () { return new VariantType ("u"); }
        public static VariantType INT64 () { return new VariantType ("x"); }
        public static VariantType UINT64 () { return new VariantType ("t"); }
        public static VariantType DOUBLE () { return new VariantType ("d"); }
        public static VariantType STRING () { return new VariantType ("s"); }
        public static VariantType VARIANT () { return new VariantType ("v"); }
        public static VariantType STRING_ARRAY () { return new VariantType ("as"); }
        public static VariantType VARDICT () { return new VariantType ("a{sv}"); }

        public string dup_string () {
            return tstr.substring (0);
        }

        public string peek_string () {
            return tstr;
        }

        public bool is_definite () {
            for (int i = 0; i < tstr.length; i++) {
                uint8 c = (uint8) tstr[i];
                if (c == '*' || c == '?' || c == 'r')
                    return false;
            }
            return true;
        }

        public bool is_basic () {
            if (tstr.length != 1)
                return false;
            uint8 c = (uint8) tstr[0];
            return c == 'b' || c == 'y' || c == 'n' || c == 'q' || c == 'i'
                || c == 'u' || c == 'x' || c == 't' || c == 'h' || c == 'd'
                || c == 's' || c == 'o' || c == 'g';
        }

        public bool is_container () {
            if (tstr.length == 0)
                return false;
            uint8 c = (uint8) tstr[0];
            return c == 'a' || c == 'm' || c == '(' || c == '{' || c == 'v' || c == 'r';
        }

        public bool is_array () {
            return tstr.length > 1 && tstr[0] == 'a';
        }

        public bool is_dict_entry () {
            return tstr.length > 2 && tstr[0] == '{';
        }

        public bool is_tuple () {
            return tstr == "r" || (tstr.length >= 2 && tstr[0] == '(');
        }

        public bool equal (VariantType other) {
            return tstr == other.tstr;
        }

        public bool is_subtype_of (VariantType supertype) {
            string sup = supertype.tstr;
            if (sup == "*" || tstr == sup)
                return true;
            if (sup == "?" && is_basic ())
                return true;
            if (sup == "r" && is_tuple ())
                return true;
            if (sup.has_prefix ("a") && is_array ()) {
                var e_sub = element ();
                var e_sup = supertype.element ();
                return e_sub.is_subtype_of (e_sup);
            }
            return false;
        }

        public VariantType element () {
            if (tstr.length > 1 && (tstr[0] == 'a' || tstr[0] == 'm'))
                return new VariantType (tstr.substring (1));
            return new VariantType ("*");
        }

        public VariantType key () {
            if (tstr.length >= 4 && tstr[0] == '{')
                return new VariantType (tstr.substring (1, 1));
            return new VariantType ("*");
        }

        public VariantType value () {
            if (tstr.length >= 4 && tstr[0] == '{')
                return new VariantType (tstr.substring (2, tstr.length - 3));
            return new VariantType ("*");
        }
    }

    public class Variant : Object {
        private VariantClass vclass;
        private VariantType vtype;
        private bool bool_val = false;
        private int64 int_val = 0;
        private double dbl_val = 0.0;
        private string str_val = "";
        private Variant? inner_val = null;
        private Variant[]? children = null;

        private const int MAX_PRINT_DEPTH = 64;

        private Variant (VariantClass cls, string tstr) {
            vclass = cls;
            vtype = new VariantType (tstr);
        }

        public static Variant new_boolean (bool value) {
            var v = new Variant (VariantClass.BOOLEAN, "b");
            v.bool_val = value;
            return v;
        }

        public static Variant new_byte (uint8 value) {
            var v = new Variant (VariantClass.BYTE, "y");
            v.int_val = (int64) value;
            return v;
        }

        public static Variant new_int16 (int16 value) {
            var v = new Variant (VariantClass.INT16, "n");
            v.int_val = (int64) value;
            return v;
        }

        public static Variant new_uint16 (uint16 value) {
            var v = new Variant (VariantClass.UINT16, "q");
            v.int_val = (int64) value;
            return v;
        }

        public static Variant new_int32 (int32 value) {
            var v = new Variant (VariantClass.INT32, "i");
            v.int_val = (int64) value;
            return v;
        }

        public static Variant new_uint32 (uint32 value) {
            var v = new Variant (VariantClass.UINT32, "u");
            v.int_val = (int64) value;
            return v;
        }

        public static Variant new_int64 (int64 value) {
            var v = new Variant (VariantClass.INT64, "x");
            v.int_val = value;
            return v;
        }

        public static Variant new_uint64 (uint64 value) {
            var v = new Variant (VariantClass.UINT64, "t");
            v.int_val = (int64) value;
            return v;
        }

        public static Variant new_double (double value) {
            var v = new Variant (VariantClass.DOUBLE, "d");
            v.dbl_val = value;
            return v;
        }

        public static Variant new_string (string value) {
            var v = new Variant (VariantClass.STRING, "s");
            v.str_val = value.substring (0);
            return v;
        }

        public static Variant new_variant (Variant value) {
            var v = new Variant (VariantClass.VARIANT, "v");
            v.inner_val = value;
            return v;
        }

        public static Variant new_strv (string[] strv) {
            var v = new Variant (VariantClass.ARRAY, "as");
            v.children = new Variant[strv.length];
            for (int i = 0; i < strv.length; i++)
                v.children[i] = Variant.new_string (strv[i]);
            return v;
        }

        public static Variant new_tuple (Variant[] items) {
            var sb = new StringBuilder ("(");
            var ch = new Variant[items.length];
            for (int i = 0; i < items.length; i++) {
                ch[i] = items[i];
                sb.append (items[i].get_type_string ());
            }
            sb.append_c (')');
            var v = new Variant (VariantClass.TUPLE, sb.str);
            v.children = ch;
            return v;
        }

        public static Variant new_array (VariantType? child_type, Variant[] items) {
            string elem_t = "*";
            if (child_type != null)
                elem_t = child_type.peek_string ();
            else if (items.length > 0)
                elem_t = items[0].get_type_string ();
            var v = new Variant (VariantClass.ARRAY, "a" + elem_t);
            v.children = new Variant[items.length];
            for (int i = 0; i < items.length; i++)
                v.children[i] = items[i];
            return v;
        }

        public static Variant new_dict_entry (Variant key, Variant val) {
            var v = new Variant (VariantClass.DICT_ENTRY, "{" + key.get_type_string () + val.get_type_string () + "}");
            v.children = new Variant[2];
            v.children[0] = key;
            v.children[1] = val;
            return v;
        }

        public VariantType get_type () {
            return vtype;
        }

        public string get_type_string () {
            return vtype.peek_string ();
        }

        public bool is_of_type (VariantType type) {
            return vtype.is_subtype_of (type);
        }

        public bool is_container () {
            return vtype.is_container ();
        }

        public VariantClass classify () {
            return vclass;
        }

        public bool get_boolean () {
            return bool_val;
        }

        public uint8 get_byte () {
            return (uint8) int_val;
        }

        public int16 get_int16 () {
            return (int16) int_val;
        }

        public uint16 get_uint16 () {
            return (uint16) int_val;
        }

        public int32 get_int32 () {
            return (int32) int_val;
        }

        public uint32 get_uint32 () {
            return (uint32) int_val;
        }

        public int64 get_int64 () {
            return int_val;
        }

        public uint64 get_uint64 () {
            return (uint64) int_val;
        }

        public double get_double () {
            return dbl_val;
        }

        public string get_string () {
            return str_val;
        }

        public string dup_string () {
            return str_val.substring (0);
        }

        public Variant? get_variant () {
            return inner_val;
        }

        public string[] get_strv () {
            if (children == null)
                return new string[0];
            var res = new string[children.length];
            for (int i = 0; i < children.length; i++)
                res[i] = children[i].get_string ();
            return res;
        }

        public int n_children () {
            if (vclass == VariantClass.VARIANT)
                return (inner_val != null) ? 1 : 0;
            if (children == null)
                return 0;
            return children.length;
        }

        public Variant? get_child_value (int index) {
            if (vclass == VariantClass.VARIANT)
                return (index == 0) ? inner_val : null;
            if (children == null || index < 0 || index >= children.length)
                return null;
            return children[index];
        }

        public Variant? lookup_value (string key, VariantType? expected_type = null) {
            if (children == null)
                return null;
            for (int i = 0; i < children.length; i++) {
                var entry = children[i];
                if (entry.classify () == VariantClass.DICT_ENTRY && entry.n_children () == 2) {
                    var k = entry.get_child_value (0);
                    var v = entry.get_child_value (1);
                    if (k != null && k.classify () == VariantClass.STRING && k.get_string () == key && v != null) {
                        Variant? target = (v.classify () == VariantClass.VARIANT) ? v.get_variant () : v;
                        if (target == null)
                            return null;
                        if (expected_type != null && !target.is_of_type (expected_type))
                            return null;
                        return target;
                    }
                }
            }
            return null;
        }

        public bool equal (Variant other) {
            if (vclass != other.vclass || !vtype.equal (other.vtype))
                return false;
            switch (vclass) {
                case VariantClass.BOOLEAN:
                    return bool_val == other.bool_val;
                case VariantClass.BYTE:
                case VariantClass.INT16:
                case VariantClass.UINT16:
                case VariantClass.INT32:
                case VariantClass.UINT32:
                case VariantClass.INT64:
                case VariantClass.UINT64:
                    return int_val == other.int_val;
                case VariantClass.DOUBLE:
                    return dbl_val == other.dbl_val;
                case VariantClass.STRING:
                    return str_val == other.str_val;
                case VariantClass.VARIANT:
                    if (inner_val == null || other.inner_val == null)
                        return inner_val == null && other.inner_val == null;
                    return inner_val.equal (other.inner_val);
                default:
                    int n = n_children ();
                    if (n != other.n_children ())
                        return false;
                    for (int i = 0; i < n; i++) {
                        var c1 = get_child_value (i);
                        var c2 = other.get_child_value (i);
                        if (c1 == null || c2 == null || !c1.equal (c2))
                            return false;
                    }
                    return true;
            }
        }

        public int compare (Variant other) {
            if (vclass != other.vclass)
                return (int) vclass - (int) other.vclass;
            switch (vclass) {
                case VariantClass.BOOLEAN:
                    if (bool_val == other.bool_val) return 0;
                    return bool_val ? 1 : -1;
                case VariantClass.BYTE:
                case VariantClass.INT16:
                case VariantClass.UINT16:
                case VariantClass.INT32:
                case VariantClass.UINT32:
                case VariantClass.INT64:
                case VariantClass.UINT64:
                    if (int_val < other.int_val) return -1;
                    if (int_val > other.int_val) return 1;
                    return 0;
                case VariantClass.DOUBLE:
                    if (dbl_val < other.dbl_val) return -1;
                    if (dbl_val > other.dbl_val) return 1;
                    return 0;
                case VariantClass.STRING:
                    if (str_val == other.str_val) return 0;
                    int la = str_val.length;
                    int lb = other.str_val.length;
                    int n = (la < lb) ? la : lb;
                    for (int i = 0; i < n; i++) {
                        int ca = (int) str_val[i];
                        int cb = (int) other.str_val[i];
                        if (ca != cb)
                            return ca - cb;
                    }
                    return la - lb;
                default:
                    return equal (other) ? 0 : -1;
            }
        }

        public int hash () {
            switch (vclass) {
                case VariantClass.BOOLEAN:
                    return bool_val ? 1 : 0;
                case VariantClass.STRING:
                    return __planc_hash (str_val);
                default:
                    return __planc_hash (int_val);
            }
        }

        private void print_into (StringBuilder sb, bool type_annotate, int depth) {
            if (depth > MAX_PRINT_DEPTH) {
                sb.append ("...");
                return;
            }
            switch (vclass) {
                case VariantClass.BOOLEAN:
                    sb.append (bool_val ? "true" : "false");
                    break;
                case VariantClass.BYTE:
                case VariantClass.INT16:
                case VariantClass.UINT16:
                case VariantClass.INT32:
                case VariantClass.UINT32:
                case VariantClass.INT64:
                case VariantClass.UINT64:
                    if (type_annotate)
                        sb.append (@"$(get_type_string ()) ");
                    sb.append (@"$int_val");
                    break;
                case VariantClass.DOUBLE:
                    sb.append (@"$dbl_val");
                    break;
                case VariantClass.STRING:
                    sb.append_c ('\'');
                    sb.append (str_val);
                    sb.append_c ('\'');
                    break;
                case VariantClass.VARIANT:
                    sb.append ("<");
                    if (inner_val != null)
                        inner_val.print_into (sb, type_annotate, depth + 1);
                    sb.append (">");
                    break;
                case VariantClass.TUPLE:
                    sb.append_c ('(');
                    int tn = n_children ();
                    for (int i = 0; i < tn; i++) {
                        if (i > 0) sb.append (", ");
                        var ch = get_child_value (i);
                        if (ch != null) ch.print_into (sb, type_annotate, depth + 1);
                    }
                    if (tn == 1) sb.append_c (',');
                    sb.append_c (')');
                    break;
                case VariantClass.DICT_ENTRY:
                    sb.append_c ('{');
                    var dk = get_child_value (0);
                    var dv = get_child_value (1);
                    if (dk != null) dk.print_into (sb, false, depth + 1);
                    sb.append (": ");
                    if (dv != null) dv.print_into (sb, type_annotate, depth + 1);
                    sb.append_c ('}');
                    break;
                case VariantClass.ARRAY:
                    sb.append_c ('[');
                    int an = n_children ();
                    for (int i = 0; i < an; i++) {
                        if (i > 0) sb.append (", ");
                        var ch = get_child_value (i);
                        if (ch != null) ch.print_into (sb, type_annotate, depth + 1);
                    }
                    sb.append_c (']');
                    break;
                default:
                    sb.append ("<variant>");
                    break;
            }
        }

        public string print (bool type_annotate = false) {
            var sb = new StringBuilder ();
            print_into (sb, type_annotate, 0);
            return sb.str;
        }
    }

    /**
     * Builds arrays and tuples without hand-constructing the child array.
     */
    public class VariantBuilder : Object {
        private VariantType type;
        private GenericArray<Variant> values = new GenericArray<Variant> ();

        public VariantBuilder (VariantType type) {
            this.type = type;
        }

        public void add_value (Variant value) {
            values.add (value);
        }

        public Variant end () {
            if (type.is_tuple ()) {
                var items = new Variant[values.length];
                for (int i = 0; i < values.length; i++)
                    items[i] = values[i];
                return Variant.new_tuple (items);
            }
            if (type.is_array ()) {
                var items = new Variant[values.length];
                for (int i = 0; i < values.length; i++)
                    items[i] = values[i];
                return Variant.new_array (type.element (), items);
            }
            if (values.length == 1)
                return values[0];
            var items = new Variant[values.length];
            for (int i = 0; i < values.length; i++)
                items[i] = values[i];
            return Variant.new_array (null, items);
        }
    }

    /**
     * Mutable view over an `a{sv}` dictionary.
     */
    public class VariantDict : Object {
        private GenericArray<Variant> entries = new GenericArray<Variant> ();

        public VariantDict (Variant? from = null) {
            if (from == null)
                return;
            int n = from.n_children ();
            for (int i = 0; i < n; i++) {
                var child = from.get_child_value (i);
                if (child != null && child.classify () == VariantClass.DICT_ENTRY)
                    entries.add (child);
            }
        }

        public static VariantDict new_from (Variant? from) {
            return new VariantDict (from);
        }

        private int find (string key) {
            for (int i = 0; i < entries.length; i++) {
                var k = entries[i].get_child_value (0);
                if (k != null && k.get_string () == key)
                    return i;
            }
            return -1;
        }

        public bool contains (string key) {
            return find (key) >= 0;
        }

        public void insert_value (string key, Variant value) {
            remove (key);
            entries.add (Variant.new_dict_entry (Variant.new_string (key), Variant.new_variant (value)));
        }

        public Variant? lookup_value (string key, VariantType? expected_type = null) {
            int i = find (key);
            if (i < 0)
                return null;
            var v = entries[i].get_child_value (1);
            if (v == null)
                return null;
            Variant? target = (v.classify () == VariantClass.VARIANT) ? v.get_variant () : v;
            if (target == null)
                return null;
            if (expected_type != null && !target.is_of_type (expected_type))
                return null;
            return target;
        }

        public bool remove (string key) {
            int i = find (key);
            if (i < 0)
                return false;
            entries.remove_index (i);
            return true;
        }

        public void clear () {
            entries = new GenericArray<Variant> ();
        }

        public Variant end () {
            var items = new Variant[entries.length];
            for (int i = 0; i < entries.length; i++)
                items[i] = entries[i];
            return Variant.new_array (VariantType.VARDICT (), items);
        }
    }

    /**
     * Iterates the children of a container variant.
     */
    public class VariantIter : Object {
        private Variant value;
        private int cursor = 0;

        public VariantIter (Variant value) {
            this.value = value;
        }

        public Variant? next_value () {
            if (cursor >= value.n_children ())
                return null;
            var child = value.get_child_value (cursor);
            cursor = cursor + 1;
            return child;
        }

        public int n_remaining () {
            int left = value.n_children () - cursor;
            return (left < 0) ? 0 : left;
        }
    }
}
