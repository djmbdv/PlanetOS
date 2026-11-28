// A pointer into a row of a 2-D array has to alias the row: writes through it
// must land in the array, not in a copy of the row's tail.
#include <stdio.h>

static unsigned char grid[3][8];

static void fill_index(int row, unsigned char base) {
    unsigned char *dest;
    int i;
    dest = grid[row] + 2;
    for (i = 0; i < 3; i++) {
        dest[i] = (unsigned char) (base + i);
    }
}

static void fill_post(int row, unsigned char base) {
    unsigned char *dest = grid[row] + 4;
    int i;
    for (i = 0; i < 3; i++) {
        *dest++ = (unsigned char) (base + i);
    }
}

int main(void) {
    int r;
    int c;

    fill_index(1, 10);
    fill_post(2, 20);
    for (r = 0; r < 3; r++) {
        for (c = 0; c < 8; c++) {
            printf("%d ", grid[r][c]);
        }
        printf("\n");
    }
    return 0;
}
