// Tier 2: varargs.
#include <stdarg.h>

int sum_ints (int count, ...) {
    va_list ap;
    int total = 0;
    va_start (ap, count);
    for (int i = 0; i < count; i++)
        total += va_arg (ap, int);
    va_end (ap);
    return total;
}