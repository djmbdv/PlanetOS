// Stage-0 (valac) compatibility helpers for Plan language features.
//
// `valac` ignores custom attributes such as [NoAlloc], [AlwaysInline],
// [CheckedOverflow], [Wrap], and [Arena], and natively supports `requires`,
// `ensures`, and `unowned`. This file provides fallback helpers for explicit
// Plan math/span utilities when building stage 0 with `valac`.

namespace Planc {

    public sealed class PlanMath : Object {
        public static uint32 wrapping_add_u32 (uint32 a, uint32 b) {
            return (uint32) ((uint64) a + (uint64) b);
        }

        public static uint32 wrapping_sub_u32 (uint32 a, uint32 b) {
            return (uint32) ((uint64) a - (uint64) b);
        }

        public static uint32 wrapping_mul_u32 (uint32 a, uint32 b) {
            return (uint32) ((uint64) a * (uint64) b);
        }

        public static int64 wrapping_add_i64 (int64 a, int64 b) {
            return (int64) ((uint64) a + (uint64) b);
        }

        public static int64 wrapping_sub_i64 (int64 a, int64 b) {
            return (int64) ((uint64) a - (uint64) b);
        }

        public static int64 wrapping_mul_i64 (int64 a, int64 b) {
            return (int64) ((uint64) a * (uint64) b);
        }
    }
}
