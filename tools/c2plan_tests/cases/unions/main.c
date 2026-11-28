// Union support in c2vala + planc: overlapping fields at offset 0.
#include <stdio.h>
#include <stdint.h>

typedef union {
    int32_t i;
    float f;
    uint32_t u;
} word_t;

int main(void) {
    word_t w;
    w.f = 1.5f;
    printf("bits=0x%x\n", w.u);
    w.i = -42;
    printf("i=%d\n", w.i);
    return 0;
}
