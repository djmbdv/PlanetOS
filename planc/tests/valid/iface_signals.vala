interface Base2 {
    public signal void tick (string tag);
}
interface Derived2 : Base2 {
    public abstract void run ();
}
class Counter2 : Derived2 {
    public int n;
    public Counter2 () { this.n = 0; }
    public void run () {
        this.n = this.n + 1;
        tick ("run");
    }
}
int main () {
    var c = new Counter2 ();
    var id1 = c.tick.connect ((sender, tag) => { print (@"a:$tag\n"); });
    var id2 = c.tick.connect ((sender, tag) => { print (@"b:$tag\n"); });
    Derived2 d = c;
    d.run ();
    c.tick.disconnect (id1);
    d.run ();
    c.tick.disconnect (id2);
    d.run ();
    print (@"n=$(c.n)\n");
    return 0;
}