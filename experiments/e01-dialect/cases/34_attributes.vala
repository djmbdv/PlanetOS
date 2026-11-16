public class Something : Object {
    [NoReturn]
    public void die() { }
    public int add(int a, int b) { return a + b; }
}
void main() { print("%d\n", new Something().add(1, 2)); }
