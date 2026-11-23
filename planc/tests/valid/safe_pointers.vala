class Node : Object {
    public int val;
    public Node? next;
    public Node (int v) { val = v; }
}

void remove_node (Node?* pp_arg, Node target) {
    Node?* pp = pp_arg;
    while (*pp != null && *pp != target) {
        pp = &((*pp).next);
    }
    if (*pp != null) {
        *pp = (*pp).next;
    }
}

int main () {
    Node?[] buckets = new Node?[2];
    var n1 = new Node (1);
    var n2 = new Node (2);
    var n3 = new Node (3);
    n1.next = n2;
    n2.next = n3;
    buckets[1] = n1;

    remove_node (&buckets[1], n2);
    void* id1 = &n1.val;
    void* id2 = &n1.val;
    print (@"eq=$(id1 == id2)\n");

    var cur = buckets[1];
    while (cur != null) {
        print (@"$(cur.val)\n");
        cur = cur.next;
    }
    return 0;
}
