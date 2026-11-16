int id(int x) {
    return x;
}

int main() {
    // Odd number of live intermediates across nested calls: exercises the
    // stack-alignment padding at the call sites.
    return (id(1) + id(2)) * (id(3) - id(1));
}
