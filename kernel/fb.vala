// Bochs/QEMU VBE (BGA) linear framebuffer driver (800x600x32 ARGB).

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
        # bga_write(reg in rdi, val in rsi) -> escribe registro en Bochs VBE (BGA)
        # Puerto 0x01CE = selector de indice VBE, puerto 0x01CF = dato de 16 bits
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

    [AsmBody(@"
        # Invalida toda la TLB recargando CR3 tras mapear el framebuffer en PD3
        mov %cr3, %rax
        mov %rax, %cr3
        ret
    ")]
    public extern void tlb_flush ();

    [AsmBody(@"
        # fb_copy_dwords(dst in rdi, src in rsi, count in rdx)
        # Copia 'count' pixeles de 32 bits (ARGB) desde el backbuffer al framebuffer LFB
        mov %rdx, %rcx
        test %rcx, %rcx
        jz _fb_cp_done
    _fb_cp_loop:
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

    private int fb_phys_addr = 0;
    private int fb_width = 0;
    private int fb_height = 0;

    public class Fb : Object {
        private const int PD3_ADDR = 0x103000;
        private const int PDPT_ADDR = 0x101000;

        private static int find_vga_bar0 () {
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

        private static void map_lfb (int phys) {
            int pdpt_idx = (phys >> 30) & 0x1FF;
            if (pdpt_idx == 0)
                return; // already identity-mapped in PD0
            for (int i = 0; i < 512; i++) {
                mmio_write64 (PD3_ADDR + i * 8, 0);
            }
            int base_2m = phys & ~0x1FFFFF;
            for (int k = 0; k < 4; k++) { // map 8 MiB
                int pa = base_2m + k * 0x200000;
                int pd_idx = (pa >> 21) & 0x1FF;
                mmio_write64 (PD3_ADDR + pd_idx * 8, pa | 0x83);
            }
            mmio_write64 (PDPT_ADDR + pdpt_idx * 8, PD3_ADDR | 0x03);
            tlb_flush ();
        }

        public static int init (int w, int h) {
            int ver = bga_read (0);
            if (ver < 0xB0C0 || ver > 0xB0C6)
                return 0;
            int bar0 = find_vga_bar0 ();
            if (bar0 == 0)
                return 0;
            map_lfb (bar0);
            bga_write (4, 0);
            bga_write (1, w);
            bga_write (2, h);
            bga_write (3, 32);
            bga_write (4, 0x41);
            fb_phys_addr = bar0;
            fb_width = w;
            fb_height = h;
            return bar0;
        }

        public static void blit (int src_buf, int w, int h) {
            if (fb_phys_addr == 0 || src_buf == 0)
                return;
            int cw = (w < fb_width) ? w : fb_width;
            int ch = (h < fb_height) ? h : fb_height;
            if (cw == fb_width) {
                fb_copy_dwords (fb_phys_addr, src_buf, cw * ch);
            } else {
                for (int y = 0; y < ch; y++) {
                    fb_copy_dwords (fb_phys_addr + y * fb_width * 4, src_buf + y * w * 4, cw);
                }
            }
        }

        public static void close () {
            if (fb_phys_addr != 0) {
                bga_write (4, 0);
                fb_phys_addr = 0;
            }
        }
    }
}
