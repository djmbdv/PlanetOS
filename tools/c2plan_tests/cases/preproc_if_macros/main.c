#include <stdio.h>
#include <string.h>

#define FLAGS ((1 << 3) | (1 << 1))
#define CHECK_BIT(x, b) (((x) & (1 << (b))) != 0)
#define STR_LINE(x) (__LINE__ > 0 ? 1 : 0)

#if (FLAGS & 8) != 0 && (FLAGS >> 1) == 5 && (10 % 3) == 1
#define COND_OK 1
#else
#define COND_OK 0
#endif

#if ('A' == 65) && (+1 ? 1 : 0) && ((3 ^ 1) == 2)
#define CHAR_TERN_OK 1
#else
#define CHAR_TERN_OK 0
#endif

int main(void) {
    int cmp1 = strncmp("ab", "abc", 5);
    int cmp2 = strncmp("abc", "ab", 5);
    int cmp3 = strncmp("abc", "abd", 2);
    unsigned int u = 10;
    int d = 3;
    u += d;
    u |= 16;
    u <<= 1;
    printf("cond=%d char_tern=%d line=%d\n", COND_OK, CHAR_TERN_OK, STR_LINE(0));
    printf("cmp=%d,%d,%d u=%u\n", cmp1 < 0 ? -1 : (cmp1 > 0 ? 1 : 0),
           cmp2 < 0 ? -1 : (cmp2 > 0 ? 1 : 0), cmp3, u);
    return 0;
}
