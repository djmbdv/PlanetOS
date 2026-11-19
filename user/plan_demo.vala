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
            int fn_gcd = h.get_symbol ("dlib_gcd");
            int fn_sqrt = h.get_symbol ("dlib_sqrt");
            int fn_pow = h.get_symbol ("dlib_pow");
            int fn_cos = h.get_symbol ("dlib_cos");
            int fn_floor = h.get_symbol ("dlib_floor");
            int fn_ceil = h.get_symbol ("dlib_ceil");
            int fn_vadd = h.get_symbol ("dlib_vec4_add");
            int fn_vmul = h.get_symbol ("dlib_vec4_mul");
            int fn_vdot = h.get_symbol ("dlib_vec4_dot");

            int sum = Sys.call_ptr2 (fn_add, 19, 23);
            int prod = Sys.call_ptr2 (fn_mul, 6, 7);
            int mix = Sys.call_ptr2 (fn_mix, 4, 5);
            int gcd = Sys.call_ptr2 (fn_gcd, 84, 36);
            double sq = Sys.call_ptr_d1 (fn_sqrt, 144.0);
            double pw = Sys.call_ptr_d2 (fn_pow, 2.0, 10.0);
            double cs = Sys.call_ptr_d1 (fn_cos, 0.0);
            double fl = Sys.call_ptr_d1 (fn_floor, 3.9);
            double cl = Sys.call_ptr_d1 (fn_ceil, 3.1);

            var va = new double[4];
            var vb = new double[4];
            var vc = new double[4];
            var vm = new double[4];
            va[0] = 1.0; va[1] = 2.0; va[2] = 3.0; va[3] = 4.0;
            vb[0] = 5.0; vb[1] = 6.0; vb[2] = 7.0; vb[3] = 8.0;
            Sys.call_ptr3 (fn_vadd, Sys.double_arr_addr (vc), Sys.double_arr_addr (va), Sys.double_arr_addr (vb));
            Sys.call_ptr3 (fn_vmul, Sys.double_arr_addr (vm), Sys.double_arr_addr (va), Sys.double_arr_addr (vb));
            double dot = Sys.call_ptr_i2d (fn_vdot, Sys.double_arr_addr (va), Sys.double_arr_addr (vb));

            print (@"plan:dlib x86-64-v3 add=$sum mul=$prod mix=$mix gcd=$gcd\n");
            check ("call-dlib_add", sum == 42);
            check ("call-dlib_mul", prod == 42);
            check ("call-dlib_mix", mix == 22);
            check ("call-dlib_gcd", gcd == 12);
            check ("simd-sqrt", sq > 11.999 && sq < 12.001);
            check ("math-pow", pw > 1023.999 && pw < 1024.001);
            check ("math-cos", cs > 0.9999 && cs < 1.0001);
            check ("math-floor", fl > 2.999 && fl < 3.001);
            check ("math-ceil", cl > 3.999 && cl < 4.001);
            check ("simd-vec4-add", vc[0] > 5.9 && vc[0] < 6.1 && vc[3] > 11.9 && vc[3] < 12.1);
            check ("simd-vec4-mul", vm[0] > 4.9 && vm[0] < 5.1 && vm[3] > 31.9 && vm[3] < 32.1);
            check ("simd-vec4-dot", dot > 69.999 && dot < 70.001);
        } catch (ModuleError e) {
            print (@"plan:error $(e.message)\n");
            check ("dlib-open", false);
        }
        print (@"plan:summary checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
    }
}
