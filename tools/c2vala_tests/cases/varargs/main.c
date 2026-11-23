#include <stdio.h>
#include <stdarg.h>

static int sum_ints(int n, ...)
{
    va_list ap;
    int s = 0;
    int i;
    va_start(ap, n);
    for (i = 0; i < n; i++) {
        s += va_arg(ap, int);
    }
    va_end(ap);
    return s;
}

static double sum_doubles(int n, ...)
{
    va_list ap;
    double s = 0.0;
    int i;
    va_start(ap, n);
    for (i = 0; i < n; i++) {
        s += va_arg(ap, double);
    }
    va_end(ap);
    return s;
}

int main(void)
{
    printf("sum_i=%d\n", sum_ints(4, 10, 20, 30, 40));
    printf("sum_d=%d\n", (int)sum_doubles(3, 1.5, 2.5, 3.0));
    return 0;
}
