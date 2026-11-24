#include <stdio.h>

typedef int (*bin_op)(int, int);

static int f01(int a, int b) { return a + b; }
static int f02(int a, int b) { return a - b; }
static int f03(int a, int b) { return a * b; }
static int f04(int a, int b) { return a + b + 1; }
static int f05(int a, int b) { return a + b + 2; }
static int f06(int a, int b) { return a + b + 3; }
static int f07(int a, int b) { return a + b + 4; }
static int f08(int a, int b) { return a + b + 5; }
static int f09(int a, int b) { return a + b + 6; }
static int f10(int a, int b) { return a + b + 7; }
static int f11(int a, int b) { return a + b + 8; }
static int f12(int a, int b) { return a + b + 9; }
static int f13(int a, int b) { return a + b + 10; }
static int f14(int a, int b) { return a + b + 11; }
static int f15(int a, int b) { return a + b + 12; }
static int f16(int a, int b) { return a + b + 13; }
static int f17(int a, int b) { return a + b + 14; }

static int apply(bin_op op, int a, int b) {
    return op(a, b);
}

int main(void) {
    int sum = 0;
    sum += apply(f01, 1, 2);
    sum += apply(f02, 5, 2);
    sum += apply(f03, 2, 3);
    sum += f04(1, 1) + f05(1, 1) + f06(1, 1) + f07(1, 1);
    sum += f08(1, 1) + f09(1, 1) + f10(1, 1) + f11(1, 1);
    sum += f12(1, 1) + f13(1, 1) + f14(1, 1) + f15(1, 1);
    sum += f16(1, 1) + f17(1, 1);
    printf("sum=%d\n", sum);
    return 0;
}
