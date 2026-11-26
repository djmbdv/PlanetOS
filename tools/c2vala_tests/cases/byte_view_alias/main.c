// A pointer derived from a struct view (`(unsigned char *)post + n`) must
// alias the view's buffer instead of copying the rest of it, and re-basing the
// view (`(post_t *)((unsigned char *)post + post->length + 4)`) must keep the
// same buffer too. Both are what a per-post picture decoder relies on.
#include <stdio.h>

typedef struct {
    unsigned char topdelta;
    unsigned char length;
} post_t;

static unsigned char data[32];

int main(void) {
    post_t *post = (post_t *) data;
    unsigned char *src;
    int i;

    for (i = 0; i < 32; i++) {
        data[i] = 0;
    }
    data[0] = 4;
    data[1] = 3;
    data[3] = 7;
    data[4] = 8;
    data[5] = 9;
    data[7] = 5;
    data[8] = 6;

    src = (unsigned char *) post + 3;
    printf("src=%d,%d,%d\n", src[0], src[1], src[2]);
    src[1] = 42;
    printf("data4=%d\n", data[4]);

    post = (post_t *) ((unsigned char *) post + post->length + 4);
    printf("next=%d,%d\n", post->topdelta, post->length);
    return 0;
}
