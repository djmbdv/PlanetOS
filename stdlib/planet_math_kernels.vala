// Trusted SIMD/scalar math kernels for the planetos mathlib.dlib demo.
//
// [AsmBody] is only allowed in stdlib/, kernel/ and planetrt/, so the machine
// code lives here and user/mathlib.vala just forwards to these checked entry
// points. Each wrapper is a plain Vala function: the dlib keeps exporting the
// same dlib_* symbols it always did.
namespace Planet {


        // SSE2 sqrtsd
        [AsmBody(@"
            .byte 0xf2, 0x0f, 0x51, 0xc0
            ret
        ")]
        private extern double __sqrt (double x);

        // SSE4.1 roundsd $0x09 (floor)
        [AsmBody(@"
            .byte 0x66, 0x0f, 0x3a, 0x0b, 0xc0, 0x09
            ret
        ")]
        private extern double __floor (double x);

        // SSE4.1 roundsd $0x0a (ceil)
        [AsmBody(@"
            .byte 0x66, 0x0f, 0x3a, 0x0b, 0xc0, 0x0a
            ret
        ")]
        private extern double __ceil (double x);

        // FMA3 vfmadd213sd (a * b + c)
        [AsmBody(@"
            .byte 0xc4, 0xe2, 0xf1, 0xa9, 0xc2
            ret
        ")]
        private extern double __fma (double a, double b, double c);

        // 4x float64 AVX2 256-bit vaddpd
        [AsmBody(@"
            .byte 0xc5, 0xfd, 0x10, 0x06
            .byte 0xc5, 0xfd, 0x10, 0x0a
            .byte 0xc5, 0xfd, 0x58, 0xc1
            .byte 0xc5, 0xfd, 0x11, 0x07
            .byte 0xc5, 0xf8, 0x77
            ret
        ")]
        private extern void __vec4_add (int dst, int a, int b);

        // 4x float64 AVX2 256-bit vsubpd
        [AsmBody(@"
            .byte 0xc5, 0xfd, 0x10, 0x06
            .byte 0xc5, 0xfd, 0x10, 0x0a
            .byte 0xc5, 0xfd, 0x5c, 0xc1
            .byte 0xc5, 0xfd, 0x11, 0x07
            .byte 0xc5, 0xf8, 0x77
            ret
        ")]
        private extern void __vec4_sub (int dst, int a, int b);

        // 4x float64 AVX2 256-bit vmulpd
        [AsmBody(@"
            .byte 0xc5, 0xfd, 0x10, 0x06
            .byte 0xc5, 0xfd, 0x10, 0x0a
            .byte 0xc5, 0xfd, 0x59, 0xc1
            .byte 0xc5, 0xfd, 0x11, 0x07
            .byte 0xc5, 0xf8, 0x77
            ret
        ")]
        private extern void __vec4_mul (int dst, int a, int b);

        // AVX2 vmulpd + horizontal sum
        [AsmBody(@"
            .byte 0xc5, 0xfd, 0x10, 0x07
            .byte 0xc5, 0xfd, 0x10, 0x0e
            .byte 0xc5, 0xfd, 0x59, 0xc1
            .byte 0xc4, 0xe3, 0x7d, 0x19, 0xc1, 0x01
            .byte 0xc5, 0xf9, 0x58, 0xc1
            .byte 0xc5, 0xf9, 0xc6, 0xc8, 0x01
            .byte 0xc5, 0xfb, 0x58, 0xc1
            .byte 0xc5, 0xf8, 0x77
            ret
        ")]
        private extern double __vec4_dot (int a, int b);

        public double math_sqrt (double x) { return __sqrt (x); }
        public double math_floor (double x) { return __floor (x); }
        public double math_ceil (double x) { return __ceil (x); }
        public double math_fma (double a, double b, double c) { return __fma (a, b, c); }
        public void math_vec4_add (int dst, int a, int b) { __vec4_add (dst, a, b); }
        public void math_vec4_sub (int dst, int a, int b) { __vec4_sub (dst, a, b); }
        public void math_vec4_mul (int dst, int a, int b) { __vec4_mul (dst, a, b); }
        public double math_vec4_dot (int a, int b) { return __vec4_dot (a, b); }
}
