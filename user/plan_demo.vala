// PlanetOS native .plan executable loading and calling mathlib.dlib dynamically.
using Planet;
using GModule;

namespace PlanDemo {

    private int checks = 0;
    private int failures = 0;

    private void check (string name, bool ok) {
        checks = checks + 1;
        if (ok) {
            print (@"plan:check $name ok\n");
        } else {
            failures = failures + 1;
            print (@"plan:check $name FAIL\n");
        }
    }

    int main (string[] args) {
        print ("plan:demo running native .plan executable\n");
        try {
            var h = Module.open ("mathlib.dlib");
            check ("dlib-open", !h.is_static ());
            check ("has-dlib_add", h.has_symbol ("dlib_add"));
            check ("has-dlib_mul", h.has_symbol ("dlib_mul"));

            int fn_add = h.get_symbol ("dlib_add");
            int fn_mul = h.get_symbol ("dlib_mul");
            int fn_mix = h.get_symbol ("dlib_mix");

            int sum = Sys.call_ptr2 (fn_add, 19, 23);
            int prod = Sys.call_ptr2 (fn_mul, 6, 7);
            int mix = Sys.call_ptr2 (fn_mix, 4, 5);

            print (@"plan:dlib results add=$sum mul=$prod mix=$mix\n");
            check ("call-dlib_add", sum == 42);
            check ("call-dlib_mul", prod == 42);
            check ("call-dlib_mix", mix == 22);
        } catch (ModuleError e) {
            print (@"plan:error $(e.message)\n");
            check ("dlib-open", false);
        }
        print (@"plan:summary checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
    }
}
