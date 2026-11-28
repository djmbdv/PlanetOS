// PlanetOS syscall dispatcher (int 0x80, DPL=3) covering console, memory,
// timer, keyboard, and XFS file I/O for the language runtime.

using Planet.Rt;

namespace Planet.Kernel {

    // Kernel handle table: 64 slots at KernelLayout.FD_TABLE, 32 bytes each.
    //   +0  kind (8) | rights (8) | generation (16) | owner (32)
    //   +8  object id (XFS inode or RAMFS slot)
    //   +16 size | +24 position
    // Userland receives `index | generation << 8`, not a table offset: a forged
    // or stale value never resolves to a live slot. A task may use only what it
    // owns; inherited stdio is the one cross-task exception.
    private const int MAX_FDS = 64;

    // Handle kinds: 1 XFS, 2 RAMFS, 3 byte device, 4 grant, 5 descriptor ring (A2/B).
    private const int KIND_GRANT = 4;
    private const int KIND_RING = 5;
    private const int KIND_RING_BLK = 6;
    private const int KIND_RING_NET = 7;
    // Ring header (docs/08 6.1): magic, version, entries, entry size, head,
    // tail, seq, wake, doorbell epoch, status. Little-endian.
    private const int RING_MAGIC = 0x524E4C50; // bytes "PLNR"
    private const int RING_VERSION = 1;
    private const int RING_ENTRY = 32;
    private const int RING_MAX_ENTRIES = 64;
    // Descriptor flags (6.1) and the status the kernel writes back.
    private const int RING_F_READ = 1;
    private const int RING_F_WRITE = 2;
    private const int RING_ST_READY = 1;
    private const int RING_ST_DONE = 2;
    private const int RING_ST_ERROR = 3;
    private const int RING_MAX_XFER = 16384;
    // A2 frame ownership: one entry per SYS_ALLOC_PAGE block, and up to four
    // task ids allowed to map a grant handle.
    private const int ALLOC_SLOTS = 4096; // KernelLayout.ALLOC_TABLE_SIZE / 16
    // Set when a block could not be tracked (table full); reported once. A
    // block that is handed out but untracked is never released on exit.
    private static int alloc_track_full = 0;
    private const int GRANT_TASKS = 4;

    private const int R_READ  = 1;
    private const int R_WRITE = 2;
    private const int R_SEEK  = 4;
    private const int R_POLL  = 8;
    private const int R_CLOSE = 16;
    private const int USER_LIMIT = 0x40000000; // 1 GiB, the PMM cap and identity map
    private const int MAX_PATH = 512;
    private const int MAX_XFER = 1048576;

    // errno values reported through SYS_ERRNO (mirrored by Planet.Sys).
    private const int E_OK = 0;
    private const int E_PERM = 1;
    private const int E_NOENT = 2;
    private const int E_IO = 5;
    private const int E_BAD_HANDLE = 9;
    private const int E_AGAIN = 11;
    private const int E_ACCES = 13;
    private const int E_EXIST = 17;
    private const int E_NOTDIR = 20;
    private const int E_ISDIR = 21;
    private const int E_INVAL = 22;
    private const int E_NOSPC = 28;
    private const int E_PIPE = 32;
    private const int E_TIMEDOUT = 110;

    // Staging buffer for user data. It sits in the low window (KernelLayout),
    // which every user CR3 maps as supervisor pages, so the kernel can always
    // reach it no matter which process is running.
    public sealed class KernelIo : Object {
        public const int CHUNK = KernelLayout.IO_SCRATCH_SIZE;

        public static int scratch_addr () {
            return KernelLayout.IO_SCRATCH;
        }
    }

    // Records the cause of a failed syscall and returns the -1 the ABI uses.
    private int fail (int err) {
        Sched.set_errno (err);
        return -1;
    }

    private void ok () {
        Sched.set_errno (E_OK);
    }

    // Readiness of the console/stdin source used by SYS_POLL.
    private bool console_input_ready () {
        int in_fd = Sched.get_stdio_in ();
        if (in_fd > 2 && fd_check (in_fd, R_READ) == 0) {
            int slot = handle_slot (in_fd);
            int kind = fd_kind_of (slot);
            if (kind == 1)
                return mmio_read64 (slot + 24) < mmio_read64 (slot + 16);
            if (kind == 2)
                return mmio_read64 (slot + 24) < mmio_read64 (slot + 16);
        }
        return (mmio_read32 (KernelLayout.KB_HEAD) != mmio_read32 (KernelLayout.KB_TAIL))
            || (serial_rx_ready () != 0);
    }

    // Walks the caller's page table. Every level must be present and
    // user-accessible; a write also needs the RW bit.
    // Flags are tested one at a time on purpose: planc miscompiles some
    // `a || b` chains over int comparisons (R-35), and a validation routine
    // must not depend on that.
    private bool page_user_ok (int cr3, int addr, bool write) {
        int pml4e = mmio_read64 (cr3 + ((addr >> 39) & 0x1FF) * 8);
        if ((pml4e & 1) == 0)
            return false;
        if ((pml4e & 4) == 0)
            return false;
        int pdpte = mmio_read64 ((pml4e & ~0xFFF) + ((addr >> 30) & 0x1FF) * 8);
        if ((pdpte & 1) == 0)
            return false;
        if ((pdpte & 4) == 0)
            return false;
        if ((pdpte & 0x80) != 0) {
            if (write) {
                if ((pdpte & 2) == 0)
                    return false;
            }
            return true;
        }
        int pde = mmio_read64 ((pdpte & ~0xFFF) + ((addr >> 21) & 0x1FF) * 8);
        if ((pde & 1) == 0)
            return false;
        if ((pde & 4) == 0)
            return false;
        if ((pde & 0x80) != 0) {
            if (write) {
                if ((pde & 2) == 0)
                    return false;
            }
            return true;
        }
        int pte = mmio_read64 ((pde & ~0xFFF) + ((addr >> 12) & 0x1FF) * 8);
        if ((pte & 1) == 0)
            return false;
        if ((pte & 4) == 0)
            return false;
        if (write) {
            if ((pte & 2) == 0)
                return false;
        }
        return true;
    }

    // Every pointer that arrives through int 0x80 is checked against the
    // caller's page table before the kernel dereferences it (KR-07). A kernel
    // caller (CR3 0) keeps the old bound check: its buffers are not user maps.
    private bool user_range_ok (int ptr, int len, bool write) {
        if (len < 0)
            return false;
        if (ptr < 0x1000)
            return false;
        if (len > MAX_XFER)
            return false;
        int end = ptr + len;
        if (end < ptr)
            return false;
        int cr3 = Sched.current_cr3 ();
        if (cr3 == 0)
            return end <= USER_LIMIT;
        if (cr3 == KernelLayout.PAGE_TABLES)
            return end <= USER_LIMIT;
        if (end > USER_LIMIT)
            return false;
        int page = ptr & ~0xFFF;
        int last = (end - 1) & ~0xFFF;
        while (true) {
            if (!page_user_ok (cr3, page, write))
                return false;
            if (page >= last)
                break;
            page = page + 4096;
        }
        return true;
    }

    private bool user_ok (int ptr, int len) {
        return user_range_ok (ptr, len, false);
    }

    private bool user_ok_w (int ptr, int len) {
        return user_range_ok (ptr, len, true);
    }

    // Guarded copy of up to 64 KiB. The frame is recorded at
    // KernelLayout.COPY_VARS; if a page fault happens inside the loop,
    // copy_recover restores that frame and returns 1, so the fault never
    // reaches the task as a fatal one (KR-07).
    [AsmBody(@"
        # int copy_guarded(dst rdi, src rsi, len rdx) -> 0 ok, 1 fault
        push %rbp
        mov %rsp, %rbp
        mov $0x107800, %rax
        mov %rsp, 8(%rax)
        mov %rbp, 16(%rax)
        movq $1, (%rax)
    cg8_loop:
        cmp $8, %rdx
        jl cg_tail
        mov (%rsi), %rax
        mov %rax, (%rdi)
        add $8, %rsi
        add $8, %rdi
        sub $8, %rdx
        jmp cg8_loop
    cg_tail:
        cmp $0, %rdx
        jz cg_done
        mov (%rsi), %al
        mov %al, (%rdi)
        inc %rsi
        inc %rdi
        sub $1, %rdx
        jmp cg_tail
    cg_done:
        mov $0x107800, %rax
        movq $0, (%rax)
        xor %eax, %eax
        leave
        ret
    ")]
    public extern int copy_guarded (int dst, int src, int len);

    // Called from fault_dispatch while COPY_VARS is active: restores the frame
    // saved by copy_guarded and returns 1 from it. Never returns to its caller.
    [AsmBody(@"
        mov $0x107800, %rax
        mov 16(%rax), %rbp
        mov 8(%rax), %rsp
        movq $0, (%rax)
        mov $1, %eax
        leave
        ret
    ")]
    public extern void copy_recover ();

    private bool path_ok (int ptr, int len) {
        return len > 0 && len <= MAX_PATH && user_ok (ptr, len);
    }

    // Copies a validated user path into the staging buffer at `off` and returns
    // the kernel address. The VFS then reads kernel memory, so a concurrent
    // change to the user buffer cannot alter a path that was already checked.
    // Two paths fit: offsets 0 and MAX_PATH.
    private int copy_path (int ptr, int len, int off) {
        if (len <= 0)
            return -1;
        if (len > MAX_PATH)
            return -1;
        if (!user_range_ok (ptr, len, false))
            return -1;
        int dst = KernelIo.scratch_addr () + off;
        if (copy_guarded (dst, ptr, len) != 0)
            return -1;
        return dst;
    }

    private static int fd_kind_of (int slot) {
        return mmio_read64 (slot) & 0xFF;
    }

    private static int fd_rights_of (int slot) {
        return (mmio_read64 (slot) >> 8) & 0xFF;
    }

    private static int fd_gen_of (int slot) {
        return (mmio_read64 (slot) >> 16) & 0xFFFF;
    }

    private static int fd_owner_of (int slot) {
        return (mmio_read64 (slot) >> 32) & 0xFF;
    }

    private static int handle_gen (int h) {
        return (h >> 8) & 0xFFFF;
    }

    private static int handle_slot (int h) {
        int index = h & 0xFF;
        if (index < 3 || index >= MAX_FDS)
            return -1;
        return KernelLayout.FD_TABLE + index * 32;
    }

    private static bool fd_inherited_stdio (int h) {
        if (h == Sched.get_stdio_in ())
            return true;
        if (h == Sched.get_stdio_out ())
            return true;
        return false;
    }

    // 0 = usable, 1 = invalid (forged, stale or foreign), 2 = missing rights.
    private static int fd_check (int h, int need) {
        int slot = handle_slot (h);
        if (slot < 0)
            return 1;
        if (fd_kind_of (slot) == 0)
            return 1;
        if (fd_gen_of (slot) != handle_gen (h))
            return 1;
        if (fd_owner_of (slot) != Sched.current_tid () && !fd_inherited_stdio (h))
            return 1;
        if ((fd_rights_of (slot) & need) != need)
            return 2;
        return 0;
    }

    private static bool fd_owned (int h) {
        int slot = handle_slot (h);
        if (slot < 0)
            return false;
        if (fd_kind_of (slot) == 0)
            return false;
        if (fd_gen_of (slot) != handle_gen (h))
            return false;
        return fd_owner_of (slot) == Sched.current_tid ();
    }

    private const int INBOX_SLOTS = 8;
    private static int[] handle_inbox;
    private static int[] kick_seen_leases;

    private static bool inbox_push (int tid, int h) {
        if (handle_inbox == null || tid < 0 || tid >= 16)
            return false;
        int base_i = tid * INBOX_SLOTS;
        for (int i = 0; i < INBOX_SLOTS; i++) {
            if (handle_inbox[base_i + i] == 0) {
                handle_inbox[base_i + i] = h;
                return true;
            }
        }
        return false;
    }

    private static int inbox_pop (int tid) {
        if (handle_inbox == null || tid < 0 || tid >= 16)
            return -1;
        int base_i = tid * INBOX_SLOTS;
        int h = handle_inbox[base_i];
        if (h <= 0)
            return -1;
        for (int i = 0; i < INBOX_SLOTS - 1; i++)
            handle_inbox[base_i + i] = handle_inbox[base_i + i + 1];
        handle_inbox[base_i + INBOX_SLOTS - 1] = 0;
        return h;
    }

    private static int fd_alloc_for (int owner, int kind, int rights, int id, int size, int extra24) {
        for (int index = 3; index < MAX_FDS; index++) {
            int slot = KernelLayout.FD_TABLE + index * 32;
            if (fd_kind_of (slot) != 0)
                continue;
            int gen = (fd_gen_of (slot) + 1) & 0xFFFF;
            if (gen == 0)
                gen = 1;
            mmio_write64 (slot + 0, kind | (rights << 8) | (gen << 16) | (owner << 32));
            mmio_write64 (slot + 8, id);
            mmio_write64 (slot + 16, size);
            mmio_write64 (slot + 24, extra24);
            return index | (gen << 8);
        }
        return -1;
    }

    private static int fd_alloc (int kind, int rights, int id, int size) {
        return fd_alloc_for (Sched.current_tid (), kind, rights, id, size, 0);
    }

    // Releases the slot but keeps its generation, so a stale value cannot be
    // revived by the next allocation in the same index.
    private static void fd_release (int slot) {
        int index = (slot - KernelLayout.FD_TABLE) / 32;
        int t = 0;
        while (t < GRANT_TASKS) {
            mmio_write32 (acl_addr (index) + t * 4, 0);
            t = t + 1;
        }
        mmio_write64 (slot + 0, (fd_gen_of (slot) << 16) | (fd_owner_of (slot) << 32));
        mmio_write64 (slot + 8, 0);
        mmio_write64 (slot + 16, 0);
        mmio_write64 (slot + 24, 0);
    }

    // Called when a task exits or is reaped. Inherited stdio belongs to the
    // parent and is deliberately left open.
    public static void release_fds (int tid) {
        for (int index = 3; index < MAX_FDS; index++) {
            int slot = KernelLayout.FD_TABLE + index * 32;
            if (fd_kind_of (slot) != 0 && fd_owner_of (slot) == tid)
                fd_release (slot);
        }
    }

    // Blocks the kernel handed to userland are recorded so a second task cannot
    // map or free them without a capability (A2, IO-02). The owner is the task
    // that called SYS_ALLOC_PAGE: a thread of the same process inherits the
    // mapping, not the ownership.
    private static int alloc_slot (int i) {
        return KernelLayout.ALLOC_TABLE + i * 16;
    }

    private static int acl_addr (int index) {
        return KernelLayout.GRANT_ACL + index * 16;
    }

    public static void alloc_track_for (int owner_cr3, uint64 phys, uint32 pages) {
        uint32 owner = (uint32) owner_cr3;
        if (owner == 0)
            return;
        if (phys == 0 || pages == 0)
            return;
        int i = 0;
        while (i < ALLOC_SLOTS) {
            int a = alloc_slot (i);
            uint64 cur = (uint64) mmio_read64 (a);
            if (cur == 0) {
                mmio_write64 (a, (int) phys);
                mmio_write32 (a + 8, (int) pages);
                mmio_write32 (a + 12, (int) owner);
                return;
            }
            if (cur == phys) {
                mmio_write32 (a + 8, (int) pages);
                mmio_write32 (a + 12, (int) owner);
                return;
            }
            i = i + 1;
        }
        // No free slot: the block is handed out but untracked, so it is never
        // released when the task exits. Report it once instead of leaking silently.
        if (alloc_track_full == 0) {
            alloc_track_full = 1;
            print (@"pmm:alloc_track_full phys=$phys pages=$pages\n");
        }
    }

    private static void alloc_track (uint64 phys, uint32 pages) {
        alloc_track_for (Sched.current_cr3 (), phys, pages);
    }

    private static void alloc_untrack (int phys) {
        int i = 0;
        while (i < ALLOC_SLOTS) {
            int a = alloc_slot (i);
            if (mmio_read64 (a) == phys) {
                mmio_write64 (a, 0);
                mmio_write32 (a + 8, 0);
                mmio_write32 (a + 12, 0);
            }
            i = i + 1;
        }
    }

    // 1 when `addr` falls inside a block owned by `cr3`, 0 otherwise.
    private static int page_owned_by (int addr, int cr3) {
        int found = 0;
        int i = 0;
        while (i < ALLOC_SLOTS) {
            int a = alloc_slot (i);
            int phys = mmio_read64 (a);
            if (phys != 0) {
                if (mmio_read32 (a + 12) == cr3) {
                    int npages = mmio_read32 (a + 8);
                    if (addr >= phys) {
                        if (addr < phys + npages * 0x1000)
                            found = 1;
                    }
                }
            }
            i = i + 1;
        }
        return found;
    }

    // 1 when `addr` falls inside a block owned by somebody else.
    private static int page_owned_by_other (int addr) {
        int me = Sched.current_cr3 ();
        int found = 0;
        int i = 0;
        while (i < ALLOC_SLOTS) {
            int a = alloc_slot (i);
            int phys = mmio_read64 (a);
            if (phys != 0) {
                int npages = mmio_read32 (a + 8);
                if (addr >= phys) {
                    if (addr < phys + npages * 0x1000) {
                        if (mmio_read32 (a + 12) != me)
                            found = 1;
                    }
                }
            }
            i = i + 1;
        }
        return found;
    }

    // True when the caller owns every page of [start, start+len). Kernel callers
    // keep the plain bound check: their buffers come from the Pmm, not a task.
    private static bool range_owned (int start, int len) {
        if (len <= 0)
            return false;
        int me = Sched.current_cr3 ();
        if (me == 0)
            return true;
        if ((start & 0xFFF) != 0)
            return false;
        int pages = (len + 0xFFF) / 0x1000;
        int p = 0;
        while (p < pages) {
            if (page_owned_by (start + p * 0x1000, me) == 0)
                return false;
            p = p + 1;
        }
        return true;
    }

    // True when a live grant covers [start, start+len) and lists this task.
    private static bool range_granted_to_me (int start, int len) {
        int me = Sched.current_tid ();
        if (len <= 0)
            return false;
        int index = 3;
        while (index < MAX_FDS) {
            int slot = KernelLayout.FD_TABLE + index * 32;
            if (fd_kind_of (slot) == KIND_GRANT) {
                int gstart = mmio_read64 (slot + 8);
                int glen = mmio_read64 (slot + 16);
                if (glen > 0) {
                    if (start >= gstart) {
                        if (start + len <= gstart + glen) {
                            if (fd_owner_of (slot) == me)
                                return true;
                            int acl = acl_addr (index);
                            int t = 0;
                            while (t < GRANT_TASKS) {
                                if (mmio_read32 (acl + t * 4) == me)
                                    return true;
                                t = t + 1;
                            }
                        }
                    }
                }
            }
            index = index + 1;
        }
        return false;
    }

    // True when a live grant overlaps [start, start+len).
    private static bool range_in_live_grant (int start, int len) {
        int index = 3;
        while (index < MAX_FDS) {
            int slot = KernelLayout.FD_TABLE + index * 32;
            int k = fd_kind_of (slot);
            if (k == KIND_GRANT || k == KIND_RING || k == KIND_RING_BLK || k == KIND_RING_NET) {
                int gstart = mmio_read64 (slot + 8);
                int glen = mmio_read64 (slot + 16);
                if (glen > 0) {
                    if (start < gstart + glen) {
                        if (gstart < start + len)
                            return true;
                    }
                }
            }
            index = index + 1;
        }
        return false;
    }

    // --- B: descriptor rings (IO-05) -----------------------------------
    // A ring is a granted block the caller owns: a fixed header followed by
    // fixed-size descriptors. Every descriptor is validated against the ring's
    // own block before anything runs, which is what keeps userland away from
    // MMIO and DMA while there is no IOMMU.
    private static bool ring_header_ok (int rstart, int rlen, int entries) {
        if (rstart <= 0 || rlen < 64)
            return false;
        if (entries <= 0 || entries > RING_MAX_ENTRIES || (entries & (entries - 1)) != 0)
            return false;
        if (rlen < 64 + entries * RING_ENTRY)
            return false;
        if (mmio_read32 (rstart) != RING_MAGIC)
            return false;
        if (mmio_read32 (rstart + 4) != RING_VERSION)
            return false;
        if (mmio_read32 (rstart + 8) != entries)
            return false;
        if (mmio_read32 (rstart + 12) != RING_ENTRY)
            return false;
        return true;
    }

    // Runs one descriptor. Returns 1 when it completed, 0 when it was rejected
    // (the entry is marked and nothing else was touched). Phase D enforces:
    // - data region separation: buffer must sit past header + descriptor table
    // - mapped/writable user-range check matching direction
    private static int ring_run_one (int rstart, int rlen, int entries, int desc, int rkind) {
        int addr = mmio_read64 (desc);
        int len = mmio_read32 (desc + 8);
        int flags = mmio_read32 (desc + 12);
        bool ok = false;
        if (rkind == KIND_RING_BLK) {
            ok = (flags == RING_F_READ) && (len >= 512) && ((len & 511) == 0);
        } else {
            if (flags == RING_F_WRITE)
                ok = true;
            if (flags == RING_F_READ)
                ok = true;
            if (flags == (RING_F_READ | RING_F_WRITE))
                ok = true;
        }
        int data_min = rstart + 64 + entries * RING_ENTRY;
        if (len <= 0 || len > RING_MAX_XFER)
            ok = false;
        if (addr < data_min || addr + len > rstart + rlen)
            ok = false;
        bool needs_write = (rkind == KIND_RING_BLK)
            || (rkind == KIND_RING_NET && flags == RING_F_READ)
            || (rkind == KIND_RING && (flags & RING_F_WRITE) != 0);
        if (ok && !user_range_ok (addr, len, needs_write))
            ok = false;
        if (!ok) {
            mmio_write32 (desc + 20, RING_ST_ERROR);
            return 0;
        }
        if (rkind == KIND_RING_BLK) {
            int lba = mmio_read64 (desc + 24);
            if (lba < 0 || !VirtioBlk.read (lba, addr, len / 512)) {
                mmio_write32 (desc + 20, RING_ST_ERROR);
                return 0;
            }
        } else if (rkind == KIND_RING_NET) {
            if (flags == RING_F_WRITE) {
                if (!VirtioNet.tx (addr, len)) {
                    mmio_write32 (desc + 20, RING_ST_ERROR);
                    return 0;
                }
            } else if (flags == RING_F_READ) {
                int rx_got = VirtioNet.rx (addr, len);
                mmio_write64 (desc + 24, rx_got);
            }
        } else if (flags != RING_F_READ) {
            int i = 0;
            while (i < len) {
                mmio_write8 (addr + i, 0xA5);
                i = i + 1;
            }
        }
        mmio_write32 (desc + 20, RING_ST_DONE);
        return 1;
    }

    // Called when an address space dies: its blocks go back to the Pmm.
    public static void release_allocs (int ucr3) {
        if (ucr3 == 0)
            return;
        int i = 0;
        while (i < ALLOC_SLOTS) {
            int a = alloc_slot (i);
            int phys = mmio_read64 (a);
            if (phys != 0) {
                if (mmio_read32 (a + 12) == ucr3) {
                    int npages = mmio_read32 (a + 8);
                    int p = 0;
                    while (p < npages) {
                        Pmm.free_frame (phys + p * 0x1000);
                        p = p + 1;
                    }
                    mmio_write64 (a, 0);
                    mmio_write32 (a + 8, 0);
                    mmio_write32 (a + 12, 0);
                }
            }
            i = i + 1;
        }
    }

    // Blocks until one byte arrives from the PS/2 keyboard or COM1.
    private int read_console_byte () {
        while (true) {
            int sc = Keyboard.poll_scancode ();
            while (sc != -1) {
                int ch = Keyboard.scancode_to_ascii (sc);
                if (ch != 0)
                    return ch;
                sc = Keyboard.poll_scancode ();
            }
            int sr = serial_try_read ();
            if (sr >= 0)
                return sr;
            cpu_sti ();
            cpu_hlt ();
        }
    }

    private void console_out (int buf, int len) {
        __planet_console_write (buf, len);
        for (int i = 0; i < len; i++) {
            int w = mmio_read32 ((buf + i) & ~3);
            int b = (w >> (((buf + i) & 3) * 8)) & 0xFF;
            Vga.write_byte (b);
        }
    }

    private int write_fd_data (int h, int buf, int len) {
        int slot = handle_slot (h);
        if (slot < 0)
            return -1;
        int fkind = fd_kind_of (slot);
        if (fkind == 3) {
            int dev = mmio_read64 (slot + 8);
            if (dev == Vfs.DEV_NULL)
                return len;
            console_out (buf, len);
            return len;
        }
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
        if (out_fd > 2 && fd_check (out_fd, R_WRITE) == 0) {
            int nw = write_fd_data (out_fd, buf, len);
            if (nw >= 0)
                return nw;
        }
        console_out (buf, len);
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
                if (a0 < 0 || a0 > 1024) {
                    print (@"sys:alloc_page_reject n=$a0\n");
                    return -1;
                }
                int count = (a0 > 1) ? a0 : 1;
                int phys = (count > 1) ? Pmm.alloc_contiguous (count) : Pmm.alloc_frame ();
                if (phys == 0) {
                    print (@"sys:alloc_page_fail n=$count\n");
                    return 0;
                }
                if (phys != 0) {
                    int ucr3 = Sched.current_cr3 ();
                    if (ucr3 != 0) {
                        // A block that cannot be mapped in full is not a buffer: give
                        // the frames back and report failure instead of handing
                        // userland memory whose first write would page fault.
                        if (Vmm.map_user_range_checked (ucr3, phys, count * 4096) == 0) {
                            print (@"sys:alloc_page_mapfail n=$count phys=$phys\n");
                            for (int i = 0; i < count; i++)
                                Pmm.free_frame (phys + i * 4096);
                            return 0;
                        }
                    }
                    alloc_track (phys, count);
                }
                return phys;
            case 4: // SYS_FREE_PAGE(phys)
                if (a0 < 0x100000 || (a0 & 0xFFF) != 0)
                    return fail (E_INVAL);
                // A2: only the owner frees, and never underneath a live grant.
                if (!range_owned (a0, 0x1000))
                    return fail (E_ACCES);
                if (range_in_live_grant (a0, 0x1000))
                    return fail (E_ACCES);
                int ucr3 = Sched.current_cr3 ();
                alloc_untrack (a0);
                Pmm.free_frame (a0);
                if (ucr3 != 0) {
                    Vmm.unmap_user_4k (ucr3, a0);
                }
                return 0;
            case 5: // SYS_READ_KEY() -> ASCII char or -1
                int in_fd = Sched.get_stdio_in ();
                if (in_fd > 2 && fd_check (in_fd, R_READ) == 0) {
                    int slot = handle_slot (in_fd);
                    int fkind = fd_kind_of (slot);
                    bool is_file = (fkind == 1);
                    if (fkind == 2)
                        is_file = true;
                    if (is_file) {
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
                    return fail (E_INVAL);
                int kp6 = copy_path (a0, a1, 0);
                if (kp6 < 0)
                    return fail (E_INVAL);
                int id = -1;
                int kind = Vfs.resolve (kp6, a1, out id);
                int fd_kind = 0;
                int fsz = 0;
                if (kind == Vfs.KIND_XFS) {
                    fd_kind = 1;
                    fsz = Xfs.file_size (id);
                } else if (kind == Vfs.KIND_FILE) {
                    fd_kind = 2;
                    fsz = Ramfs.file_size (id);
                } else if (kind == Vfs.KIND_DEV) {
                    fd_kind = 3;
                    fsz = 0;
                } else if (kind == Vfs.KIND_DIR || kind == Vfs.KIND_XFS_DIR) {
                    return fail (E_ISDIR);
                } else {
                    return fail (E_NOENT);
                }
                // A byte device has no position: seek is not a right it holds.
                int rights6 = (fd_kind == 3)
                    ? (R_READ | R_WRITE | R_POLL | R_CLOSE)
                    : (R_READ | R_WRITE | R_SEEK | R_POLL | R_CLOSE);
                int fd6 = fd_alloc (fd_kind, rights6, id, fsz);
                if (fd6 < 0)
                    return fail (E_NOSPC);
                ok ();
                return fd6;
            case 7: // SYS_READ(fd, buf, len)
                if (!user_ok_w (a1, a2))
                    return fail (E_INVAL);
                int hc7 = fd_check (a0, R_READ);
                if (hc7 == 1)
                    return fail (E_BAD_HANDLE);
                if (hc7 == 2)
                    return fail (E_ACCES);
                int slot7 = handle_slot (a0);
                int kind7 = fd_kind_of (slot7);
                int id7 = mmio_read64 (slot7 + 8);
                if (kind7 == 3) {
                    if (a2 <= 0) {
                        ok ();
                        return 0;
                    }
                    if (id7 == Vfs.DEV_NULL) {
                        ok ();
                        return 0;
                    }
                    if (id7 == Vfs.DEV_SERIAL) {
                        int max7 = (a2 > KernelIo.CHUNK) ? KernelIo.CHUNK : a2;
                        int sc7s = KernelIo.scratch_addr ();
                        if (sc7s == 0)
                            return fail (E_IO);
                        int got7 = 0;
                        while (got7 == 0) {
                            int sr7 = serial_try_read ();
                            if (sr7 >= 0) {
                                mmio_write8 (sc7s, sr7);
                                got7 = 1;
                                break;
                            }
                            cpu_sti ();
                            cpu_hlt ();
                        }
                        while (got7 < max7) {
                            int sr7 = serial_try_read ();
                            if (sr7 < 0)
                                break;
                            mmio_write8 (sc7s + got7, sr7);
                            got7 = got7 + 1;
                        }
                        if (copy_guarded (a1, sc7s, got7) != 0)
                            return fail (E_INVAL);
                        ok ();
                        return got7;
                    }
                    int ch7 = read_console_byte ();
                    if (ch7 < 0)
                        return fail (E_IO);
                    int b7 = KernelLayout.SYSCALL_SCRATCH;
                    mmio_write8 (b7, ch7);
                    if (copy_guarded (a1, b7, 1) != 0)
                        return fail (E_INVAL);
                    ok ();
                    return 1;
                }
                int fsz7 = mmio_read64 (slot7 + 16);
                int pos7 = mmio_read64 (slot7 + 24);
                if (pos7 >= fsz7) {
                    ok ();
                    return 0;
                }
                int sc7 = KernelIo.scratch_addr ();
                if (sc7 == 0)
                    return fail (E_IO);
                int want7 = (a2 > KernelIo.CHUNK) ? KernelIo.CHUNK : a2;
                int n7 = (kind7 == 2) ? Ramfs.read (id7, pos7, sc7, want7) : Xfs.read_file (id7, pos7, sc7, want7);
                if (n7 < 0)
                    return fail (E_IO);
                if (n7 > 0) {
                    if (copy_guarded (a1, sc7, n7) != 0)
                        return fail (E_INVAL);
                    mmio_write64 (slot7 + 24, pos7 + n7);
                }
                ok ();
                return n7;
            case 8: // SYS_CLOSE(fd)
                int hc8 = fd_check (a0, R_CLOSE);
                if (hc8 == 1)
                    return fail (E_BAD_HANDLE);
                if (hc8 == 2)
                    return fail (E_ACCES);
                if (!fd_owned (a0))
                    return fail (E_ACCES);
                fd_release (handle_slot (a0));
                ok ();
                return 0;
            case 9: // SYS_FILE_SIZE(fd)
                int hc9 = fd_check (a0, 0);
                if (hc9 == 1)
                    return fail (E_BAD_HANDLE);
                if (hc9 == 2)
                    return fail (E_ACCES);
                return mmio_read64 (handle_slot (a0) + 16);
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
                int kp13 = copy_path (a0, a1, 0);
                if (kp13 < 0)
                    return fail (E_INVAL);
                return ElfLoader.exec_from_xfs (kp13, a1, a2);
            case 14: // SYS_CREATE(path_ptr, path_len) -> fd
                if (!path_ok (a0, a1))
                    return fail (E_INVAL);
                int kp14 = copy_path (a0, a1, 0);
                if (kp14 < 0)
                    return fail (E_INVAL);
                int base_ptr14 = 0;
                int base_len14 = 0;
                int parent14 = Vfs.resolve_parent (kp14, a1, out base_ptr14, out base_len14);
                if (parent14 < -1 || Vfs.reserved_name (base_ptr14, base_len14))
                    return fail (E_ACCES);
                if (parent14 == Vfs.DEV_DIR)
                    return fail (E_ACCES);
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
                        return fail (E_NOSPC);
                }
                int fd14 = fd_alloc (fd_kind14, R_WRITE | R_SEEK | R_POLL | R_CLOSE, fid14, 0);
                if (fd14 < 0)
                    return fail (E_NOSPC);
                ok ();
                return fd14;
            case 15: // SYS_WRITE(fd, buf, len)
                if (!user_ok (a1, a2))
                    return fail (E_INVAL);
                if (a0 == 1 || a0 == 2)
                    return write_console_or_stdio (a1, a2);
                int hc15 = fd_check (a0, R_WRITE);
                if (hc15 == 1)
                    return fail (E_BAD_HANDLE);
                if (hc15 == 2)
                    return fail (E_ACCES);
                int sc15 = KernelIo.scratch_addr ();
                if (sc15 == 0)
                    return fail (E_IO);
                int want15 = (a2 > KernelIo.CHUNK) ? KernelIo.CHUNK : a2;
                if (copy_guarded (sc15, a1, want15) != 0)
                    return fail (E_INVAL);
                int w15 = write_fd_data (a0, sc15, want15);
                if (w15 < 0)
                    return fail (E_IO);
                return w15;
            case 16: // SYS_SPAWN(name_ptr, name_len, cmdline_ptr) -> tid
                if (!path_ok (a0, a1) || (a2 != 0 && !user_ok (a2, 1)))
                    return fail (E_INVAL);
                int kp16 = copy_path (a0, a1, 0);
                if (kp16 < 0)
                    return fail (E_INVAL);
                return ElfLoader.spawn_from_xfs (kp16, a1, a2);
            case 17: // SYS_WAIT(tid) -> exit_code
                return Sched.wait_tid (a0);
            case 18: // SYS_PS(buf, max_bytes) -> bytes
                if (a1 <= 0 || !user_ok_w (a0, a1))
                    return fail (E_INVAL);
                int max18 = (a1 > 16384) ? 16384 : a1;
                int n18 = Sched.list_tasks (KernelLayout.IO_SCRATCH, max18);
                if (n18 > 0 && copy_guarded (a0, KernelLayout.IO_SCRATCH, n18) != 0)
                    return fail (E_INVAL);
                return n18;
            case 19: // SYS_SET_STDIO(in_fd, out_fd)
                if (a0 != -1) {
                    int hci = fd_check (a0, R_READ);
                    if (hci == 1)
                        return fail (E_BAD_HANDLE);
                    if (hci == 2)
                        return fail (E_ACCES);
                }
                if (a1 != -1) {
                    int hco = fd_check (a1, R_WRITE);
                    if (hco == 1)
                        return fail (E_BAD_HANDLE);
                    if (hco == 2)
                        return fail (E_ACCES);
                }
                Sched.set_stdio (a0, a1);
                return 0;
            case 20: // SYS_SEEK(fd, offset; -1 = end)
                int hc20 = fd_check (a0, R_SEEK);
                if (hc20 == 1)
                    return fail (E_BAD_HANDLE);
                if (hc20 == 2)
                    return fail (E_ACCES);
                int slot20 = handle_slot (a0);
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
                if (!user_ok_w (a0, 56))
                    return -1;
                Mouse.poll_state (KernelLayout.IO_SCRATCH);
                if (copy_guarded (a0, KernelLayout.IO_SCRATCH, 56) != 0)
                    return fail (E_INVAL);
                return 0;
            case 25: // SYS_FB_INFO(out_buf) -> (w<<16)|h
                if (!user_ok_w (a0, 8))
                    return -1;
                int fi25 = Fb.info (KernelLayout.IO_SCRATCH);
                if (copy_guarded (a0, KernelLayout.IO_SCRATCH, 8) != 0)
                    return fail (E_INVAL);
                return fi25;
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
                int kp28 = copy_path (a0, a1, 0);
                if (kp28 < 0)
                    return fail (E_INVAL);
                int id28 = -1;
                int kind28 = Vfs.resolve (kp28, a1, out id28);
                if (kind28 == Vfs.KIND_XFS) {
                    int bp = 0;
                    int bl = 0;
                    if (Vfs.resolve_parent (kp28, a1, out bp, out bl) == -1)
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
                    return fail (E_INVAL);
                int kp29a = copy_path (a0, a1, 0);
                int kp29b = copy_path (a2, a3, MAX_PATH);
                if (kp29a < 0 || kp29b < 0)
                    return fail (E_INVAL);
                int id29 = -1;
                int kind29 = Vfs.resolve (kp29a, a1, out id29);
                if (kind29 != Vfs.KIND_FILE && kind29 != Vfs.KIND_DIR)
                    return fail (E_NOENT);
                if (id29 < 0)
                    return fail (E_ACCES); // the root cannot be renamed
                int base_ptr29 = 0;
                int base_len29 = 0;
                int parent29 = Vfs.resolve_parent (kp29b, a3, out base_ptr29, out base_len29);
                if (parent29 < -1 || Vfs.reserved_name (base_ptr29, base_len29))
                    return fail (E_ACCES);
                if (parent29 == Vfs.DEV_DIR)
                    return fail (E_ACCES);
                if (kind29 == Vfs.KIND_DIR && Vfs.is_descendant (parent29, id29))
                    return fail (E_INVAL);
                int rn29 = Ramfs.rename_to (id29, parent29, base_ptr29, base_len29);
                return (rn29 < 0) ? fail (E_EXIST) : rn29;
            case 30: // SYS_MKDIR(path_ptr, path_len)
                if (!path_ok (a0, a1))
                    return fail (E_INVAL);
                int kp30 = copy_path (a0, a1, 0);
                if (kp30 < 0)
                    return fail (E_INVAL);
                int base_ptr30 = 0;
                int base_len30 = 0;
                int parent30 = Vfs.resolve_parent (kp30, a1, out base_ptr30, out base_len30);
                if (parent30 < -1 || Vfs.reserved_name (base_ptr30, base_len30))
                    return fail (E_ACCES);
                if (parent30 == Vfs.DEV_DIR)
                    return fail (E_ACCES);
                if (parent30 == -1 && Xfs.lookup_root (base_ptr30, base_len30) > 0)
                    return fail (E_EXIST);
                int rslot30 = Ramfs.create_in (parent30, base_ptr30, base_len30, 2);
                if (rslot30 < 0)
                    return fail (E_EXIST);
                ok ();
                return 0;
            case 31: // SYS_READDIR(path_ptr, path_len, buf, max_bytes)
                if (!path_ok (a0, a1) || !user_ok_w (a2, a3))
                    return fail (E_INVAL);
                int kp31 = copy_path (a0, a1, 0);
                if (kp31 < 0)
                    return fail (E_INVAL);
                int id31 = -1;
                int kind31 = Vfs.resolve (kp31, a1, out id31);
                if (kind31 != Vfs.KIND_DIR && kind31 != Vfs.KIND_XFS_DIR)
                    return fail (E_NOTDIR);
                int sc31 = KernelIo.scratch_addr ();
                int want31 = (a3 > KernelIo.CHUNK) ? KernelIo.CHUNK : a3;
                if (kind31 == Vfs.KIND_XFS_DIR) {
                    int n31x = Xfs.list_dir (id31, sc31, want31);
                    if (n31x < 0)
                        n31x = 0;
                    if (n31x > 0 && copy_guarded (a2, sc31, n31x) != 0)
                        return fail (E_INVAL);
                    return n31x;
                }
                if (id31 == Vfs.DEV_DIR) {
                    string names31 = "console\nserial0\nnull\n";
                    int n31d = (names31.length > want31) ? want31 : names31.length;
                    for (int i31 = 0; i31 < n31d; i31++)
                        mmio_write8 (sc31 + i31, (int) names31[i31]);
                    if (n31d > 0 && copy_guarded (a2, sc31, n31d) != 0)
                        return fail (E_INVAL);
                    return n31d;
                }
                int n31_1 = Ramfs.list_children (id31, sc31, want31);
                if (n31_1 < 0)
                    n31_1 = 0;
                int n31_2 = 0;
                if (id31 == -1 && want31 > n31_1)
                    n31_2 = Xfs.list_root (sc31 + n31_1, want31 - n31_1);
                if (n31_2 < 0)
                    n31_2 = 0;
                int tot31 = n31_1 + n31_2;
                if (tot31 > 0 && copy_guarded (a2, sc31, tot31) != 0)
                    return fail (E_INVAL);
                return tot31;
            case 32: // SYS_STAT(path_ptr, path_len) -> 0 none, 1 file, 2 dir
                if (!path_ok (a0, a1)) {
                    Sched.set_errno (E_INVAL);
                    return 0;
                }
                int kp32 = copy_path (a0, a1, 0);
                if (kp32 < 0) {
                    Sched.set_errno (E_INVAL);
                    return 0;
                }
                int id32 = -1;
                int kind32 = Vfs.resolve (kp32, a1, out id32);
                if (kind32 == Vfs.KIND_DIR || kind32 == Vfs.KIND_XFS_DIR)
                    return 2;
                if (kind32 == Vfs.KIND_FILE || kind32 == Vfs.KIND_XFS || kind32 == Vfs.KIND_DEV)
                    return 1;
                // The ABI keeps 0 = "does not exist"; the cause is in errno.
                Sched.set_errno (E_NOENT);
                return 0;
            case 33: // SYS_KEY_MODS() -> shift|ctrl<<1|alt<<2|super<<3
                return Keyboard.modifiers ();
            case 34: // SYS_RTC_TIME() -> packed UTC date/time
                return Rtc.read_packed ();
            case 35: // SYS_GETENV(k_ptr, k_len, out_buf, max_len) -> len or -1
                if (!path_ok (a0, a1) || a3 <= 0 || !user_ok_w (a2, a3))
                    return -1;
                int max35 = (a3 > 16384) ? 16384 : a3;
                int n35 = Env.sys_get (a0, a1, KernelLayout.IO_SCRATCH, max35);
                if (n35 > 0 && copy_guarded (a2, KernelLayout.IO_SCRATCH, n35) != 0)
                    return fail (E_INVAL);
                return n35;
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
                if (a0 == 0 || a1 <= 0 || a1 > 128 || !user_ok_w (a0, a1 * 64))
                    return -1;
                int n44 = Klog.read_records (KernelLayout.IO_SCRATCH, a1);
                if (n44 > 0 && copy_guarded (a0, KernelLayout.IO_SCRATCH, n44 * 64) != 0)
                    return fail (E_INVAL);
                return n44;
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
            case 50: // SYS_MAP_USER_AT(start, size) -> 0 or -1 (for .dlib loading)
                if (a0 < KernelLayout.RESERVED_END || a1 <= 0 || a1 > 0x800000 || a0 + a1 > 0x40000000)
                    return -1;
                // A2: mapping is allowed for what the caller owns, for a range a
                // grant shared with it, and for image segments nobody owns (the
                // .dlib loader). Another task's block is refused (IO-02).
                if (!range_owned (a0, a1)) {
                    if (!range_granted_to_me (a0, a1)) {
                        int p50 = a0;
                        while (p50 < a0 + a1) {
                            if (page_owned_by_other (p50) != 0)
                                return fail (E_ACCES);
                            p50 = p50 + 0x1000;
                        }
                        if (range_in_live_grant (a0, a1))
                            return fail (E_ACCES);
                    }
                }
                int ucr3_50 = Sched.current_cr3 ();
                Pmm.reserve_range (a0, a1);
                if (ucr3_50 != 0)
                    Vmm.map_user_range (ucr3_50, a0, a1);
                return 0;
            case 51: // SYS_GPU_3D_READBACK(ctx_id, res_id, width, height) -> 0 or -1
                return VirtioGpu.transfer_from_host_3d (a0, a1, a2, a3) ? 0 : -1;
            case 52: // SYS_PROTECT_USER_RO(vaddr, size) -> 0 or -1 (read-only .text/.rodata)
                if (a0 < KernelLayout.RESERVED_END || a1 <= 0 || a1 > 0x800000 || a0 + a1 > 0x40000000)
                    return -1;
                int ucr3_52 = Sched.current_cr3 ();
                if (ucr3_52 != 0)
                    Vmm.protect_user_range_ro (ucr3_52, a0, a1);
                return 0;
            case 53: // SYS_MAP_USER_RO_AT(vaddr, size) -> 0 or -1 (shared read-only .dlib mapping)
                if (a0 < KernelLayout.RESERVED_END || a1 <= 0 || a1 > 0x800000 || a0 + a1 > 0x40000000)
                    return -1;
                int ucr3_53 = Sched.current_cr3 ();
                Pmm.reserve_range (a0, a1);
                if (ucr3_53 != 0)
                    Vmm.map_user_range_ro (ucr3_53, a0, a1);
                return 0;
            case 54: // SYS_ERRNO() -> last error of this task
                return Sched.errno_code ();
            case 55: // SYS_STAT_EX(path_ptr, path_len, out16) -> kind or 0
                if (!path_ok (a0, a1) || !user_ok_w (a2, 16))
                    return fail (E_INVAL);
                int kp55 = copy_path (a0, a1, 0);
                if (kp55 < 0)
                    return fail (E_INVAL);
                int id55 = -1;
                int kind55 = Vfs.resolve (kp55, a1, out id55);
                int sz55 = 0;
                int k55 = 0;
                if (kind55 == Vfs.KIND_XFS) {
                    k55 = 1;
                    sz55 = Xfs.file_size (id55);
                } else if (kind55 == Vfs.KIND_FILE) {
                    k55 = 1;
                    sz55 = Ramfs.file_size (id55);
                } else if (kind55 == Vfs.KIND_DIR || kind55 == Vfs.KIND_XFS_DIR) {
                    k55 = 2;
                } else if (kind55 == Vfs.KIND_DEV) {
                    k55 = 1;
                } else {
                    return fail (E_NOENT);
                }
                int st55 = KernelLayout.SYSCALL_SCRATCH;
                for (int b55 = 0; b55 < 16; b55++)
                    mmio_write8 (st55 + b55, 0);
                mmio_write8 (st55 + 0, k55);
                mmio_write8 (st55 + 4, sz55 & 0xFF);
                mmio_write8 (st55 + 5, (sz55 >> 8) & 0xFF);
                mmio_write8 (st55 + 6, (sz55 >> 16) & 0xFF);
                mmio_write8 (st55 + 7, (sz55 >> 24) & 0xFF);
                if (copy_guarded (a2, st55, 16) != 0)
                    return fail (E_INVAL);
                ok ();
                return k55;
            case 56: // SYS_KLOG_WRITE(cat, level, msg_ptr, msg_len)
                if (a3 <= 0 || !user_ok (a2, a3))
                    return fail (E_INVAL);
                Klog.write_bytes (a0, a1, a2, a3);
                return 0;
            case 57: // SYS_WAIT_ADDR(addr, expected, timeout_ms)
                if (a0 < 0x1000 || a0 + 4 > USER_LIMIT)
                    return fail (E_INVAL);
                if (mmio_read32 (a0) != a1) {
                    ok ();
                    return 0;
                }
                int deadline57 = 0;
                if (a2 > 0)
                    deadline57 = (int) (mmio_read64 (KernelLayout.TICK) + (a2 + 9) / 10);
                while (true) {
                    Sched.block_on (a0, deadline57);
                    cpu_sti ();
                    cpu_hlt ();
                    Sched.unblock_self ();
                    if (mmio_read32 (a0) != a1) {
                        ok ();
                        return 0;
                    }
                    if (deadline57 != 0 && (int) mmio_read64 (KernelLayout.TICK) >= deadline57)
                        return fail (E_TIMEDOUT);
                }
            case 58: // SYS_WAKE_ADDR(addr, count) -> tasks woken
                return Sched.wake_word (a0, (a1 > 0) ? a1 : 1);
            case 59: // SYS_POLL(fds_ptr, nfds, timeout_ms) -> ready bitmask
                if (a1 <= 0 || a1 > 30 || !user_ok (a0, a1 * 4))
                    return fail (E_INVAL);
                int deadline59 = (a2 > 0)
                    ? (int) (mmio_read64 (KernelLayout.TICK) + (a2 + 9) / 10) : 0;
                while (true) {
                    int mask59 = 0;
                    for (int i59 = 0; i59 < a1; i59++) {
                        int fd59 = mmio_read32 (a0 + i59 * 4);
                        bool rd59 = false;
                        if (fd59 == 0) {
                            rd59 = console_input_ready ();
                        } else if (fd59 == 1 || fd59 == 2) {
                            rd59 = true;
                        } else if (fd_check (fd59, R_POLL) == 0) {
                            int slot59 = handle_slot (fd59);
                            int kind59 = fd_kind_of (slot59);
                            if (kind59 == 3) {
                                int dev59 = mmio_read64 (slot59 + 8);
                                if (dev59 == Vfs.DEV_SERIAL)
                                    rd59 = (serial_rx_ready () != 0);
                                else if (dev59 != Vfs.DEV_NULL)
                                    rd59 = console_input_ready ();
                            } else if (kind59 == KIND_RING || kind59 == KIND_RING_BLK || kind59 == KIND_RING_NET) {
                                int rbase59 = mmio_read64 (slot59 + 8);
                                if (user_ok (rbase59, 64)) {
                                    int rhead59 = mmio_read32 (rbase59 + 0x10);
                                    int rtail59 = mmio_read32 (rbase59 + 0x14);
                                    int rseq59 = mmio_read32 (rbase59 + 0x18);
                                    rd59 = (rseq59 != 0) || (rhead59 != rtail59)
                                        || (kind59 == KIND_RING_NET && VirtioNet.has_rx ());
                                }
                            } else {
                                rd59 = (kind59 == 1 || kind59 == 2)
                                    && mmio_read64 (slot59 + 24) < mmio_read64 (slot59 + 16);
                            }
                        }
                        if (rd59)
                            mask59 = mask59 | (1 << i59);
                    }
                    if (mask59 != 0) {
                        ok ();
                        return mask59;
                    }
                    if (a2 == 0) {
                        ok ();
                        return 0;
                    }
                    if (deadline59 != 0 && (int) mmio_read64 (KernelLayout.TICK) >= deadline59) {
                        ok ();
                        return 0;
                    }
                    cpu_sti ();
                    cpu_hlt ();
                }
            case 60: // SYS_SLEEP_MS(ms)
                if (a0 <= 0)
                    return 0;
                int deadline60 = (int) (mmio_read64 (KernelLayout.TICK) + (a0 + 9) / 10);
                while ((int) mmio_read64 (KernelLayout.TICK) < deadline60) {
                    if (Sched.has_ready_other ()) {
                        Sched.block_on (1, deadline60);
                        cpu_sti ();
                        cpu_hlt ();
                        Sched.unblock_self ();
                    } else {
                        cpu_sti ();
                        cpu_hlt ();
                    }
                }
                return 0;
            case 61: // SYS_ABI_VERSION() -> integer compared by dlib consumers
                return 2;
            case 62: // SYS_TID() -> current kernel task id
                return Sched.current_tid ();
            case 63: // SYS_GRANT(start, len) -> handle | -1
                // A grant turns a block the caller owns into a capability (A2).
                if (a0 < KernelLayout.RESERVED_END || a1 <= 0 || a1 > 0x800000 || a0 + a1 > 0x40000000)
                    return fail (E_INVAL);
                if ((a0 & 0xFFF) != 0)
                    return fail (E_INVAL);
                if (!range_owned (a0, a1))
                    return fail (E_ACCES);
                int h63 = fd_alloc (KIND_GRANT, R_READ | R_WRITE | R_CLOSE, a0, a1);
                if (h63 < 0)
                    return fail (E_NOSPC);
                ok ();
                return h63;
            case 64: // SYS_GRANT_SHARE(handle, tid) -> 0 | -1
                if (fd_check (a0, 0) != 0)
                    return fail (E_BAD_HANDLE);
                if (fd_kind_of (handle_slot (a0)) != KIND_GRANT)
                    return fail (E_INVAL);
                if (!fd_owned (a0))
                    return fail (E_ACCES);
                if (a1 <= 0)
                    return fail (E_INVAL);
                int acl64 = acl_addr (a0 & 0xFF);
                int t64 = 0;
                while (t64 < GRANT_TASKS) {
                    if (mmio_read32 (acl64 + t64 * 4) == a1) {
                        ok ();
                        return 0;
                    }
                    t64 = t64 + 1;
                }
                t64 = 0;
                while (t64 < GRANT_TASKS) {
                    if (mmio_read32 (acl64 + t64 * 4) == 0) {
                        mmio_write32 (acl64 + t64 * 4, a1);
                        ok ();
                        return 0;
                    }
                    t64 = t64 + 1;
                }
                return fail (E_NOSPC);
            case 65: // SYS_RING_ATTACH(grant_handle, entries, dev_kind) -> ring handle | -1
                if (fd_check (a0, R_READ) != 0)
                    return fail (E_BAD_HANDLE);
                if (a2 != 0 && a2 != 1 && a2 != 2)
                    return fail (E_INVAL);
                if (a2 == 1 && !VirtioBlk.is_present ())
                    return fail (E_IO);
                if (a2 == 2 && !VirtioNet.is_present ())
                    return fail (E_IO);
                int gslot65 = handle_slot (a0);
                if (fd_kind_of (gslot65) != KIND_GRANT)
                    return fail (E_INVAL);
                int rstart65 = mmio_read64 (gslot65 + 8);
                int rlen65 = mmio_read64 (gslot65 + 16);
                if (!ring_header_ok (rstart65, rlen65, a1))
                    return fail (E_INVAL);
                int rkind65 = KIND_RING;
                if (a2 == 1) rkind65 = KIND_RING_BLK;
                if (a2 == 2) rkind65 = KIND_RING_NET;
                int h65 = fd_alloc (rkind65, R_READ | R_WRITE | R_POLL | R_CLOSE,
                                    rstart65, rlen65);
                if (h65 < 0)
                    return fail (E_NOSPC);
                mmio_write64 (handle_slot (h65) + 24, a1);
                ok ();
                return h65;
            case 66: // SYS_RING_KICK(ring_handle) -> completed | -1 when a descriptor is bad
                if (fd_check (a0, R_WRITE) != 0)
                    return fail (E_BAD_HANDLE);
                int rslot66 = handle_slot (a0);
                int rkind66 = fd_kind_of (rslot66);
                if (rkind66 != KIND_RING && rkind66 != KIND_RING_BLK && rkind66 != KIND_RING_NET)
                    return fail (E_INVAL);
                int rstart66 = mmio_read64 (rslot66 + 8);
                int rlen66 = mmio_read64 (rslot66 + 16);
                int entries66 = mmio_read64 (rslot66 + 24);
                if (!user_range_ok (rstart66, rlen66, true))
                    return fail (E_INVAL);
                if (!ring_header_ok (rstart66, rlen66, entries66))
                    return fail (E_INVAL);
                int head66 = mmio_read32 (rstart66 + 16) & (entries66 - 1);
                int tail66 = mmio_read32 (rstart66 + 20) & (entries66 - 1);
                int done66 = 0;
                int budget66 = entries66;
                int seen_cnt66 = 0;
                while (head66 != tail66 && budget66 > 0) {
                    int desc66 = rstart66 + 64 + head66 * RING_ENTRY;
                    if (mmio_read32 (desc66 + 20) == RING_ST_READY) {
                        int lid66 = mmio_read32 (desc66 + 16);
                        if (lid66 != 0) {
                            for (int li66 = 0; li66 < seen_cnt66; li66++) {
                                if (kick_seen_leases[li66] == lid66) {
                                    mmio_write32 (desc66 + 20, RING_ST_ERROR);
                                    return fail (E_ACCES);
                                }
                            }
                            if (seen_cnt66 < RING_MAX_ENTRIES) {
                                kick_seen_leases[seen_cnt66] = lid66;
                                seen_cnt66 = seen_cnt66 + 1;
                            }
                        }
                        if (ring_run_one (rstart66, rlen66, entries66, desc66, rkind66) == 0)
                            return fail (E_INVAL);
                        done66 = done66 + 1;
                    }
                    head66 = (head66 + 1) & (entries66 - 1);
                    mmio_write32 (rstart66 + 16, head66);
                    budget66 = budget66 - 1;
                }
                mmio_write32 (rstart66 + 24, mmio_read32 (rstart66 + 24) + 1);
                Sched.wake_word (rstart66 + 24, 1);
                ok ();
                return done66;
            case 67: // SYS_BLK_READ(buf, sector, count) -> bytes | -1
                if (a2 <= 0 || a2 > 64)
                    return fail (E_INVAL);
                if (!user_ok_w (a0, a2 * 512))
                    return fail (E_INVAL);
                if (!VirtioBlk.read (a1, a0, a2))
                    return fail (E_IO);
                ok ();
                return a2 * 512;
            case 68: // SYS_BLK_STATS() -> late << 24 | wakes << 16 | capacity in MiB
                return (VirtioBlk.irq_late () << 24)
                    | ((VirtioBlk.irq_wakes () << 16) & 0xFF0000)
                    | ((VirtioBlk.capacity_sectors () / 2048) & 0xFFFF);
            case 69: // SYS_NET_MAC(out_buf) -> 0 | -1
                if (!VirtioNet.is_present ())
                    return fail (E_IO);
                if (!user_ok_w (a0, 6))
                    return fail (E_INVAL);
                for (int i69 = 0; i69 < 6; i69++)
                    mmio_write8 (a0 + i69, VirtioNet.mac_byte (i69));
                ok ();
                return 0;
            case 70: // SYS_HANDLE_SEND(target_tid, handle) -> new_handle | -1
                if (!Sched.is_task_live (a0))
                    return fail (E_INVAL);
                if (fd_check (a1, 0) != 0)
                    return fail (E_BAD_HANDLE);
                if (!fd_owned (a1))
                    return fail (E_ACCES);
                int sslot70 = handle_slot (a1);
                int skind70 = fd_kind_of (sslot70);
                int srights70 = fd_rights_of (sslot70);
                int sid70 = mmio_read64 (sslot70 + 8);
                int ssz70 = mmio_read64 (sslot70 + 16);
                int sext70 = mmio_read64 (sslot70 + 24);
                int nh70 = fd_alloc_for (a0, skind70, srights70, sid70, ssz70, sext70);
                if (nh70 < 0)
                    return fail (E_NOSPC);
                if (!inbox_push (a0, nh70)) {
                    fd_release (handle_slot (nh70));
                    return fail (E_NOSPC);
                }
                if (skind70 == KIND_GRANT && a0 > 0) {
                    int acl70 = acl_addr (a1 & 0xFF);
                    for (int t70 = 0; t70 < GRANT_TASKS; t70++) {
                        int cur70 = mmio_read32 (acl70 + t70 * 4);
                        if (cur70 == a0)
                            break;
                        if (cur70 == 0) {
                            mmio_write32 (acl70 + t70 * 4, a0);
                            break;
                        }
                    }
                }
                ok ();
                return nh70;
            case 71: // SYS_HANDLE_RECV() -> handle | -1
                int rh71 = inbox_pop (Sched.current_tid ());
                if (rh71 < 0)
                    return fail (E_AGAIN);
                ok ();
                return rh71;
            case 72: // SYS_HANDLE_INFO(handle, out_buf16) -> kind | -1
                if (fd_check (a0, 0) != 0)
                    return fail (E_BAD_HANDLE);
                if (!fd_owned (a0))
                    return fail (E_ACCES);
                if (!user_ok_w (a1, 16))
                    return fail (E_INVAL);
                int slot72 = handle_slot (a0);
                int k72 = fd_kind_of (slot72);
                int sc72 = KernelLayout.SYSCALL_SCRATCH;
                mmio_write64 (sc72 + 0, mmio_read64 (slot72 + 8));
                mmio_write64 (sc72 + 8, mmio_read64 (slot72 + 16));
                if (copy_guarded (a1, sc72, 16) != 0)
                    return fail (E_INVAL);
                ok ();
                return k72;
            case 73: // SYS_MEM_FREE() -> free 4 KiB frames left in the user pool
                ok ();
                return Pmm.free_frames ();
            default:
                return -1;
        }
    }

    private static string fault_name (int vec) {
        switch (vec) {
            case 0: return "Divide Error (#DE)";
            case 1: return "Debug (#DB)";
            case 2: return "Non-Maskable Interrupt";
            case 3: return "Breakpoint (#BP)";
            case 4: return "Overflow (#OF)";
            case 5: return "Bound Range Exceeded (#BR)";
            case 6: return "Invalid Opcode (#UD)";
            case 7: return "Device Not Available (#NM)";
            case 8: return "Double Fault (#DF)";
            case 10: return "Invalid TSS (#TS)";
            case 11: return "Segment Not Present (#NP)";
            case 12: return "Stack Segment Fault (#SS)";
            case 13: return "General Protection Fault (#GP)";
            case 14: return "Page Fault (#PF)";
            case 16: return "x87 FPU Error (#MF)";
            case 17: return "Alignment Check (#AC)";
            case 18: return "Machine Check (#MC)";
            case 19: return "SIMD FP Exception (#XM)";
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

    private static int fault_depth = 0;

    public int fault_dispatch (int vec, int err, int rip, int cr2) {
        // A kernel-mode fault inside a guarded copy is recoverable: restore the
        // copy frame and let it return 1 to the syscall handler (KR-07).
        if (vec == 14 && (err & 4) == 0 && mmio_read64 (KernelLayout.COPY_VARS) == 1) {
            copy_recover ();
        }
        fault_depth = fault_depth + 1;
        if (fault_depth > 1) {
            print ("\n[fault] nested fault\n");
            while (true) {
                cpu_hlt ();
            }
        }
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
        fault_depth = 0;
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

    // Syscall entry (int 0x80, DPL=3 interrupt gate -> IF=0 on entry).
    // Precondition: cld guarantees ascending string ops for Vala/kernel helpers.
    // Preserves caller-clobbered registers not in SysV return (rcx, rdx, rsi, rdi,
    // r8-r11), remaps ABI (rax=num, rdi=a0, rsi=a1, rdx=a2) -> (rdi, rsi, rdx, rcx),
    // calls syscall_dispatch, and returns to Ring 3 via iretq with result in rax.
    [AsmBody(@"
        # int 0x80 entry: rax=num, rdi=a0, rsi=a1, rdx=a2, r8=a3 -> returns in rax
        cld
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
            for (int slot = 0; slot < MAX_FDS; slot++) {
                mmio_write64 (KernelLayout.FD_TABLE + slot * 32 + 0, 0);
                mmio_write64 (KernelLayout.FD_TABLE + slot * 32 + 8, 0);
                mmio_write64 (KernelLayout.FD_TABLE + slot * 32 + 16, 0);
                mmio_write64 (KernelLayout.FD_TABLE + slot * 32 + 24, 0);
            }
            for (int i = 0; i < ALLOC_SLOTS; i++) {
                mmio_write64 (KernelLayout.ALLOC_TABLE + i * 16 + 0, 0);
                mmio_write64 (KernelLayout.ALLOC_TABLE + i * 16 + 8, 0);
            }
            for (int i = 0; i < MAX_FDS * GRANT_TASKS; i++)
                mmio_write32 (KernelLayout.GRANT_ACL + i * 4, 0);
            handle_inbox = new int[16 * INBOX_SLOTS];
            kick_seen_leases = new int[RING_MAX_ENTRIES];
            Hal.set_idt_gate_dpl (0x80, addr_isr_syscall (), 1);
        }
    }
}
