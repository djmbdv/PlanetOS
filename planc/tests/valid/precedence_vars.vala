int main() {
    int a = 3;
    int b = 4;
    int c = 0;

    // Regression test for parser seed precedence:
    //   2 * a + b   must parse as (2 * a) + b = 10, not 2 * (a + b) = 14
    //   c && a || 1 must parse as (c && a) || 1 = 1, not c && (a || 1) = 0
    int p1 = 2 * a + b;
    int p2 = c && a || 1;
    a + b;

    return p1 * 10 + p2;
}
