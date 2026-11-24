#include <stdio.h>

int main(void) {
    int arr[6] = {10, 20, 30, 40, 50, 60};
    int *p = arr;
    int *end = arr;
    end += 6;
    int sum = 0;

    while (p < end) {
        sum += *p;
        p++;
    }

    p = 2 + arr;
    int *q = arr;
    q += 2;
    int eq1 = (p == q);
    int val = *(1 + p);
    int diff = (int)(end - p);

    printf("sum=%d eq1=%d val=%d diff=%d\n", sum, eq1, val, diff);
    return 0;
}
