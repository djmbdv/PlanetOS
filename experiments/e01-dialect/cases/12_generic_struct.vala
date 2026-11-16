public class Box<T> : Object {
    public T value { get; set; }
}
void main() { var b = new Box<int>(); b.value = 42; print("%d\n", b.value); }
