delegate int Op (int a, int b);

class Holder {
    public Op? cb;
}

static int sub_op (int a, int b) {
    return a - b;
}

static Op? make_op (bool want, int bias) {
    if (!want)
        return null;
    return (a, b) => a + b + bias;
}

static int apply_or (Op? fn, int a, int b, int defval) {
    if (fn != null)
        return fn (a, b);
    return defval;
}

void main () {
    Op? d = null;
    print (@"init=$(d == null),$(d != null)\n");

    int base_v = 100;
    d = (a, b) => a + b + base_v;
    print (@"set=$(d != null),$(((!) d) (3, 4))\n");

    if (d != null)
        print (@"narrow=$(d (5, 6))\n");

    d = null;
    print (@"cleared=$(d == null)\n");

    Op sub_del = sub_op;
    Op mul_del = (a, b) => a * b;
    bool flag = false;
    Op? t1 = flag ? sub_del : null;
    Op? t2 = !flag ? mul_del : null;
    var t3 = flag ? t1 : t2;
    print (@"tern=$(t1 == null),$(t3 == null),$(((!) t3) (6, 7))\n");

    var d2 = t1 ?? make_op (true, 20);
    Op? d3 = t1 ?? null;
    print (@"coal=$(((!) d2) (1, 2)),$(d3 == null)\n");

    Op? r0 = make_op (false, 5);
    Op? r1 = make_op (true, 5);
    print (@"ret=$(apply_or (r0, 4, 5, -1)),$(apply_or (r1, 4, 5, -1))\n");

    var h = new Holder ();
    print (@"field0=$(h.cb == null)\n");
    h.cb = (a, b) => a + b + base_v;
    print (@"field1=$(((!) h.cb) (10, 20))\n");
    h.cb = null;
    print (@"field2=$(h.cb == null)\n");

    Op? d4 = (Op?) null;
    Op d5 = (Op) t3;
    print (@"cast=$(d4 == null),$(d5 (2, 9))\n");
}
