int id(int x) {
    return x;
}

int sum8(int a, int b, int c, int d, int e, int f, int g, int h) {
    return a + b + c + d + e + f + g + h;
}

int main() {
    // Stack arguments evaluated while nested calls and an odd number of live
    // pushes are in flight.
    return sum8(id(1), id(2), id(3), id(4), id(5), id(6), id(7), id(8)) + id(1);
}
