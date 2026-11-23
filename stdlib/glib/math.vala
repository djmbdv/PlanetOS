// Pure-Vala GLib.Math implementation (constants, IEEE-754 helpers, trig, exp/log).

namespace GLib {

    public class Math : Object {
        public const double E = 2.71828182845904523536;
        public const double PI = 3.14159265358979323846;
        public const double PI_2 = 1.57079632679489661923;
        public const double PI_4 = 0.78539816339744830962;
        public const double LN2 = 0.69314718055994530942;
        public const double LN10 = 2.30258509299404568402;
        public const double SQRT2 = 1.41421356237309504880;
        public const double LOG_2_BASE_10 = 0.30102999566398119521;

        [AsmBody(@"
            # movq %xmm0, %rax
            .byte 0x66, 0x48, 0x0f, 0x7e, 0xc0
            ret
        ")]
        private static extern uint64 dbl_bits (double x);

        [AsmBody(@"
            # movq %rdi, %xmm0
            .byte 0x66, 0x48, 0x0f, 0x6e, 0xc7
            ret
        ")]
        private static extern double bits_to_dbl (uint64 b);

        [AsmBody(@"
            # sqrtsd %xmm0, %xmm0
            .byte 0xf2, 0x0f, 0x51, 0xc0
            ret
        ")]
        private static extern double hw_sqrt (double x);

        [AsmBody(@"
            # sqrtss %xmm0, %xmm0
            .byte 0xf3, 0x0f, 0x51, 0xc0
            ret
        ")]
        private static extern float hw_sqrtf (float x);

        private static double nan_val () {
            return bits_to_dbl (0x7FF8000000000000UL);
        }

        private static double pos_inf () {
            return bits_to_dbl (0x7FF0000000000000UL);
        }

        private static double neg_inf () {
            return bits_to_dbl (0xFFF0000000000000UL);
        }

        // ---- IEEE-754 classification & bit manipulation ----

        public static int isnan (double value) {
            uint64 b = dbl_bits (value) & 0x7FFFFFFFFFFFFFFFUL;
            return (b > 0x7FF0000000000000UL) ? 1 : 0;
        }

        public static int isnanf (float value) {
            return isnan ((double) value);
        }

        public static int isinf (double value) {
            uint64 b = dbl_bits (value);
            if ((b & 0x7FFFFFFFFFFFFFFFUL) == 0x7FF0000000000000UL)
                return ((b >> 63) != 0) ? -1 : 1;
            return 0;
        }

        public static int isfinite (double value) {
            uint64 b = dbl_bits (value) & 0x7FFFFFFFFFFFFFFFUL;
            return (b < 0x7FF0000000000000UL) ? 1 : 0;
        }

        public static int isinff (float value) {
            return isinf ((double) value);
        }

        public static int finite (double value) {
            uint64 exp = (dbl_bits (value) >> 52) & 0x7FFUL;
            return (exp != 0x7FFUL) ? 1 : 0;
        }

        public static int finitef (float value) {
            return finite ((double) value);
        }

        public static int signbit (double value) {
            return (int) ((dbl_bits (value) >> 63) & 1UL);
        }

        public static double fabs (double x) {
            return bits_to_dbl (dbl_bits (x) & 0x7FFFFFFFFFFFFFFFUL);
        }

        public static float fabsf (float x) {
            return (float) fabs ((double) x);
        }

        public static double copysign (double x, double y) {
            uint64 mag = dbl_bits (x) & 0x7FFFFFFFFFFFFFFFUL;
            uint64 sgn = dbl_bits (y) & 0x8000000000000000UL;
            return bits_to_dbl (mag | sgn);
        }

        public static float copysignf (float x, float y) {
            return (float) copysign ((double) x, (double) y);
        }

        public static double nan (string tagb) {
            return nan_val ();
        }

        public static float nanf (string tagb) {
            return (float) nan_val ();
        }

        public static double frexp (double x, out int exponent) {
            uint64 b = dbl_bits (x);
            uint64 abs_b = b & 0x7FFFFFFFFFFFFFFFUL;
            if (abs_b == 0UL || (abs_b >> 52) == 0x7FFUL) {
                exponent = 0;
                return x;
            }
            int exp = (int) (abs_b >> 52);
            if (exp == 0) {
                // Subnormal: scale by 2^54 to normalize.
                x = x * 18014398509481984.0;
                b = dbl_bits (x);
                exp = (int) ((b & 0x7FFFFFFFFFFFFFFFUL) >> 52) - 54;
            }
            exponent = exp - 1022;
            uint64 mant = (b & 0x800FFFFFFFFFFFFFUL) | 0x3FE0000000000000UL;
            return bits_to_dbl (mant);
        }

        public static float frexpf (float x, out int exponent) {
            return (float) frexp ((double) x, out exponent);
        }

        public static double ldexp (double x, int exponent) {
            if (finite (x) == 0 || x == 0.0 || exponent == 0)
                return x;
            int e = 0;
            double m = frexp (x, out e);
            int target = e + exponent;
            if (target > 1024)
                return (signbit (x) != 0) ? neg_inf () : pos_inf ();
            if (target < -1074)
                return copysign (0.0, x);
            if (target >= -1021) {
                uint64 mb = dbl_bits (m) & 0x800FFFFFFFFFFFFFUL;
                uint64 eb = (uint64) (target + 1022);
                return bits_to_dbl (mb | (eb << 52));
            }
            // Subnormal range: scale by 2^-54 after placing in normal range.
            uint64 mb2 = dbl_bits (m) & 0x800FFFFFFFFFFFFFUL;
            uint64 eb2 = (uint64) (target + 54 + 1022);
            return bits_to_dbl (mb2 | (eb2 << 52)) * bits_to_dbl (0x3C90000000000000UL);
        }

        public static float ldexpf (float x, int exponent) {
            return (float) ldexp ((double) x, exponent);
        }

        // ---- Rounding, min/max, remainder ----

        public static double trunc (double x) {
            if (finite (x) == 0)
                return x;
            double ax = fabs (x);
            if (ax >= 4503599627370496.0) // 2^52: already integer
                return x;
            int64 i = (int64) x;
            double r = (double) i;
            return (r == 0.0) ? copysign (0.0, x) : r;
        }

        public static float truncf (float x) {
            return (float) trunc ((double) x);
        }

        public static double floor (double x) {
            if (finite (x) == 0)
                return x;
            double ax = fabs (x);
            if (ax >= 4503599627370496.0)
                return x;
            double t = trunc (x);
            if (t > x)
                t = t - 1.0;
            return (t == 0.0) ? copysign (0.0, x) : t;
        }

        public static float floorf (float x) {
            return (float) floor ((double) x);
        }

        public static double ceil (double x) {
            if (finite (x) == 0)
                return x;
            double ax = fabs (x);
            if (ax >= 4503599627370496.0)
                return x;
            double t = trunc (x);
            if (t < x)
                t = t + 1.0;
            return (t == 0.0) ? copysign (0.0, x) : t;
        }

        public static float ceilf (float x) {
            return (float) ceil ((double) x);
        }

        public static double round (double x) {
            if (finite (x) == 0)
                return x;
            double ax = fabs (x);
            if (ax >= 4503599627370496.0)
                return x;
            double t = floor (ax + 0.5);
            return copysign (t, x);
        }

        public static float roundf (float x) {
            return (float) round ((double) x);
        }

        public static double rint (double x) {
            if (finite (x) == 0)
                return x;
            double ax = fabs (x);
            if (ax >= 4503599627370496.0)
                return x;
            double fl = floor (ax);
            double frac = ax - fl;
            double res = fl;
            if (frac > 0.5)
                res = fl + 1.0;
            else if (frac == 0.5 && fmod (fl, 2.0) != 0.0)
                res = fl + 1.0;
            return copysign (res, x);
        }

        public static float rintf (float x) {
            return (float) rint ((double) x);
        }

        public static long lrint (double x) {
            return (long) rint (x);
        }

        public static long lround (double x) {
            return (long) round (x);
        }

        public static double modf (double x, out double iptr) {
            if (isnan (x) != 0) {
                iptr = x;
                return x;
            }
            if (isinf (x) != 0) {
                iptr = x;
                return copysign (0.0, x);
            }
            double t = trunc (x);
            iptr = t;
            return copysign (x - t, x);
        }

        public static float modff (float x, out float iptr) {
            double ip = 0.0;
            double r = modf ((double) x, out ip);
            iptr = (float) ip;
            return (float) r;
        }

        public static double fmod (double x, double y) {
            if (isnan (x) != 0 || isnan (y) != 0 || isinf (x) != 0 || y == 0.0)
                return nan_val ();
            if (isinf (y) != 0 || x == 0.0)
                return x;
            double q = trunc (x / y);
            double r = x - q * y;
            return (r == 0.0) ? copysign (0.0, x) : r;
        }

        public static float fmodf (float x, float y) {
            return (float) fmod ((double) x, (double) y);
        }

        public static double remainder (double x, double y) {
            if (isnan (x) != 0 || isnan (y) != 0 || isinf (x) != 0 || y == 0.0)
                return nan_val ();
            if (isinf (y) != 0)
                return x;
            double q = rint (x / y);
            double r = x - q * y;
            return (r == 0.0) ? copysign (0.0, x) : r;
        }

        public static double fmin (double x, double y) {
            if (isnan (x) != 0) return y;
            if (isnan (y) != 0) return x;
            return (x < y) ? x : y;
        }

        public static float fminf (float x, float y) {
            return (float) fmin ((double) x, (double) y);
        }

        public static double fmax (double x, double y) {
            if (isnan (x) != 0) return y;
            if (isnan (y) != 0) return x;
            return (x > y) ? x : y;
        }

        public static float fmaxf (float x, float y) {
            return (float) fmax ((double) x, (double) y);
        }

        public static double fdim (double x, double y) {
            if (isnan (x) != 0 || isnan (y) != 0)
                return nan_val ();
            return (x > y) ? (x - y) : 0.0;
        }

        // ---- Roots & hypotenuse ----

        public static double sqrt (double x) {
            return hw_sqrt (x);
        }

        public static float sqrtf (float x) {
            return hw_sqrtf (x);
        }

        public static double cbrt (double x) {
            if (finite (x) == 0 || x == 0.0)
                return x;
            double ax = fabs (x);
            int e = 0;
            double m = frexp (ax, out e);
            int rem = e % 3;
            if (rem < 0)
                rem = rem + 3;
            double y = ldexp (0.5 + 0.5 * m, (e - rem) / 3);
            if (y == 0.0)
                y = 1.0;
            for (int i = 0; i < 6; i++)
                y = (2.0 * y + ax / (y * y)) / 3.0;
            return copysign (y, x);
        }

        public static float cbrtf (float x) {
            return (float) cbrt ((double) x);
        }

        public static double hypot (double x, double y) {
            if (isinf (x) != 0 || isinf (y) != 0)
                return pos_inf ();
            if (isnan (x) != 0 || isnan (y) != 0)
                return nan_val ();
            double ax = fabs (x);
            double ay = fabs (y);
            if (ax < ay) {
                double t = ax;
                ax = ay;
                ay = t;
            }
            if (ax == 0.0)
                return 0.0;
            double r = ay / ax;
            return ax * hw_sqrt (1.0 + r * r);
        }

        public static float hypotf (float x, float y) {
            return (float) hypot ((double) x, (double) y);
        }

        // ---- Exponentials, logarithms, powers ----

        public static double exp (double x) {
            if (isnan (x) != 0)
                return x;
            if (x > 709.782712893384)
                return pos_inf ();
            if (x < -745.1332191019412)
                return 0.0;
            double k_d = rint (x / LN2);
            int k = (int) k_d;
            double ln2_hi = 0.6931471803691238;
            double ln2_lo = 1.9082149292705877e-10;
            double r = (x - k_d * ln2_hi) - k_d * ln2_lo;
            // Horner evaluation of Taylor series of exp(r) up to r^11 / 11! (no runtime division).
            double sum = 1.0 / 39916800.0;
            sum = sum * r + (1.0 / 3628800.0);
            sum = sum * r + (1.0 / 362880.0);
            sum = sum * r + (1.0 / 40320.0);
            sum = sum * r + (1.0 / 5040.0);
            sum = sum * r + (1.0 / 720.0);
            sum = sum * r + (1.0 / 120.0);
            sum = sum * r + (1.0 / 24.0);
            sum = sum * r + (1.0 / 6.0);
            sum = sum * r + 0.5;
            sum = sum * r + 1.0;
            sum = sum * r + 1.0;
            return ldexp (sum, k);
        }

        public static float expf (float x) {
            return (float) exp ((double) x);
        }

        public static double exp2 (double x) {
            return exp (x * LN2);
        }

        public static double exp10 (double x) {
            return exp (x * LN10);
        }

        public static double expm1 (double x) {
            if (fabs (x) < 1e-5)
                return x + 0.5 * x * x + (x * x * x) / 6.0;
            return exp (x) - 1.0;
        }

        public static double log (double x) {
            if (isnan (x) != 0)
                return x;
            if (x < 0.0)
                return nan_val ();
            if (x == 0.0)
                return neg_inf ();
            if (isinf (x) != 0)
                return pos_inf ();
            int e = 0;
            double m = frexp (x, out e);
            if (m < SQRT2 * 0.5) {
                m = m * 2.0;
                e = e - 1;
            }
            double u = (m - 1.0) / (m + 1.0);
            double u2 = u * u;
            double p = u;
            double sum = u;
            for (int k = 3; k <= 17; k += 2) {
                p = p * u2;
                sum = sum + p / (double) k;
            }
            return 2.0 * sum + ((double) e) * LN2;
        }

        public static float logf (float x) {
            return (float) log ((double) x);
        }

        public static double log2 (double x) {
            return log (x) / LN2;
        }

        public static double log10 (double x) {
            return log (x) / LN10;
        }

        public static double log1p (double x) {
            if (fabs (x) < 1e-5)
                return x - 0.5 * x * x + (x * x * x) / 3.0;
            return log (1.0 + x);
        }

        public static double pow (double x, double y) {
            if (y == 0.0)
                return 1.0;
            if (x == 1.0)
                return 1.0;
            if (isnan (x) != 0 || isnan (y) != 0)
                return nan_val ();
            if (x == 0.0) {
                bool odd = (trunc (y) == y) && (fmod (fabs (y), 2.0) == 1.0);
                if (y < 0.0)
                    return (signbit (x) != 0 && odd) ? neg_inf () : pos_inf ();
                return odd ? copysign (0.0, x) : 0.0;
            }
            if (x < 0.0) {
                double iy = trunc (y);
                if (iy != y)
                    return nan_val ();
                double res = exp (y * log (-x));
                int odd = (fmod (fabs (iy), 2.0) == 1.0) ? 1 : 0;
                return (odd != 0) ? -res : res;
            }
            return exp (y * log (x));
        }

        public static float powf (float x, float y) {
            return (float) pow ((double) x, (double) y);
        }

        // ---- Trigonometry & hyperbolic functions ----

        private static double poly_sin (double r) {
            double r2 = r * r;
            double p = -1.0 / 6227020800.0;
            p = p * r2 + (1.0 / 39916800.0);
            p = p * r2 - (1.0 / 362880.0);
            p = p * r2 + (1.0 / 5040.0);
            p = p * r2 - (1.0 / 120.0);
            p = p * r2 + (1.0 / 6.0);
            return r + (r * r2) * (-p);
        }

        private static double poly_cos (double r) {
            double r2 = r * r;
            double p = 1.0 / 479001600.0;
            p = p * r2 - (1.0 / 3628800.0);
            p = p * r2 + (1.0 / 40320.0);
            p = p * r2 - (1.0 / 720.0);
            p = p * r2 + (1.0 / 24.0);
            p = p * r2 - 0.5;
            return 1.0 + r2 * p;
        }

        private static double reduce_pi_2 (double x, out int quad) {
            double k_d = rint (x / PI_2);
            double qm = fmod (k_d, 4.0);
            if (qm < 0.0)
                qm = qm + 4.0;
            quad = ((int) qm) & 3;
            double pi2_hi = 1.57079632673412561417;
            double pi2_lo = 6.07710050650619224932e-11;
            return (x - k_d * pi2_hi) - k_d * pi2_lo;
        }

        public static double sin (double x) {
            if (finite (x) == 0)
                return nan_val ();
            int q = 0;
            double r = reduce_pi_2 (x, out q);
            if (q == 0) return poly_sin (r);
            if (q == 1) return poly_cos (r);
            if (q == 2) return -poly_sin (r);
            return -poly_cos (r);
        }

        public static float sinf (float x) {
            return (float) sin ((double) x);
        }

        public static double cos (double x) {
            if (finite (x) == 0)
                return nan_val ();
            int q = 0;
            double r = reduce_pi_2 (x, out q);
            if (q == 0) return poly_cos (r);
            if (q == 1) return -poly_sin (r);
            if (q == 2) return -poly_cos (r);
            return poly_sin (r);
        }

        public static float cosf (float x) {
            return (float) cos ((double) x);
        }

        public static void sincos (double x, out double sinx, out double cosx) {
            if (finite (x) == 0) {
                sinx = nan_val ();
                cosx = nan_val ();
                return;
            }
            int q = 0;
            double r = reduce_pi_2 (x, out q);
            double s = poly_sin (r);
            double c = poly_cos (r);
            if (q == 0) { sinx = s; cosx = c; }
            else if (q == 1) { sinx = c; cosx = -s; }
            else if (q == 2) { sinx = -s; cosx = -c; }
            else { sinx = -c; cosx = s; }
        }

        public static double tan (double x) {
            double s = 0.0;
            double c = 0.0;
            sincos (x, out s, out c);
            return s / c;
        }

        public static float tanf (float x) {
            return (float) tan ((double) x);
        }

        public static double atan (double x) {
            if (isnan (x) != 0)
                return x;
            bool neg = x < 0.0;
            double ax = neg ? -x : x;
            if (isinf (ax) != 0)
                return neg ? -PI_2 : PI_2;
            bool recip = false;
            if (ax > 1.0) {
                ax = 1.0 / ax;
                recip = true;
            }
            bool sixth = false;
            double sqrt3 = 1.73205080756887729353;
            double tan_pi12 = 0.26794919243112270647;
            if (ax > tan_pi12) {
                ax = (ax * sqrt3 - 1.0) / (sqrt3 + ax);
                sixth = true;
            }
            double x2 = ax * ax;
            double term = ax;
            double sum = ax;
            for (int k = 1; k <= 10; k++) {
                term = -term * x2;
                sum = sum + term / (double) (2 * k + 1);
            }
            if (sixth)
                sum = sum + (PI / 6.0);
            if (recip)
                sum = PI_2 - sum;
            return neg ? -sum : sum;
        }

        public static float atanf (float x) {
            return (float) atan ((double) x);
        }

        public static double atan2 (double y, double x) {
            if (isnan (y) != 0 || isnan (x) != 0)
                return nan_val ();
            int iy = isinf (y);
            int ix = isinf (x);
            if (iy != 0 && ix != 0) {
                double base_a = (ix > 0) ? PI_4 : (3.0 * PI_4);
                return (iy < 0) ? -base_a : base_a;
            }
            if (x > 0.0)
                return atan (y / x);
            if (x < 0.0) {
                if (y >= 0.0)
                    return atan (y / x) + PI;
                return atan (y / x) - PI;
            }
            if (y > 0.0) return PI_2;
            if (y < 0.0) return -PI_2;
            return 0.0;
        }

        public static float atan2f (float y, float x) {
            return (float) atan2 ((double) y, (double) x);
        }

        public static double asin (double x) {
            if (isnan (x) != 0 || x < -1.0 || x > 1.0)
                return nan_val ();
            if (x == 1.0) return PI_2;
            if (x == -1.0) return -PI_2;
            return atan2 (x, hw_sqrt (1.0 - x * x));
        }

        public static float asinf (float x) {
            return (float) asin ((double) x);
        }

        public static double acos (double x) {
            if (isnan (x) != 0 || x < -1.0 || x > 1.0)
                return nan_val ();
            return PI_2 - asin (x);
        }

        public static float acosf (float x) {
            return (float) acos ((double) x);
        }

        public static double sinh (double x) {
            if (fabs (x) < 1e-5)
                return x + (x * x * x) / 6.0;
            double ex = exp (x);
            return 0.5 * (ex - 1.0 / ex);
        }

        public static double cosh (double x) {
            double ex = exp (fabs (x));
            return 0.5 * (ex + 1.0 / ex);
        }

        public static double tanh (double x) {
            if (x > 20.0) return 1.0;
            if (x < -20.0) return -1.0;
            double e2x = exp (2.0 * x);
            return (e2x - 1.0) / (e2x + 1.0);
        }

        public static double asinh (double x) {
            return log (x + hw_sqrt (x * x + 1.0));
        }

        public static double acosh (double x) {
            if (x < 1.0)
                return nan_val ();
            return log (x + hw_sqrt (x * x - 1.0));
        }

        public static double atanh (double x) {
            if (x <= -1.0 || x >= 1.0)
                return (x == 1.0) ? pos_inf () : ((x == -1.0) ? neg_inf () : nan_val ());
            return 0.5 * log ((1.0 + x) / (1.0 - x));
        }
    }

}
