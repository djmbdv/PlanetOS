struct Pair {
    public int x;
    public int y;
}

union Val {
    public int i;
    public double d;
}

delegate int Op (int a, int b);

int add_op (int a, int b) { return a + b; }
int mul_op (int a, int b) { return a * b; }

int main () {
    Pair[] pairs = new Pair[2];
    pairs[0] = Pair () { x = 10, y = 20 };
    pairs[1] = Pair () { x = 3, y = 4 };
    int psum = 0;
    foreach (var p in pairs)
        psum += p.x + p.y;

    Val[] vals = new Val[2];
    vals[0] = Val () { i = 42 };
    vals[1] = Val () { i = 8 };
    int vsum = vals[0].i + vals[1].i;

    Op[] ops = { add_op, mul_op, (a, b) => a - b };
    int r0 = ops[0] (6, 7);
    int r1 = ops[1] (6, 7);
    int r2 = ops[2] (10, 3);

    print (@"$psum $vsum $r0 $r1 $r2\n");
    return 0;
}
