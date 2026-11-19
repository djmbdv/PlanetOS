sealed class Base {
    public int v;
    public Base (int v) { this.v = v; }
}
class Derived : Base {
    public Derived (int v) : base (v) { }
}
int main () {
    return 0;
}