#include <stdio.h>
#include <stdint.h>

typedef struct __attribute__((packed)) {
    uint8_t tag;
    uint32_t val;
} PackedItem;

typedef struct {
    int x;
    int y;
} Point;

static __attribute__((unused)) int unused_helper (int a) {
    return a + 1;
}

__extension__ static int ext_val = 42;

static Point make_point (int x, int y) {
    return (Point){ .y = y, .x = x };
}

static int sum_point (Point p) {
    return p.x * 10 + p.y;
}

int main (void) {
    PackedItem pi = { .val = 0x12345678u, .tag = 7 };
    Point p1 = make_point (3, 5);
    Point p2 = (Point){ 4, 9 };
    int arr_sum = ((int[]){ 10, 20, 30 })[1];

    int cond = 1;
    int exp_v = __builtin_expect (cond, 1) ? 100 : 0;
    int ctz32 = __builtin_ctz (0x10u);
    int ctz64 = __builtin_ctzll (0x100000000ULL);
    int clz32 = __builtin_clz (1u);
    int pop32 = __builtin_popcount (0x55u);
    uint32_t bs32 = __builtin_bswap32 (0x12345678u);
    double hf1 = 0x1.8p-1;
    double hf2 = 0x1.08p4;

    printf ("pi=%u,%u p1=%d p2=%d arr=%d exp=%d ext=%d\n",
            (unsigned)pi.tag, (unsigned)pi.val,
            sum_point (p1), sum_point (p2), arr_sum, exp_v, ext_val);
    printf ("bits=%d,%d,%d,%d,%08x hf=%.2f,%.1f\n", ctz32, ctz64, clz32, pop32, (unsigned)bs32, hf1, hf2);
    return 0;
}
