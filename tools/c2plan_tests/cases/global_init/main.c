/* Global initializers that cannot be static data: arrays, string tables,
** pointers into another table, structs and function pointers. They are all
** filled in by c2vala_init_globals () before main runs. */

#include <stdio.h>

typedef struct Pair {
    int a;
    int b;
} Pair;

typedef int (*twice_fn) (int);

static const char version[] = "3.47.2";
static const unsigned char table[] = { 10, 11, 12, 13, 14 };
static const unsigned char *alt = &table[2];
static const char *banner = "hello";
static const char aPrefix[] = "-x0\000X0";
static const char spaces[] = "\011\012\015\040";
static char letters[8] = "abcdefg";
static int counter = 42;
static unsigned trace = 0;
static Pair pair = { 1, 2 };
static const int one = 1;
static twice_fn fn = 0;

static int twice (int x) {
    return x * 2;
}

static const char *tail (const char *z) {
    return &z[2];
}

int main () {
    fn = twice;
    printf ("%s %d %d %d %s %d %d %d\n", version, (int) alt[0], (int) table[4],
            counter, banner, pair.a, pair.b, one);
    printf ("%d %d %d %d %d\n", (int) aPrefix[0], (int) aPrefix[3],
            (int) aPrefix[4], (int) spaces[0], (int) spaces[3]);
    printf ("%d %d %d\n", (int) letters[2], fn (21), trace);
    printf ("%s %d\n", tail ("abcdef"), (int) tail ("abcdef")[0]);
    return 0;
}
