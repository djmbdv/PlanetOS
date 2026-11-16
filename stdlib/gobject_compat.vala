// Pure-Vala GObject compatibility layer for PlanetOS (zero C, zero .vapi).
//
// The language already gives classes, static signals, properties and ARC
// reference counting; what source code written for GObject still expects is
// the type system (GType ids) and the tagged GValue container. This layer
// implements those two pieces in Vala.

using Planet;

namespace GObject {

    public class Type : Object {
        public const int INVALID = 0;
        public const int NONE = 4;
        public const int INTERFACE = 8;
        public const int CHAR = 12;
        public const int UCHAR = 16;
        public const int BOOLEAN = 20;
        public const int INT = 24;
        public const int UINT = 28;
        public const int LONG = 32;
        public const int ULONG = 36;
        public const int INT64 = 40;
        public const int UINT64 = 44;
        public const int ENUM = 48;
        public const int FLAGS = 52;
        public const int FLOAT = 56;
        public const int DOUBLE = 60;
        public const int STRING = 64;
        public const int POINTER = 68;
        public const int BOXED = 72;
        public const int PARAM = 76;
        public const int OBJECT = 80;
        public const int VARIANT = 84;

        // Registered types start here; the id is stable for the process.
        public const int FIRST_REGISTERED = 100;
    }

    private GenericArray<string> registered_names;

    private void ensure_registry () {
        if (registered_names == null)
            registered_names = new GenericArray<string> ();
    }

    public string type_name (int gtype) {
        if (gtype == Type.INVALID)
            return "invalid";
        if (gtype == Type.NONE)
            return "void";
        if (gtype == Type.INTERFACE)
            return "gpointer";
        if (gtype == Type.CHAR)
            return "gchar";
        if (gtype == Type.UCHAR)
            return "guchar";
        if (gtype == Type.BOOLEAN)
            return "gboolean";
        if (gtype == Type.INT)
            return "gint";
        if (gtype == Type.UINT)
            return "guint";
        if (gtype == Type.LONG)
            return "glong";
        if (gtype == Type.ULONG)
            return "gulong";
        if (gtype == Type.INT64)
            return "gint64";
        if (gtype == Type.UINT64)
            return "guint64";
        if (gtype == Type.ENUM)
            return "GEnum";
        if (gtype == Type.FLAGS)
            return "GFlags";
        if (gtype == Type.FLOAT)
            return "gfloat";
        if (gtype == Type.DOUBLE)
            return "gdouble";
        if (gtype == Type.STRING)
            return "gchararray";
        if (gtype == Type.POINTER)
            return "gpointer";
        if (gtype == Type.BOXED)
            return "GBoxed";
        if (gtype == Type.PARAM)
            return "GParam";
        if (gtype == Type.OBJECT)
            return "GObject";
        if (gtype == Type.VARIANT)
            return "GVariant";
        if (gtype >= Type.FIRST_REGISTERED) {
            ensure_registry ();
            int index = gtype - Type.FIRST_REGISTERED;
            if (index >= 0 && index < registered_names.length)
                return registered_names[index];
        }
        return "unknown";
    }

    // Registers a user type name and returns its stable id. Registering the
    // same name twice returns the same id.
    public int type_register (string name) {
        if (name.length == 0)
            return Type.INVALID;
        ensure_registry ();
        for (int i = 0; i < registered_names.length; i++) {
            if (registered_names[i] == name)
                return Type.FIRST_REGISTERED + i;
        }
        registered_names.add (name);
        return Type.FIRST_REGISTERED + registered_names.length - 1;
    }

    public int type_registered_count () {
        ensure_registry ();
        return registered_names.length;
    }

    // Tagged value container. Setters check the tag and return false instead
    // of silently storing a value of the wrong type.
    public class Value : Object {
        private int value_type = Type.INVALID;
        private int64 ival = 0;
        private double dval = 0.0;
        private bool bval = false;
        private string? sval = null;

        public Value (int gtype) {
            value_type = gtype;
        }

        public int get_value_type () {
            return value_type;
        }

        public void unset () {
            value_type = Type.INVALID;
            sval = null;
        }

        public bool set_int (int v) {
            if (value_type != Type.INT)
                return false;
            ival = v;
            return true;
        }

        public int get_int () {
            return (value_type == Type.INT) ? (int) ival : 0;
        }

        public bool set_uint (uint32 v) {
            if (value_type != Type.UINT)
                return false;
            ival = (int64) v;
            return true;
        }

        public uint32 get_uint () {
            return (value_type == Type.UINT) ? (uint32) ival : 0;
        }

        public bool set_int64 (int64 v) {
            if (value_type != Type.INT64)
                return false;
            ival = v;
            return true;
        }

        public int64 get_int64 () {
            return (value_type == Type.INT64) ? ival : 0;
        }

        public bool set_boolean (bool v) {
            if (value_type != Type.BOOLEAN)
                return false;
            bval = v;
            return true;
        }

        public bool get_boolean () {
            return (value_type == Type.BOOLEAN) ? bval : false;
        }

        public bool set_double (double v) {
            if (value_type != Type.DOUBLE)
                return false;
            dval = v;
            return true;
        }

        public double get_double () {
            return (value_type == Type.DOUBLE) ? dval : 0.0;
        }

        public bool set_string (string v) {
            if (value_type != Type.STRING)
                return false;
            sval = v;
            return true;
        }

        public string? get_string () {
            return (value_type == Type.STRING) ? sval : null;
        }
    }
}
