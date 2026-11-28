#define _DEFAULT_SOURCE
#include <stdio.h>
#include <math.h>

int main(void) {
    double a = sqrt(2.0);
    double b = pow(2.0, 5.0);
    double c = sin(M_PI_2) + cos(M_PI);
    double d = atan2(1.0, 1.0);
    double e = hypot(3.0, 4.0);
    double f = cbrt(-27.0);
    double g = exp(0.0) + log(1.0) + log2(8.0) + log10(100.0);
    int ok = fabs(a - M_SQRT2) < 1e-12
          && fabs(b - 32.0) < 1e-12
          && fabs(c) < 1e-12
          && fabs(d - M_PI_4) < 1e-12
          && fabs(e - 5.0) < 1e-12
          && fabs(f + 3.0) < 1e-12
          && fabs(g - 6.0) < 1e-12;
    printf("ok=%d\n", ok);
    return ok ? 0 : 1;
}
