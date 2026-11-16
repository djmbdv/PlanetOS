// PlanetOS syscall dispatcher (int 0x80, DPL=3) and freestanding syscall stubs.

using Planet.Rt;

namespace Planet.Kernel {

    public int syscall_dispatch (int num, int a0, int a1) {
        if (num == 1) {
            __planet_console_write (a0, a1);
            return a1;
        }
        if (num == 2) {
            return Hal.ticks ();
        }
        if (num == 3) {
            return Pmm.alloc_frame ();
        }
        if (num == 4) {
            Pmm.free_frame (a0);
            return 0;
        }
        return -1;
    }

    [AsmBody(@"
        # int 0x80 entry: rax=num, rdi=a0, rsi=a1 -> returns in rax
        push %rcx
        push %rdx
        push %rsi
        push %rdi
        push %r8
        push %r9
        push %r10
        push %r11
        mov %rsi, %rdx
        mov %rdi, %rsi
        mov %rax, %rdi
        call syscall_dispatch
        pop %r11
        pop %r10
        pop %r9
        pop %r8
        pop %rdi
        pop %rsi
        pop %rdx
        pop %rcx
        iretq
    ")]
    public extern void isr_syscall ();

    [AsmBody(@"
        lea isr_syscall(%rip), %rax
        ret
    ")]
    public extern int addr_isr_syscall ();

    [AsmBody(@"
        # sys_call2(num in rdi, a0 in rsi, a1 in rdx) -> int 0x80
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        int $0x80
        ret
    ")]
    public extern int invoke_syscall (int num, int a0, int a1);

    public class Syscalls : Object {
        public static void init () {
            Hal.set_idt_gate_dpl (0x80, addr_isr_syscall (), 1);
        }
    }
}
