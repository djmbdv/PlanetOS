struct Point {
    public int x;
    public int y;
}

int main() {
    var p = Point () { x = 1, y = 2 };
    switch (p) {
        default:
            return 1;
    }
    return 0;
}
