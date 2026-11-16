public class Box<T> : Object where T : Object {
    public T value { get; set; }
}
public class Thing : Object { }
void main() { var b = new Box<Thing>(); print("%s\n", (b.value == null) ? "null" : "x"); }
