T identity<T> (T x) {
    return x;
}
T pick<T> (T a, T b) {
    return a;
}
class Util {
    public static T first<T> (T a, T b) {
        return a;
    }
    public T echo<T> (T x) {
        return x;
    }
}
int main () {
    int a = identity (7);
    string s = identity ("hi");
    double d = identity (2.5);
    print (@"$a $s $d\n");
    print (@"$(identity<int> (11)) $(pick ("x", "y"))\n");
    print (@"$(Util.first (3, 4))\n");
    var u = new Util ();
    print (@"$(u.echo ("z"))\n");
    return 0;
}