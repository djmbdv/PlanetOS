// Pure-Vala GLib.AtomicPointer and GLib.Once (lock-prefixed x86-64 atomics) for PlanetOS.
using Planet;

namespace GLib {

    [AsmBody(@"
        # __atomic_get(addr in rdi) -> rax
        .byte 0x0f, 0xae, 0xf0
        mov (%rdi), %rax
        ret
    ")]
    private extern int __atomic_get (int addr);

    [AsmBody(@"
        # __atomic_set(addr in rdi, val in rsi)
        .byte 0x48, 0x87, 0x37
        ret
    ")]
    private extern void __atomic_set (int addr, int val);

    [AsmBody(@"
        # __atomic_cas(addr in rdi, oldv in rsi, newv in rdx) -> al (bool)
        mov %rsi, %rax
        .byte 0xf0, 0x48, 0x0f, 0xb1, 0x17
        .byte 0x0f, 0x94, 0xc0
        movzbl %al, %eax
        ret
    ")]
    private extern bool __atomic_cas (int addr, int oldv, int newv);

    [AsmBody(@"
        # __atomic_xchg(addr in rdi, val in rsi) -> rax (old)
        .byte 0x48, 0x87, 0x37
        mov %rsi, %rax
        ret
    ")]
    private extern int __atomic_xchg (int addr, int val);

    [AsmBody(@"
        # __atomic_xadd(addr in rdi, val in rsi) -> rax (old)
        .byte 0xf0, 0x48, 0x0f, 0xc1, 0x37
        mov %rsi, %rax
        ret
    ")]
    private extern int __atomic_xadd (int addr, int val);

    [AsmBody(@"
        # __atomic_bts(addr in rdi, bit in rsi) -> al (old bit)
        .byte 0xf0, 0x48, 0x0f, 0xab, 0x37
        .byte 0x0f, 0x92, 0xc0
        movzbl %al, %eax
        ret
    ")]
    private extern bool __atomic_bts (int addr, int bit);

    [AsmBody(@"
        # __atomic_btr(addr in rdi, bit in rsi) -> al (old bit)
        .byte 0xf0, 0x48, 0x0f, 0xb3, 0x37
        .byte 0x0f, 0x92, 0xc0
        movzbl %al, %eax
        ret
    ")]
    private extern bool __atomic_btr (int addr, int bit);

    /**
     * Lock-free atomic pointer/word operations (GLib.AtomicPointer).
     */
    public class AtomicPointer : Object {

        public static int get (int atomic_addr) {
            if (atomic_addr == 0)
                return 0;
            return __atomic_get (atomic_addr);
        }

        public static void set (int atomic_addr, int newval) {
            if (atomic_addr == 0)
                return;
            __atomic_set (atomic_addr, newval);
        }

        public static bool compare_and_exchange (int atomic_addr, int oldval, int newval) {
            if (atomic_addr == 0)
                return false;
            return __atomic_cas (atomic_addr, oldval, newval);
        }

        public static int exchange (int atomic_addr, int newval) {
            if (atomic_addr == 0)
                return 0;
            return __atomic_xchg (atomic_addr, newval);
        }

        public static int add (int atomic_addr, int val) {
            if (atomic_addr == 0)
                return 0;
            return __atomic_xadd (atomic_addr, val);
        }

        public static bool bit_test_and_set (int atomic_addr, int bit) {
            if (atomic_addr == 0 || bit < 0 || bit >= 64)
                return false;
            return __atomic_bts (atomic_addr, bit);
        }

        public static bool bit_test_and_reset (int atomic_addr, int bit) {
            if (atomic_addr == 0 || bit < 0 || bit >= 64)
                return false;
            return __atomic_btr (atomic_addr, bit);
        }
    }

    /**
     * Thread-safe one-time initialization (GLib.Once).
     */
    public class Once : Object {
        public static bool init_enter (int value_location_addr) {
            if (value_location_addr == 0)
                return false;
            while (true) {
                int v = AtomicPointer.get (value_location_addr);
                if (v == 0) {
                    if (AtomicPointer.compare_and_exchange (value_location_addr, 0, 1))
                        return true;
                } else if (v == 1) {
                    Sys.yield_cpu ();
                } else {
                    return false;
                }
            }
        }

        public static void init_leave (int value_location_addr, int result) {
            if (value_location_addr == 0 || result == 0 || result == 1)
                return;
            AtomicPointer.set (value_location_addr, result);
        }
    }

    [AsmBody(@"
        # __atomic_int_get(ref int in rdi) -> rax
        .byte 0x0f, 0xae, 0xf0
        mov (%rdi), %rax
        ret
    ")]
    private extern int __atomic_int_get (ref int atomic);

    [AsmBody(@"
        # __atomic_int_set(ref int in rdi, val in rsi)
        .byte 0x48, 0x87, 0x37
        ret
    ")]
    private extern void __atomic_int_set (ref int atomic, int newval);

    [AsmBody(@"
        # __atomic_int_xadd(ref int in rdi, val in rsi) -> rax (old)
        .byte 0xf0, 0x48, 0x0f, 0xc1, 0x37
        mov %rsi, %rax
        ret
    ")]
    private extern int __atomic_int_xadd (ref int atomic, int val);

    [AsmBody(@"
        # __atomic_int_cas(ref int in rdi, oldv in rsi, newv in rdx) -> al (bool)
        mov %rsi, %rax
        .byte 0xf0, 0x48, 0x0f, 0xb1, 0x17
        .byte 0x0f, 0x94, 0xc0
        movzbl %al, %eax
        ret
    ")]
    private extern bool __atomic_int_cas (ref int atomic, int oldval, int newval);

    /**
     * Thread-safe atomic integer operations (GLib.AtomicInt).
     */
    public class AtomicInt : Object {
        public static int get (ref int atomic) {
            return __atomic_int_get (ref atomic);
        }

        public static void set (ref int atomic, int newval) {
            __atomic_int_set (ref atomic, newval);
        }

        public static void inc (ref int atomic) {
            __atomic_int_xadd (ref atomic, 1);
        }

        public static bool dec_and_test (ref int atomic) {
            return __atomic_int_xadd (ref atomic, -1) == 1;
        }

        public static int add (ref int atomic, int val) {
            return __atomic_int_xadd (ref atomic, val);
        }

        public static int exchange_and_add (ref int atomic, int val) {
            return __atomic_int_xadd (ref atomic, val);
        }

        public static bool compare_and_exchange (ref int atomic, int oldval, int newval) {
            return __atomic_int_cas (ref atomic, oldval, newval);
        }
    }
}
