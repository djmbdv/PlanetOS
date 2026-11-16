public class Constants : Object {
    public const int MAX = 10;
    public static int counter = 0;
    public static int increment() { return ++counter; }
}
void main() { print("%d %d %d\n", Constants.MAX, Constants.increment(), Constants.increment()); }
