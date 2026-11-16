// Tier 0: pure arithmetic and loops, no pointers.
#include <stdio.h>

int gcd(int a, int b) {
    while (b != 0) {
        int t = a % b;
        a = b;
        b = t;
    }
    return a;
}

int collatz_steps(int n) {
    int steps = 0;
    while (n != 1) {
        if (n % 2 == 0) {
            n = n / 2;
        } else {
            n = 3 * n + 1;
        }
        steps = steps + 1;
    }
    return steps;
}

int main(void) {
    int i;
    printf("gcd=%d\n", gcd(1071, 462));
    for (i = 1; i <= 6; i++) {
        printf("collatz(%d)=%d\n", i, collatz_steps(i));
    }
    return 0;
}