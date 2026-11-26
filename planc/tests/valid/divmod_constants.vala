// Constant divisors: `/` and `%` by a power of two are strength-reduced to
// shifts (with a sign bias so signed division still truncates toward zero).
// Every reduced form must agree with the generic idiv path at -O0/-O1/-O2.
int q8 (int x) { return x / 8; }
int r8 (int x) { return x % 8; }
int qv (int x, int d) { return x / d; }
int rv (int x, int d) { return x % d; }
int mv (int x, int d) { return x * d; }

uint64 uq8 (uint64 x) { return x / 8; }
uint64 ur8 (uint64 x) { return x % 8; }
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
    }
    uint64 u = 0;
    uint64 ud = 8;
    for (int i = 0; i < 2000; i++) {
        if (uq8(u) != uqv(u, ud)) bad++;
        if (ur8(u) != urv(u, ud)) bad++;
        u++;
    }
    uint64 umax = 0;
    umax--;
    if (uq8(umax) != uqv(umax, ud)) bad++;
    if (ur8(umax) != urv(umax, ud)) bad++;
    print(@"bad=$bad q=$((-17) / 8),$(-17 % 8) p=$((17) / 8),$(17 % 8)
");
    return bad;
}
