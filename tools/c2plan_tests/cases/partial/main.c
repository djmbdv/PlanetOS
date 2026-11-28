// One function is translatable, the other is out of scope: with --report the
// translator must emit the first, skip the second and say so.
#include <stdio.h>

int square(int n) {
    return n * n;
}

int jump_test(int x) {
    void *lbl = &&done;
    goto *lbl;
done:
    return x;
}