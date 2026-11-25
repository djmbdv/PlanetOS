int main() {
    int[] a = { 1, 2, 3 };
    a.resize(5);
    print(@"a=$(a.length):$(a[0]):$(a[2]):$(a[3]):$(a[4])\n");
    a.resize(2);
    print(@"a=$(a.length):$(a[0]):$(a[1])\n");
    a.resize(3);
    a[2] = 9;
    print(@"a=$(a.length):$(a[0]):$(a[1]):$(a[2])\n");

    int[] b = { 10, 20, 30, 40, 50 };
    b.move(0, 1, 3);
    print(@"b=$(b[0]):$(b[1]):$(b[2]):$(b[3]):$(b[4])\n");
    b.move(3, 0, 2);
    print(@"b=$(b[0]):$(b[1]):$(b[2]):$(b[3]):$(b[4])\n");

    string[] s = { "a", "b" };
    s.resize(4);
    print(@"s=$(s.length):$(s[0]):$(s[1]):$(s[2]):$(s[3])\n");
    s[3] = "d";
    s.resize(2);
    print(@"s=$(s.length):$(s[0]):$(s[1])\n");

    uint8[] u = new uint8[] { 7, 8 };
    u.resize(4);
    u[3] = 200;
    print(@"u=$(u.length):$(u[0]):$(u[1]):$(u[2]):$(u[3])\n");

    return 0;
}
