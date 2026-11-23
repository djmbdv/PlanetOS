class StrIter : Object {
    private string[] items;
    private int idx = -1;

    public StrIter (string[] items) {
        this.items = items;
    }

    public bool next () {
        idx++;
        return idx < items.length;
    }

    public string get () {
        return items[idx];
    }
}

class StrBox : Object {
    private string[] items;

    public StrBox (string[] items) {
        this.items = items;
    }

    public StrIter iterator () {
        return new StrIter (items);
    }
}

int main () {
    var box = new StrBox (new string[] { "uno", "dos", "tres", "cuatro" });
    string acc = "";
    foreach (var s in box) {
        if (s == "dos")
            continue;
        if (s == "cuatro")
            break;
        acc = acc + s + ",";
    }
    print (@"$acc\n");
    return 0;
}
