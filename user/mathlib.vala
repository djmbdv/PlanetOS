// PlanetOS mathlib.dlib: scalar math (translated from C via c2vala) + native x86-64-v3 (SSE4.1/AVX2/FMA3) SIMD.

[AsmBody(@"
    # dlib_sqrt(x in xmm0) -> xmm0 (SSE2 sqrtsd)
    .byte 0xf2, 0x0f, 0x51, 0xc0
    ret
")]
public extern double dlib_sqrt (double x);

[AsmBody(@"
    # dlib_floor(x in xmm0) -> SSE4.1 roundsd $0x09
    .byte 0x66, 0x0f, 0x3a, 0x0b, 0xc0, 0x09
    ret
")]
public extern double dlib_floor (double x);

[AsmBody(@"
    # dlib_ceil(x in xmm0) -> SSE4.1 roundsd $0x0a
    .byte 0x66, 0x0f, 0x3a, 0x0b, 0xc0, 0x0a
    ret
")]
public extern double dlib_ceil (double x);

[AsmBody(@"
    # dlib_fma(a in xmm0, b in xmm1, c in xmm2) -> FMA3 vfmadd213sd (a * b + c)
    .byte 0xc4, 0xe2, 0xe9, 0xa9, 0xc2
    ret
")]
public extern double dlib_fma (double a, double b, double c);

[AsmBody(@"
    # dlib_vec4_add(dst in rdi, a in rsi, b in rdx) -> 4x float64 AVX2 256-bit vaddpd
    .byte 0xc5, 0xfd, 0x10, 0x06
    .byte 0xc5, 0xfd, 0x10, 0x0a
    .byte 0xc5, 0xfd, 0x58, 0xc1
    .byte 0xc5, 0xfd, 0x11, 0x07
    .byte 0xc5, 0xf8, 0x77
    ret
")]
public extern void dlib_vec4_add (int dst, int a, int b);

[AsmBody(@"
    # dlib_vec4_sub(dst in rdi, a in rsi, b in rdx) -> 4x float64 AVX2 256-bit vsubpd
    .byte 0xc5, 0xfd, 0x10, 0x06
    .byte 0xc5, 0xfd, 0x10, 0x0a
    .byte 0xc5, 0xfd, 0x5c, 0xc1
    .byte 0xc5, 0xfd, 0x11, 0x07
    .byte 0xc5, 0xf8, 0x77
    ret
")]
public extern void dlib_vec4_sub (int dst, int a, int b);

[AsmBody(@"
    # dlib_vec4_mul(dst in rdi, a in rsi, b in rdx) -> 4x float64 AVX2 256-bit vmulpd
    .byte 0xc5, 0xfd, 0x10, 0x06
    .byte 0xc5, 0xfd, 0x10, 0x0a
    .byte 0xc5, 0xfd, 0x59, 0xc1
    .byte 0xc5, 0xfd, 0x11, 0x07
    .byte 0xc5, 0xf8, 0x77
    ret
")]
public extern void dlib_vec4_mul (int dst, int a, int b);

[AsmBody(@"
    # dlib_vec4_dot(a in rdi, b in rsi) -> double in xmm0 (AVX2 vmulpd + horizontal sum)
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
public extern double dlib_vec4_dot (int a, int b);

public double dlib_vec4_len (int a) {
    return dlib_sqrt (dlib_vec4_dot (a, a));
}

// --- Scalar math (generated from math_core.c via c2vala) ----------------

public int dlib_add (int a, int b) {
    return (a + b);
}

public int dlib_mul (int a, int b) {
    return (a * b);
}

public int dlib_mix (int a, int b) {
    return ((a * 3) + (b * 2));
}

public int dlib_abs (int a) {
    return ((a < 0) ? -a : a);
}

public int dlib_clamp_i (int v, int lo, int hi) {
    return ((v < lo) ? lo : ((v > hi) ? hi : v));
}

public int dlib_gcd (int a, int b) {
    int x = ((a < 0) ? -a : a);
    int y = ((b < 0) ? -b : b);
    while (y != 0) {
        int t = (x % y);
        x = y;
        y = t;
    }
    return x;
}

public double dlib_fabs (double x) {
    return ((x < 0.0) ? -x : x);
}

public double dlib_lerp (double a, double b, double t) {
    return (a + ((b - a) * t));
}

public double dlib_sin (double x) {
    double pi = 3.14159265358979323846;
    double twopi = 6.28318530717958647692;
    double halfpi = 1.57079632679489661923;
    int k = ((int) (x / twopi));
    x = (x - (((double) k) * twopi));
    if (x > pi) x = (x - twopi);
    if (x < -pi) x = (x + twopi);
    if (x > halfpi) x = (pi - x);
    if (x < -halfpi) x = (-pi - x);
    double x2 = (x * x);
    return (x * (1.0 - (x2 * (0.16666666666666632 - (x2 * (0.00833333333330950 - (x2 * (0.0001984126943568 - (x2 * 0.0000027557313707)))))))));
}

public double dlib_cos (double x) {
    return dlib_sin (x + 1.57079632679489661923);
}

public double dlib_tan (double x) {
    double c = dlib_cos (x);
    return (dlib_fabs (c) < 1.0e-12) ? 0.0 : (dlib_sin (x) / c);
}

public double dlib_exp (double x) {
    if (x > 709.0) return 1.0e308;
    if (x < -709.0) return 0.0;
    double ln2 = 0.69314718055994530942;
    int k = ((int) ((x / ln2) + ((x >= 0.0) ? 0.5 : -0.5)));
    double r = (x - (((double) k) * ln2));
    double p = (1.0 + (r * (1.0 + (r * (0.5 + (r * (0.16666666666666666 + (r * (0.04166666666666666 + (r * (0.00833333333333333 + (r * 0.00138888888888889))))))))))));
    while (k > 0) { p = (p * 2.0); k = (k - 1); }
    while (k < 0) { p = (p * 0.5); k = (k + 1); }
    return p;
}

public double dlib_log (double x) {
    if (x <= 0.0) return -1.0e308;
    double ln2 = 0.69314718055994530942;
    int k = 0;
    while (x >= 1.4142135623730951) { x = (x * 0.5); k = (k + 1); }
    while (x < 0.7071067811865475) { x = (x * 2.0); k = (k - 1); }
    double f = ((x - 1.0) / (x + 1.0));
    double f2 = (f * f);
    double s = (f * (2.0 + (f2 * (0.6666666666666666 + (f2 * (0.4 + (f2 * (0.2857142857142857 + (f2 * 0.2222222222222222)))))))));
    return (s + (((double) k) * ln2));
}

public double dlib_pow (double base_v, double exp_v) {
    if (exp_v == 0.0) return 1.0;
    if (base_v == 0.0) return 0.0;
    int ei = ((int) exp_v);
    if (((double) ei) == exp_v && ei >= 0 && ei <= 64) {
        double res = 1.0;
        double cur = base_v;
        int e = ei;
        while (e > 0) {
            if ((e & 1) != 0) res = (res * cur);
            cur = (cur * cur);
            e = (e >> 1);
        }
        return res;
    }
    return dlib_exp (exp_v * dlib_log (base_v));
}

public double dlib_atan (double x) {
    int sign = 1;
    if (x < 0.0) { x = -x; sign = -1; }
    int inv = 0;
    if (x > 1.0) { x = (1.0 / x); inv = 1; }
    double x2 = (x * x);
    double r = (x * (1.0 - (x2 * (0.3333333333333333 - (x2 * (0.2 - (x2 * (0.14285714285714285 - (x2 * (0.1111111111111111 - (x2 * 0.09090909090909091)))))))))));
    if (inv != 0) r = (1.57079632679489661923 - r);
    return ((sign < 0) ? -r : r);
}

public double dlib_atan2 (double y, double x) {
    double pi = 3.14159265358979323846;
    double halfpi = 1.57079632679489661923;
    if (x > 0.0) return dlib_atan (y / x);
    if (x < 0.0 && y >= 0.0) return (dlib_atan (y / x) + pi);
    if (x < 0.0 && y < 0.0) return (dlib_atan (y / x) - pi);
    if (x == 0.0 && y > 0.0) return halfpi;
    if (x == 0.0 && y < 0.0) return -halfpi;
    return 0.0;
}
