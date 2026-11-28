#include <stdio.h>

enum Color { RED, GREEN, BLUE };

int main(void) {
    int a[5] = {10, 20, 30, 40, 50};
    int n = (int)(sizeof(a) / sizeof(a[0]));
    int eq1 = (sizeof(int) == sizeof(n));
    int eq2 = (sizeof(enum Color) == sizeof(int));
    int eq3 = (sizeof(int[4]) == 4 * sizeof(int));
    printf("n=%d eq=%d%d%d\n", n, eq1, eq2, eq3);
    return 0;
}

