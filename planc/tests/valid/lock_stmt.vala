class Guard {
    public int total;

    public Guard () {
        this.total = 0;
    }

    public void bump (int n) {
        for (int i = 0; i < n; i++) {
            lock (this) {
                this.total = this.total + 1;
            }
        }
    }
}
int main () {
    var g = new Guard ();
    g.bump (1000);
    print (@"$(g.total)\n");
    for (int i = 0; i < 3; i++) {
        lock (g) {
            g.total = g.total + 10;
        }
    }
    print (@"$(g.total)\n");
    return 0;
}