class Alpha {
    public int v;
    public Alpha (int v) { this.v = v; }
}

class Beta {
    public string s;
    public Beta (string s) { this.s = s; }
}

interface Marker { }

class Gamma : Marker {
    public double d;
    public Gamma (double d) { this.d = d; }
}

int describe (Object o) {
    if (o is Alpha) return ((Alpha) o).v;
    if (o is Beta) return 32;
    if (o is Marker) return 64;
    return 0;
}

int main () {
    Object a = new Alpha (3);
    Object b = new Beta ("x");
    Object g = new Gamma (1.5);

    var arr = new Object[3];
    arr[0] = a;
    arr[1] = b;
    arr[2] = g;
    int sum = 0;
    for (int i = 0; i < arr.length; i++) sum += describe (arr[i]);
    print (@"$(sum)\n");

    print (@"$(a is Object) $(g is Marker)\n");

    var back = a as Alpha;
    print (@"$(back != null) $(back.v)\n");
    var miss = b as Alpha;
    print (@"$(miss == null)\n");

    Object? n = null;
    print (@"$(n == null) $(a == a) $(a != b)\n");
    return 0;
}
