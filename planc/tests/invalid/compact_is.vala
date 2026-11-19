[Compact]
class Buf {
    public int n;
    public Buf (int n) { this.n = n; }
}
int main () {
    var b = new Buf (3);
    if (b is Buf) print ("owned\n");
    return 0;
}
