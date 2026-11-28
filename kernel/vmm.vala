// Virtual Memory Manager (4 KiB page-table splitting, null-page unmap, guard pages).
//
// boot_mb2.vala identity-maps 1 GiB (512 x 2 MiB pages) in PD at 0x102000.
// Vmm splits any 2 MiB PD entry into 512 x 4 KiB PT entries on demand so
// individual 4 KiB pages (page 0x0 for NULL-deref protection, and per-process
// stack guard pages) can be unmapped in hardware.

namespace Planet.Kernel {

    [AsmBody(@"
        invlpg (%rdi)
        ret
    ")]
    private extern void vmm_invlpg (int addr);

    [AsmBody(@"
        mov %cr3, %rax
        ret
    ")]
    public extern int vmm_read_cr3 ();

    [AsmBody(@"
        mov %rdi, %cr3
        ret
    ")]
    public extern void vmm_write_cr3 (int cr3);

    public sealed class Vmm : Object {
        private const int MAX_SPLIT_ADDR = 0x40000000; // 1 GiB identity map
        private const uint64 PTE_PRESENT   = 0x01;
        private const uint64 PTE_WRITABLE  = 0x02;
        private const uint64 PTE_USER      = 0x04;
        private const uint64 PTE_PS        = 0x80;
        private const uint64 PTE_SUP_RW    = PTE_PRESENT | PTE_WRITABLE;
        private const uint64 PTE_USER_RO   = PTE_PRESENT | PTE_USER;
        private const uint64 PTE_USER_RW   = PTE_PRESENT | PTE_WRITABLE | PTE_USER;
        private const uint64 PTE_ADDR_MASK = ~0xFFF;

        private static bool ensure_pt_in_pd (int pd_base, int addr, bool user_dir, out int pt_base) {
            pt_base = 0;
            if (addr < 0 || addr >= MAX_SPLIT_ADDR)
                return false;
            int pd_idx = addr >> 21;
            int pde_addr = pd_base + pd_idx * 8;
            uint64 pde = (uint64) mmio_read64 (pde_addr);
            if ((pde & PTE_PRESENT) == 0)
                return false;
            // Already split into a 4 KiB PT (PS bit 7 == 0)
            if ((pde & PTE_PS) == 0) {
                if (user_dir && (pde & PTE_USER) == 0)
                    mmio_write64 (pde_addr, (int) (pde | PTE_USER_RW));
                pt_base = (int) (pde & PTE_ADDR_MASK);
                return true;
            }
            // Split 2 MiB page into 512 x 4 KiB pages (supervisor-only by default)
            int pt = Pmm.alloc_frame ();
            if (pt == 0)
                return false;
            uint64 region_base = (uint64) (pd_idx << 21);
            for (int i = 0; i < 512; i++) {
                mmio_write64 (pt + i * 8, (int) ((region_base + (uint64) (i * 4096)) | PTE_SUP_RW));
            }
            mmio_write64 (pde_addr, (int) ((uint64) pt | (user_dir ? PTE_USER_RW : PTE_SUP_RW)));
            pt_base = pt;
            return true;
        }

        private static bool ensure_pt (int addr, out int pt_base) {
            return ensure_pt_in_pd (KernelLayout.PD, addr, false, out pt_base);
        }

        public static int create_user_space () {
            int pml4 = Pmm.alloc_frame ();
            int pdpt = Pmm.alloc_frame ();
            int pd = Pmm.alloc_frame ();
            if (pml4 == 0 || pdpt == 0 || pd == 0) {
                if (pml4 != 0) Pmm.free_frame (pml4);
                if (pdpt != 0) Pmm.free_frame (pdpt);
                if (pd != 0) Pmm.free_frame (pd);
                return 0;
            }
            for (int i = 0; i < 512; i++) {
                int pde = mmio_read64 (KernelLayout.PD + i * 8);
                if ((pde & 0x01) != 0 && (pde & 0x80) == 0) {
                    // Clone already-split 4 KiB PT (e.g. page 0 unmapped)
                    int src_pt = pde & ~0xFFF;
                    int dst_pt = Pmm.alloc_frame ();
                    if (dst_pt == 0) {
                        mmio_write64 (pd + i * 8, 0);
                        continue;
                    }
                    for (int j = 0; j < 512; j++) {
                        mmio_write64 (dst_pt + j * 8, mmio_read64 (src_pt + j * 8) & ~0x04);
                    }
                    mmio_write64 (pd + i * 8, dst_pt | 0x03);
                } else {
                    mmio_write64 (pd + i * 8, pde & ~0x04);
                }
            }
            mmio_write64 (pdpt + 0, pd | 0x07);
            for (int i = 1; i < 512; i++) {
                mmio_write64 (pdpt + i * 8, mmio_read64 (0x101000 + i * 8) & ~0x04);
            }
            mmio_write64 (pml4 + 0, pdpt | 0x07);
            return pml4;
        }

        public static void destroy_user_space (int cr3) {
            if (cr3 == 0 || cr3 == KernelLayout.PAGE_TABLES)
                return;
            int pdpt = mmio_read64 (cr3) & ~0xFFF;
            if (pdpt != 0) {
                int pd = mmio_read64 (pdpt) & ~0xFFF;
                if (pd != 0) {
                    for (int i = 0; i < 512; i++) {
                        int pde = mmio_read64 (pd + i * 8);
                        if ((pde & 0x01) != 0 && (pde & 0x80) == 0) {
                            int pt = pde & ~0xFFF;
                            if (pt != 0)
                                Pmm.free_frame (pt);
                        }
                    }
                    Pmm.free_frame (pd);
                }
                Pmm.free_frame (pdpt);
            }
            Pmm.free_frame (cr3);
        }

        public static int virt_to_phys (int cr3, int vaddr) {
            if (cr3 == 0 || cr3 == KernelLayout.PAGE_TABLES)
                return vaddr;
            if (vaddr < 0 || vaddr >= MAX_SPLIT_ADDR)
                return 0;
            int pdpt = mmio_read64 (cr3) & ~0xFFF;
            if (pdpt == 0)
                return 0;
            int pd = mmio_read64 (pdpt) & ~0xFFF;
            if (pd == 0)
                return 0;
            int pde = mmio_read64 (pd + (vaddr >> 21) * 8);
            if ((pde & 0x01) == 0)
                return 0;
            if ((pde & 0x80) != 0)
                return (pde & ~0x1FFFFF) | (vaddr & 0x1FFFFF);
            int pt = pde & ~0xFFF;
            int pte = mmio_read64 (pt + ((vaddr >> 12) & 0x1FF) * 8);
            if ((pte & 0x01) == 0)
                return 0;
            return (pte & ~0xFFF) | (vaddr & 0xFFF);
        }

        public static void map_user_4k_phys (int cr3, int vaddr, int paddr, int flags = 0x07) {
            if (cr3 == 0 || cr3 == KernelLayout.PAGE_TABLES)
                return;
            int va = vaddr & ~0xFFF;
            int pa = paddr & ~0xFFF;
            uint64 pf = (flags == 0x05) ? PTE_USER_RO : ((flags == 0x03) ? PTE_SUP_RW : PTE_USER_RW);
            int pdpt = mmio_read64 (cr3) & ~0xFFF;
            int pd = mmio_read64 (pdpt) & ~0xFFF;
            int pt_base = 0;
            if (!ensure_pt_in_pd (pd, va, true, out pt_base))
                return;
            int pt_idx = (va >> 12) & 0x1FF;
            mmio_write64 (pt_base + pt_idx * 8, (int) ((uint64) pa | pf));
            if (vmm_read_cr3 () == cr3)
                vmm_invlpg (va);
        }

        public static void map_user_4k (int cr3, int addr) {
            map_user_4k_phys (cr3, addr, addr, 0x07);
        }

        public static void map_user_4k_ro (int cr3, int addr) {
            map_user_4k_phys (cr3, addr, addr, 0x05);
        }

        // Supervisor RW mapping for frames whose user mapping was just removed.
        // Pmm writes free-list metadata into the frame itself, so releasing it
        // while the owning CR3 is active needs the frame reachable from ring 0.
        public static void map_supervisor_range (int cr3, int start, int size) {
            if (cr3 == 0 || cr3 == KernelLayout.PAGE_TABLES || size <= 0)
                return;
            int first = start & ~0xFFF;
            int last = (start + size - 1) & ~0xFFF;
            for (int p = first; p <= last; p += 4096)
                map_user_4k_phys (cr3, p, p, 0x03);
        }

        public static void unmap_user_4k (int cr3, int addr) {
            if (cr3 == 0 || cr3 == KernelLayout.PAGE_TABLES)
                return;
            int aligned = addr & ~0xFFF;
            int pdpt = mmio_read64 (cr3) & ~0xFFF;
            int pd = mmio_read64 (pdpt) & ~0xFFF;
            int pt_base = 0;
            if (!ensure_pt_in_pd (pd, aligned, true, out pt_base))
                return;
            int pt_idx = (aligned >> 12) & 0x1FF;
            // Revoke user access while keeping the kernel's supervisor identity map
            // intact so PMM/VMM can reuse the frame while this CR3 is active.
            mmio_write64 (pt_base + pt_idx * 8, (aligned == 0) ? 0 : (aligned | 0x03));
            if (vmm_read_cr3 () == cr3)
                vmm_invlpg (aligned);
        }

        public static void map_user_range (int cr3, int start, int size) {
            if (size <= 0)
                return;
            int first = start & ~0xFFF;
            int last = (start + size - 1) & ~0xFFF;
            for (int p = first; p <= last; p += 4096) {
                map_user_4k (cr3, p);
            }
        }

        public static void map_user_range_ro (int cr3, int start, int size) {
            if (size <= 0)
                return;
            int first = start & ~0xFFF;
            int last = (start + size - 1) & ~0xFFF;
            for (int p = first; p <= last; p += 4096) {
                map_user_4k_ro (cr3, p);
            }
        }

        // Downgrades already-mapped user pages to read-only without ever
        // granting USER access to unmapped or supervisor-only pages.
        public static void protect_user_range_ro (int cr3, int start, int size) {
            if (cr3 == 0 || cr3 == KernelLayout.PAGE_TABLES || size <= 0)
                return;
            int pdpt = mmio_read64 (cr3) & ~0xFFF;
            if (pdpt == 0)
                return;
            int pd = mmio_read64 (pdpt) & ~0xFFF;
            if (pd == 0)
                return;
            int cur = vmm_read_cr3 ();
            int first = start & ~0xFFF;
            int last = (start + size - 1) & ~0xFFF;
            for (int p = first; p <= last; p += 4096) {
                if (p < 0 || p >= MAX_SPLIT_ADDR)
                    continue;
                int pde = mmio_read64 (pd + (p >> 21) * 8);
                if ((pde & 0x05) != 0x05 || (pde & 0x80) != 0)
                    continue;
                int pt = pde & ~0xFFF;
                int idx = (p >> 12) & 0x1FF;
                int pte = mmio_read64 (pt + idx * 8);
                if ((pte & 0x05) == 0x05 && (pte & 0x02) != 0) {
                    mmio_write64 (pt + idx * 8, pte & ~0x02);
                    if (cur == cr3)
                        vmm_invlpg (p);
                }
            }
        }

        public static void unmap_user_range (int cr3, int start, int size) {
            if (size <= 0)
                return;
            int first = start & ~0xFFF;
            int last = (start + size - 1) & ~0xFFF;
            for (int p = first; p <= last; p += 4096) {
                unmap_user_4k (cr3, p);
            }
        }

        // All-or-nothing variant of map_user_range: returns the number of 4 KiB
        // pages mapped, or 0 when any of them could not be mapped (the pages it
        // already touched are unmapped again). A caller that gets 0 must free the
        // frames it just allocated - an unmapped buffer must never reach userland,
        // because the first write to it would be a #PF instead of an error code.
        public static int map_user_range_checked (int cr3, int start, int size) {
            if (cr3 == 0 || cr3 == KernelLayout.PAGE_TABLES || size <= 0)
                return 0;
            int first = start & ~0xFFF;
            int last = (start + size - 1) & ~0xFFF;
            int mapped = 0;
            for (int p = first; p <= last; p += 4096) {
                if (!map_user_4k_checked (cr3, p)) {
                    for (int q = first; q < p; q += 4096)
                        unmap_user_4k (cr3, q);
                    return 0;
                }
                mapped = mapped + 1;
            }
            return mapped;
        }

        private static bool map_user_4k_checked (int cr3, int addr) {
            int aligned = addr & ~0xFFF;
            int pdpt = mmio_read64 (cr3) & ~0xFFF;
            int pd = mmio_read64 (pdpt) & ~0xFFF;
            int pt_base = 0;
            if (!ensure_pt_in_pd (pd, aligned, true, out pt_base))
                return false;
            int pt_idx = (aligned >> 12) & 0x1FF;
            mmio_write64 (pt_base + pt_idx * 8, aligned | 0x07);
            if (vmm_read_cr3 () == cr3)
                vmm_invlpg (aligned);
            return true;
        }

        public static void unmap_4k (int addr) {
            int aligned = addr & ~0xFFF;
            int pt_base = 0;
            if (!ensure_pt (aligned, out pt_base))
                return;
            int pt_idx = (aligned >> 12) & 0x1FF;
            mmio_write64 (pt_base + pt_idx * 8, 0);
            vmm_invlpg (aligned);
        }

        public static void map_4k (int addr) {
            int aligned = addr & ~0xFFF;
            int pt_base = 0;
            if (!ensure_pt (aligned, out pt_base))
                return;
            int pt_idx = (aligned >> 12) & 0x1FF;
            mmio_write64 (pt_base + pt_idx * 8, aligned | 0x03);
            vmm_invlpg (aligned);
        }

        public static void map_mmio_2m (int phys) {
            int pdpt_idx = (phys >> 30) & 0x1FF;
            if (pdpt_idx != 3)
                return;
            int pd3 = 0x103000;
            int pdpt = 0x101000;
            int pdpt_e = mmio_read64 (pdpt + pdpt_idx * 8);
            if ((pdpt_e & 0x01) == 0) {
                for (int i = 0; i < 512; i++)
                    mmio_write64 (pd3 + i * 8, 0);
                mmio_write64 (pdpt + pdpt_idx * 8, pd3 | 0x03);
            }
            int base_2m = phys & ~0x1FFFFF;
            int pd_idx = (base_2m >> 21) & 0x1FF;
            mmio_write64 (pd3 + pd_idx * 8, base_2m | 0x83);
            vmm_write_cr3 (vmm_read_cr3 ());
        }

        public static void init () {
            // Unmap page 0 (0x0000..0x0FFF) so any NULL pointer dereference triggers #PF
            unmap_4k (0);
        }
    }
}
