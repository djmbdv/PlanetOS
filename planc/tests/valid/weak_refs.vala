class Node : Object {
    public string name;
    public Node? child = null;
    public weak Node? parent = null;

    public Node (string name) {
        this.name = name;
    }

    ~Node () {
        print (@"dtor:$(this.name)\n");
    }
}

void test_local_weak () {
    Node? a = new Node ("A");
    weak Node? w = a;
    if (w != null) {
        print (@"alive:$(((Node) w).name)\n");
    }
    a = null;
    if (w == null) {
        print ("zeroed:1\n");
    } else {
        print ("zeroed:0\n");
    }
}

void test_cycle_weak () {
    Node? p = new Node ("P");
    Node? c = new Node ("C");
    ((Node) p).child = c;
    ((Node) c).parent = p;
    c = null;
    if (((Node) ((Node) p).child).parent != null) {
        print ("parent_alive:1\n");
    }
    p = null;
    print ("cycle_done\n");
}

int main () {
    test_local_weak ();
    test_cycle_weak ();
    return 0;
}
