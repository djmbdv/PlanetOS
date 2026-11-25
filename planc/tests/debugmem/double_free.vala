[Compact]
class Buf {
    public int v = 9;
}

int main () {
    Buf b = new Buf ();
    b.free ();
    b.free ();
    return 0;
}