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

    public class Keyboard : Object {
        private const int KB_BUF = 0x106100;
        private const int KB_HEAD = 0x106140;
        private const int KB_TAIL = 0x106148;

        public static void init () {
            mmio_write32 (KB_HEAD, 0);
            mmio_write32 (KB_TAIL, 0);
            Hal.set_idt_gate_dpl (33, addr_isr_irq1 (), 0);
        }

        public static int poll_scancode () {
            int head = mmio_read32 (KB_HEAD);
            int tail = mmio_read32 (KB_TAIL);
            if (head == tail)
                return -1;
            int addr = KB_BUF + (tail & 63);
            int v = (mmio_read32 (addr & ~3) >> ((addr & 3) * 8)) & 0xFF;
            mmio_write32 (KB_TAIL, (tail + 1) & 63);
            return v;
        }

        public static int scancode_to_ascii (int sc) {
            if (sc == 0x1C) return '\n';
            if (sc == 0x39) return ' ';
            if (sc == 0x0E) return 8;
            if (sc >= 0x02 && sc <= 0x0A) return '1' + (sc - 0x02);
            if (sc == 0x0B) return '0';
            if (sc == 0x1E) return 'a';
            if (sc == 0x30) return 'b';
            if (sc == 0x2E) return 'c';
            if (sc == 0x20) return 'd';
            if (sc == 0x12) return 'e';
            if (sc == 0x21) return 'f';
            if (sc == 0x22) return 'g';
            if (sc == 0x23) return 'h';
            if (sc == 0x17) return 'i';
            if (sc == 0x24) return 'j';
            if (sc == 0x25) return 'k';
            if (sc == 0x26) return 'l';
            if (sc == 0x32) return 'm';
            if (sc == 0x31) return 'n';
            if (sc == 0x18) return 'o';
            if (sc == 0x19) return 'p';
            if (sc == 0x10) return 'q';
            if (sc == 0x13) return 'r';
            if (sc == 0x1F) return 's';
            if (sc == 0x14) return 't';
            if (sc == 0x16) return 'u';
            if (sc == 0x2F) return 'v';
            if (sc == 0x11) return 'w';
            if (sc == 0x2D) return 'x';
            if (sc == 0x15) return 'y';
            if (sc == 0x2C) return 'z';
            if (sc == 0x34) return '.';
            if (sc == 0x0C) return '-';
            if (sc == 0x35) return '/';
            return 0;
        }
    }
}
