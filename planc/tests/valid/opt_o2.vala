int prop_test (int x) {
    int a = 10;
    int b = a + 5;
    int c = b * 2;
    bool cond = !(x == 0);
    int d = (x + 3) + 7;
    if (cond == true && !(x < 0)) {
        return c + d;
    }
    return c - d;
}

int main () {
    int r1 = prop_test (5);
    int r2 = prop_test (-2);
    print (@"r1=$r1 r2=$r2\n");
    return 0;
}
