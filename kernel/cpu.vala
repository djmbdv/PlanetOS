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
        mov %edi, %edx
        in %dx, %al
        movzbl %al, %eax
        ret
    ")]
    public extern int port_in8 (int port);

    [AsmBody(@"
        mov %edi, %edx
        mov %esi, %eax
        out %al, %dx
        ret
    ")]
    public extern void port_out8 (int port, int val);

    [AsmBody(@"
        mov %edi, %edx
        in %dx, %eax
        ret
    ")]
    public extern int port_in32 (int port);

    [AsmBody(@"
        mov %edi, %edx
        mov %esi, %eax
        out %eax, %dx
        ret
    ")]
    public extern void port_out32 (int port, int val);

    [AsmBody(@"
        # rdmsr(msr in edi) -> edx:eax, returned in rax
        mov %edi, %ecx
        rdmsr
        shl $32, %rdx
        or %rdx, %rax
        ret
    ")]
    public extern int rdmsr64 (int msr);

    [AsmBody(@"
        # wrmsr(msr in edi, value in rsi)
        mov %edi, %ecx
        mov %rsi, %rax
        mov %rax, %rdx
        shr $32, %rdx
        wrmsr
        ret
    ")]
    public extern void wrmsr64 (int msr, int value);

    [AsmBody(@"
        sti
        ret
    ")]
    public extern void cpu_sti ();

    // Non-consuming check of COM1 Line Status Register (0x3FD) bit 0 (DR).
    [AsmBody(@"
        mov $0x3fd, %dx
        in %dx, %al
        and $1, %eax
        ret
    ")]
    public extern int serial_rx_ready ();

    // Saves RFLAGS and disables maskable interrupts (cli). Must be paired with
    // cpu_irq_restore(flags) so nested callers preserve the prior IF state.
    [AsmBody(@"
        pushfq
        pop %rax
        cli
        ret
    ")]
    public extern uint64 cpu_irq_save ();

    // Restores IF (RFLAGS bit 9 = 0x200) from the value returned by cpu_irq_save().
    [AsmBody(@"
        test $0x200, %rdi
        jz _cir_done
        sti
    _cir_done:
        ret
    ")]
    public extern void cpu_irq_restore (uint64 flags);

    [AsmBody(@"
        hlt
        ret
    ")]
    public extern void cpu_hlt ();

    [AsmBody(@"
        # Habilita SSE/SSE2 en x86-64 (requerido para float/double en userland y kernel):
        # - CR0.EM (bit 2) = 0: desactiva emulacion x87 para permitir instrucciones SSE
        # - CR0.MP (bit 1) = 1: monitor coprocessor
        # - CR4.OSFXSR (bit 9) = 1: habilita FXSAVE/FXRSTOR e instrucciones SSE
        # - CR4.OSXMMEXCPT (bit 10) = 1: habilita excepciones SIMD #XF
        # - Si CPUID.1:ECX[26] (XSAVE)=1: habilita CR4.OSXSAVE (bit 18) + XCR0(x87|SSE|AVX)
        mov %cr0, %rax
        and $0xFFFFFFFB, %eax
        or $0x02, %eax
        mov %rax, %cr0
        mov %cr4, %rax
        or $0x600, %eax
        mov %rax, %cr4
        push %rbx
        mov $1, %eax
        xor %ecx, %ecx
        cpuid
        test $0x04000000, %ecx
        jz .L_no_xsave
        mov %cr4, %rax
        or $0x40000, %eax
        mov %rax, %cr4
        xor %ecx, %ecx
        .byte 0x0f, 0x01, 0xd0
        or $0x07, %eax
        .byte 0x0f, 0x01, 0xd1
    .L_no_xsave:
        pop %rbx
        ret
    ")]
    public extern void cpu_enable_sse ();

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
        push %rbx
        mov $1, %eax
        xor %ecx, %ecx
        cpuid
        shr $19, %ecx
        and $1, %ecx
        mov %ecx, %eax
        pop %rbx
        ret
    ")]
    public extern int cpuid_has_sse41_raw ();

    [AsmBody(@"
        push %rbx
        xor %eax, %eax
        cpuid
        cmp $7, %eax
        jb .L_no_avx2
        mov $7, %eax
        xor %ecx, %ecx
        cpuid
        shr $5, %ebx
        and $1, %ebx
        mov %ebx, %eax
        pop %rbx
        ret
    .L_no_avx2:
        xor %eax, %eax
        pop %rbx
        ret
    ")]
    public extern int cpuid_has_avx2_raw ();

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

    // Exception entry stubs (vectors 0, 6, 13, 14). Vectors 13 (#GP) and 14 (#PF)
    // have a hardware error code at (%rsp) and faulting RIP at 8(%rsp); vectors
    // 0 (#DE) and 6 (#UD) have RIP directly at (%rsp). All align RSP to 16 bytes
    // before calling fault_dispatch(vec, err, rip, cr2), and halt if it returns.
    [AsmBody(@"
        # #DE (vector 0, no error code)
        mov $0, %edi
        xor %esi, %esi
        mov (%rsp), %rdx
        xor %ecx, %ecx
        and $-16, %rsp
        call fault_dispatch
        cli
        hlt
    ")]
    public extern void isr_de ();

    [AsmBody(@"
        # #UD (vector 6, no error code)
        mov $6, %edi
        xor %esi, %esi
        mov (%rsp), %rdx
        xor %ecx, %ecx
        and $-16, %rsp
        call fault_dispatch
        cli
        hlt
    ")]
    public extern void isr_ud ();

    [AsmBody(@"
        # #GP (vector 13, error code at [rsp])
        mov $13, %edi
        mov (%rsp), %rsi
        mov 8(%rsp), %rdx
        xor %ecx, %ecx
        and $-16, %rsp
        call fault_dispatch
        cli
        hlt
    ")]
    public extern void isr_gp ();

    [AsmBody(@"
        # #PF (vector 14, error code at [rsp], faulting address in CR2)
        mov $14, %edi
        mov (%rsp), %rsi
        mov 8(%rsp), %rdx
        mov %cr2, %rcx
        and $-16, %rsp
        call fault_dispatch
        cli
        hlt
    ")]
    public extern void isr_pf ();

    [AsmBody(@"
        lea isr_de(%rip), %rax
        ret
    ")]
    public extern int addr_isr_de ();

    [AsmBody(@"
        lea isr_ud(%rip), %rax
        ret
    ")]
    public extern int addr_isr_ud ();

    [AsmBody(@"
        lea isr_gp(%rip), %rax
        ret
    ")]
    public extern int addr_isr_gp ();

    [AsmBody(@"
        lea isr_pf(%rip), %rax
        ret
    ")]
    public extern int addr_isr_pf ();

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
        lgdt (%rdi)
        mov %si, %ax
        ltr %ax
        ret
    ")]
    public extern void load_gdt_tss (int gdtr_addr, int tss_sel);

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
        # Mask all except IRQ0 (timer) and IRQ1 (keyboard) on master, mask all on slave
        mov $0xFC, %al
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

    public sealed class Hal : Object {
        public static void set_tss_rsp0 (int rsp0) {
            mmio_write64 (KernelLayout.TSS_RSP0, rsp0);
        }

        public static int get_tss_rsp0 () {
            return mmio_read64 (KernelLayout.TSS_RSP0);
        }

        public static void init_gdt_tss () {
            // 64-bit GDT: 0x00=null, 0x08=kcode, 0x10=kdata, 0x18=udata, 0x20=ucode, 0x28=TSS(16B)
            mmio_write64 (KernelLayout.GDT + 0x00, 0);
            mmio_write64 (KernelLayout.GDT + 0x08, 0x00AF9A000000FFFF);
            mmio_write64 (KernelLayout.GDT + 0x10, 0x00AF92000000FFFF);
            mmio_write64 (KernelLayout.GDT + 0x18, 0x00AFF2000000FFFF);
            mmio_write64 (KernelLayout.GDT + 0x20, 0x00AFFA000000FFFF);
            for (int i = 0; i < 104; i += 8) {
                mmio_write64 (KernelLayout.TSS + i, 0);
            }
            mmio_write64 (KernelLayout.TSS_RSP0, KernelLayout.STACK_TOP);
            mmio_write16 (KernelLayout.TSS + 102, 104); // iomap_base
            int tss_lo = (103 & 0xFFFF)
                | ((KernelLayout.TSS & 0xFFFFFF) << 16)
                | (0x89 << 40)
                | (((KernelLayout.TSS >> 24) & 0xFF) << 56);
            int tss_hi = (KernelLayout.TSS >> 32) & 0xFFFFFFFF;
            mmio_write64 (KernelLayout.GDT + 0x28, tss_lo);
            mmio_write64 (KernelLayout.GDT + 0x30, tss_hi);
            mmio_write16 (KernelLayout.GDTR + 0, 55);
            mmio_write64 (KernelLayout.GDTR + 2, KernelLayout.GDT);
            load_gdt_tss (KernelLayout.GDTR, 0x28);
        }

        public static void set_idt_gate_dpl (int vec, int handler_addr, int dpl3) {
            int entry = KernelLayout.IDT + vec * 16;
            mmio_write16 (entry + 0, handler_addr & 0xFFFF);
            mmio_write16 (entry + 2, 0x08);
            mmio_write8 (entry + 4, 0);
            mmio_write8 (entry + 5, (dpl3 != 0) ? 0xEE : 0x8E);
            mmio_write16 (entry + 6, (handler_addr >> 16) & 0xFFFF);
            mmio_write64 (entry + 8, (handler_addr >> 32) & 0xFFFFFFFF);
        }

        private static void set_idt_gate (int vec, int handler_addr) {
            set_idt_gate_dpl (vec, handler_addr, 0);
        }

        // --- Local APIC -----------------------------------------------------
        // MSI-X delivers a message to the local APIC, so the kernel needs it
        // enabled even though the 8259 still handles the legacy IRQs (C2).
        private static int lapic_base = 0;

        public static bool lapic_init () {
            int apic_base = rdmsr64 (0x1B); // IA32_APIC_BASE
            // QEMU's -cpu max leaves x2APIC enabled, and in that mode the LAPIC
            // registers are MSR-only. This kernel drives them through MMIO, so
            // x2APIC has to go (bit 10) while the global enable stays (bit 11).
            int wanted = (apic_base | 0x800) & ~0x400;
            wrmsr64 (0x1B, wanted);
            apic_base = rdmsr64 (0x1B);
            int apic_phys = apic_base & 0xFFFFF000;
            if (apic_phys == 0)
                return false;
            Vmm.map_mmio_2m (apic_phys);
            lapic_base = apic_phys;
            // Spurious vector 0xFF, then accept every priority (TPR = 0).
            mmio_write32 (lapic_base + 0xF0, 0x1FF);
            mmio_write32 (lapic_base + 0x80, 0);
            return (mmio_read32 (lapic_base + 0xF0) & 0x100) != 0;
        }

        public static int lapic_id () {
            if (lapic_base == 0)
                return 0;
            return (mmio_read32 (lapic_base + 0x20) >> 24) & 0xFF;
        }

        public static void lapic_eoi () {
            if (lapic_base == 0)
                return;
            mmio_write32 (lapic_base + 0xB0, 0);
        }

        // Delivery diagnostics: a latched request sits in IRR, a taken interrupt
        // sits in ISR. `/ 32` and `* 16` pick the dword and the bit inside it.
        public static int lapic_irr (int vec) {
            if (lapic_base == 0)
                return 0;
            int word = mmio_read32 (lapic_base + 0x280 + (vec / 32) * 16);
            return (word >> (vec % 32)) & 1;
        }

        public static int lapic_isr (int vec) {
            if (lapic_base == 0)
                return 0;
            int word = mmio_read32 (lapic_base + 0x100 + (vec / 32) * 16);
            return (word >> (vec % 32)) & 1;
        }

        public static int lapic_tpr () {
            if (lapic_base == 0)
                return 0;
            return mmio_read32 (lapic_base + 0x80) & 0xFF;
        }

        public static void init_interrupts () {
            init_gdt_tss ();
            mmio_write64 (KernelLayout.TICK, 0);
            int def_addr = addr_isr_default ();
            for (int v = 0; v < 256; v++) {
                set_idt_gate (v, def_addr);
            }
            set_idt_gate (0, addr_isr_de ());
            set_idt_gate (6, addr_isr_ud ());
            set_idt_gate (13, addr_isr_gp ());
            set_idt_gate (14, addr_isr_pf ());
            set_idt_gate (32, addr_isr_irq0 ());

            // IDTR: limit = 4095 (256 * 16 - 1), base = KernelLayout.IDT
            mmio_write16 (KernelLayout.IDTR + 0, 4095);
            mmio_write64 (KernelLayout.IDTR + 2, KernelLayout.IDT);
            load_idt (KernelLayout.IDTR);
            pic_pit_init ();
            lapic_init ();
            cpu_sti ();
        }

        public static int ticks () {
            return mmio_read64 (KernelLayout.TICK);
        }

        public static void print_cpu_vendor () {
            int buf = KernelLayout.CPUID_BUF;
            cpuid_vendor_raw (buf);
            print ("CPU: ");
            __planet_console_write (buf, 12);
            print ("\n");
        }

        public static bool has_sse41 () {
            return cpuid_has_sse41_raw () != 0;
        }

        public static bool has_avx2 () {
            return cpuid_has_avx2_raw () != 0;
        }
    }
}
