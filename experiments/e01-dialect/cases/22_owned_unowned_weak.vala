public class Node : Object { public string name { get; set; } }
void main() {
    owned Node a = new Node();
    unowned Node b = a;
    weak Node w = a;
    print("%s %s\n", b.name ?? "-", (w == null) ? "null" : "alive");
}
