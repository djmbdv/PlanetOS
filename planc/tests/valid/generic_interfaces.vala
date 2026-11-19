interface Holder<T> {
    public abstract T get_item_at (int i);
    public abstract int count ();
    public virtual T first () {
        return get_item_at (0);
    }
}
interface Named {
    public abstract string label ();
}
class IntBag : Holder<int> {
    private int[] data;
    public IntBag () { this.data = new int[3]; this.data[0] = 7; this.data[1] = 8; this.data[2] = 9; }
    public int get_item_at (int i) { return data[i]; }
    public int count () { return 3; }
}
class StrBag : Holder<string>, Named {
    private string[] data;
    public StrBag () { this.data = new string[2]; this.data[0] = "a"; this.data[1] = "b"; }
    public string get_item_at (int i) { return data[i]; }
    public int count () { return 2; }
    public string label () { return "strbag"; }
}
int main () {
    Holder<int> h = new IntBag ();
    print (@"$(h.first ()) $(h.count ())\n");
    Holder<string> s = new StrBag ();
    print (@"$(s.get_item_at (1)) $(s.first ())\n");
    var n = s as Named;
    print (@"$(n.label ())\n");
    var i2 = h as IntBag;
    print (@"$(i2.count ())\n");
    return 0;
}