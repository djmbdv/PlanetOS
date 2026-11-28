// Upgraded Bochs/QEMU VBE (BGA) linear framebuffer driver:
// - Up to 16 MiB VRAM mapped in PD3 (supports 800x600, 1024x768, 1280x720 @ 32bpp)
// - Hardware double-buffering via VBE_DISPI_INDEX_Y_OFFSET (page flipping)
// - Dirty-rectangle partial blit support

namespace Planet.Kernel {

    [AsmBody(@"
        # pci_cfg_read32(addr in rdi) -> lee 32 bits del espacio de configuracion PCI
        # Puerto 0xCF8 = CONFIG_ADDRESS, puerto 0xCFC = CONFIG_DATA
        mov %edi, %eax
        mov $0xCF8, %dx
        out %eax, %dx
        mov $0xCFC, %dx
        in %dx, %eax
        ret
    ")]
    public extern int pci_cfg_read32 (int addr);

    [AsmBody(@"
        # bga_write(reg in rdi, val in rsi) -> escribe registro de 16 bits en Bochs VBE (BGA)
        # Puerto 0x01CE = indice VBE, puerto 0x01CF = dato
        mov %di, %ax
        mov $0x01CE, %dx
        out %ax, %dx
        mov %si, %ax
        mov $0x01CF, %dx
        out %ax, %dx
        ret
    ")]
    public extern void bga_write (int reg, int val);

    [AsmBody(@"
        # bga_read(reg in rdi) -> lee registro de 16 bits desde Bochs VBE (BGA)
        mov %di, %ax
        mov $0x01CE, %dx
        out %ax, %dx
        mov $0x01CF, %dx
        xor %eax, %eax
        in %dx, %ax
        ret
    ")]
    public extern int bga_read (int reg);

#if PLANC
    [NoAlloc]
    [AlwaysInline]
#endif
    public void tlb_flush () {
        vmm_write_cr3 (vmm_read_cr3 ());
    }

    [AsmBody(@"
        # fb_copy_dwords(dst in rdi, src in rsi, count in rdx)
        # Copia 'count' pixeles de 32 bits (ARGB) usando SSE2 (16B/iter) + cola de 4B
        mov %rdx, %rcx
        test %rcx, %rcx
        jle _fb_cp_done
    _fb_cp_sse:
        cmp $4, %rcx
        jb _fb_cp_loop
        .byte 0xf3, 0x0f, 0x6f, 0x06
        .byte 0xf3, 0x0f, 0x7f, 0x07
        add $16, %rsi
        add $16, %rdi
        sub $4, %rcx
        jmp _fb_cp_sse
    _fb_cp_loop:
        test %rcx, %rcx
        jz _fb_cp_done
        mov (%rsi), %eax
        mov %eax, (%rdi)
        add $4, %rsi
        add $4, %rdi
        dec %rcx
        jnz _fb_cp_loop
    _fb_cp_done:
        ret
    ")]
    public extern void fb_copy_dwords (int dst, int src, int count);

    [AsmBody(@"
        # fb_copy_dwords_avx2(dst in rdi, src in rsi, count in rdx)
        # Copia 'count' pixeles de 32 bits (ARGB) usando AVX2 (32B/iter) + cola de 4B
        mov %rdx, %rcx
        test %rcx, %rcx
        jle _fb_avx_done
    _fb_avx_loop:
        cmp $8, %rcx
        jb _fb_avx_tail
        .byte 0xc5, 0xfe, 0x6f, 0x06
        .byte 0xc5, 0xfe, 0x7f, 0x07
        add $32, %rsi
        add $32, %rdi
        sub $8, %rcx
        jmp _fb_avx_loop
    _fb_avx_tail:
        test %rcx, %rcx
        jz _fb_avx_done
        mov (%rsi), %eax
        mov %eax, (%rdi)
        add $4, %rsi
        add $4, %rdi
        dec %rcx
        jnz _fb_avx_tail
    _fb_avx_done:
        .byte 0xc5, 0xf8, 0x77
        ret
    ")]
    public extern void fb_copy_dwords_avx2 (int dst, int src, int count);

#if PLANC
    [NoAlloc]
    [AlwaysInline]
#endif
    public int vga_inb (int port) {
        return port_in8 (port);
    }

#if PLANC
    [NoAlloc]
    [AlwaysInline]
#endif
    public void vga_outb (int port, int val) {
        port_out8 (port, val);
    }

    public interface DisplayBackend : Object {
        public abstract int init_mode (int w, int h);
        public abstract void blit_full (int src_buf, int w, int h);
        public abstract void blit_rect (int src_buf, int rx, int ry, int rw, int rh);
        public abstract void close_mode ();
    }

    public sealed class VirtioGpuDisplay : Object, DisplayBackend {
        public int init_mode (int w, int h) {
            VirtioGpu.set_console_active (false);
            return VirtioGpu.init_scanout (w, h);
        }

        public void blit_full (int src_buf, int w, int h) {
            VirtioGpu.present_full (src_buf, w, h);
        }

        public void blit_rect (int src_buf, int rx, int ry, int rw, int rh) {
            VirtioGpu.present_rect (src_buf, rx, ry, rw, rh);
        }

        public void close_mode () {
            VirtioGpu.close_scanout ();
            if (VirtioGpu.init_scanout (1280, 720) != 0)
                VirtioGpu.set_console_active (true);
        }
    }

    public sealed class BgaDisplay : Object, DisplayBackend {
        private int phys_addr = 0;
        private int width = 0;
        private int height = 0;
        private int page = 0;

        public int init_mode (int w, int h) {
            int ver = bga_read (0);
            if (ver < 0xB0C0 || ver > 0xB0C6)
                return 0;
            int bar0 = Fb.find_vga_bar0 ();
            if (bar0 == 0)
                return 0;
            Fb.save_vga_text_state ();
            Fb.map_lfb (bar0);
            bga_write (4, 0);       // VBE_DISPI_INDEX_ENABLE = 0
            bga_write (1, w);       // XRES
            bga_write (2, h);       // YRES
            bga_write (3, 32);      // BPP = 32 ARGB
            bga_write (6, w);       // VIRT_WIDTH = w
            bga_write (7, h * 2);   // VIRT_HEIGHT = 2*h (hardware double-buffering)
            bga_write (8, 0);       // X_OFFSET = 0
            bga_write (9, 0);       // Y_OFFSET = 0
            bga_write (4, 0x41);    // ENABLED | LFB_ENABLED
            this.phys_addr = bar0;
            this.width = w;
            this.height = h;
            this.page = 0;
            return bar0;
        }

        public void blit_full (int src_buf, int w, int h) {
            int back = 1 - this.page;
            int dst_base = this.phys_addr + back * this.width * this.height * 4;
            int cw = (w < this.width) ? w : this.width;
            int ch = (h < this.height) ? h : this.height;
            if (cw == this.width) {
                Fb.copy_fast (dst_base, src_buf, cw * ch);
            } else {
                for (int y = 0; y < ch; y++) {
                    Fb.copy_fast (dst_base + y * this.width * 4, src_buf + y * w * 4, cw);
                }
            }
            this.page = back;
            bga_write (9, back * this.height); // Page flip via Y_OFFSET
        }

        public void blit_rect (int src_buf, int rx, int ry, int rw, int rh) {
            if (rx < 0) rx = 0;
            if (ry < 0) ry = 0;
            if (rx + rw > this.width) rw = this.width - rx;
            if (ry + rh > this.height) rh = this.height - ry;
            if (rw <= 0 || rh <= 0)
                return;
            int dst_base = this.phys_addr + this.page * this.width * this.height * 4;
            for (int row = 0; row < rh; row++) {
                int off = ((ry + row) * this.width + rx) * 4;
                Fb.copy_fast (dst_base + off, src_buf + off, rw);
            }
        }

        public void close_mode () {
            bga_write (4, 0);
            bga_write (8, 0);
            bga_write (9, 0);
            Fb.restore_vga_text_state ();
            this.phys_addr = 0;
            this.width = 0;
            this.height = 0;
            this.page = 0;
        }
    }

    public sealed class Fb : Object {
        private static int fb_phys_addr = 0;
        private static int fb_owner_cr3 = 0;
        private static int fb_width = 0;
        private static int fb_height = 0;
        private static int vga_saved = 0;
        private static int vga_misc = 0;
        private static int vga_state_buf = 0;
        private static DisplayBackend? active_backend;
        internal static int find_vga_bar0 () {
            for (int dev = 0; dev < 32; dev++) {
                int id = pci_cfg_read32 (0x80000000 | (dev << 11));
                if ((id & 0xFFFF) == 0xFFFF)
                    continue;
                int cls = pci_cfg_read32 (0x80000000 | (dev << 11) | 0x08);
                int base_cls = (cls >> 24) & 0xFF;
                int sub_cls = (cls >> 16) & 0xFF;
                if ((id & 0xFFFF) == 0x1234 || (base_cls == 0x03 && sub_cls == 0x00)) {
                    int bar0 = pci_cfg_read32 (0x80000000 | (dev << 11) | 0x10);
                    return bar0 & 0xFFFFFFF0;
                }
            }
            return 0;
        }

        internal static void map_lfb (int phys) {
            int pdpt_idx = (phys >> 30) & 0x1FF;
            if (pdpt_idx == 0)
                return;
            for (int i = 0; i < 512; i++) {
                mmio_write64 (KernelLayout.PD3 + i * 8, 0);
            }
            int base_2m = phys & ~0x1FFFFF;
            for (int k = 0; k < 8; k++) { // map 16 MiB (supports double-buffered 1280x720x32 / 1024x768x32)
                int pa = base_2m + k * 0x200000;
                int pd_idx = (pa >> 21) & 0x1FF;
                mmio_write64 (KernelLayout.PD3 + pd_idx * 8, pa | 0x83);
            }
            mmio_write64 (KernelLayout.PDPT + pdpt_idx * 8, KernelLayout.PD3 | 0x03);
            int cur_cr3 = vmm_read_cr3 ();
            if (cur_cr3 != 0 && cur_cr3 != KernelLayout.PAGE_TABLES) {
                int cur_pdpt = mmio_read64 (cur_cr3) & ~0xFFF;
                if (cur_pdpt != 0)
                    mmio_write64 (cur_pdpt + pdpt_idx * 8, KernelLayout.PD3 | 0x03);
            }
            tlb_flush ();
        }

        private static int reg_read (int idx) {
            int addr = vga_state_buf + 8192 + idx;
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        internal static void save_vga_text_state () {
            if (vga_saved != 0)
                return;
            vga_state_buf = Pmm.alloc_contiguous (3); // 8 KiB font + VGA registers
            if (vga_state_buf == 0)
                return;
            vga_misc = vga_inb (0x3CC);
            for (int i = 0; i < 5; i++) {
                vga_outb (0x3C4, i);
                mmio_write8 (vga_state_buf + 8192 + i, vga_inb (0x3C5));
            }
            for (int i = 0; i < 25; i++) {
                vga_outb (0x3D4, i);
                mmio_write8 (vga_state_buf + 8192 + 5 + i, vga_inb (0x3D5));
            }
            for (int i = 0; i < 9; i++) {
                vga_outb (0x3CE, i);
                mmio_write8 (vga_state_buf + 8192 + 30 + i, vga_inb (0x3CF));
            }
            for (int i = 0; i < 21; i++) {
                vga_inb (0x3DA);
                vga_outb (0x3C0, i);
                mmio_write8 (vga_state_buf + 8192 + 39 + i, vga_inb (0x3C1));
            }
            vga_inb (0x3DA);
            vga_outb (0x3C0, 0x20);

            vga_outb (0x3C4, 0x02); vga_outb (0x3C5, 0x04);
            vga_outb (0x3C4, 0x04); vga_outb (0x3C5, 0x06);
            vga_outb (0x3CE, 0x04); vga_outb (0x3CF, 0x02);
            vga_outb (0x3CE, 0x05); vga_outb (0x3CF, 0x00);
            vga_outb (0x3CE, 0x06); vga_outb (0x3CF, 0x04);
            fb_copy_dwords (vga_state_buf, 0xA0000, 2048);
            vga_saved = 1;
        }

        internal static void restore_vga_text_state () {
            if (vga_saved == 0 || vga_state_buf == 0)
                return;
            vga_outb (0x3C2, vga_misc);
            vga_outb (0x3C4, 0x00); vga_outb (0x3C5, 0x01);
            for (int i = 1; i < 5; i++) {
                vga_outb (0x3C4, i);
                vga_outb (0x3C5, reg_read (i));
            }
            vga_outb (0x3C4, 0x00); vga_outb (0x3C5, 0x03);

            vga_outb (0x3D4, 0x11);
            vga_outb (0x3D5, reg_read (5 + 0x11) & 0x7F);
            for (int i = 0; i < 25; i++) {
                vga_outb (0x3D4, i);
                vga_outb (0x3D5, reg_read (5 + i));
            }

            vga_outb (0x3C4, 0x02); vga_outb (0x3C5, 0x04);
            vga_outb (0x3C4, 0x04); vga_outb (0x3C5, 0x06);
            vga_outb (0x3CE, 0x05); vga_outb (0x3CF, 0x00);
            vga_outb (0x3CE, 0x06); vga_outb (0x3CF, 0x04);
            fb_copy_dwords (0xA0000, vga_state_buf, 2048);

            for (int i = 1; i < 5; i++) {
                vga_outb (0x3C4, i);
                vga_outb (0x3C5, reg_read (i));
            }
            for (int i = 0; i < 9; i++) {
                vga_outb (0x3CE, i);
                vga_outb (0x3CF, reg_read (30 + i));
            }
            vga_inb (0x3DA);
            for (int i = 0; i < 21; i++) {
                vga_outb (0x3C0, i);
                vga_outb (0x3C0, reg_read (39 + i));
            }
            vga_inb (0x3DA);
            vga_outb (0x3C0, 0x20);
        }

        public static int init (int w, int h) {
            int cur_cr3 = Sched.current_cr3 ();
            if (fb_phys_addr != 0 && fb_owner_cr3 != 0 && cur_cr3 != fb_owner_cr3)
                return 0;
            if (VirtioGpu.is_present ()) {
                var vg = new VirtioGpuDisplay ();
                int vfb = vg.init_mode (w, h);
                if (vfb != 0) {
                    active_backend = vg;
                    fb_phys_addr = vfb;
                    fb_width = w;
                    fb_height = h;
                    fb_owner_cr3 = cur_cr3;
                    return vfb;
                }
            }
            var bga = new BgaDisplay ();
            int bar0 = bga.init_mode (w, h);
            if (bar0 == 0)
                return 0;
            active_backend = bga;
            fb_phys_addr = bar0;
            fb_width = w;
            fb_height = h;
            fb_owner_cr3 = cur_cr3;
            return bar0;
        }

        public static int info (int out_buf) {
            if (out_buf != 0) {
                mmio_write64 (out_buf + 0, fb_width);
                mmio_write64 (out_buf + 8, fb_height);
                mmio_write64 (out_buf + 16, 32);
                mmio_write64 (out_buf + 24, fb_width * 4);
                mmio_write64 (out_buf + 32, fb_phys_addr);
            }
            return (fb_width << 16) | fb_height;
        }

        public static void copy_fast (int dst, int src, int count) {
            fb_copy_dwords_avx2 (dst, src, count);
        }

        public static void blit (int src_buf, int w, int h) {
            if (fb_phys_addr == 0 || src_buf == 0 || active_backend == null)
                return;
            if (fb_owner_cr3 != 0 && Sched.current_cr3 () != fb_owner_cr3)
                return;
            active_backend.blit_full (src_buf, w, h);
        }

        public static void blit_rect (int src_buf, int xy_packed, int wh_packed) {
            if (fb_phys_addr == 0 || src_buf == 0 || active_backend == null)
                return;
            if (fb_owner_cr3 != 0 && Sched.current_cr3 () != fb_owner_cr3)
                return;
            int rx = (xy_packed >> 16) & 0xFFFF;
            int ry = xy_packed & 0xFFFF;
            int rw = (wh_packed >> 16) & 0xFFFF;
            int rh = wh_packed & 0xFFFF;
            active_backend.blit_rect (src_buf, rx, ry, rw, rh);
        }

        public static int width () {
            return fb_width;
        }

        public static int height () {
            return fb_height;
        }

        public static void release_for_cr3 (int cr3) {
            if (fb_phys_addr != 0 && fb_owner_cr3 != 0 && fb_owner_cr3 == cr3) {
                fb_owner_cr3 = 0;
                close ();
            }
        }

        public static void close () {
            if (fb_owner_cr3 != 0 && Sched.current_cr3 () != fb_owner_cr3)
                return;
            if (fb_phys_addr != 0) {
                if (active_backend != null) {
                    active_backend.close_mode ();
                    active_backend = null;
                }
                fb_phys_addr = 0;
                fb_width = 0;
                fb_height = 0;
                fb_owner_cr3 = 0;
                Vga.init ();
            }
        }
    }
}
