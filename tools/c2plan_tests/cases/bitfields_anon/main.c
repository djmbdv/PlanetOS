#include <stdio.h>
#include <stdint.h>

#define MAKE_VAL(prefix, num) prefix##num
#define TO_STR(x) #x

struct Flags {
    unsigned int active : 1;
    unsigned int mode : 3;
    int32_t delta : 5;
    unsigned int : 0;
    uint32_t tag : 4;
    struct {
        int px;
        int py;
    };
};

int main(void) {
    int MAKE_VAL(item_, 7) = 77;
    printf("pp=%d,%s\n", item_7, TO_STR(hello_world));

    struct Flags f;
    f.active = 1;
    f.mode = 5;
    f.delta = -7;
    f.tag = 12;
    f.px = 100;
    f.py = 200;
    printf("bf=%u,%u,%d,%u,%d,%d\n",
           f.active, f.mode, (int) f.delta, f.tag, f.px, f.py);
    f.delta = 15;
    printf("bf2=%d,%u\n", (int) f.delta, f.mode);
    return 0;
}
