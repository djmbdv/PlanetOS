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

    // int.parse / uint64.parse
    var up = uint64.parse ("18446744073709551615");
    print (@"parse: $(int.parse("123abc")) $(int.parse("  \t\n\r -42xyz")) $(int.parse("+77")) $(int.parse("abc")) $up\n");

    // string.ascii_casecmp / string.ascii_ncasecmp (including size_t.MAX and unsigned bytes)
    int c1 = "Hello".ascii_casecmp ("hELLo");
    int c2 = "abc".ascii_casecmp ("abd");
    int c3 = "abcd".ascii_casecmp ("abc");
    int c4 = "HelloWorld".ascii_ncasecmp ("hELLoThere", 5);
    int c5 = "abc".ascii_ncasecmp ("abd", 2);
    int c6 = "abc".ascii_ncasecmp ("abd", 3);
    int c7 = "a".ascii_ncasecmp ("b", 0);
    int c8 = "abc".ascii_ncasecmp ("abd", size_t.MAX);
    int c9 = "\x80".ascii_casecmp ("a");
    print (@"casecmp: $c1 $(c2 < 0) $(c3 > 0) $c4 $c5 $(c6 < 0) $c7 $(c8 < 0) $(c9 > 0)\n");
}
