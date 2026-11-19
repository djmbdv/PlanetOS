class Tracked {
    public int id;
    public Tracked (int id) { this.id = id; }
    ~Tracked () { print (@"drop $(id)\n"); }
}

[Compact]
class Buf {
    public int n;
    public string tag;
    public Tracked owner;

    public Buf (int n, string tag, Tracked owner) {
        this.n = n;
        this.tag = tag;
        this.owner = owner;
    }
}

int main () {
    var b = new Buf (7, "abc", new Tracked (1));
    print (@"$(b.n) $(b.tag) $(b.owner.id)\n");

    var c = new Buf (9, "de", new Tracked (2));
    b.n = b.n + c.n;
    print (@"$(b.n) $(c.n)\n");

    b.free ();
    print ("freed b\n");
    c.free ();
    print ("freed c\n");
    return 0;
}
