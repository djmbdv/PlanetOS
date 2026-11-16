public struct Pair {
    public int a;
    public int b;
    public int sum() { return a + b; }
}
void main() { var p = Pair() { a = 1, b = 2 }; print("%d\n", p.sum()); }
