// Blocks above 4 KiB used to be dropped on free, never handed out again: a
// loop that keeps allocating >4 KiB arrays grew the heap without bound.
uint64 checksum (int seed, int len) {
    var buf = new uint8[len];
    for (int i = 0; i < len; i++)
        buf[i] = (uint8) ((seed * 7 + i) & 0xFF);
    uint64 sum = 0;
    for (int i = 0; i < len; i++)
        sum += buf[i];
    return sum;
}

int main () {
    uint64 expected = checksum (0, 5000);
    for (int i = 0; i < 2000; i++) {
        if (checksum (i, 5000) != checksum (i, 5000)) {
            print ("mismatch\n");
            return 1;
        }
    }
    if (checksum (0, 5000) != expected) {
        print ("corrupted\n");
        return 2;
    }
    print ("ok\n");
    return 0;
}
