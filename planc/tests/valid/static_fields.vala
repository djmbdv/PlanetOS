class Counter {
    public static int total;
    public static string label = "c";
    public int inst;

    public Counter () {
        this.inst = 1;
    }

    public static int bump (int d) {
        total = total + d;
        return total;
    }

    public int peek () {
        return total;
    }
}
class Sub : Counter {
}
int main () {
    Counter.bump (5);
    Counter.total = Counter.total + 1;
    print (@"$(Counter.total)\n");
    var c = new Counter ();
    print (@"$(c.peek()) $(c.inst)\n");
    print (@"$(Counter.label)\n");
    Counter.total++;
    Sub.bump (10);
    print (@"$(Counter.total)\n");
    return 0;
}