// Freestanding COM1 (0x3F8) serial driver and console/panic hooks for planetrt.

namespace Planet.Rt {

    [AsmBody(@"
        mov $0x3F9, %dx
        xor %eax, %eax
        out %al, %dx
        mov $0x3FB, %dx
        mov $0x80, %al
        out %al, %dx
        mov $0x3F8, %dx
        mov $0x01, %al
        out %al, %dx
        mov $0x3F9, %dx
        xor %eax, %eax
        out %al, %dx
        mov $0x3FB, %dx
        mov $0x03, %al
        out %al, %dx
        mov $0x3FA, %dx
        mov $0xC7, %al
        out %al, %dx
        mov $0x3FC, %dx
        mov $0x0B, %al
        out %al, %dx
        ret
    ")]
    public extern void serial_init ();

    [AsmBody(@"
        mov $0x3FD, %dx
        in %dx, %al
        and $0x01, %eax
        jz _ser_rx_empty
        mov $0x3F8, %dx
        xor %eax, %eax
        in %dx, %al
        ret
    _ser_rx_empty:
        mov $-1, %rax
        ret
    ")]
    public extern int serial_try_read ();

    [AsmBody(@"
        mov %rdi, %rcx
    _ser_wait:
        mov $0x3FD, %dx
        in %dx, %al
        and $0x20, %eax
        jz _ser_wait
        mov $0x3F8, %dx
        mov %rcx, %rax
        out %al, %dx
        ret
    ")]
    public extern void serial_putc (int c);

    [AsmBody(@"
        push %rbx
        push %r12
        push %r13
        mov %rdi, %r12
        mov %rsi, %r13
        xor %ebx, %ebx
    _cw_loop:
        cmp %r13, %rbx
        jge _cw_done
        movzbl (%r12,%rbx,1), %edi
        call serial_putc
        inc %rbx
        jmp _cw_loop
    _cw_done:
        pop %r13
        pop %r12
        pop %rbx
        ret
    ")]
    public extern void __planet_console_write (int buf_ptr, int len);

    [AsmBody(@"
        call __planet_console_write
        cli
    _panic_halt:
        hlt
        jmp _panic_halt
    ")]
    public extern void __planet_panic (int msg_ptr, int len);

    [AsmBody(@"
        mov $0xF4, %dx
        mov %rdi, %rax
        out %al, %dx
        ret
    ")]
    public extern void qemu_debug_exit (int code);
}
