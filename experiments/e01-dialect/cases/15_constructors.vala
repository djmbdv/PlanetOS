public class Order : Object {
    public int a { get; set; default = 1; }
    public int b { get; construct; }
    public int c { get; set; }
    public Order(int b) { this.b = b; this.c = 3; }
    public Order.with_a(int a) { this.a = a; this.b = 0; }
    construct { print("construct a=%d b=%d c=%d\n", a, b, c); }
}
void main() { var o = new Order(2); print("%d %d %d\n", o.a, o.b, o.c); }
