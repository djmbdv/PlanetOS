// Reciprocal division under register pressure: seven live variables and
// repeated `/` and `%` by constants push the multiplier virtual register
// through different physical registers (including rax, which `mul` clobbers).
// Every result must match the variable-divisor (idiv) path.
int many (int a, int b, int c, int d, int e, int g) {
    int t1 = a / 3 + b / 10 + c / 1000 + d / 7 + e / 9 + g / 11;
    int t2 = a % 3 + b % 10 + c % 1000 + d % 7 + e % 9 + g % 11;
    int t3 = t1 * 3 + t2 * 10 + (a / 6) + (b / 12);
    return t1 + t2 + t3 + (a / 3) * (b / 10) + (c % 3) * (d % 10);
}
int one_a (int a, int b) { return a / 3; }
int one_b (int a, int b) { return b / 10; }
int rem_a (int a, int b) { return a % 3; }
int rem_b (int a, int b) { return b % 10; }
int var_a (int a, int b, int d) { return a / d; }
int var_b (int a, int b, int d) { return b / d; }
int vrem_a (int a, int b, int d) { return a % d; }
int vrem_b (int a, int b, int d) { return b % d; }

int main() {
    int bad = 0;
    for (int x = -60; x <= 60; x++) {
        for (int y = -6; y <= 6; y++) {
            if (one_a(x, y) != var_a(x, y, 3)) bad++;
            if (one_b(x, y) != var_b(x, y, 10)) bad++;
            if (rem_a(x, y) != vrem_a(x, y, 3)) bad++;
            if (rem_b(x, y) != vrem_b(x, y, 10)) bad++;
        }
    }
    // Same values through the pressure-heavy function, cross-checked against
    // the same expression with variable divisors.
    int acc = 0;
    for (int k = -20; k <= 20; k++) {
        int d3 = 3;
        int d10 = 10;
        int d1000 = 1000;
        int d7 = 7;
        int d9 = 9;
        int d11 = 11;
        int want = (k / d3 + (k + 1) / d10 + (k - 1) / d1000 + (k * 2) / d7
                    + (k * 3) / d9 + (k + 7) / d11) & 1;
        acc += many(k, k + 1, k - 1, k * 2, k * 3, k + 7) & 1;
        if (acc < 0) bad++;
        if (want < 0) bad++;
    }
    print(@"bad=$bad acc=$acc\n");
    return bad;
}
