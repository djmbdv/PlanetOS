// user/gobject_demo.vala -- exercises the pure-Vala GObject layer on PlanetOS.
//
// Run from the PlanetOS shell:  gobject_demo
// Prints one deterministic line per check and a summary line.

using GObject;

namespace GObjectDemo {
    private int checks = 0;
    private int failures = 0;

    private void check (string what, bool ok) {
        checks = checks + 1;
        if (ok) {
            print (@"gobject:check $what ok\n");
        } else {
            failures = failures + 1;
            print (@"gobject:check $what FAIL\n");
        }
    }

    int main (string[] args) {
        check ("type-int", Type.INT == 24);
        check ("type-string", Type.STRING == 64);
        check ("type-name", type_name (Type.STRING) == "gchararray");
        check ("type-name-double", type_name (Type.DOUBLE) == "gdouble");
        check ("type-unknown", type_name (9999) == "unknown");

        var v = new Value (Type.INT);
        check ("value-init", v.get_value_type () == Type.INT);
        check ("value-set-int", v.set_int (42));
        check ("value-get-int", v.get_int () == 42);
        check ("value-wrong-type", !v.set_string ("nope"));

        var u = new Value (Type.UINT);
        u.set_uint ((uint32) 4000000000);
        check ("value-uint", u.get_uint () == (uint32) 4000000000);

        var l = new Value (Type.INT64);
        l.set_int64 (9000000000);
        check ("value-int64", l.get_int64 () == 9000000000);

        var d = new Value (Type.DOUBLE);
        d.set_double (2.5);
        check ("value-double", d.get_double () == 2.5);

        var b = new Value (Type.BOOLEAN);
        b.set_boolean (true);
        check ("value-boolean", b.get_boolean ());

        var s = new Value (Type.STRING);
        check ("value-set-string", s.set_string ("planet"));
        string? got = s.get_string ();
        if (got == null) {
            check ("value-get-string", false);
        } else {
            check ("value-get-string", got == "planet");
        }

        int t1 = type_register ("PlanetThing");
        int t2 = type_register ("PlanetThing");
        check ("type-register-stable", t1 == t2 && t1 >= Type.FIRST_REGISTERED);
        check ("type-register-name", type_name (t1) == "PlanetThing");
        check ("type-register-count", type_registered_count () >= 1);

        v.unset ();
        check ("value-unset", v.get_value_type () == Type.INVALID);

        print (@"gobject:summary checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
    }
}
