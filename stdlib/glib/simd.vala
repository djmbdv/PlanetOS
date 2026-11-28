// Safe wrappers around a few SIMD/special instructions.
//
// [AsmBody] is confined to stdlib/ and kernel/ sources, so user code can never
// emit machine code. These kernels are private: the public entry points are
// plain Vala that validate lengths and only then call a kernel whose
// preconditions they have already established. No pointer ever escapes.
namespace Simd {

    // 64-bit population count (POPCNT).
    public int popcount (uint64 v) {
        return __popcnt64 (v);
    }

    // Sum of every byte in `a`, 16 bytes at a time.
    public int sum_u8 (uint8[] a) {
        int n = a.length;
        int total = 0;
        int i = 0;
        while (i + 16 <= n) {
            total += __sum16 (a, i);
            i += 16;
        }
        while (i < n) {
            total += a[i];
            i++;
        }
        return total;
    }

    // Average of the bytes, rounded down. Bound-checked; 0 for an empty array.
    public int avg_u8 (uint8[] a) {
        if (a.length == 0)
            return 0;
        return sum_u8 (a) / a.length;
    }

    // popcnt rax, rdi  (F3 48 0F B8 C7)
    [AsmBody(@"
        .byte 0xF3, 0x48, 0x0F, 0xB8, 0xC7
        ret
    ")]
    private extern int __popcnt64 (uint64 v);

    // Sum of the 16 bytes at a[off]. Preconditions checked by sum_u8:
    // 0 <= off and off + 16 <= a.length.
    //   movdqu (%rdi), %xmm1
    //   pxor   %xmm2, %xmm2
    //   psadbw %xmm2, %xmm1      -> two 64-bit sums of 8 bytes
    //   movq   %xmm1, %rax
    //   psrldq $8, %xmm1
    //   movq   %xmm1, %rcx
    //   add    %rcx, %rax
    [AsmBody(@"
        add $16, %rdi
        add %rsi, %rdi
        .byte 0xF3, 0x0F, 0x6F, 0x0F
        .byte 0x66, 0x0F, 0xEF, 0xD2
        .byte 0x66, 0x0F, 0xF6, 0xCA
        .byte 0x66, 0x48, 0x0F, 0x7E, 0xC8
        .byte 0x66, 0x0F, 0x73, 0xD9, 0x08
        .byte 0x66, 0x48, 0x0F, 0x7E, 0xC9
        add %rcx, %rax
        ret
    ")]
    private extern int __sum16 (uint8[] a, int off);

    /**
     * Portable 4-lane 32-bit unsigned SIMD vector (Simd.u32x4).
     */
    public struct u32x4 {
        public uint32 x;
        public uint32 y;
        public uint32 z;
        public uint32 w;

        public static u32x4 make (uint32 vx = 0, uint32 vy = 0, uint32 vz = 0, uint32 vw = 0) {
            return u32x4 () { x = vx, y = vy, z = vz, w = vw };
        }

        public static u32x4 splat (uint32 v) {
            return u32x4 () { x = v, y = v, z = v, w = v };
        }

        public u32x4 add (u32x4 o) { return u32x4 () { x = x + o.x, y = y + o.y, z = z + o.z, w = w + o.w }; }
        public u32x4 sub (u32x4 o) { return u32x4 () { x = x - o.x, y = y - o.y, z = z - o.z, w = w - o.w }; }
        public u32x4 mul (u32x4 o) { return u32x4 () { x = x * o.x, y = y * o.y, z = z * o.z, w = w * o.w }; }
        public u32x4 bit_and (u32x4 o) { return u32x4 () { x = x & o.x, y = y & o.y, z = z & o.z, w = w & o.w }; }
        public u32x4 bit_or (u32x4 o) { return u32x4 () { x = x | o.x, y = y | o.y, z = z | o.z, w = w | o.w }; }
        public u32x4 bit_xor (u32x4 o) { return u32x4 () { x = x ^ o.x, y = y ^ o.y, z = z ^ o.z, w = w ^ o.w }; }
    }

    /**
     * Portable 4-lane 32-bit signed SIMD vector (Simd.i32x4).
     */
    public struct i32x4 {
        public int32 x;
        public int32 y;
        public int32 z;
        public int32 w;

        public static i32x4 make (int32 vx = 0, int32 vy = 0, int32 vz = 0, int32 vw = 0) {
            return i32x4 () { x = vx, y = vy, z = vz, w = vw };
        }

        public static i32x4 splat (int32 v) {
            return i32x4 () { x = v, y = v, z = v, w = v };
        }

        public i32x4 add (i32x4 o) { return i32x4 () { x = x + o.x, y = y + o.y, z = z + o.z, w = w + o.w }; }
        public i32x4 sub (i32x4 o) { return i32x4 () { x = x - o.x, y = y - o.y, z = z - o.z, w = w - o.w }; }
        public i32x4 mul (i32x4 o) { return i32x4 () { x = x * o.x, y = y * o.y, z = z * o.z, w = w * o.w }; }
    }

    /**
     * Portable 4-lane 32-bit float SIMD vector (Simd.f32x4).
     */
    public struct f32x4 {
        public float x;
        public float y;
        public float z;
        public float w;

        public static f32x4 make (float vx = 0.0f, float vy = 0.0f, float vz = 0.0f, float vw = 0.0f) {
            return f32x4 () { x = vx, y = vy, z = vz, w = vw };
        }

        public static f32x4 splat (float v) {
            return f32x4 () { x = v, y = v, z = v, w = v };
        }

        public f32x4 add (f32x4 o) { return f32x4 () { x = x + o.x, y = y + o.y, z = z + o.z, w = w + o.w }; }
        public f32x4 sub (f32x4 o) { return f32x4 () { x = x - o.x, y = y - o.y, z = z - o.z, w = w - o.w }; }
        public f32x4 mul (f32x4 o) { return f32x4 () { x = x * o.x, y = y * o.y, z = z * o.z, w = w * o.w }; }
        public float dot (f32x4 o) { return x * o.x + y * o.y + z * o.z + w * o.w; }
    }
}