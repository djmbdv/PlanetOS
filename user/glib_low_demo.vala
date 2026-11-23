// Test suite for GLib.Bit, GLib.Memory, GLib.Slice, and GLib.AtomicPointer.
using GLib;
using Planet;

[AsmBody(@"
    add $16, %rdi
    mov %rdi, %rax
    ret
")]
private extern int __test_arr_addr (uint8[] a);

int main (string[] args) {
    int fails = 0;
    int checks = 0;

    // 1. GLib.Bit
    checks++;
    if (Bit.nth_lsf (0x18UL, -1) != 3 || Bit.nth_lsf (0x18UL, 3) != 4 || Bit.nth_lsf (0x18UL, 4) != -1) {
        print ("glib_low: FAIL Bit.nth_lsf\n");
        fails++;
    }
    checks++;
    if (Bit.nth_msf (0x18UL, -1) != 4 || Bit.nth_msf (0x18UL, 4) != 3 || Bit.nth_msf (0x18UL, 3) != -1) {
        print ("glib_low: FAIL Bit.nth_msf\n");
        fails++;
    }
    checks++;
    if (Bit.storage (0UL) != 1 || Bit.storage (1UL) != 1 || Bit.storage (8UL) != 4 || Bit.storage (255UL) != 8) {
        print ("glib_low: FAIL Bit.storage\n");
        fails++;
    }

    // 2. GLib.Memory (AVX2 copy/set/move/cmp on uint8[] buffers so it runs on host & PlanetOS)
    var src_buf = new uint8[96];
    var dst_buf = new uint8[96];
    for (int i = 0; i < 96; i++)
        src_buf[i] = (uint8) (i + 1);
    int sa = __test_arr_addr (src_buf);
    int da = __test_arr_addr (dst_buf);

    Memory.copy (da, sa, 73);
    checks++;
    if (Memory.cmp (da, sa, 73) != 0 || dst_buf[72] != 73 || dst_buf[73] != 0) {
        print ("glib_low: FAIL Memory.copy/cmp\n");
        fails++;
    }
    Memory.set (da, 0xAA, 70);
    checks++;
    if (dst_buf[0] != 0xAA || dst_buf[69] != 0xAA || dst_buf[70] != 71) {
        print ("glib_low: FAIL Memory.set\n");
        fails++;
    }
    // Overlapping move
    Memory.move (sa + 8, sa, 32);
    checks++;
    if (src_buf[8] != 1 || src_buf[39] != 32) {
        print ("glib_low: FAIL Memory.move\n");
        fails++;
    }

    // 3. GLib.AtomicPointer
    var cell = new uint8[8];
    int ca = __test_arr_addr (cell);
    AtomicPointer.set (ca, 42);
    checks++;
    if (AtomicPointer.get (ca) != 42) {
        print ("glib_low: FAIL AtomicPointer.get/set\n");
        fails++;
    }
    checks++;
    if (!AtomicPointer.compare_and_exchange (ca, 42, 100) || AtomicPointer.compare_and_exchange (ca, 42, 200)) {
        print ("glib_low: FAIL AtomicPointer.cas\n");
        fails++;
    }
    checks++;
    if (AtomicPointer.add (ca, 23) != 100 || AtomicPointer.get (ca) != 123) {
        print ("glib_low: FAIL AtomicPointer.add\n");
        fails++;
    }
    checks++;
    if (AtomicPointer.bit_test_and_set (ca, 10) || !AtomicPointer.bit_test_and_reset (ca, 10) || AtomicPointer.get (ca) != 123) {
        print ("glib_low: FAIL AtomicPointer.bts/btr\n");
        fails++;
    }

    print (@"glib_low:summary checks=$checks failures=$fails\n");
    return (fails == 0) ? 0 : 1;
}
