// A block-scope `extern` declaration names the global; it must not become a
// zero-initialised local that shadows it.
#include <stdio.h>

int counter = 3;
int table[4] = { 10, 20, 30, 40 };

static int read_counter(void) {
    extern int counter;
    counter = counter + 1;
    return counter;
}

static int read_table(void) {
    extern int table[];
    int sum = 0;
    int i;
    for (i = 0; i < 4; i++) {
        sum += table[i];
    }
    return sum;
}

int main(void) {
    int a = read_counter();
    int b = read_counter();
    int s = read_table();
    printf("a=%d b=%d global=%d sum=%d\n", a, b, counter, s);
    return 0;
}
