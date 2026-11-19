class Store {
    private int[] data;
    private int n;

    public Store (int n) {
        this.n = n;
        this.data = new int[n];
    }

    public int this [int i] {
        get {
            return data[i] * 2;
        }
        set {
            data[i] = value;
        }
    }
}
int main () {
    var s = new Store (3);
    s[0] = 5;
    s[1] = 7;
    s[2] = 9;
    int sum = s[0] + s[1] + s[2];
    print (@"sum=$sum\n");
    return 0;
}