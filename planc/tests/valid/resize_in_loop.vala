// Growing an array inside a loop: `resize` must rebind the local, so the local
// cannot live in a register (the -O2 hot-register pass used to keep the old
// pointer and read a freed block).
int grow_by_resize (int n) {
    int[] a = new int[0];
    for (int i = 0; i < n; i++) {
        a.resize (i + 1);
        a[i] = i * 3 + 7;
    }
    int s = 0;
    for (int i = 0; i < a.length; i++)
        s += a[i];
    return s;
}

int grow_doubling (int n) {
    int[] a = new int[0];
    int cap = 0;
    for (int i = 0; i < n; i++) {
        if (i == cap) {
            cap = cap == 0 ? 4 : cap * 2;
            a.resize (cap);
        }
        a[i] = i + 1;
    }
    int s = 0;
    for (int i = 0; i < n; i++)
        s += a[i];
    return s;
}

void grow_to (ref int[] a, int n) {
    a.resize (n);
}

int grow_by_helper (int n) {
    int[] a = new int[0];
    for (int i = 0; i < n; i++) {
        grow_to (ref a, i + 1);
        a[i] = 2;
    }
    return a.length;
}

int shrink_and_check (int n) {
    uint8[] b = new uint8[n];
    for (int i = 0; i < n; i++)
        b[i] = (uint8) i;
    int before = b.length;
    b.resize (n / 2);
    int after = b.length;
    int s = 0;
    for (int i = 0; i < b.length; i++)
        s += b[i];
    print (@"shrink $before -> $after sum=$s\n");
    return after;
}

int main () {
    print (@"resize=$((int) grow_by_resize (40))\n");
    print (@"doubling=$((int) grow_doubling (100))\n");
    print (@"helper=$((int) grow_by_helper (7))\n");
    grow_by_resize (5);
    shrink_and_check (20);
    return 0;
}
