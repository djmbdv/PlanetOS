#include <stdio.h>
#include <stdint.h>

enum Color {
    RED = 1,
    GREEN = 2
};

struct Pair {
    int a;
    int b;
};

int main(void) {
    int x = 42;
    _Bool b1 = (_Bool)x;
    _Bool b2 = (_Bool)0;
    int bi = (int)(x == 42);

    enum Color col = GREEN;
    int ci = (int)col;
    enum Color col2 = (enum Color)1;

    char buf[16];
    buf[0] = 'X';
    buf[1] = 0;
    char ch = (char)buf[0];

    uint8_t raw[16];
    for (int i = 0; i < 16; i++) raw[i] = 0;
    uint8_t *p = raw;
    p += 4;
    struct Pair *sp = (struct Pair *)p;
    sp->a = 123;
    sp->b = 456;

    uintptr_t a0 = (uintptr_t)raw;
    uintptr_t a1 = (uintptr_t)p;
    int off_bytes = (int)(a1 - a0);

    printf("b=%d,%d bi=%d col=%d,%d ch=%c sp=%d,%d off=%d\n",
           (int)b1, (int)b2, bi, ci, (int)col2, ch, sp->a, sp->b, off_bytes);
    return 0;
}
