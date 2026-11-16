// One function is translatable, the other is out of scope: with --report the
// translator must emit the first, skip the second and say so.
#include <stdio.h>
#include <stdarg.h>

int square(int n) {
    return n * n;
}

int sum_ints(int count, ...) {
    va_list ap;
    int total = 0;
    va_start(ap, count);
    for (int i = 0; i < count; i++) {
        total = total + va_arg(ap, int);
    }
    va_end(ap);
    return total;
}