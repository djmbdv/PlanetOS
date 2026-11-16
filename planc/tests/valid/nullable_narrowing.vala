class Node {
    public int val;
    public Node? next;

    public Node(int val, Node? next) {
        this.val = val;
        this.next = next;
    }
}

int must_read(Node? n) {
    if (n == null) {
        return -1;
    }
    Node guaranteed = n;
    return guaranteed.val;
}

int sum_list(Node? head) {
    int total = 0;
    Node? cur = head;
    while (cur != null) {
        Node step = cur;
        total += step.val;
        cur = cur.next;
    }
    return total;
}

int main() {
    var list = new Node(10, new Node(20, new Node(30, null)));
    int a = sum_list(list);
    int b = must_read(list.next);
    int c = must_read(null);
    string? label = "ok";
    if (label != null) {
        string non_null_s = label;
        print(@"$non_null_s:$a:$b:$c\n");
    }
    return a + b;
}
