delegate int Operation(int x);
Operation make(int extra) { return (x) => x + extra; }
void main() { var f = make(10); print("%d\n", f(5)); }
