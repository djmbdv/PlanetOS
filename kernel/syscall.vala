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
            for (int i = 0; i < a1; i++) {
                int w = mmio_read32 ((a0 + i) & ~3);
                int b = (w >> (((a0 + i) & 3) * 8)) & 0xFF;
                Vga.write_byte (b);
            }
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
        if (num == 5) { // SYS_READ_KEY() -> ASCII char or -1
            while (true) {
                int sc = Keyboard.poll_scancode ();
                if (sc == -1)
                    break;
                int ch = Keyboard.scancode_to_ascii (sc);
                if (ch != 0)
                    return ch;
            }
            return serial_try_read ();
        }
        if (num == 6) { // SYS_OPEN(name_ptr, name_len)
            int rslot = Ramfs.find (a0, a1);
            int kind = 0;
            int id = 0;
            int fsz = 0;
            if (rslot >= 0) {
                kind = 2;
                id = rslot;
                fsz = Ramfs.file_size (rslot);
            } else {
                int ino = Xfs.lookup_root (a0, a1);
                if (ino <= 0)
                    return -1;
                kind = 1;
                id = ino;
                fsz = Xfs.file_size (ino);
            }
            for (int fd = 3; fd < MAX_FDS; fd++) {
                int slot = FD_TABLE_ADDR + fd * 32;
                if (mmio_read64 (slot) == 0) {
                    mmio_write64 (slot + 0, kind);
                    mmio_write64 (slot + 8, id);
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
            int kind = mmio_read64 (slot);
            if (kind == 0)
                return -1;
            int id = mmio_read64 (slot + 8);
            int fsz = mmio_read64 (slot + 16);
            int pos = mmio_read64 (slot + 24);
            if (pos >= fsz)
                return 0;
            int n = (kind == 2) ? Ramfs.read (id, pos, a1, a2) : Xfs.read_file (id, a1, a2);
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
            if (exec_depth > 0) {
                exec_depth = exec_depth - 1;
                exec_return_to_parent (a0);
            }
            qemu_debug_exit (a0);
            return 0;
        }
        if (num == 12) { // SYS_READDIR(buf, max_bytes)
            int n1 = Xfs.list_root (a0, a1);
            if (n1 < 0)
                n1 = 0;
            int n2 = Ramfs.list (a0 + n1, a1 - n1);
            return n1 + n2;
        }
        if (num == 13) { // SYS_EXEC(name_ptr, name_len)
            return ElfLoader.exec_from_xfs (a0, a1);
        }
        if (num == 14) { // SYS_CREATE(name_ptr, name_len) -> fd
            int rslot = Ramfs.create (a0, a1);
            if (rslot < 0)
                return -1;
            for (int fd = 3; fd < MAX_FDS; fd++) {
                int slot = FD_TABLE_ADDR + fd * 32;
                if (mmio_read64 (slot) == 0) {
                    mmio_write64 (slot + 0, 2);
                    mmio_write64 (slot + 8, rslot);
                    mmio_write64 (slot + 16, 0);
                    mmio_write64 (slot + 24, 0);
                    return fd;
                }
            }
            return -1;
        }
        if (num == 15) { // SYS_WRITE(fd, buf, len)
            if (a0 == 1 || a0 == 2) {
                __planet_console_write (a1, a2);
                for (int i = 0; i < a2; i++) {
                    int w = mmio_read32 ((a1 + i) & ~3);
                    int b = (w >> (((a1 + i) & 3) * 8)) & 0xFF;
                    Vga.write_byte (b);
                }
                return a2;
            }
            if (a0 < 3 || a0 >= MAX_FDS)
                return -1;
            int slot = FD_TABLE_ADDR + a0 * 32;
            if (mmio_read64 (slot) != 2)
                return -1;
            int rslot = mmio_read64 (slot + 8);
            int pos = mmio_read64 (slot + 24);
            int nw = Ramfs.write (rslot, pos, a1, a2);
            if (nw > 0) {
                mmio_write64 (slot + 24, pos + nw);
                mmio_write64 (slot + 16, Ramfs.file_size (rslot));
            }
            return nw;
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
