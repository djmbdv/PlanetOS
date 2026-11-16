// PlanetOS syscall dispatcher (int 0x80, DPL=3) covering console, memory,
// timer, keyboard, and XFS file I/O for the language runtime.

using Planet.Rt;

namespace Planet.Kernel {

    // Simple kernel FD table (16 slots stored at 0x107000, 32 bytes each:
    // +0 in_use, +8 ino, +16 size, +24 pos)
    private const int FD_TABLE_ADDR = 0x107000;
    private const int MAX_FDS = 16;

    public int syscall_dispatch (int num, int a0, int a1, int a2) {
        if (num == 1) { // SYS_CONSOLE_WRITE(buf, len)
            __planet_console_write (a0, a1);
            return a1;
        }
        if (num == 2) { // SYS_TICKS()
            return Hal.ticks ();
        }
        if (num == 3) { // SYS_ALLOC_PAGE()
            return Pmm.alloc_frame ();
        }
        if (num == 4) { // SYS_FREE_PAGE(phys)
            Pmm.free_frame (a0);
            return 0;
        }
        if (num == 5) { // SYS_READ_KEY()
            return Keyboard.poll_scancode ();
        }
        if (num == 6) { // SYS_OPEN(name_ptr, name_len)
            int ino = Xfs.lookup_root (a0, a1);
            if (ino <= 0)
                return -1;
            int fsz = Xfs.file_size (ino);
            for (int fd = 3; fd < MAX_FDS; fd++) {
                int slot = FD_TABLE_ADDR + fd * 32;
                if (mmio_read64 (slot) == 0) {
                    mmio_write64 (slot + 0, 1);
                    mmio_write64 (slot + 8, ino);
                    mmio_write64 (slot + 16, fsz);
                    mmio_write64 (slot + 24, 0);
                    return fd;
                }
            }
            return -1;
        }
        if (num == 7) { // SYS_READ(fd, buf, len)
            if (a0 < 3 || a0 >= MAX_FDS)
                return -1;
            int slot = FD_TABLE_ADDR + a0 * 32;
            if (mmio_read64 (slot) == 0)
                return -1;
            int ino = mmio_read64 (slot + 8);
            int fsz = mmio_read64 (slot + 16);
            int pos = mmio_read64 (slot + 24);
            if (pos >= fsz)
                return 0;
            int n = Xfs.read_file (ino, a1, a2);
            if (n > 0)
                mmio_write64 (slot + 24, pos + n);
            return n;
        }
        if (num == 8) { // SYS_CLOSE(fd)
            if (a0 < 3 || a0 >= MAX_FDS)
                return -1;
            int slot = FD_TABLE_ADDR + a0 * 32;
            mmio_write64 (slot, 0);
            return 0;
        }
        if (num == 9) { // SYS_FILE_SIZE(fd)
            if (a0 < 3 || a0 >= MAX_FDS)
                return -1;
            int slot = FD_TABLE_ADDR + a0 * 32;
            if (mmio_read64 (slot) == 0)
                return -1;
            return mmio_read64 (slot + 16);
        }
        if (num == 10) { // SYS_YIELD()
            cpu_hlt ();
            return 0;
        }
        if (num == 11) { // SYS_EXIT(code)
            qemu_debug_exit (a0);
            return 0;
        }
        return -1;
    }

    [AsmBody(@"
        # int 0x80 entry: rax=num, rdi=a0, rsi=a1, rdx=a2 -> returns in rax
        push %rcx
        push %rdx
        push %rsi
        push %rdi
        push %r8
        push %r9
        push %r10
        push %r11
        mov %rdx, %rcx
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
        # invoke_syscall(num in rdi, a0 in rsi, a1 in rdx, a2 in rcx) -> int 0x80
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        int $0x80
        ret
    ")]
    public extern int invoke_syscall (int num, int a0, int a1, int a2);

    public class Syscalls : Object {
        public static void init () {
            for (int fd = 0; fd < MAX_FDS; fd++) {
                mmio_write64 (FD_TABLE_ADDR + fd * 32, 0);
            }
            Hal.set_idt_gate_dpl (0x80, addr_isr_syscall (), 1);
        }
    }
}
