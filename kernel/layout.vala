// Fixed low-memory layout of the kernel's non-compiler-placed structures.
//
// Everything below 0x200000 is hand-partitioned: the bootstrapper builds its
// page tables there before paging is on, and the kernel keeps its byte buffers
// in the same window. planc cannot place byte buffers in .bss (it has no
// arrays, only scalar globals), so those structures keep physical addresses;
// what changes here is that the partition is declared once instead of being
// spread over ten files as independent magic numbers.
//
// Two checks consume this table:
//   * tools/check_layout.py parses it at build time and fails the build when a
//     region leaves the window, when two regions overlap, when the produced
//     image reaches into the window, or when an address that only exists as a
//     literal inside an asm body drifts away from its constant.
//   * KernelLayout.verify () walks the same regions at boot and refuses to run
//     on a broken table. Regions are declared in ascending address order, so a
//     single cursor proves both the ordering and the disjointness.
//
// planc folds `const` initialisers only when they are plain integer literals,
// hence no BASE + OFFSET arithmetic below.

namespace Planet.Kernel {

    // Address just past the last region checked by verify (), kept as a global
    // so the walk needs no table: the language has no arrays to hold one.
    private int layout_cursor = 0;

    public class KernelLayout : Object {
        // Window start (boot page tables) and end (past the FXSAVE area).
        public const int WINDOW_BASE = 0x100000;
        public const int WINDOW_END = 0x129000;

        // The boot stack lives in [STACK_LIMIT, STACK_TOP) and grows down from
        // STACK_TOP, so nothing else may be placed above WINDOW_END.
        public const int STACK_TOP = 0x200000;
        public const int STACK_LIMIT = 0x1F0000;

        // Pmm starts handing out frames at RESERVED_END: it has to stay above
        // the window or the bitmap itself would become allocatable.
        public const int RESERVED_END = 0x600000;

        // planc --freestanding loads the image here and it grows upwards, away
        // from everything in the window.
        public const int IMAGE_BASE = 0x400000;

        // --- boot asm owns these (addresses appear as literals) ------------
        public const int PAGE_TABLES = 0x100000;   // PML4 / PDPT / PD / PD3
        public const int PAGE_TABLES_SIZE = 0x4000;
        public const int PDPT = 0x101000;
        public const int PD = 0x102000;            // 2 MiB PD entries the Vmm splits
        public const int PD3 = 0x103000;           // Fb framebuffer PD
        public const int GDT = 0x104000;
        public const int GDTR = 0x104040;
        public const int TSS = 0x104100;
        public const int TSS_RSP0 = 0x104104;      // kernel rsp0, rewritten per exec
        public const int GDT_TSS_SIZE = 0x200;
        public const int IDT = 0x105000;
        public const int IDT_SIZE = 0x1000;
        public const int TICK = 0x106000;          // Hal.tick counter
        public const int IDTR = 0x106010;
        public const int CPUID_BUF = 0x106020;     // cpuid vendor scratch
        public const int CPU_VARS_SIZE = 0x40;
        public const int MB_INFO = 0x106040;       // boot asm stores the EBX pointer here
        public const int MB_INFO_SIZE = 0x8;

        // --- PS/2 input rings ---------------------------------------------
        public const int KB_RING = 0x106100;       // 64 scancodes, mask 63
        public const int KB_RING_SIZE = 0x40;
        public const int KB_HEAD = 0x106140;
        public const int KB_TAIL = 0x106148;
        public const int KB_POS_SIZE = 0x10;
        public const int MOUSE_RING = 0x106300;    // 256 bytes, mask 255
        public const int MOUSE_RING_SIZE = 0x100;
        public const int MOUSE_HEAD = 0x106400;
        public const int MOUSE_TAIL = 0x106408;
        public const int MOUSE_POS_SIZE = 0x10;

        // --- nested SYS_EXEC bookkeeping ----------------------------------
        // 32 bytes per level: saved rsp, cr3 and rsp0. The guard in
        // ElfLoader.exec_from_xfs keeps the level count inside this region.
        public const int EXEC_SLOTS = 0x106200;
        public const int EXEC_SLOT_SIZE = 0x20;
        public const int EXEC_SLOTS_SIZE = 0x100;
        public const int EXEC_MAX_DEPTH = 8;

        // Byte buffer for SYS_READ_KEY when stdin is a ramfs file. It used to
        // sit at 0x106210, inside the first EXEC_SLOTS entry.
        public const int SYSCALL_SCRATCH = 0x106800;
        public const int SYSCALL_SCRATCH_SIZE = 0x10;

        // --- kernel tables -------------------------------------------------
        public const int FD_TABLE = 0x107000;      // 16 slots x 32 bytes
        public const int FD_TABLE_SIZE = 0x200;
        public const int KLOG_RING = 0x108000;     // 128 records x 64 bytes
        public const int KLOG_RING_SIZE = 0x2000;
        public const int PMM_BITMAP = 0x110000;    // 64 MiB / 4 KiB frames
        public const int PMM_BITMAP_SIZE = 0x800;
        public const int RAMFS_TABLE = 0x120000;   // 32 slots x 256 bytes
        public const int RAMFS_TABLE_SIZE = 0x2000;
        public const int SCHED_CUR = 0x123FF0;     // current tid
        public const int SCHED_ENABLED = 0x123FF8; // scheduler armed
        public const int SCHED_VARS_SIZE = 0x10;
        public const int TCB_TABLE = 0x124000;     // 16 tasks x 128 bytes
        public const int TCB_TABLE_SIZE = 0x800;
        public const int FXSAVE_AREA = 0x125000;   // 16 tasks x 1024 bytes (XSAVE x87+SSE+AVX)
        public const int FXSAVE_AREA_SIZE = 0x4000;

        // --- legacy bootstrap stack used by ElfLoader.load_and_run --------
        public const int LEGACY_STACK = 0x1FE000;
        public const int LEGACY_ARGV = 0x1FE800;

        // Region identifiers, returned as 100 + id (out of order or
        // overlapping) or 200 + id (past WINDOW_END) by verify ().
        private const int R_PAGE_TABLES = 1;
        private const int R_GDT_TSS = 2;
        private const int R_IDT = 3;
        private const int R_CPU_VARS = 4;
        private const int R_MB_INFO = 5;
        private const int R_KB_RING = 6;
        private const int R_KB_POS = 7;
        private const int R_EXEC_SLOTS = 8;
        private const int R_MOUSE_RING = 9;
        private const int R_MOUSE_POS = 10;
        private const int R_SYSCALL_SCRATCH = 11;
        private const int R_FD_TABLE = 12;
        private const int R_KLOG_RING = 18;
        private const int R_PMM_BITMAP = 13;
        private const int R_RAMFS_TABLE = 14;
        private const int R_SCHED_VARS = 15;
        private const int R_TCB_TABLE = 16;
        private const int R_FXSAVE_AREA = 17;

        private static int step (int id, int addr, int size) {
            if (size <= 0 || addr < layout_cursor)
                return 100 + id;
            if (addr + size > WINDOW_END)
                return 200 + id;
            layout_cursor = addr + size;
            return 0;
        }

        // 0 when the fixed regions are disjoint, ascending and inside the
        // window and the window itself stays clear of the boot stack, the PMM
        // and the kernel image.
        public static int verify () {
            layout_cursor = WINDOW_BASE;
            int r = step (R_PAGE_TABLES, PAGE_TABLES, PAGE_TABLES_SIZE);
            if (r != 0) return r;
            r = step (R_GDT_TSS, GDT, GDT_TSS_SIZE);
            if (r != 0) return r;
            r = step (R_IDT, IDT, IDT_SIZE);
            if (r != 0) return r;
            r = step (R_CPU_VARS, TICK, CPU_VARS_SIZE);
            if (r != 0) return r;
            r = step (R_MB_INFO, MB_INFO, MB_INFO_SIZE);
            if (r != 0) return r;
            r = step (R_KB_RING, KB_RING, KB_RING_SIZE);
            if (r != 0) return r;
            r = step (R_KB_POS, KB_HEAD, KB_POS_SIZE);
            if (r != 0) return r;
            r = step (R_EXEC_SLOTS, EXEC_SLOTS, EXEC_SLOTS_SIZE);
            if (r != 0) return r;
            r = step (R_MOUSE_RING, MOUSE_RING, MOUSE_RING_SIZE);
            if (r != 0) return r;
            r = step (R_MOUSE_POS, MOUSE_HEAD, MOUSE_POS_SIZE);
            if (r != 0) return r;
            r = step (R_SYSCALL_SCRATCH, SYSCALL_SCRATCH, SYSCALL_SCRATCH_SIZE);
            if (r != 0) return r;
            r = step (R_FD_TABLE, FD_TABLE, FD_TABLE_SIZE);
            if (r != 0) return r;
            r = step (R_KLOG_RING, KLOG_RING, KLOG_RING_SIZE);
            if (r != 0) return r;
            r = step (R_PMM_BITMAP, PMM_BITMAP, PMM_BITMAP_SIZE);
            if (r != 0) return r;
            r = step (R_RAMFS_TABLE, RAMFS_TABLE, RAMFS_TABLE_SIZE);
            if (r != 0) return r;
            r = step (R_SCHED_VARS, SCHED_CUR, SCHED_VARS_SIZE);
            if (r != 0) return r;
            r = step (R_TCB_TABLE, TCB_TABLE, TCB_TABLE_SIZE);
            if (r != 0) return r;
            r = step (R_FXSAVE_AREA, FXSAVE_AREA, FXSAVE_AREA_SIZE);
            if (r != 0) return r;

            if (WINDOW_END > STACK_LIMIT)
                return 300; // the window would run into the boot stack
            if (WINDOW_BASE < PAGE_TABLES)
                return 301;
            if (RESERVED_END < WINDOW_END)
                return 302; // Pmm would hand out frames inside the window
            if (IMAGE_BASE < WINDOW_END)
                return 303; // the image grows into the window
            return 0;
        }
    }
}
