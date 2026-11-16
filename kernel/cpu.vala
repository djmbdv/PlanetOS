// Bare-metal x86-64 HAL: memory access, CPUID, IDT, PIC 8259, PIT 100Hz timer.

using Planet.Rt;

namespace Planet.Kernel {

    [AsmBody(@"
        mov %rsi, (%rdi)
        ret
    ")]
    public extern void mmio_write64 (int addr, int val);

    [AsmBody(@"
        mov %si, (%rdi)
        ret
    ")]
    public extern void mmio_write16 (int addr, int val);

    [AsmBody(@"
        mov %sil, (%rdi)
        ret
    ")]
    public extern void mmio_write8 (int addr, int val);

    [AsmBody(@"
        mov (%rdi), %rax
        ret
    ")]
    public extern int mmio_read64 (int addr);

    [AsmBody(@"
        sti
        ret
    ")]
    public extern void cpu_sti ();

    [AsmBody(@"
        hlt
        ret
    ")]
    public extern void cpu_hlt ();

    [AsmBody(@"
        push %rbx
        xor %eax, %eax
        cpuid
        mov %ebx, (%rdi)
        mov %edx, 4(%rdi)
        mov %ecx, 8(%rdi)
        movb $0, 12(%rdi)
        pop %rbx
        ret
    ")]
    public extern void cpuid_vendor_raw (int buf_addr);

    [AsmBody(@"
        push %rax
        push %rdx
        mov $0x106000, %rax
        incq (%rax)
        mov $0x20, %al
        out %al, $0x20
        pop %rdx
        pop %rax
        iretq
    ")]
    public extern void isr_irq0 ();

    [AsmBody(@"
        # Default spurious/exception handler: send EOI if PIC and iretq
        push %rax
        mov $0x20, %al
        out %al, $0x20
        pop %rax
        iretq
    ")]
    public extern void isr_default ();

    [AsmBody(@"
        lea isr_irq0(%rip), %rax
        ret
    ")]
    public extern int addr_isr_irq0 ();

    [AsmBody(@"
        lea isr_default(%rip), %rax
        ret
    ")]
    public extern int addr_isr_default ();

    [AsmBody(@"
        lidt (%rdi)
        ret
    ")]
    public extern void load_idt (int idtr_addr);

    [AsmBody(@"
        # Remap 8259 PIC: IRQ 0..7 -> 32..39, IRQ 8..15 -> 40..47
        mov $0x11, %al
        out %al, $0x20
        out %al, $0xA0
        mov $0x20, %al
        out %al, $0x21
        mov $0x28, %al
        out %al, $0xA1
        mov $0x04, %al
        out %al, $0x21
        mov $0x02, %al
        out %al, $0xA1
        mov $0x01, %al
        out %al, $0x21
        out %al, $0xA1
        # Mask all except IRQ0 (timer) on master, mask all on slave
        mov $0xFE, %al
        out %al, $0x21
        mov $0xFF, %al
        out %al, $0xA1
        # Program PIT channel 0 to ~100 Hz (1193182 / 11932 = 100 Hz -> 0x2E9C)
        mov $0x36, %al
        out %al, $0x43
        mov $0x9C, %al
        out %al, $0x40
        mov $0x2E, %al
        out %al, $0x40
        ret
    ")]
    public extern void pic_pit_init ();

    public class Hal : Object {
        private const int IDT_BASE = 0x105000;
        private const int TICK_ADDR = 0x106000;
        private const int IDTR_ADDR = 0x106010;

        private static void set_idt_gate (int vec, int handler_addr) {
            int entry = IDT_BASE + vec * 16;
            mmio_write16 (entry + 0, handler_addr & 0xFFFF);
            mmio_write16 (entry + 2, 0x08);
            mmio_write8 (entry + 4, 0);
            mmio_write8 (entry + 5, 0x8E);
            mmio_write16 (entry + 6, (handler_addr >> 16) & 0xFFFF);
            mmio_write64 (entry + 8, (handler_addr >> 32) & 0xFFFFFFFF);
        }

        public static void init_interrupts () {
            mmio_write64 (TICK_ADDR, 0);
            int def_addr = addr_isr_default ();
            for (int v = 0; v < 256; v++) {
                set_idt_gate (v, def_addr);
            }
            set_idt_gate (32, addr_isr_irq0 ());

            // IDTR: limit = 4095 (256 * 16 - 1), base = IDT_BASE
            mmio_write16 (IDTR_ADDR + 0, 4095);
            mmio_write64 (IDTR_ADDR + 2, IDT_BASE);
            load_idt (IDTR_ADDR);
            pic_pit_init ();
            cpu_sti ();
        }

        public static int ticks () {
            return mmio_read64 (TICK_ADDR);
        }

        public static void print_cpu_vendor () {
            int buf = 0x106020;
            cpuid_vendor_raw (buf);
            print ("CPU: ");
            __planet_console_write (buf, 12);
            print ("\n");
        }
    }
}
