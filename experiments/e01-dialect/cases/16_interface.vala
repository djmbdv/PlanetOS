public interface Greeter : Object {
    public abstract string greet();
}
public class Simple : Object, Greeter {
    public string greet() { return "hello"; }
}
void main() { Greeter g = new Simple(); print("%s\n", g.greet()); }
