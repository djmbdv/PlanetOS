class Parent : Object {
    public int id;
    public Child? child = null;

    public Parent (int id) {
        this.id = id;
    }
}

class Child : Object {
    public unowned Parent? parent = null;
    public int tag;

    public Child (Parent p, int tag) {
        this.parent = p;
        this.tag = tag;
    }
}

int main () {
    var p = new Parent (7);
    var c = new Child (p, 42);
    p.child = c;
    unowned Parent? up = c.parent;
    int pid = (up != null) ? up.id : -1;
    print (@"$pid $(c.tag)\n");
    return 0;
}

