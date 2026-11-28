#include <stdio.h>
#include <stdlib.h>

int test_goto(int a, int b) {
    int res = 0;
    int i;
    for (i = 0; i < 4; i++) {
        if (a && i == 2) {
            res += 100;
            goto err1;
        }
        if (b && i == 1) {
            res += 200;
            goto err2;
        }
        res += 1;
    }
    return res;
err1:
    res += 10;
err2:
    res += 5;
    return res;
}

int main(void) {
    int acc = 0;
    int k;
    for (k = 0; k < 4; k++) {
        switch (k) {
        case 0:
            acc += 1;
        case 1:
            acc += 10;
            break;
        case 2:
            acc += 100;
            continue;
        default:
            acc += 1000;
            break;
        }
        acc += 2;
    }
    printf("sw=%d\n", acc);
    printf("gt=%d,%d,%d\n", test_goto(0, 0), test_goto(1, 0), test_goto(0, 1));

    int *arr = malloc(6 * sizeof(int));
    int *p = arr;
    int j;
    for (j = 0; j < 6; j++)
        arr[j] = (j + 1) * 10;
    *p = 99;
    p++;
    *p = 88;
    p += 2;
    printf("ptr=%d,%d,%d,%d\n", arr[0], arr[1], *p, *(p + 1));
    printf("diff=%d,%d\n", (int) (p - arr), p[2]);
    free(arr);
    return 0;
}
