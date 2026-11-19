class Base {
    public int v;
    public Base (int v) { this.v = v; }
}
[Compact]
class Buf : Base {
    public Buf (int v) : base (v) { }
}
int main () {
    return 0;
}
