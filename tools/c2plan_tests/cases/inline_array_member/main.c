// `p->field[i]` on an inline array of a struct that lives in a byte buffer has
// to read that buffer directly. Building the array property materialises every
// element that is left in the buffer, so a flexible member (patch_t's
// columnofs, indexed once per column) copies the whole lump on each access.
#include <stdio.h>

typedef struct {
    short width;
    short height;
    int offsets[8];
} header_t;

static unsigned char blob[64];

int main(void) {
    header_t *h = (header_t *) blob;
    int i;
    int sum = 0;

    for (i = 0; i < 64; i++) {
        blob[i] = 0;
    }
    h->width = 4;
    h->height = 3;

    for (i = 0; i < 4; i++) {
        h->offsets[i] = i * 7;
    }

    for (i = 0; i < 4; i++) {
        sum += h->offsets[i];
    }
    printf("w=%d h=%d sum=%d off3=%d\n", (int) h->width, (int) h->height, sum, h->offsets[3]);
    return 0;
}
