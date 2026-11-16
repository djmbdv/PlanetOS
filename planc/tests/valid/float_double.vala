const double PI = 3.14159265;
double g_acc = 1.5;

double sum10(double a0, double a1, double a2, double a3, double a4,
             double a5, double a6, double a7, double a8, double a9) {
    return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9;
}

float add_f32(float a, int b) {
    return a + b;
}

void scale_out(ref double x, out double sq) {
    x *= 2.0;
    sq = x * x;
}

struct Vec2 {
    public double x;
    public double y;
}

class BoxF : Object {
    public float v;
}

void main() {
    double a = 2.5;
    float f = 1.25f;
    double b = a + f;
    double c = 10 - a;
    c += 0.5;
    c /= 2.0;
    print(@"b=$b c=$c\n");

    var neg = -a;
    var r10 = sum10(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0);
    var fsum = add_f32(2.5f, 3);
    print(@"neg=$neg r10=$r10 fsum=$fsum\n");

    double rx = 3.0;
    double rsq = 0.0;
    scale_out(ref rx, out rsq);
    print(@"rx=$rx rsq=$rsq\n");

    var nan = double.NAN;
    bool n_eq = (nan == nan);
    bool n_ne = (nan != nan);
    bool n_lt = (nan < 1.0);
    bool n_gt = (nan > 1.0);
    print(@"nan: eq=$n_eq ne=$n_ne lt=$n_lt gt=$n_gt\n");

    int trunc = (int) 3.9;
    float df = (float) PI;
    g_acc *= 4.0;
    print(@"trunc=$trunc g=$g_acc df=$(df > 3.14f)\n");

    var v = Vec2() { x = 1.5, y = 2.5 };
    var bx = new BoxF() { v = 4.5f };
    var arr = new double[] { 0.5, 1.5, 2.5 };
    var ga = new GenericArray<double>();
    ga.add(arr[0] + arr[2]);
    print(@"vec=$(v.x + v.y) bx=$(bx.v) ga=$(ga[0])\n");

    var p1 = double.parse("-12.5");
    var p2 = float.parse("1.5e2");
    print(@"parsed=$(p1.to_string()) $(p2.to_string())\n");
}
