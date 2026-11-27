// Loop shapes whose bounds checks can be dropped because the index provably
// stays in range: declared init, reset init, a local copy of `.length`, and the
// same index against several arrays. Everything must still read and write the
// right element, and a loop that resizes its array must not assume a length.
int sum_declared (int[] a) {
    int s = 0;
    for (int i = 0; i < a.length; i++)
        s += a[i];
    return s;
}

int sum_reset (int[] a) {
    int i = 0;
    int s = 0;
    for (i = 0; i < a.length; i++) {
        a[i] = a[i] + 1;
        s += a[i];
    }
    return s;
}

int sum_alias_len (int[] a) {
    int n = a.length;
    int s = 0;
    for (int i = 0; i < n; i++)
        s += a[i] * 2;
    return s;
}

int sum_two_arrays (uint8[] a, uint8[] b) {
    int s = 0;
    for (int i = 0; i < a.length; i++)
        s += a[i] + b[i];
    return s;
}

void main () {
    var a = new int[5];
    var b = new uint8[5];
    for (int i = 0; i < 5; i++) {
        a[i] = i + 1;
        b[i] = (uint8) (10 + i);
    }
    int d = sum_declared (a);
    int r = sum_reset (a);      // also increments every element
    int al = sum_alias_len (a);
    int two = sum_two_arrays (b, b);
    int a0 = a[0];
    print (@"declared=$d reset=$r alias=$al two=$two a0=$a0\n");
}
