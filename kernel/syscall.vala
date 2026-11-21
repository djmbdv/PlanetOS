// PlanetOS syscall dispatcher (int 0x80, DPL=3) covering console, memory,
// timer, keyboard, and XFS file I/O for the language runtime.

using Planet.Rt;

namespace Planet.Kernel {

    // Simple kernel FD table (16 slots at KernelLayout.FD_TABLE, 32 bytes
    // each: +0 in_use, +8 ino, +16 size, +24 pos)
    private const int MAX_FDS = 16;
    private const int USER_LIMIT = 0x4000000; // 64 MiB, the PMM cap
    private const int MAX_PATH = 512;
    private const int MAX_XFER = 1048576;

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

    private int write_fd_data (int fd, int buf, int len) {
        if (fd < 3 || fd >= MAX_FDS)
            return -1;
        int slot = KernelLayout.FD_TABLE + fd * 32;
        int fkind = mmio_read64 (slot);
        if (fkind != 1 && fkind != 2)
            return -1;
        int rslot = mmio_read64 (slot + 8);
        int pos = mmio_read64 (slot + 24);
        int nw = (fkind == 1) ? Xfs.write_file (rslot, pos, buf, len) : Ramfs.write (rslot, pos, buf, len);
        if (nw > 0) {
            mmio_write64 (slot + 24, pos + nw);
            int nsz = (fkind == 1) ? Xfs.file_size (rslot) : Ramfs.file_size (rslot);
            mmio_write64 (slot + 16, nsz);
        }
        return nw;
    }

    private int write_console_or_stdio (int buf, int len) {
        int out_fd = Sched.get_stdio_out ();
        if (out_fd >= 3 && out_fd < MAX_FDS) {
            int nw = write_fd_data (out_fd, buf, len);
            if (nw >= 0)
                return nw;
        }
        __planet_console_write (buf, len);
        for (int i = 0; i < len; i++) {
            int w = mmio_read32 ((buf + i) & ~3);
            int b = (w >> (((buf + i) & 3) * 8)) & 0xFF;
            Vga.write_byte (b);
        }
        return len;
    }

    public int syscall_dispatch (int num, int a0, int a1, int a2, int a3) {
        switch (num) {
            case 1: // SYS_CONSOLE_WRITE(buf, len)
                if (!user_ok (a0, a1))
                    return -1;
                return write_console_or_stdio (a0, a1);
            case 2: // SYS_TICKS()
                return Hal.ticks ();
            case 3: // SYS_ALLOC_PAGE(num_pages)
                if (a0 < 0 || a0 > 1024)
                    return -1;
                int count = (a0 > 1) ? a0 : 1;
                int phys = (count > 1) ? Pmm.alloc_contiguous (count) : Pmm.alloc_frame ();
                if (phys != 0) {
                    int ucr3 = Sched.current_cr3 ();
                    if (ucr3 != 0) {
                        // A block that cannot be mapped in full is not a buffer: give
                        // the frames back and report failure instead of handing
                        // userland memory whose first write would page fault.
                        if (Vmm.map_user_range_checked (ucr3, phys, count * 4096) == 0) {
                            for (int i = 0; i < count; i++)
                                Pmm.free_frame (phys + i * 4096);
                            return 0;
                        }
                    }
                }
                return phys;
            case 4: // SYS_FREE_PAGE(phys)
                if (a0 < 0x100000 || (a0 & 0xFFF) != 0)
                    return -1;
                int ucr3 = Sched.current_cr3 ();
                if (ucr3 != 0) {
                    Vmm.unmap_user_4k (ucr3, a0);
                }
                Pmm.free_frame (a0);
                return 0;
            case 5: // SYS_READ_KEY() -> ASCII char or -1
                int in_fd = Sched.get_stdio_in ();
                if (in_fd >= 3 && in_fd < MAX_FDS) {
                    int slot = KernelLayout.FD_TABLE + in_fd * 32;
                    int fkind = mmio_read64 (slot);
                    if (fkind == 1 || fkind == 2) {
                        int rslot = mmio_read64 (slot + 8);
                        int pos = mmio_read64 (slot + 24);
                        int bbuf = KernelLayout.SYSCALL_SCRATCH;
                        int nr = (fkind == 1) ? Xfs.read_file (rslot, pos, bbuf, 1) : Ramfs.read (rslot, pos, bbuf, 1);
                        if (nr <= 0)
                            return -2; // EOF
                        mmio_write64 (slot + 24, pos + 1);
                        return mmio_read32 (bbuf) & 0xFF;
                    }
                }
                if (VirtioGpu.is_console_active ())
                    VirtioGpu.console_flush_dirty ();
                while (true) {
                    int sc = Keyboard.poll_scancode ();
                    if (sc == -1)
                        break;
                    int ch = Keyboard.scancode_to_ascii (sc);
                    if (ch != 0)
                        return ch;
                }
                return serial_try_read ();
            case 6: // SYS_OPEN(name_ptr, name_len)
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
                    int slot = KernelLayout.FD_TABLE + fd * 32;
                    if (mmio_read64 (slot) == 0) {
                        mmio_write64 (slot + 0, fd_kind);
                        mmio_write64 (slot + 8, id);
                        mmio_write64 (slot + 16, fsz);
                        mmio_write64 (slot + 24, 0);
                        return fd;
                    }
                }
                return -1;
            case 7: // SYS_READ(fd, buf, len)
                if (!user_ok (a1, a2))
                    return -1;
                if (a0 < 3 || a0 >= MAX_FDS)
                    return -1;
                int slot7 = KernelLayout.FD_TABLE + a0 * 32;
                int kind7 = mmio_read64 (slot7);
                if (kind7 == 0)
                    return -1;
                int id7 = mmio_read64 (slot7 + 8);
                int fsz7 = mmio_read64 (slot7 + 16);
                int pos7 = mmio_read64 (slot7 + 24);
                if (pos7 >= fsz7)
                    return 0;
                int n7 = (kind7 == 2) ? Ramfs.read (id7, pos7, a1, a2) : Xfs.read_file (id7, pos7, a1, a2);
                if (n7 > 0)
                    mmio_write64 (slot7 + 24, pos7 + n7);
                return n7;
            case 8: // SYS_CLOSE(fd)
                if (a0 < 3 || a0 >= MAX_FDS)
                    return -1;
                int slot8 = KernelLayout.FD_TABLE + a0 * 32;
                mmio_write64 (slot8, 0);
                return 0;
            case 9: // SYS_FILE_SIZE(fd)
                if (a0 < 3 || a0 >= MAX_FDS)
                    return -1;
                int slot9 = KernelLayout.FD_TABLE + a0 * 32;
                if (mmio_read64 (slot9) == 0)
                    return -1;
                return mmio_read64 (slot9 + 16);
            case 10: // SYS_YIELD()
                cpu_sti ();
                cpu_hlt ();
                return 0;
            case 11: // SYS_EXIT(code)
                if (Sched.current_tid () > 0) {
                    Sched.exit_current (a0);
                }
                if (ElfLoader.exec_depth > 0) {
                    ElfLoader.exec_depth = ElfLoader.exec_depth - 1;
                    exec_return_to_parent (a0, KernelLayout.EXEC_SLOTS + ElfLoader.exec_depth * KernelLayout.EXEC_SLOT_SIZE);
                }
                qemu_debug_exit (a0);
                return 0;
            case 12: // SYS_READDIR(buf, max_bytes)
                int n1 = Xfs.list_root (a0, a1);
                if (n1 < 0)
                    n1 = 0;
                int n2 = Ramfs.list (a0 + n1, a1 - n1);
                return n1 + n2;
            case 13: // SYS_EXEC(name_ptr, name_len, cmdline_ptr)
                if (!path_ok (a0, a1) || (a2 != 0 && !user_ok (a2, 1)))
                    return -1;
                return ElfLoader.exec_from_xfs (a0, a1, a2);
            case 14: // SYS_CREATE(path_ptr, path_len) -> fd
                if (!path_ok (a0, a1))
                    return -1;
                int base_ptr14 = 0;
                int base_len14 = 0;
                int parent14 = Vfs.resolve_parent (a0, a1, out base_ptr14, out base_len14);
                if (parent14 < -1 || Vfs.reserved_name (base_ptr14, base_len14))
                    return -1;
                int fd_kind14 = 2;
                int fid14 = -1;
                if (parent14 == -1 && Xfs.is_mounted ()) {
                    fid14 = Xfs.create_file (base_ptr14, base_len14);
                    if (fid14 > 0)
                        fd_kind14 = 1;
                }
                if (fd_kind14 == 2) {
                    fid14 = Ramfs.create_in (parent14, base_ptr14, base_len14, 1);
                    if (fid14 < 0)
                        return -1;
                }
                for (int fd = 3; fd < MAX_FDS; fd++) {
                    int slot14 = KernelLayout.FD_TABLE + fd * 32;
                    if (mmio_read64 (slot14) == 0) {
                        mmio_write64 (slot14 + 0, fd_kind14);
                        mmio_write64 (slot14 + 8, fid14);
                        mmio_write64 (slot14 + 16, 0);
                        mmio_write64 (slot14 + 24, 0);
                        return fd;
                    }
                }
                return -1;
            case 15: // SYS_WRITE(fd, buf, len)
                if (!user_ok (a1, a2))
                    return -1;
                if (a0 == 1 || a0 == 2)
                    return write_console_or_stdio (a1, a2);
                return write_fd_data (a0, a1, a2);
            case 16: // SYS_SPAWN(name_ptr, name_len, cmdline_ptr) -> tid
                if (!path_ok (a0, a1) || (a2 != 0 && !user_ok (a2, 1)))
                    return -1;
                return ElfLoader.spawn_from_xfs (a0, a1, a2);
            case 17: // SYS_WAIT(tid) -> exit_code
                return Sched.wait_tid (a0);
            case 18: // SYS_PS(buf, max_bytes) -> bytes
                if (!user_ok (a0, a1))
                    return -1;
                return Sched.list_tasks (a0, a1);
            case 19: // SYS_SET_STDIO(in_fd, out_fd)
                if (!fd_ok (a0) || !fd_ok (a1))
                    return -1;
                Sched.set_stdio (a0, a1);
                return 0;
            case 20: // SYS_SEEK(fd, offset; -1 = end)
                if (a0 < 3 || a0 >= MAX_FDS)
                    return -1;
                int slot20 = KernelLayout.FD_TABLE + a0 * 32;
                if (mmio_read64 (slot20) == 0)
                    return -1;
                int sz20 = mmio_read64 (slot20 + 16);
                int target20 = (a1 < 0) ? sz20 : a1;
                mmio_write64 (slot20 + 24, target20);
                return target20;
            case 21: // SYS_FB_INIT(w, h) -> fb_phys or 0
                return Fb.init (a0, a1);
            case 22: // SYS_FB_BLIT(src_buf, w, h)
                Fb.blit (a0, a1, a2);
                return 0;
            case 23: // SYS_FB_CLOSE()
                Fb.close ();
                return 0;
            case 24: // SYS_MOUSE_READ(out_buf)
                if (!user_ok (a0, 56))
                    return -1;
                Mouse.poll_state (a0);
                return 0;
            case 25: // SYS_FB_INFO(out_buf) -> (w<<16)|h
                if (!user_ok (a0, 8))
                    return -1;
                return Fb.info (a0);
            case 26: // SYS_FB_BLIT_RECT(src_buf, (x<<16)|y, (w<<16)|h)
                Fb.blit_rect (a0, a1, a2);
                return 0;
            case 27: // SYS_THREAD_SPAWN(entry_fn, arg) -> tid
                if (!user_ok (a0, 16))
                    return -1;
                return Sched.spawn_thread (a0, a1);
            case 28: // SYS_UNLINK(path_ptr, path_len)
                if (!path_ok (a0, a1))
                    return -1;
                int id28 = -1;
                int kind28 = Vfs.resolve (a0, a1, out id28);
                if (kind28 == Vfs.KIND_XFS) {
                    int bp = 0;
                    int bl = 0;
                    if (Vfs.resolve_parent (a0, a1, out bp, out bl) == -1)
                        return Xfs.unlink_root (bp, bl);
                    return -1;
                }
                if (kind28 == Vfs.KIND_FILE)
                    return Ramfs.unlink_slot (id28);
                if (kind28 == Vfs.KIND_DIR && id28 >= 0)
                    return Ramfs.has_children (id28) ? -1 : Ramfs.unlink_slot (id28);
                return -1;
            case 29: // SYS_RENAME(old_ptr, old_len, new_ptr, new_len)
                if (!path_ok (a0, a1) || !path_ok (a2, a3))
                    return -1;
                int id29 = -1;
                int kind29 = Vfs.resolve (a0, a1, out id29);
                if (kind29 != Vfs.KIND_FILE && kind29 != Vfs.KIND_DIR)
                    return -1;
                if (id29 < 0)
                    return -1; // the root cannot be renamed
                int base_ptr29 = 0;
                int base_len29 = 0;
                int parent29 = Vfs.resolve_parent (a2, a3, out base_ptr29, out base_len29);
                if (parent29 < -1 || Vfs.reserved_name (base_ptr29, base_len29))
                    return -1;
                if (kind29 == Vfs.KIND_DIR && Vfs.is_descendant (parent29, id29))
                    return -1;
                return Ramfs.rename_to (id29, parent29, base_ptr29, base_len29);
            case 30: // SYS_MKDIR(path_ptr, path_len)
                if (!path_ok (a0, a1))
                    return -1;
                int base_ptr30 = 0;
                int base_len30 = 0;
                int parent30 = Vfs.resolve_parent (a0, a1, out base_ptr30, out base_len30);
                if (parent30 < -1 || Vfs.reserved_name (base_ptr30, base_len30))
                    return -1;
                if (parent30 == -1 && Xfs.lookup_root (base_ptr30, base_len30) > 0)
                    return -1;
                int rslot30 = Ramfs.create_in (parent30, base_ptr30, base_len30, 2);
                return (rslot30 < 0) ? -1 : 0;
            case 31: // SYS_READDIR(path_ptr, path_len, buf, max_bytes)
                if (!path_ok (a0, a1) || !user_ok (a2, a3))
                    return -1;
                int id31 = -1;
                int kind31 = Vfs.resolve (a0, a1, out id31);
                if (kind31 != Vfs.KIND_DIR)
                    return -1;
                int n31_1 = Ramfs.list_children (id31, a2, a3);
                if (n31_1 < 0)
                    n31_1 = 0;
                int n31_2 = 0;
                if (id31 == -1 && a3 > n31_1)
                    n31_2 = Xfs.list_root (a2 + n31_1, a3 - n31_1);
                if (n31_2 < 0)
                    n31_2 = 0;
                return n31_1 + n31_2;
            case 32: // SYS_STAT(path_ptr, path_len) -> 0 none, 1 file, 2 dir
                if (!path_ok (a0, a1))
                    return 0;
                int id32 = -1;
                int kind32 = Vfs.resolve (a0, a1, out id32);
                if (kind32 == Vfs.KIND_DIR)
                    return 2;
                if (kind32 == Vfs.KIND_FILE || kind32 == Vfs.KIND_XFS)
                    return 1;
                return 0;
            case 33: // SYS_KEY_MODS() -> shift|ctrl<<1|alt<<2|super<<3
                return Keyboard.modifiers ();
            case 34: // SYS_RTC_TIME() -> packed UTC date/time
                return Rtc.read_packed ();
            case 35: // SYS_GETENV(k_ptr, k_len, out_buf, max_len) -> len or -1
                if (!path_ok (a0, a1) || !user_ok (a2, a3))
                    return -1;
                return Env.sys_get (a0, a1, a2, a3);
            case 36: // SYS_SETENV(k_ptr, k_len, v_ptr, v_len) -> 0 or -1
                if (!path_ok (a0, a1))
                    return -1;
                if (a2 != 0 && !user_ok (a2, a3))
                    return -1;
                return Env.sys_set (a0, a1, a2, a3);
            case 37: // SYS_GPU_INFO() -> packed caps + w/h
                return VirtioGpu.packed_caps ();
            case 38: // SYS_GPU_CTX_CREATE(ctx_id, capset_id)
                return VirtioGpu.ctx_create (a0, a1) ? 0 : -1;
            case 39: // SYS_GPU_CTX_DESTROY(ctx_id)
                return VirtioGpu.ctx_destroy (a0) ? 0 : -1;
            case 40: // SYS_GPU_SUBMIT_3D(ctx_id, cmd_buf, cmd_bytes)
                if (!user_ok (a1, a2))
                    return -1;
                return VirtioGpu.submit_3d (a0, a1, a2, true) ? 0 : -1;
            case 41: // SYS_GPU_CURSOR_MOVE(x, y)
                return VirtioGpu.move_cursor (a0, a1) ? 0 : -1;
            case 42: // SYS_GPU_CURSOR_SET(rgba_64x64_buf, hot_x, hot_y)
                if (!user_ok (a0, 16384))
                    return -1;
                return VirtioGpu.set_cursor (a0, a1, a2) ? 0 : -1;
            case 43: // SYS_GPU_BLOB_CREATE(ctx_id, res_id, size) -> mapped addr or 0
                return VirtioGpu.create_blob_mapped (a0, a1, a2);
            case 44: // SYS_KLOG_READ(buf, max_records) -> records copied
                if (a0 == 0 || a1 <= 0 || a1 > 128 || !user_ok (a0, a1 * 64))
                    return -1;
                return Klog.read_records (a0, a1);
            case 45: // SYS_KLOG_CTL(op, a, b)
                switch (a0) {
                    case 0: // set level
                        Klog.set_level (a1);
                        return Klog.level ();
                    case 1: // set category a1 on/off
                        Klog.set_category (a1, a2 != 0);
                        return Klog.mask ();
                    case 2: // clear
                        Klog.clear ();
                        return 0;
                    case 3: // query: level | mask << 8
                        return (Klog.level () & 0xFF) | ((Klog.mask () & 0xFF) << 8);
                    case 4: // records written since the last clear
                        return Klog.total ();
                    default:
                        return -1;
                }
            case 46: // SYS_GPU_RESOURCE_DESTROY(ctx_id, res_id, pa, size)
                return VirtioGpu.resource_destroy (a0, a1, a2, a3) ? 0 : -1;
            case 47: // SYS_GPU_3D_CREATE(ctx_id, res_id, width, height) -> pa or 0
                return VirtioGpu.create_3d_mapped (a0, a1, a2, a3);
            case 48: // SYS_WAIT_NB(tid) -> exit_code, -2 if running, -1 if invalid
                return Sched.try_wait_tid (a0);
            case 49: // SYS_KILL(tid) -> exit_code or -1
                return Sched.kill_tid (a0);
            // Also how a client attaches a surface the compositor allocated, so the
            // floor is the first frame the Pmm can hand out (RESERVED_END) and not a
            // fixed 16 MiB: a 1.2 MiB block often lands in the 6-8 MiB hole below the
            // static userland window, and refusing it would force the file transport.
            case 50: // SYS_MAP_USER_AT(vaddr, size) -> 0 or -1 (for .dlib loading)
                if (a0 < KernelLayout.RESERVED_END || a1 <= 0 || a1 > 0x800000 || a0 + a1 > 0x40000000)
                    return -1;
                int ucr3_50 = Sched.current_cr3 ();
                Pmm.reserve_range (a0, a1);
                if (ucr3_50 != 0)
                    Vmm.map_user_range (ucr3_50, a0, a1);
                return 0;
            case 51: // SYS_GPU_3D_READBACK(ctx_id, res_id, width, height) -> 0 or -1
                return VirtioGpu.transfer_from_host_3d (a0, a1, a2, a3) ? 0 : -1;
            default:
                return -1;
        }
    }

    private static string fault_name (int vec) {
        switch (vec) {
            case 0: return "Divide Error";
            case 6: return "Invalid Opcode";
            case 8: return "Double Fault";
            case 13: return "General Protection Fault";
            case 14: return "Page Fault";
            default: return "CPU Exception";
        }
    }

    private static string hex64 (int v) {
        string hex = "0123456789abcdef";
        string out_s = "0x";
        bool started = false;
        for (int s = 60; s >= 0; s -= 4) {
            int nib = (v >> s) & 0xF;
            if (nib != 0 || started || s == 0) {
                out_s = out_s + hex.substring (nib, 1);
                started = true;
            }
        }
        return out_s;
    }

    public int fault_dispatch (int vec, int err, int rip, int cr2) {
        int cur_cr3 = Sched.current_cr3 ();
        int tid = Sched.current_tid ();
        if (cur_cr3 != 0)
            Fb.release_for_cr3 (cur_cr3);
        Sched.set_stdio (0, 1);
        string pf_info = "";
        if (vec == 14) {
            string p_str = ((err & 1) != 0) ? "prot" : "unmapped";
            string w_str = ((err & 2) != 0) ? "write" : "read";
            string u_str = ((err & 4) != 0) ? "user" : "kernel";
            pf_info = @" [$u_str/$w_str/$p_str]";
        }
        string msg = @"\n[fault] $(fault_name (vec))$pf_info (tid=$tid vec=$vec err=$err rip=$(hex64 (rip)) cr2=$(hex64 (cr2)))\n";
        Klog.error (Klog.CAT_SCHED, msg);
        print (msg);
        for (int i = 0; i < msg.length; i++)
            Vga.write_byte ((int) msg[i]);
        if (Sched.current_tid () > 0) {
            cpu_sti ();
            Sched.exit_current (128 + vec);
        }
        if (ElfLoader.exec_depth > 0) {
            ElfLoader.exec_depth = ElfLoader.exec_depth - 1;
            cpu_sti ();
            exec_return_to_parent (128 + vec, KernelLayout.EXEC_SLOTS + ElfLoader.exec_depth * KernelLayout.EXEC_SLOT_SIZE);
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

    public sealed class Syscalls : Object {
        public static void init () {
            for (int fd = 0; fd < MAX_FDS; fd++) {
                mmio_write64 (KernelLayout.FD_TABLE + fd * 32, 0);
            }
            Hal.set_idt_gate_dpl (0x80, addr_isr_syscall (), 1);
        }
    }
}
