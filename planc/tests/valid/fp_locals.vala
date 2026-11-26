// Floating-point locals, parameters and compound assignments. The movsd
// direct local access path replaced a movq-via-rax pair, and it deliberately
// invalidates the emitter's `last_store_local` peephole, so the integer and FP
// slots that share a frame are checked together here.
//
// Values are scaled to integers before printing so the expectations are exact.

double mix (double a, double b, double c, double d,
            double e, double f, double g, double h,
            double i, double j) {
    // Eight in xmm registers, two on the stack.
    double s1 = a + b;
    double s2 = c + d;
    double s3 = e + f;
    double s4 = g + h;
    double s5 = i + j;
    double t = s1 + s2 + s3 + s4 + s5;
    return t;
}

double compound (double x) {
    double acc = x;
    acc += 1.5;
    acc *= 2.0;
    acc -= 0.25;
    acc /= 2.0;
    double copy = acc;
    copy += acc;
    return copy;
}

float f32_roundtrip (float v, float w) {
    float t = v * w;
    float u = t + v;
    return u - w;
}

int main() {
    // 1+2+...+10 = 55, times 0.5 = 27.5 -> 27 with truncation.
    double m = mix(0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5, 9.5);
    int mi = (int) (m * 2.0);
    // ((4.0+1.5)*2 - 0.25)/2 = 5.375, doubled by `copy += acc` = 10.75
    int ci = (int) compound(4.0);
    int ci_scaled = (int) (compound(4.0) * 100.0);

    // float: (1.5*2.5 + 1.5) - 2.5 = 2.75 -> scaled by 100 = 275 (float exact here)
    float fv = f32_roundtrip(1.5f, 2.5f);
    int fi = (int) (fv * 100.0f);

    // FP and int locals interleaved in one frame.
    int n = 7;
    double d = 0.5;
    int acc = 0;
    for (int k = 0; k < 5; k++) {
        d *= 2.0;
        acc += n;
        n += 1;
        acc += (int) d;
    }
    // d: 1,2,4,8,16 -> 31 added; acc: 7+8+9+10+11 = 45
    print(@"m=$mi comp=$ci comp100=$ci_scaled f=$fi acc=$acc n=$n\n");

    // Repeated read/write of the same double local: r = 3*r + 0.5 ten times
    // starting at 1.0 gives 73811 exactly (all values are exactly
    // representable), so the scaled read must be 73 and the >180000 false.
    double r = 1.0;
    for (int k = 0; k < 10; k++) {
        r = r * 3.0 + 0.5;
    }
    print(@"r=$(r > 180000.0) ra=$((int) (r / 1000.0))\n");
    return 0;
}
