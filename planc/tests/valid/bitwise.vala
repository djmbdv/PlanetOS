int main() {
    int a = 12;   /* 1100 */
    int b = 10;   /* 1010 */
    int c = a & b;            /* 8  */
    int d = a | b;            /* 14 */
    int e = a ^ b;            /* 6  */
    int f = (1 << 4) >> 2;    /* 4  */
    int g = (~0) & 7;         /* 7  */

    /* Precedence: << binds tighter than &, & tighter than ^, ^ tighter than | */
    int p = 1 | 2 ^ 3 & 1 << 1;  /* 1 | (2 ^ (3 & 2)) = 1 | (2 ^ 2) = 1 */

    return c + d + e + f + g + p; /* 8+14+6+4+7+1 = 40 */
}
