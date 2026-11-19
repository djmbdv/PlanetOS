interface HasName {
    public abstract string name { get; set; }
    public abstract int size { get; }
}
class P : HasName {
    public string name { get; set; }
    public int size { get; set; }
}
int main () {
    HasName h = new P ();
    h.name = "abc";
    print (@"$(h.name) $(h.size)\n");
    return 0;
}