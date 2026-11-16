int fact(int n) {
    if (n <= 1) {
        return 1;
    }
    return n * fact(n - 1);
}

int add(int a, int b) {
    return a + b;
}

int main() {
    return add(fact(3), add(1, 2));
}
