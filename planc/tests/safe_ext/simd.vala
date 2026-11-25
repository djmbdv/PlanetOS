int main () {
    int pc = Simd.popcount (0xF0F0);
    uint8[] a = new uint8[] {
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 200
    };
    print (@"pc=$(pc) sum=$(Simd.sum_u8 (a)) avg=$(Simd.avg_u8 (a))\n");
    uint8[] empty = new uint8[0];
    print (@"empty=$(Simd.sum_u8 (empty)):$(Simd.avg_u8 (empty))\n");
    return 0;
}