[Compact]
class Buf {
    public int n;
    public Buf (int n) { this.n = n; }
}
int main () {
    var b = new Buf (3);
    Object o = b;
    print (@"$(o != null)\n");
    return 0;
}
