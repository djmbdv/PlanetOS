// A stack parameter is a local copy: writing to it must not disturb the
// caller's outgoing area.
int f(int a, int b, int c, int d, int e, int g, int x, int y) {
    x = x * 2;
    y = y + 1;
    return a + b + c + d + e + g + x + y;
}

int main() {
    return f(1, 2, 3, 4, 5, 6, 10, 20) * 0 + f(1, 2, 3, 4, 5, 6, 10, 20);
}
