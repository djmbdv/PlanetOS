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
}