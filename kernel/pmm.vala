// Physical Memory Manager (PMM): Fibonacci Buddy System over 4 KiB frames (TAOCP Vol. 1, Sec. 2.5).
//
// Metadata lives in the KernelLayout.PMM_BITMAP window (0x110000..0x119000):
//   +0x0000..+0x7FFF: META[0..16383] (16 bits per frame: free, is_root, order, lbc)
//   +0x8000..+0x805F: AVAIL[0..23]   (32-bit head frame index per Fibonacci order, -1 = empty)
//   +0x8100..+0x815F: FIB[0..23]     (32-bit precomputed Fibonacci block sizes in 4 KiB pages)
// Doubly-linked free-list pointers (next, prev) are stored in the first 8 bytes of each free page.

namespace Planet.Kernel {

    [AsmBody(@"
        mov (%rdi), %eax
        ret
    ")]
    public extern int mmio_read32 (int addr);

    [AsmBody(@"
        mov %esi, (%rdi)
        ret
    ")]
    public extern void mmio_write32 (int addr, int val);

    [AsmBody(@"
        # zero_page(phys_addr in rdi)
        mov %rdi, %rax
        mov $512, %rcx
        xor %rdx, %rdx
    _zp_loop:
        mov %rdx, (%rax)
        add $8, %rax
        dec %rcx
        jnz _zp_loop
        ret
    ")]
    public extern void zero_page_4k (int phys_addr);

    [AsmBody(@"
        # poison_page_4k(phys_addr in rdi) with 0xAA
        mov %rdi, %rax
        mov $512, %rcx
        mov $0xAAAAAAAAAAAAAAAA, %rdx
    _pp_loop:
        mov %rdx, (%rax)
        add $8, %rax
        dec %rcx
        jnz _pp_loop
        ret
    ")]
    public extern void poison_page_4k (int phys_addr);

    public sealed class Pmm : Object {
        private static int pmm_total_frames = 0;
        private static int pmm_free_count = 0;
        private static int pmm_double_free_count = 0;
        private const int PAGE_SIZE = 4096;
        private const int MAX_BYTES = 0x4000000;   // 64 MiB cap (16384 frames)
        private const int MAX_FRAMES = MAX_BYTES / PAGE_SIZE;
        private const int MAX_ORDER = 23;          // F[22] = 17711 > 16384

        private const int META_BASE = KernelLayout.PMM_BITMAP;
        private const int AVAIL_BASE = META_BASE + 0x8000;
        private const int FIB_BASE = AVAIL_BASE + 0x100;

        // 16-bit META layout per frame:
        // bit 15: free (1 = head of free block, 0 = allocated or interior)
        // bit 14: is_root (1 = Zeckendorf root boundary, do not coalesce left past it)
        // bits 11..7: order (0..22)
        // bits 6..0:  lbc (Left-Buddy Count)
        private const int META_FREE = 0x8000;
        private const int META_ROOT = 0x4000;
        private const int NIL = 0; // frame 0 is always reserved (< RESERVED_END), safe 32-bit sentinel

        private static int read_meta (int frame) {
            int addr = META_BASE + (frame & ~1) * 2;
            int w = mmio_read32 (addr);
            if ((frame & 1) != 0)
                return (w >> 16) & 0xFFFF;
            return w & 0xFFFF;
        }

        private static void write_meta (int frame, int val) {
            int addr = META_BASE + (frame & ~1) * 2;
            int w = mmio_read32 (addr);
            if ((frame & 1) != 0)
                w = (w & 0xFFFF) | ((val & 0xFFFF) << 16);
            else
                w = (w & ~0xFFFF) | (val & 0xFFFF);
            mmio_write32 (addr, w);
        }

        private static int pack_meta (bool is_free, bool is_root, int order, int lbc) {
            int v = (order & 0x1F) << 7;
            v = v | (lbc & 0x7F);
            if (is_free)
                v = v | META_FREE;
            if (is_root)
                v = v | META_ROOT;
            return v;
        }

        private static bool meta_is_free (int m) { return (m & META_FREE) != 0; }
        private static bool meta_is_root (int m) { return (m & META_ROOT) != 0; }
        private static int meta_order (int m) { return (m >> 7) & 0x1F; }
        private static int meta_lbc (int m) { return m & 0x7F; }

        private static int fib_size (int order) {
            return mmio_read32 (FIB_BASE + order * 4);
        }

        private static int avail_head (int order) {
            return mmio_read32 (AVAIL_BASE + order * 4);
        }

        private static void set_avail_head (int order, int frame) {
            mmio_write32 (AVAIL_BASE + order * 4, frame);
        }

        // Frame zeroing, poisoning and free-list pointer updates are scratch accesses
        // to physical pages. A user CR3 may have those pages unmapped, so switch to
        // the kernel identity map and restore the caller's CR3 afterwards.
        private static int kernel_cr3_enter () {
            int cur = vmm_read_cr3 ();
            if (cur != KernelLayout.PAGE_TABLES)
                vmm_write_cr3 (KernelLayout.PAGE_TABLES);
            return cur;
        }

        private static void kernel_cr3_leave (int saved) {
            if (saved != KernelLayout.PAGE_TABLES)
                vmm_write_cr3 (saved);
        }

        private static void poison_frame (int phys) {
            int saved = kernel_cr3_enter ();
            poison_page_4k (phys);
            kernel_cr3_leave (saved);
        }

        private static void list_insert (int frame, int order, bool is_root, int lbc) {
            write_meta (frame, pack_meta (true, is_root, order, lbc));
            int head = avail_head (order);
            int phys = frame * PAGE_SIZE;
            int saved = kernel_cr3_enter ();
            mmio_write32 (phys, head);
            mmio_write32 (phys + 4, NIL);
            if (head != NIL)
                mmio_write32 (head * PAGE_SIZE + 4, frame);
            kernel_cr3_leave (saved);
            set_avail_head (order, frame);
        }

        private static void list_remove (int frame, int order) {
            int phys = frame * PAGE_SIZE;
            int saved = kernel_cr3_enter ();
            int next = mmio_read32 (phys);
            int prev = mmio_read32 (phys + 4);
            if (prev != NIL)
                mmio_write32 (prev * PAGE_SIZE, next);
            else
                set_avail_head (order, next);
            if (next != NIL)
                mmio_write32 (next * PAGE_SIZE + 4, prev);
            kernel_cr3_leave (saved);
        }

        private static void add_free_range (int start_f, int end_f) {
            int cur = start_f;
            while (cur < end_f) {
                int rem = end_f - cur;
                int k = MAX_ORDER - 1;
                while (k > 0 && fib_size (k) > rem)
                    k = k - 1;
                int sz = fib_size (k);
                list_insert (cur, k, true, 0);
                pmm_free_count = pmm_free_count + sz;
                cur = cur + sz;
            }
        }

        public static void init () {
            int mb = mmio_read32 (KernelLayout.MB_INFO);
            int mem_bytes = 0x2000000; // default 32 MiB fallback
            if (mb != 0) {
                int flags = mmio_read32 (mb);
                if ((flags & 1) != 0) {
                    int mem_upper_kb = mmio_read32 (mb + 8);
                    int calc = 0x100000 + mem_upper_kb * 1024;
                    if (calc > KernelLayout.RESERVED_END)
                        mem_bytes = calc;
                }
            }
            if (mem_bytes > MAX_BYTES)
                mem_bytes = MAX_BYTES;

            pmm_total_frames = mem_bytes / PAGE_SIZE;
            pmm_free_count = 0;

            // Precompute Fibonacci sizes F[0]=1, F[1]=1, F[k]=F[k-1]+F[k-2]
            mmio_write32 (FIB_BASE, 1);
            mmio_write32 (FIB_BASE + 4, 1);
            for (int k = 2; k < MAX_ORDER; k++) {
                int f = mmio_read32 (FIB_BASE + (k - 1) * 4) + mmio_read32 (FIB_BASE + (k - 2) * 4);
                mmio_write32 (FIB_BASE + k * 4, f);
            }

            // Initialize AVAIL heads to NIL and clear META table
            for (int k = 0; k < MAX_ORDER; k++)
                set_avail_head (k, NIL);
            for (int w = 0; w < MAX_FRAMES / 2; w++)
                mmio_write32 (META_BASE + w * 4, 0);

            int first_free = KernelLayout.RESERVED_END / PAGE_SIZE;
            int res_start = 0x800000 / PAGE_SIZE;
            int res_end = 0x1000000 / PAGE_SIZE;

            // Add free ranges excluding reserved 8..16 MiB static userland ELF load bases
            if (first_free < res_start) {
                int top1 = (pmm_total_frames < res_start) ? pmm_total_frames : res_start;
                add_free_range (first_free, top1);
            }
            if (pmm_total_frames > res_end) {
                int bot2 = (first_free > res_end) ? first_free : res_end;
                int dlib_start = 0x1800000 / PAGE_SIZE;
                int dlib_end = 0x2000000 / PAGE_SIZE;
                if (bot2 < dlib_start) {
                    int top2 = (pmm_total_frames < dlib_start) ? pmm_total_frames : dlib_start;
                    add_free_range (bot2, top2);
                }
                if (pmm_total_frames > dlib_end) {
                    int bot3 = (bot2 > dlib_end) ? bot2 : dlib_end;
                    add_free_range (bot3, pmm_total_frames);
                }
            }
        }

        // Split block `frame` of `order` into 1-page leaves for the first `want` pages
        // (marked allocated) and return any remaining `F[order] - want` pages to AVAIL.
        private static void assign_split (int frame, int order, bool is_root, int lbc, int want) {
            if (want <= 0) {
                list_insert (frame, order, is_root, lbc);
                return;
            }
            if (order <= 1) {
                write_meta (frame, pack_meta (false, is_root, order, lbc));
                return;
            }
            int left_sz = fib_size (order - 1);
            if (want <= left_sz) {
                assign_split (frame, order - 1, is_root, lbc + 1, want);
                list_insert (frame + left_sz, order - 2, false, 0);
            } else {
                assign_split (frame, order - 1, is_root, lbc + 1, left_sz);
                assign_split (frame + left_sz, order - 2, false, 0, want - left_sz);
            }
        }

        public static int alloc_frame () {
            return alloc_contiguous (1);
        }

        public static void free_frame (int phys) {
            if (phys < KernelLayout.RESERVED_END || (phys & 4095) != 0)
                return;
            int frame = phys / PAGE_SIZE;
            if (frame >= pmm_total_frames)
                return;
            int irq = cpu_irq_save ();
            int m = read_meta (frame);
            if (meta_is_free (m)) {
                pmm_double_free_count = pmm_double_free_count + 1;
                print ("pmm:double_free\n");
                cpu_irq_restore (irq);
                return;
            }
            poison_frame (phys);
            pmm_free_count = pmm_free_count + 1;

            int order = meta_order (m);
            bool is_root = meta_is_root (m);
            int lbc = meta_lbc (m);

            // Coalesce with Fibonacci buddy while possible
            while (order < MAX_ORDER - 1) {
                if (lbc == 0 && is_root)
                    break;
                if (lbc > 0) {
                    // Left buddy: right buddy is at frame + F[order] with order - 1
                    int b_order = order - 1;
                    int buddy = frame + fib_size (order);
                    if (buddy >= pmm_total_frames)
                        break;
                    int bm = read_meta (buddy);
                    if (!meta_is_free (bm) || meta_order (bm) != b_order || meta_lbc (bm) != 0)
                        break;
                    list_remove (buddy, b_order);
                    write_meta (buddy, 0);
                    order = order + 1;
                    lbc = lbc - 1;
                } else {
                    // Right buddy (lbc == 0, !is_root): left buddy is at frame - F[order + 1]
                    int b_order = order + 1;
                    int buddy = frame - fib_size (b_order);
                    if (buddy < 0)
                        break;
                    int bm = read_meta (buddy);
                    if (!meta_is_free (bm) || meta_order (bm) != b_order || meta_lbc (bm) == 0)
                        break;
                    list_remove (buddy, b_order);
                    write_meta (frame, 0);
                    frame = buddy;
                    order = order + 2;
                    is_root = meta_is_root (bm);
                    lbc = meta_lbc (bm) - 1;
                }
            }
            list_insert (frame, order, is_root, lbc);
            cpu_irq_restore (irq);
        }

        public static int alloc_contiguous (int num_pages) {
            if (num_pages <= 0)
                return 0;

            int req_order = 0;
            while (req_order < MAX_ORDER && fib_size (req_order) < num_pages)
                req_order = req_order + 1;
            if (req_order >= MAX_ORDER)
                return 0;

            int irq = cpu_irq_save ();
            int j = req_order;
            while (j < MAX_ORDER && avail_head (j) == NIL)
                j = j + 1;
            if (j >= MAX_ORDER) {
                cpu_irq_restore (irq);
                return 0;
            }

            int frame = avail_head (j);
            int m = read_meta (frame);
            list_remove (frame, j);

            assign_split (frame, j, meta_is_root (m), meta_lbc (m), num_pages);
            pmm_free_count = pmm_free_count - num_pages;

            int saved = kernel_cr3_enter ();
            for (int k = 0; k < num_pages; k++)
                zero_page_4k ((frame + k) * PAGE_SIZE);
            kernel_cr3_leave (saved);
            cpu_irq_restore (irq);
            return frame * PAGE_SIZE;
        }

        public static void reserve_range (int start_addr, int size) {
            // Initial static reservations (0x800000..0x1000000) are excluded in init().
            // Kept for API compatibility.
            if (size <= 0 || start_addr < 0)
                return;
        }

        public static int free_frames () {
            return pmm_free_count;
        }
    }
}
