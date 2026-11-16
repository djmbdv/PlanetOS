class Counter {
    public int value = 10;
    public string label;

    public Counter(string label, int bonus) {
        this.label = label;
        this.value += bonus;
    }

    public void add(int delta) {
        value += delta;
    }

    public void step() {
        value++;
        value++;
        value--;
        add(3);
    }

    public int total() {
        return value;
    }
}

int read_total(Counter c) {
    c.value += 5;
    return c.total();
}

int main() {
    var c = new Counter("ops", 5);
    c.step();
    int t = read_total(c);
    print(@"$(c.label)=$t\n");
    return t;
}
