async int slow_add(int a, int b) {
    yield;
    return a + b;
}
void main() {
    var loop = new MainLoop();
    slow_add.begin(2, 3, (o, r) => { print("%d\n", slow_add.end(r)); loop.quit(); });
    loop.run();
}
