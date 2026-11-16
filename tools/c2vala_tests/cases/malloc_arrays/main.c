// Memory model: malloc'd buffers become GC-owned Vala arrays.
#include <stdio.h>
#include <stdlib.h>

int *make_table(int n) {
    int *t = malloc(n * sizeof(int));
    int i;
    for (i = 0; i < n; i++) {
        t[i] = i * i;
    }
    return t;
}

int sum_all(const int *t, int n) {
    int total = 0;
    int i;
    for (i = 0; i < n; i++) {
        total = total + t[i];
    }
    return total;
}

int main(void) {
    int n = 8;
    int *table;
    char *buf;
    int i;

    table = make_table(n);
    printf("sum=%d\n", sum_all(table, n));
    printf("last=%d\n", table[n - 1]);
    free(table);

    buf = malloc(8);
    for (i = 0; i < 8; i++) {
        buf[i] = 'A' + i;
    }
    printf("buf=%c%c%c\n", (int) buf[0], (int) buf[3], (int) buf[7]);
    free(buf);
    return 0;
}