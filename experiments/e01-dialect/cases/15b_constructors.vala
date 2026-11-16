public class Order : Object {
    public int a { get; set; default = 1; }
    public int b { get; construct; }
    public int c { get; set; }
    public Order(int b) { this.b = b; this.c = 3; print("body a=%d b=%d c=%d\n", a, b, c); }
    construct { print("construct a=%d b=%d c=%d\n", a, b, c); }
    ~Order() { print("destructor\n"); }
}
void main() { var o = new Order(2); print("after new: %d %d %d\n", o.a, o.b, o.c); }
