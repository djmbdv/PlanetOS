// PS/2 Keyboard driver (IRQ1 / vector 33, scancode Set 1 ring buffer).

namespace Planet.Kernel {

    [AsmBody(@"
        push %rax
        push %rcx
        push %rdx
        mov $0x60, %dx
        in %dx, %al
        movzbl %al, %eax
        mov $0x106140, %rcx
        mov (%rcx), %edx
        and $63, %edx
        mov %al, 0x106100(%rdx)
        inc %edx
        and $63, %edx
        mov %edx, (%rcx)
        mov $0x20, %al
        out %al, $0x20
        pop %rdx
        pop %rcx
        pop %rax
        iretq
    ")]
    public extern void isr_irq1 ();

    [AsmBody(@"
        lea isr_irq1(%rip), %rax
        ret
    ")]
    public extern int addr_isr_irq1 ();

    [AsmBody(@"
    _ps2_drain:
        in $0x64, %al
        test $0x01, %al
        jz _ps2_done
        in $0x60, %al
        jmp _ps2_drain
    _ps2_done:
        ret
    ")]
    public extern void ps2_drain ();

    private int kb_shift = 0;
    private int kb_ext = 0;
    private int kb_ctrl = 0;
    private int kb_alt = 0;
    private int kb_super = 0;

    public class Keyboard : Object {
        public static void init () {
            ps2_drain ();
            kb_shift = 0;
            kb_ext = 0;
            kb_ctrl = 0;
            kb_alt = 0;
            kb_super = 0;
            mmio_write32 (KernelLayout.KB_HEAD, 0);
            mmio_write32 (KernelLayout.KB_TAIL, 0);
            Hal.set_idt_gate_dpl (33, addr_isr_irq1 (), 0);
        }

        public static int poll_scancode () {
            int head = mmio_read32 (KernelLayout.KB_HEAD);
            int tail = mmio_read32 (KernelLayout.KB_TAIL);
            if (head == tail)
                return -1;
            int addr = KernelLayout.KB_RING + (tail & 63);
            int v = (mmio_read32 (addr & ~3) >> ((addr & 3) * 8)) & 0xFF;
            mmio_write32 (KernelLayout.KB_TAIL, (tail + 1) & 63);
            return v;
        }

        // Modifier state for the last decoded key (bit0 shift, bit1 ctrl,
        // bit2 alt, bit3 super), read by SYS_KEY_MODS so userland can bind
        // Alt+Tab / Super+arrows without modifier-encoded key values.
        public static int modifiers () {
            int m = 0;
            if (kb_shift != 0) m = m | 1;
            if (kb_ctrl != 0) m = m | 2;
            if (kb_alt != 0) m = m | 4;
            if (kb_super != 0) m = m | 8;
            return m;
        }

        public static int scancode_to_ascii (int sc) {
            if (sc == 0xE0) { kb_ext = 1; return 0; }
            if (kb_ext != 0) {
                kb_ext = 0;
                if (sc == 0x5B) { kb_super = 1; return 0; }
                if (sc == 0xDB) { kb_super = 0; return 0; }
                if (sc == 0x38) { kb_alt = 1; return 0; }
                if (sc == 0xB8) { kb_alt = 0; return 0; }
                if ((sc & 0x80) != 0)
                    return 0;
                // Extended keys are reported as KEY_UP/DOWN/LEFT/RIGHT (0x81..0x84)
                if (sc == 0x48) return 0x81;
                if (sc == 0x50) return 0x82;
                if (sc == 0x4B) return 0x83;
                if (sc == 0x4D) return 0x84;
                if (sc == 0x47) return 0x85;
                if (sc == 0x4F) return 0x86;
                return 0;
            }
            if (sc == 0x2A || sc == 0x36) { kb_shift = 1; return 0; }
            if (sc == 0xAA || sc == 0xB6) { kb_shift = 0; return 0; }
            if (sc == 0x1D) { kb_ctrl = 1; return 0; }
            if (sc == 0x9D) { kb_ctrl = 0; return 0; }
            if (sc == 0x38) { kb_alt = 1; return 0; }
            if (sc == 0xB8) { kb_alt = 0; return 0; }
            if ((sc & 0x80) != 0) return 0;
            if (sc == 0x1C) return '\n';
            if (sc == 0x39) return ' ';
            if (sc == 0x0E) return 8;
            if (sc == 0x0F) return '\t';
            if (sc >= 0x02 && sc <= 0x0B) {
                if (kb_shift != 0) {
                    if (sc == 0x02) return '!';
                    if (sc == 0x03) return '@';
                    if (sc == 0x04) return '#';
                    if (sc == 0x05) return '$';
                    if (sc == 0x06) return '%';
                    if (sc == 0x07) return '^';
                    if (sc == 0x08) return '&';
                    if (sc == 0x09) return '*';
                    if (sc == 0x0A) return '(';
                    return ')';
                }
                return (sc == 0x0B) ? '0' : ('1' + (sc - 0x02));
            }
            int ch = 0;
            if (sc == 0x1E) ch = 'a';
            else if (sc == 0x30) ch = 'b';
            else if (sc == 0x2E) ch = 'c';
            else if (sc == 0x20) ch = 'd';
            else if (sc == 0x12) ch = 'e';
            else if (sc == 0x21) ch = 'f';
            else if (sc == 0x22) ch = 'g';
            else if (sc == 0x23) ch = 'h';
            else if (sc == 0x17) ch = 'i';
            else if (sc == 0x24) ch = 'j';
            else if (sc == 0x25) ch = 'k';
            else if (sc == 0x26) ch = 'l';
            else if (sc == 0x32) ch = 'm';
            else if (sc == 0x31) ch = 'n';
            else if (sc == 0x18) ch = 'o';
            else if (sc == 0x19) ch = 'p';
            else if (sc == 0x10) ch = 'q';
            else if (sc == 0x13) ch = 'r';
            else if (sc == 0x1F) ch = 's';
            else if (sc == 0x14) ch = 't';
            else if (sc == 0x16) ch = 'u';
            else if (sc == 0x2F) ch = 'v';
            else if (sc == 0x11) ch = 'w';
            else if (sc == 0x2D) ch = 'x';
            else if (sc == 0x15) ch = 'y';
            else if (sc == 0x2C) ch = 'z';
            if (ch != 0)
                return (kb_shift != 0) ? (ch - 32) : ch;
            if (sc == 0x0C) return (kb_shift != 0) ? '_' : '-';
            if (sc == 0x0D) return (kb_shift != 0) ? '+' : '=';
            if (sc == 0x1A) return (kb_shift != 0) ? '{' : '[';
            if (sc == 0x1B) return (kb_shift != 0) ? '}' : ']';
            if (sc == 0x27) return (kb_shift != 0) ? ':' : ';';
            if (sc == 0x28) return (kb_shift != 0) ? '"' : '\'';
            if (sc == 0x33) return (kb_shift != 0) ? '<' : ',';
            if (sc == 0x34) return (kb_shift != 0) ? '>' : '.';
            if (sc == 0x35) return (kb_shift != 0) ? '?' : '/';
            if (sc == 0x2B) return (kb_shift != 0) ? '|' : '\\';
            return 0;
        }
    }
}
