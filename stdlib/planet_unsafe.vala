// Internal raw-memory and function-pointer escapes (Phase A4).
// Available only to targets that explicitly link planet_unsafe.vala
// (runtime shims, .dlib/.plan loaders, SharedSurface, and low-level tests).
namespace Planet {

    [AsmBody(@"
        # __call_ptr2(fn in rdi, a0 in rsi, a1 in rdx) -> rax
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        .byte 0xff, 0xd0
        ret
    ")]
    private extern int __call_ptr2 (int fn_addr, int a0, int a1);

    [AsmBody(@"
        # __call_ptr3(fn in rdi, a0 in rsi, a1 in rdx, a2 in rcx) -> rax
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        .byte 0xff, 0xd0
        ret
    ")]
    private extern int __call_ptr3 (int fn_addr, int a0, int a1, int a2);

    [AsmBody(@"
        # __call_ptr_d1(fn in rdi, x in xmm0) -> xmm0
        .byte 0xff, 0xd7
        ret
    ")]
    private extern double __call_ptr_d1 (int fn_addr, double x);

    [AsmBody(@"
        # __call_ptr_d2(fn in rdi, a in xmm0, b in xmm1) -> xmm0
        .byte 0xff, 0xd7
        ret
    ")]
    private extern double __call_ptr_d2 (int fn_addr, double a, double b);

    [AsmBody(@"
        # __call_ptr_i2d(fn in rdi, a0 in rsi, a1 in rdx) -> xmm0
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        .byte 0xff, 0xd0
        ret
    ")]
    private extern double __call_ptr_i2d (int fn_addr, int a0, int a1);

    [AsmBody(@"
        # __sys_poke8(addr in rdi, val in rsi)
        mov %sil, (%rdi)
        ret
    ")]
    private extern void __sys_poke8 (int addr, int val);

    [AsmBody(@"
        # __sys_peek32(addr in rdi) -> eax
        mov (%rdi), %eax
        ret
    ")]
    private extern int __sys_peek32 (int addr);

    [AsmBody(@"
        # __sys_poke32(addr in rdi, val in esi)
        mov %esi, (%rdi)
        ret
    ")]
    private extern void __sys_poke32 (int addr, int val);

    [AsmBody(@"
        # __sys_peek64(addr in rdi) -> rax
        mov (%rdi), %rax
        ret
    ")]
    private extern int __sys_peek64 (int addr);

    [AsmBody(@"
        # __sys_mfence(): full memory fence
        .byte 0x0f, 0xae, 0xf0
        ret
    ")]
    private extern void __sys_mfence ();

    public sealed class Unsafe : Object {
        public static void poke8 (int addr, int val) {
            if (addr < Sys.USER_MIN_ADDR)
                return;
            __sys_poke8 (addr, val);
        }

        public static int peek32 (int addr) {
            if (addr < Sys.USER_MIN_ADDR || addr > Sys.USER_MAX_ADDR - 4)
                return 0;
            return __sys_peek32 (addr);
        }

        public static int peek64 (int addr) {
            if (addr < Sys.USER_MIN_ADDR || addr > Sys.USER_MAX_ADDR - 8)
                return 0;
            return __sys_peek64 (addr);
        }

        public static void mfence () {
            __sys_mfence ();
        }

        public static void poke32 (int addr, int val) {
            if (addr < Sys.USER_MIN_ADDR || addr > Sys.USER_MAX_ADDR - 4)
                return;
            __sys_poke32 (addr, val);
        }

        public static int call_ptr2 (int fn_addr, int a0, int a1) {
            if (fn_addr < Sys.USER_MIN_ADDR)
                return -1;
            return __call_ptr2 (fn_addr, a0, a1);
        }

        public static int call_ptr3 (int fn_addr, int a0, int a1, int a2) {
            if (fn_addr < Sys.USER_MIN_ADDR)
                return -1;
            return __call_ptr3 (fn_addr, a0, a1, a2);
        }

        public static double call_ptr_d1 (int fn_addr, double x) {
            if (fn_addr < Sys.USER_MIN_ADDR)
                return 0.0;
            return __call_ptr_d1 (fn_addr, x);
        }

        public static double call_ptr_d2 (int fn_addr, double a, double b) {
            if (fn_addr < Sys.USER_MIN_ADDR)
                return 0.0;
            return __call_ptr_d2 (fn_addr, a, b);
        }

        public static double call_ptr_i2d (int fn_addr, int a0, int a1) {
            if (fn_addr < Sys.USER_MIN_ADDR)
                return 0.0;
            return __call_ptr_i2d (fn_addr, a0, a1);
        }
    }
}
