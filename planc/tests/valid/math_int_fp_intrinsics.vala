void main () {
    // int.abs (instance and static-style)
    int a = -42;
    int b = 17;
    int z = 0;
    int64 big = -1000000000000L;
    print (@"abs: $(a.abs()) $(b.abs()) $(z.abs()) $(big.abs())\n");
    print (@"abs_s: $(int.abs(a)) $(int.abs(-99)) $(int64.abs(big))\n");

    // double / float is_nan, is_finite, is_infinity, abs
    double d_nan = double.NAN;
    double d_inf = double.INFINITY;
    double d_ninf = -double.INFINITY;
    double d_neg = -3.5;
    double d_pos = 2.25;
    print (@"d_nan: $(d_nan.is_nan()) $(double.is_nan(d_nan)) $(d_pos.is_nan()) $(d_inf.is_nan())\n");
    print (@"d_fin: $(d_pos.is_finite()) $(d_nan.is_finite()) $(d_inf.is_finite()) $(d_ninf.is_finite())\n");
    print (@"d_inf: $(d_inf.is_infinity()) $(d_ninf.is_infinity()) $(d_pos.is_infinity()) $(d_nan.is_infinity())\n");
    print (@"d_abs: $(d_neg.abs()) $(double.abs(-12.5))\n");

    float f_nan = float.NAN;
    float f_inf = float.INFINITY;
    float f_ninf = -float.INFINITY;
    float f_neg = -1.75f;
    float f_pos = 4.5f;
    print (@"f_nan: $(f_nan.is_nan()) $(float.is_nan(f_nan)) $(f_pos.is_nan()) $(f_inf.is_nan())\n");
    print (@"f_fin: $(f_pos.is_finite()) $(f_nan.is_finite()) $(f_inf.is_finite()) $(f_ninf.is_finite())\n");
    print (@"f_inf: $(f_inf.is_infinity()) $(f_ninf.is_infinity()) $(f_pos.is_infinity()) $(f_nan.is_infinity())\n");
    print (@"f_abs: $(f_neg.abs()) $(float.abs(-6.25f))\n");

    // int.parse (atoi semantics: leading whitespace including \n/\r/\t, trailing non-digits)
    print (@"parse: $(int.parse("123abc")) $(int.parse("  \t\n\r -42xyz")) $(int.parse("+77")) $(int.parse("abc"))\n");
}
