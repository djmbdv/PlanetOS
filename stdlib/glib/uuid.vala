// Pure-Vala GLib.Uuid (RFC 4122 v4) using WyRand + AVX2 hex formatting for PlanetOS.
using Planet;

namespace GLib {

    [AsmBody(@"
        # __uuid_rdtsc() -> rax (64-bit TSC)
        rdtsc
        shl $32, %rdx
        or %rdx, %rax
        ret
    ")]
    private extern uint64 __uuid_rdtsc ();

    [AsmBody(@"
        # __uuid_wyrand_mix(s in rdi) -> rax
        # Pure WyRand 64x64->128 mixer for lock-free thread-safe generation.
        mov %rdi, %rax
        .byte 0x48, 0xb9, 0xdb, 0x28, 0xb4, 0xa0, 0xd1, 0x7e, 0x03, 0xe7
        xor %rax, %rcx
        .byte 0x48, 0xf7, 0xe1
        xor %rdx, %rax
        ret
    ")]
    private extern uint64 __uuid_wyrand_mix (uint64 s);

    [AsmBody(@"
        # __uuid_arr_addr(a in rdi) -> rax
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __uuid_arr_addr (uint8[] a);

    [AsmBody(@"
        # __uuid_avx2_hex(dst32 in rdi, hi in rsi, lo in rdx, lut32 in rcx)
        # Converts 16 UUID bytes (lo:hi) into 32 lowercase hex ASCII bytes via AVX2.
        add $16, %rdi
        add $16, %rcx
        .byte 0xc4, 0xe1, 0xf9, 0x6e, 0xc6
        .byte 0xc4, 0xe3, 0xf9, 0x22, 0xc2, 0x01
        .byte 0xc4, 0xe2, 0x7d, 0x30, 0xc0
        .byte 0xb8, 0x0f, 0x0f, 0x0f, 0x0f
        .byte 0xc5, 0xf9, 0x6e, 0xe0
        .byte 0xc4, 0xe2, 0x7d, 0x58, 0xe4
        .byte 0xc5, 0xfd, 0xdb, 0xcc
        .byte 0xc5, 0xed, 0x71, 0xd0, 0x04
        .byte 0xc5, 0xed, 0xdb, 0xd4
        .byte 0xc5, 0xf5, 0x71, 0xf1, 0x08
        .byte 0xc5, 0xf5, 0xeb, 0xc2
        .byte 0xc5, 0xfe, 0x6f, 0x19
        .byte 0xc4, 0xe2, 0x65, 0x00, 0xc0
        .byte 0xc5, 0xfe, 0x7f, 0x07
        .byte 0xc5, 0xf8, 0x77
        ret
    ")]
    private extern void __uuid_avx2_hex (uint8[] dst32, uint64 hi, uint64 lo, uint8[] lut32);

    /**
     * UUID generation and validation (GLib.Uuid).
     */
    public class Uuid : Object {
        private static uint8[]? seed_state;
        private static uint8[]? hex_lut;

        private static uint8[] ensure_seed () {
            var cur = seed_state;
            if (cur != null)
                return cur;
            var st = new uint8[8];
            uint64 s = __uuid_rdtsc () ^ 0x123456789abcdef0;
            if (s == 0)
                s = 0x123456789abcdef0;
            for (int i = 0; i < 8; i++)
                st[i] = (uint8) ((s >> (i * 8)) & 0xFF);
            seed_state = st;
            return st;
        }

        private static uint8[] ensure_lut () {
            var cur = hex_lut;
            if (cur != null)
                return cur;
            var lut = new uint8[32];
            string hex = "0123456789abcdef";
            for (int i = 0; i < 16; i++) {
                uint8 c = (uint8) hex[i];
                lut[i] = c;
                lut[i + 16] = c;
            }
            hex_lut = lut;
            return lut;
        }

        private static bool is_hex_byte (uint8 c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        }

        /**
         * Generates a random version 4 UUID string (RFC 4122).
         */
        public static string string_random () {
            var st = ensure_seed ();
            var lut = ensure_lut ();
            int sa = __uuid_arr_addr (st);
            uint64 step = 0xa0761d6478bd642fUL;
            uint64 s1 = (uint64) AtomicPointer.add (sa, (int) step) + step;
            uint64 s2 = (uint64) AtomicPointer.add (sa, (int) step) + step;
            uint64 hi = __uuid_wyrand_mix (s1);
            uint64 lo = __uuid_wyrand_mix (s2);

            // Byte 6 high nibble = 0x4 (version 4), byte 8 top 2 bits = 0b10 (RFC 4122 variant).
            hi = (hi & 0xFF0FFFFFFFFFFFFF) | 0x0040000000000000;
            lo = (lo & 0xFFFFFFFFFFFFFF3F) | 0x0000000000000080;

            var hex32 = new uint8[32];
            __uuid_avx2_hex (hex32, hi, lo, lut);

            var out36 = new uint8[36];
            for (int i = 0; i < 8; i++) out36[i] = hex32[i];
            out36[8] = '-';
            for (int i = 0; i < 4; i++) out36[9 + i] = hex32[8 + i];
            out36[13] = '-';
            for (int i = 0; i < 4; i++) out36[14 + i] = hex32[12 + i];
            out36[18] = '-';
            for (int i = 0; i < 4; i++) out36[19 + i] = hex32[16 + i];
            out36[23] = '-';
            for (int i = 0; i < 12; i++) out36[24 + i] = hex32[20 + i];

            return __planc_host_bytes_to_str (out36, 36);
        }

        /**
         * Checks whether str is a valid 36-character UUID string.
         */
        public static bool string_is_valid (string str) {
            if (str.length != 36)
                return false;
            for (int i = 0; i < 36; i++) {
                uint8 c = (uint8) str[i];
                if (i == 8 || i == 13 || i == 18 || i == 23) {
                    if (c != '-')
                        return false;
                } else {
                    if (!is_hex_byte (c))
                        return false;
                }
            }
            return true;
        }
    }
}
