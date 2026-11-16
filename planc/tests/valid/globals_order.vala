// Argument evaluation order is left to right (VL-12). A global accumulator
// makes the order observable: each call appends its digit.
int acc = 0;

int mark(int v) {
    acc = acc * 10 + v;
    return v;
}

int three(int a, int b, int c) {
    return a + b + c;
}

int main() {
    three(mark(1), mark(2), mark(3));
    return acc;
}
