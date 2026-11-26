// Returning an array hands its only reference to the caller. The -O2 backend
// used to release every array local on the way out, including the one it had
// just returned, so the caller read freed memory.
int[] make_ints (int n) {
    var a = new int[n];
    for (int i = 0; i < a.length; i++)
        a[i] = i * 3;
    return a;
}

uint8[] make_bytes (int n) {
    var b = new uint8[n];
    for (int i = 0; i < b.length; i++)
        b[i] = (uint8) (i & 0x7f);
    return b;
}

int sum_ints (int[] a) {
    int s = 0;
    for (int i = 0; i < a.length; i++)
        s += a[i];
    return s;
}

int sum_bytes (uint8[] a) {
    int s = 0;
    for (int i = 0; i < a.length; i++)
        s += a[i];
    return s;
}

void main () {
    var ints = make_ints (64);
    var bytes = make_bytes (256);
    int si = sum_ints (ints);
    int sb = sum_bytes (bytes);
    int n_i = ints.length;
    int n_b = bytes.length;
    int last = bytes[255];
    // Reading both after the callee returned is what used to break: the block
    // had already been released.
    print (@"ints=$n_i/$si bytes=$n_b/$sb last=$last\n");
    ints[0] = 7;
    bytes[0] = 9;
    int si2 = sum_ints (ints);
    int b0 = bytes[0];
    print (@"again=$si2 $b0\n");
}
