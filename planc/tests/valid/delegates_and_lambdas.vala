public delegate int IntOp(int x);
public delegate string Formatter(string label, int n);

int free_double(int x) {
    return x * 2;
}

public class MathBox {
    public static int square(int x) {
        return x * x;
    }
}

public class Holder {
    public string tag;
    public int bias;

    public Holder(string tag, int bias) {
        this.tag = tag;
        this.bias = bias;
    }

    public int apply_bias(int x) {
        return x + bias;
    }
}

int run_op(IntOp op, int v) {
    return op(v);
}

Formatter make_formatter(string prefix, Holder h) {
    int mult = 3;
    return (lbl, n) => {
        int val = h.apply_bias(n * mult);
        return @"$prefix:$(h.tag):$lbl=$val";
    };
}

int main() {
    IntOp f1 = free_double;
    IntOp f2 = MathBox.square;
    var h = new Holder("H1", 5);
    IntOp f3 = h.apply_bias;
    IntOp f4 = x => x + 10;
    IntOp f5 = (x) => {
        return x - 1;
    };

    print(@"free=$(run_op(f1, 6))\n");
    print(@"static=$(run_op(f2, 5))\n");
    print(@"bound=$(run_op(f3, 7))\n");
    print(@"nc1=$(run_op(f4, 4))\n");
    print(@"nc2=$(run_op(f5, 9))\n");

    int k = 100;
    string note = "cap";
    Formatter fmt1 = (lbl, n) => @"$note:$lbl=$(n + k)";
    string r1 = fmt1("a", 23);
    print(@"fmt1=$r1\n");

    Formatter fmt2 = make_formatter("pre", h);
    string r2 = fmt2("b", 4);
    print(@"fmt2=$r2\n");

    fmt1 = fmt2;
    string r3 = fmt1("c", 2);
    print(@"fmt1_re=$r3\n");

    var wrap = new Holder("Wrap", 1);
    IntOp self_check = wrap.apply_bias;
    self_check = self_check;
    print(@"self=$(self_check(9))\n");
    return 0;
}
