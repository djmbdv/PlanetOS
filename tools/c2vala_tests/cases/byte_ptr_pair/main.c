// `p = buffer + i + j` keeps the buffer and an offset: copying the tail of the
// buffer would duplicate the screen on every patch, block or column. The same
// applies to memcpy/memmove, which take the offsets instead of sliced copies.
#include <string.h>
#include <stdio.h>

static unsigned char screen[340];
static unsigned char back[340];

int main(void) {
    unsigned char *dest;
    unsigned char *src;
    int y = 3;
    int x = 4;
    int i;

    for (i = 0; i < 340; i++) {
        screen[i] = 0;
        back[i] = (unsigned char) (i & 0x7f);
    }

    dest = screen + y * 20 + x;
    src = back + y * 20 + x;
    memcpy(dest, src, 5);
    printf("copy=%d,%d,%d\n", screen[64], screen[65], screen[68]);

    dest = screen + y * 20;
    src = dest + 2;
    memmove(dest, src, 3);
    printf("move=%d,%d,%d\n", screen[60], screen[61], screen[62]);

    dest = screen + 10;
    *dest = 200;
    dest[3] = 201;
    printf("write=%d,%d,%d\n", screen[10], screen[13], screen[9]);
    return 0;
}
