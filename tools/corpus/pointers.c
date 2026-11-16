// Tier 1: pointers and pointer arithmetic.
void swap (int *a, int *b) {
    int t = *a;
    *a = *b;
    *b = t;
}

int sum_ptr (const int *p, int n) {
    int s = 0;
    while (n-- > 0) {
        s += *p;
        p++;
    }
    return s;
}

void fill (char *dst, char v, int n) {
    for (int i = 0; i < n; i++)
        dst[i] = v;
}