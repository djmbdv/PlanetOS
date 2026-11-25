#include <stdio.h>

struct Padded {
    char a;
    int b;
};

static const int tbl[20] = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    11, 12, 13, 14, 15, 16, 17, 18, 19, 20
};

static int read_dp(int **pp) {
    return (*pp)[0] + (*pp)[1];
}

int main(void) {
    int local_arr[] = { 10, 20, 30, 40 };
    int zeros[64] = { 0 };
    int *p = local_arr;
    p += 1;
    int dp = read_dp(&p);
    int diff = (int)(p - local_arr);
    int sz_pad = (int)sizeof(struct Padded);
    int sz_us = (int)sizeof(unsigned short);
    int sz_uc = (int)sizeof(unsigned char);
    printf("tbl=%d,%d zeros=%d dp=%d diff=%d sz=%d,%d,%d\n",
           tbl[0], tbl[19], zeros[63], dp, diff, sz_pad, sz_us, sz_uc);
    return 0;
}
