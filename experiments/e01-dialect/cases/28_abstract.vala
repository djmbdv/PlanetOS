public abstract class Base : Object {
    public abstract int value();
    public int doubled() { return value() * 2; }
}
public class Derived : Base {
    public override int value() { return 21; }
}
void main() { print("%d\n", new Derived().doubled()); }
