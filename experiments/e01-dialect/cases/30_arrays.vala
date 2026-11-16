void main() {
    int[] fixed_size = { 1, 2, 3 };
    var buf = new int[4];
    buf[0] = 9;
    print("%d %d %d\n", fixed_size[2], buf[0], fixed_size.length);
}
