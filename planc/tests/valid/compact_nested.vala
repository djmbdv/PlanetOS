class Log {
    public int k;
    public Log (int k) { this.k = k; }
    ~Log () { print (@"drop $(k)\n"); }
}

[Compact]
class Inner {
    public int v;
    public Inner (int v) { this.v = v; }
}

[Compact]
class Outer {
    public Inner child;
    public Log log;

    public Outer (int v) {
        this.child = new Inner (v);
        this.log = new Log (v);
    }
}

int main () {
    var o = new Outer (4);
    print (@"$(o.child.v)\n");

    var inner = o.child;
    o.free ();
    print ("outer freed\n");

    inner.free ();
    print ("inner freed\n");
    return 0;
}
