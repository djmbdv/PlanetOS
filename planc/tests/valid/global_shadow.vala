int x = 100;

int main() {
    // A local with the same name shadows the global.
    int x = 5;
    return x + lookup();
}

int lookup() {
    return x;
}
