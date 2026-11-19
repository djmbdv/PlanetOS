[Compact]
class Buf {
    public int n;
    public Buf (int n) { this.n = n; }
}
int main () {
    var b = new Buf (3);
    var c = b as Buf;
    print (@"$(c.n)\n");
    return 0;
}
