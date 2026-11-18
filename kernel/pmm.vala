// Physical Memory Manager (PMM): 4 KiB frame bitmap allocator.

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

    private int pmm_total_frames = 0;
    private int pmm_free_count = 0;
    private int pmm_double_free_count = 0;

    public class Pmm : Object {
        private const int PAGE_SIZE = 4096;
        private const int MAX_BYTES = 0x4000000;   // 64 MiB cap (16384 frames = 2048 B bitmap)

        private static void set_bit (int frame) {
            int byte_idx = frame >> 3;
            int bit = frame & 7;
            int addr = KernelLayout.PMM_BITMAP + byte_idx;
            int v = mmio_read32 (addr & ~3);
            int shift = (addr & 3) * 8 + bit;
            mmio_write32 (addr & ~3, v | (1 << shift));
        }

        private static void clear_bit (int frame) {
            int byte_idx = frame >> 3;
            int bit = frame & 7;
            int addr = KernelLayout.PMM_BITMAP + byte_idx;
            int v = mmio_read32 (addr & ~3);
            int shift = (addr & 3) * 8 + bit;
            mmio_write32 (addr & ~3, v & ~(1 << shift));
        }

        private static bool test_bit (int frame) {
            int byte_idx = frame >> 3;
            int bit = frame & 7;
            int addr = KernelLayout.PMM_BITMAP + byte_idx;
            int v = mmio_read32 (addr & ~3);
            int shift = (addr & 3) * 8 + bit;
            return ((v >> shift) & 1) != 0;
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

            // Mark all frames used initially
            int words = (pmm_total_frames + 31) / 32;
            for (int w = 0; w < words; w++) {
                mmio_write32 (KernelLayout.PMM_BITMAP + w * 4, -1);
            }

            // Free frames from RESERVED_END .. pmm_total_frames
            int first_free = KernelLayout.RESERVED_END / PAGE_SIZE;
            for (int f = first_free; f < pmm_total_frames; f++) {
                clear_bit (f);
                pmm_free_count = pmm_free_count + 1;
            }
            // Reserve 8..16 MiB for static userland ELF load bases (0x800000..0x1000000)
            reserve_range (0x800000, 0x800000);
        }

        // Frame zeroing and poisoning are scratch writes to a physical page. A
        // user CR3 can have that page unmapped (a resource destroy unmaps it
        // before releasing the frame), so do them under the kernel identity map
        // and restore the caller's CR3 afterwards.
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

        private static void zero_frame (int phys) {
            int saved = kernel_cr3_enter ();
            zero_page_4k (phys);
            kernel_cr3_leave (saved);
        }

        private static void poison_frame (int phys) {
            int saved = kernel_cr3_enter ();
            poison_page_4k (phys);
            kernel_cr3_leave (saved);
        }

        public static int alloc_frame () {            int first_free = KernelLayout.RESERVED_END / PAGE_SIZE;
            for (int f = first_free; f < pmm_total_frames; f++) {
                if (!test_bit (f)) {
                    set_bit (f);
                    pmm_free_count = pmm_free_count - 1;
                    int phys = f * PAGE_SIZE;
                    zero_frame (phys);
                    return phys;
                }
            }
            return 0;
        }

        public static void free_frame (int phys) {
            if (phys < KernelLayout.RESERVED_END || (phys & 4095) != 0)
                return;
            int f = phys / PAGE_SIZE;
            if (f >= pmm_total_frames)
                return;
            if (!test_bit (f)) {
                pmm_double_free_count = pmm_double_free_count + 1;
                print ("pmm:double_free\n");
                return;
            }
            poison_frame (phys);
            clear_bit (f);
            pmm_free_count = pmm_free_count + 1;
        }

        public static int alloc_contiguous (int num_pages) {
            if (num_pages <= 0)
                return 0;
            int first_free = KernelLayout.RESERVED_END / PAGE_SIZE;
            int run = 0;
            int start_f = first_free;
            for (int f = first_free; f < pmm_total_frames; f++) {
                if (!test_bit (f)) {
                    if (run == 0)
                        start_f = f;
                    run = run + 1;
                    if (run == num_pages) {
                        for (int k = 0; k < num_pages; k++) {
                            set_bit (start_f + k);
                            pmm_free_count = pmm_free_count - 1;
                        }
                        // The caller may run with a user CR3 where the frames
                        // were unmapped by a previous destroy. Zeroing through
                        // that CR3 would fault, so use the kernel's identity map
                        // for the whole run.
                        int saved = kernel_cr3_enter ();
                        for (int k = 0; k < num_pages; k++)
                            zero_page_4k ((start_f + k) * PAGE_SIZE);
                        kernel_cr3_leave (saved);
                        return start_f * PAGE_SIZE;
                    }
                } else {
                    run = 0;
                }
            }
            return 0;
        }

        public static void reserve_range (int start_addr, int size) {
            if (size <= 0)
                return;
            int start_f = start_addr / PAGE_SIZE;
            int end_f = (start_addr + size + PAGE_SIZE - 1) / PAGE_SIZE;
            if (start_f < 0)
                start_f = 0;
            if (end_f > pmm_total_frames)
                end_f = pmm_total_frames;
            for (int f = start_f; f < end_f; f++) {
                if (!test_bit (f)) {
                    set_bit (f);
                    pmm_free_count = pmm_free_count - 1;
                }
            }
        }

        public static int free_frames () {
            return pmm_free_count;
        }
    }
}
