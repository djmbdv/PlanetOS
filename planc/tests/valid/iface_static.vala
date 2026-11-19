interface Mathy {
    public static int double_it (int x) {
        return x * 2;
    }
    public abstract int apply (int x);
}
class Doubler : Mathy {
    public int apply (int x) { return Mathy.double_it (x); }
}
int main () {
    print (@"$(Mathy.double_it (21))\n");
    Mathy m = new Doubler ();
    print (@"$(m.apply (4))\n");
    return 0;
}