// Tier 2: function pointers (and callbacks through them).
typedef int (*cmp_fn) (int, int);

int apply (int a, int b, cmp_fn fn) {
    return fn (a, b);
}

int greater (int a, int b) {
    return (a > b) ? a : b;
}

int run (int a, int b) {
    return apply (a, b, greater);
}