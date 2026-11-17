class Box : Object {
    public string text = "init";
    public void append_a () {
        text = text + "a";
    }
    public string get_text () {
        return text;
    }
}

int main () {
    var b = new Box ();
    b.append_a ();
    print (@"1:$(b.get_text ())\n");
    print (@"2:$(b.text)\n");
    return 0;
}
