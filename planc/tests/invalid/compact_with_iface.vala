interface Sized {
    public abstract int size ();
}
[Compact]
class Buf : Sized {
    public int n;
    public int size () { return n; }
}
int main () {
    return 0;
}
