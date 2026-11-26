// `--trace-alloc=N` reports each allocation of at least N bytes.
void main () {
    uint8[] small = new uint8[16];
    small[0] = 1;
    uint8[] big = new uint8[4096];
    big[0] = 2;
    print (@"$(small[0])$(big[0])\n");
}