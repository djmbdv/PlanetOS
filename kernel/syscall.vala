// PlanetOS syscall dispatcher (int 0x80, DPL=3) covering console, memory,
// timer, keyboard, and XFS file I/O for the language runtime.

using Planet.Rt;

namespace Planet.Kernel {

    // Simple kernel FD table (16 slots stored at 0x107000, 32 bytes each:
    // +0 in_use, +8 ino, +16 size, +24 pos)
    private const int FD_TABLE_ADDR = 0x107000;
    private const int MAX_FDS = 16;
    private const int USER_LIMIT = 0x4000000; // 64 MiB, the PMM cap
    private const int MAX_PATH = 512;
    private const int MAX_XFER = 1048576;
    private int stdio_in_fd = -1;
    private int stdio_out_fd = -1;

    // Userland and the kernel share one address space, so every pointer that
    // arrives through int 0x80 is checked before the kernel dereferences it.
    private bool user_ok (int ptr, int len) {
        if (len < 0 || ptr < 0x1000 || len > MAX_XFER)
            return false;
        int end = ptr + len;
        if (end < ptr)
            return false;
        return end <= USER_LIMIT;
    }

    private bool path_ok (int ptr, int len) {
        return len > 0 && len <= MAX_PATH && user_ok (ptr, len);
    }

    private bool fd_ok (int fd) {
        return fd == -1 || (fd >= 3 && fd < MAX_FDS);
    }

    public int syscall_dispatch (int num, int a0, int a1, int a2, int a3) {
        if (num == 1) { // SYS_CONSOLE_WRITE(buf, len)
            if (!user_ok (a0, a1))
                return -1;
            if (stdio_out_fd >= 3 && stdio_out_fd < MAX_FDS) {
                int slot = FD_TABLE_ADDR + stdio_out_fd * 32;
                if (mmio_read64 (slot) == 2) {
                    int rslot = mmio_read64 (slot + 8);
                    int pos = mmio_read64 (slot + 24);
                    int nw = Ramfs.write (rslot, pos, a0, a1);
                    if (nw > 0) {
                        mmio_write64 (slot + 24, pos + nw);
                        mmio_write64 (slot + 16, Ramfs.file_size (rslot));
                    }
                    return nw;
                }
            }
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
        if (num == 3) { // SYS_ALLOC_PAGE(num_pages)
            if (a0 < 0 || a0 > 1024)
                return -1;
            int count = (a0 > 1) ? a0 : 1;
            int phys = (count > 1) ? Pmm.alloc_contiguous (count) : Pmm.alloc_frame ();
            if (phys != 0) {
                int ucr3 = Sched.current_cr3 ();
                if (ucr3 != 0) {
                    Vmm.map_user_range (ucr3, phys, count * 4096);
                }
            }
            return phys;
        }
        if (num == 4) { // SYS_FREE_PAGE(phys)
            Pmm.free_frame (a0);
            int ucr3 = Sched.current_cr3 ();
            if (ucr3 != 0) {
                Vmm.unmap_user_4k (ucr3, a0);
            }
            return 0;
        }
        if (num == 5) { // SYS_READ_KEY() -> ASCII char or -1
            if (stdio_in_fd >= 3 && stdio_in_fd < MAX_FDS) {
                int slot = FD_TABLE_ADDR + stdio_in_fd * 32;
                if (mmio_read64 (slot) == 2) {
                    int rslot = mmio_read64 (slot + 8);
                    int pos = mmio_read64 (slot + 24);
                    int bbuf = 0x106210;
                    int nr = Ramfs.read (rslot, pos, bbuf, 1);
                    if (nr <= 0)
                        return -2; // EOF
                    mmio_write64 (slot + 24, pos + 1);
                    return mmio_read32 (bbuf) & 0xFF;
                }
            }
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
            if (!path_ok (a0, a1))
                return -1;
            int id = -1;
            int kind = Vfs.resolve (a0, a1, out id);
            int fd_kind = 0;
            int fsz = 0;
            if (kind == Vfs.KIND_XFS) {
                fd_kind = 1;
                fsz = Xfs.file_size (id);
            } else if (kind == Vfs.KIND_FILE) {
                fd_kind = 2;
                fsz = Ramfs.file_size (id);
            } else {
                return -1;
            }
            for (int fd = 3; fd < MAX_FDS; fd++) {
                int slot = FD_TABLE_ADDR + fd * 32;
                if (mmio_read64 (slot) == 0) {
                    mmio_write64 (slot + 0, fd_kind);
                    mmio_write64 (slot + 8, id);
                    mmio_write64 (slot + 16, fsz);
                    mmio_write64 (slot + 24, 0);
                    return fd;
                }
            }
            return -1;
        }
        if (num == 7) { // SYS_READ(fd, buf, len)
            if (!user_ok (a1, a2))
                return -1;
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
            int n = (kind == 2) ? Ramfs.read (id, pos, a1, a2) : Xfs.read_file (id, pos, a1, a2);
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
            cpu_sti ();
            cpu_hlt ();
            return 0;
        }
        if (num == 11) { // SYS_EXIT(code)
            if (Sched.current_tid () > 0) {
                Sched.exit_current (a0);
            }
            if (exec_depth > 0) {
                exec_depth = exec_depth - 1;
                exec_return_to_parent (a0, 0x106200 + exec_depth * 32);
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
        if (num == 13) { // SYS_EXEC(name_ptr, name_len, cmdline_ptr)
            if (!path_ok (a0, a1) || (a2 != 0 && !user_ok (a2, 1)))
                return -1;
            return ElfLoader.exec_from_xfs (a0, a1, a2);
        }
        if (num == 14) { // SYS_CREATE(path_ptr, path_len) -> fd
            if (!path_ok (a0, a1))
                return -1;
            int base_ptr = 0;
            int base_len = 0;
            int parent = Vfs.resolve_parent (a0, a1, out base_ptr, out base_len);
            if (parent < -1 || Vfs.reserved_name (base_ptr, base_len))
                return -1;
            int rslot = Ramfs.create_in (parent, base_ptr, base_len, 1);
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
            if (!user_ok (a1, a2))
                return -1;
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
        if (num == 16) { // SYS_SPAWN(name_ptr, name_len, cmdline_ptr) -> tid
            if (!path_ok (a0, a1) || (a2 != 0 && !user_ok (a2, 1)))
                return -1;
            return ElfLoader.spawn_from_xfs (a0, a1, a2);
        }
        if (num == 17) { // SYS_WAIT(tid) -> exit_code
            return Sched.wait_tid (a0);
        }
        if (num == 18) { // SYS_PS(buf, max_bytes) -> bytes
            if (!user_ok (a0, a1))
                return -1;
            return Sched.list_tasks (a0, a1);
        }
        if (num == 19) { // SYS_SET_STDIO(in_fd, out_fd)
            if (!fd_ok (a0) || !fd_ok (a1))
                return -1;
            stdio_in_fd = a0;
            stdio_out_fd = a1;
            return 0;
        }
        if (num == 20) { // SYS_SEEK(fd, offset; -1 = end)
            if (a0 < 3 || a0 >= MAX_FDS)
                return -1;
            int slot = FD_TABLE_ADDR + a0 * 32;
            if (mmio_read64 (slot) == 0)
                return -1;
            int sz = mmio_read64 (slot + 16);
            int target = (a1 < 0) ? sz : a1;
            mmio_write64 (slot + 24, target);
            return target;
        }
        if (num == 21) { // SYS_FB_INIT(w, h) -> fb_phys or 0
            return Fb.init (a0, a1);
        }
        if (num == 22) { // SYS_FB_BLIT(src_buf, w, h)
            Fb.blit (a0, a1, a2);
            return 0;
        }
        if (num == 23) { // SYS_FB_CLOSE()
            Fb.close ();
            return 0;
        }
        if (num == 24) { // SYS_MOUSE_READ(out_buf)
            if (!user_ok (a0, 24))
                return -1;
            Mouse.poll_state (a0);
            return 0;
        }
        if (num == 25) { // SYS_FB_INFO(out_buf) -> (w<<16)|h
            if (!user_ok (a0, 8))
                return -1;
            return Fb.info (a0);
        }
        if (num == 26) { // SYS_FB_BLIT_RECT(src_buf, (x<<16)|y, (w<<16)|h)
            Fb.blit_rect (a0, a1, a2);
            return 0;
        }
        if (num == 27) { // SYS_THREAD_SPAWN(entry_fn, arg) -> tid
            if (!user_ok (a0, 16))
                return -1;
            return Sched.spawn_thread (a0, a1);
        }
        if (num == 28) { // SYS_UNLINK(path_ptr, path_len)
            if (!path_ok (a0, a1))
                return -1;
            int id = -1;
            int kind = Vfs.resolve (a0, a1, out id);
            if (kind == Vfs.KIND_FILE)
                return Ramfs.unlink_slot (id);
            if (kind == Vfs.KIND_DIR && id >= 0)
                return Ramfs.has_children (id) ? -1 : Ramfs.unlink_slot (id);
            return -1;
        }
        if (num == 29) { // SYS_RENAME(old_ptr, old_len, new_ptr, new_len)
            if (!path_ok (a0, a1) || !path_ok (a2, a3))
                return -1;
            int id = -1;
            int kind = Vfs.resolve (a0, a1, out id);
            if (kind != Vfs.KIND_FILE && kind != Vfs.KIND_DIR)
                return -1;
            if (id < 0)
                return -1; // the root cannot be renamed
            int base_ptr = 0;
            int base_len = 0;
            int parent = Vfs.resolve_parent (a2, a3, out base_ptr, out base_len);
            if (parent < -1 || Vfs.reserved_name (base_ptr, base_len))
                return -1;
            if (kind == Vfs.KIND_DIR && Vfs.is_descendant (parent, id))
                return -1;
            return Ramfs.rename_to (id, parent, base_ptr, base_len);
        }
        if (num == 30) { // SYS_MKDIR(path_ptr, path_len)
            if (!path_ok (a0, a1))
                return -1;
            int base_ptr = 0;
            int base_len = 0;
            int parent = Vfs.resolve_parent (a0, a1, out base_ptr, out base_len);
            if (parent < -1 || Vfs.reserved_name (base_ptr, base_len))
                return -1;
            if (parent == -1 && Xfs.lookup_root (base_ptr, base_len) > 0)
                return -1;
            int rslot = Ramfs.create_in (parent, base_ptr, base_len, 2);
            return (rslot < 0) ? -1 : 0;
        }
        if (num == 31) { // SYS_READDIR(path_ptr, path_len, buf, max_bytes)
            if (!path_ok (a0, a1) || !user_ok (a2, a3))
                return -1;
            int id = -1;
            int kind = Vfs.resolve (a0, a1, out id);
            if (kind != Vfs.KIND_DIR)
                return -1;
            int n1 = Ramfs.list_children (id, a2, a3);
            if (n1 < 0)
                n1 = 0;
            int n2 = 0;
            if (id == -1 && a3 > n1)
                n2 = Xfs.list_root (a2 + n1, a3 - n1);
            if (n2 < 0)
                n2 = 0;
            return n1 + n2;
        }
        if (num == 32) { // SYS_STAT(path_ptr, path_len) -> 0 none, 1 file, 2 dir
            if (!path_ok (a0, a1))
                return 0;
            int id = -1;
            int kind = Vfs.resolve (a0, a1, out id);
            if (kind == Vfs.KIND_DIR)
                return 2;
            if (kind == Vfs.KIND_FILE || kind == Vfs.KIND_XFS)
                return 1;
            return 0;
        }
        if (num == 33) { // SYS_KEY_MODS() -> shift|ctrl<<1|alt<<2|super<<3
            return Keyboard.modifiers ();
        }
        if (num == 34) { // SYS_RTC_TIME() -> packed UTC date/time
            return Rtc.read_packed ();
        }
        if (num == 35) { // SYS_GETENV(k_ptr, k_len, out_buf, max_len) -> len or -1
            if (!path_ok (a0, a1) || !user_ok (a2, a3))
                return -1;
            return Env.sys_get (a0, a1, a2, a3);
        }
        if (num == 36) { // SYS_SETENV(k_ptr, k_len, v_ptr, v_len) -> 0 or -1
            if (!path_ok (a0, a1))
                return -1;
            if (a2 != 0 && !user_ok (a2, a3))
                return -1;
            return Env.sys_set (a0, a1, a2, a3);
        }
        return -1;
    }

    public int fault_dispatch (int vec, int err, int rip, int cr2) {
        print (@"fault:vec=$vec err=$err rip=$rip cr2=$cr2\n");
        if (Sched.current_tid () > 0) {
            cpu_sti ();
            Sched.exit_current (128 + vec);
        }
        if (exec_depth > 0) {
            exec_depth = exec_depth - 1;
            cpu_sti ();
            exec_return_to_parent (128 + vec, 0x106200 + exec_depth * 32);
        }
        print ("kernel:fault_halt\n");
        while (true) {
            cpu_hlt ();
        }
    }

    [AsmBody(@"
        # int 0x80 entry: rax=num, rdi=a0, rsi=a1, rdx=a2, r8=a3 -> returns in rax
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
