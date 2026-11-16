// Tier 0: pure arithmetic, loops and calls. Must translate as-is.
int gcd (int a, int b) {
    while (b != 0) {
        int t = a % b;
        a = b;
        b = t;
    }
    return a;
}

double mean (double *values, int n) {
    double sum = 0.0;
    for (int i = 0; i < n; i++)
        sum = sum + values[i];
    return (n > 0) ? sum / (double) n : 0.0;
}

int clamp (int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}