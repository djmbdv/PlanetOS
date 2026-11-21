#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

enum mode {
    MODE_IN = 1,
    MODE_OUT = 2
};

struct Pair {
    int in;
    int out;
};

int lock(int base, int new) {
    int value = base + new;
    return value;
}

int main(void) {
    int arr[4] = { 10, 20, 30, 40 };
    int unsized[] = { 3, 5, 7 };
    struct Pair p = { 11, 22 };
    struct Pair pairs[2] = { { 1, 2 }, { 3, 4 } };
    printf("init=%d,%d,%d,%d\n", arr[2], unsized[1], p.out, pairs[1].in);

    int i = 0;
    int sum = 0;
    do {
        i++;
        if (i == 2)
            continue;
        sum += i;
    } while (i < 5);
    printf("do=%d,%d\n", i, sum);

    printf("kw=%d\n", lock(10, 5));

    char *buf = malloc(8);
    char *src = malloc(4);
    memset(buf, 'A', 4);
    src[0] = 'X';
    src[1] = 'Y';
    src[2] = 'Z';
    src[3] = 'W';
    memcpy(buf, src, 3);
    memmove(buf, src, 2);
    printf("mem=%c%c%c,%d\n", (int) buf[0], (int) buf[2], (int) buf[3], memcmp(buf, src, 2));
    buf = realloc(buf, 12);
    buf[8] = 'Q';
    printf("realloc=%c%c\n", (int) buf[0], (int) buf[8]);
    free(buf);
    free(src);

    uint32_t u32 = 0xFFFFFFFFU;
    uint64_t u64 = 1ULL << 40;
    uint8_t u8 = (uint8_t) 260;
    int8_t s8 = (int8_t) -5;
    printf("ints=%u,%llu,%u,%d\n", u32, (unsigned long long) u64, (unsigned int) u8, (int) s8);
    return 0;
}
