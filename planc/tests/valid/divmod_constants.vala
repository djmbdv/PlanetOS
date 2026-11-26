// Constant divisors: `/` and `%` by a power of two are strength-reduced to
// shifts (with a sign bias so signed division still truncates toward zero);
// other constants use a verified reciprocal (mulhi + shift) instead of idiv.
// Every reduced form must agree with the generic idiv path at -O0/-O1/-O2.
int q8 (int x) { return x / 8; }
int r8 (int x) { return x % 8; }
int qv (int x, int d) { return x / d; }
int rv (int x, int d) { return x % d; }
int mv (int x, int d) { return x * d; }

// Non-power-of-two divisors whose reciprocal bound checks out: 3, 10, 1000.
int q3 (int x) { return x / 3; }
int r3 (int x) { return x % 3; }
int q10 (int x) { return x / 10; }
int r10 (int x) { return x % 10; }
int q1000 (int x) { return x / 1000; }

uint64 uq8 (uint64 x) { return x / 8; }
uint64 ur8 (uint64 x) { return x % 8; }
uint64 uq10 (uint64 x) { return x / 10; }
uint64 ur10 (uint64 x) { return x % 10; }
uint64 uqv (uint64 x, uint64 d) { return x / d; }
uint64 urv (uint64 x, uint64 d) { return x % d; }

int main() {
    int bad = 0;
    for (int x = -300; x <= 300; x++) {
        if (q8(x) != qv(x, 8)) bad++;
        if (r8(x) != rv(x, 8)) bad++;
        if ((x / 2) != qv(x, 2)) bad++;
        if ((x % 2) != rv(x, 2)) bad++;
        if ((x / 64) != qv(x, 64)) bad++;
        if ((x % 1024) != rv(x, 1024)) bad++;
        if ((x * 2) != mv(x, 2)) bad++;
        if ((x * 3) != mv(x, 3)) bad++;
        if ((x * 5) != mv(x, 5)) bad++;
        if ((x * 9) != mv(x, 9)) bad++;
        if (q3(x) != qv(x, 3)) bad++;
        if (r3(x) != rv(x, 3)) bad++;
        if (q10(x) != qv(x, 10)) bad++;
        if (r10(x) != rv(x, 10)) bad++;
        if (q1000(x) != qv(x, 1000)) bad++;
    }
    uint64 u = 0;
    uint64 ud = 8;
    for (int i = 0; i < 2000; i++) {
        if (uq8(u) != uqv(u, ud)) bad++;
        if (ur8(u) != urv(u, ud)) bad++;
        u++;
    }
    // 64-bit boundaries exercise the sign bias and the unsigned top bit.
    int64 lo = -9223372036854775807 - 1;
    int64 hi = 9223372036854775807;
    int l10 = 10;
    int l3 = 3;
    int l1000 = 1000;
    if (q10((int) lo) != qv((int) lo, l10)) bad++;
    if (r10((int) lo) != rv((int) lo, l10)) bad++;
    if (q3((int) lo) != qv((int) lo, l3)) bad++;
    if (r3((int) lo) != rv((int) lo, l3)) bad++;
    if (q10((int) hi) != qv((int) hi, l10)) bad++;
    if (r10((int) hi) != rv((int) hi, l10)) bad++;
    if (q1000((int) lo) != qv((int) lo, l1000)) bad++;
    uint64 umax = 0;
    umax--;
    uint64 ud10 = 10;
    if (uq8(umax) != uqv(umax, ud)) bad++;
    if (ur8(umax) != urv(umax, ud)) bad++;
    if (uq10(umax) != uqv(umax, ud10)) bad++;
    if (ur10(umax) != urv(umax, ud10)) bad++;
    uint64 utop = 9223372036854775808u;
    if (uq10(utop) != uqv(utop, ud10)) bad++;
    if (ur10(utop) != urv(utop, ud10)) bad++;
    print(@"bad=$bad q=$((-17) / 8),$((-17 % 8)) p=$((17) / 8),$(17 % 8) m=$((-17) / 10),$((-17 % 10))\n");
    return bad;
}
