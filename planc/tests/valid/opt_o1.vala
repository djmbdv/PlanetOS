int fold_arith (int x) {
    int a = 2 + 3 * 4;
    int b = (100 - 20) / 4 + (7 % 3);
    int c = (x + 0) * 1;
    int d = x * 8;
    int e = x * 0;
    int f = (1 << 4) | 3;
    int g = 1 > 2 ? 999 : 42;
    return a + b + c + d + e + f + g;
}

int dce_test (int x) {
    if (false) {
        print ("NEVER_1\n");
        return 999;
    }
    while (false) {
        print ("NEVER_2\n");
    }
    if (true) {
        int y = x + 0;
        return y * 4;
    }
    print ("NEVER_3\n");
    return 0;
}

int main () {
    int r1 = fold_arith (5);
    int r2 = dce_test (7);
    int z = 0;
    bool b = true && (r1 > 0);
    if (b) {
        print (@"r1=$r1 r2=$r2 z=$z\n");
    }
    return 0;
}
