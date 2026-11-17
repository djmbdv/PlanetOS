// VirtIO-GPU PCI driver (Modern VirtIO 1.0 MMIO transport + controlq).
// Phase 1: PCI probe, Modern capability discovery, feature negotiation
// (VIRGL, RESOURCE_BLOB, CONTEXT_INIT), split virtqueue setup, and
// GET_DISPLAY_INFO / GET_CAPSET_INFO (Venus capset=4 detection).

namespace Planet.Kernel {

    [AsmBody(@"
        # pci_cfg_write32(addr in rdi, val in rsi)
        mov %edi, %eax
        mov $0xCF8, %dx
        out %eax, %dx
        mov %esi, %eax
        mov $0xCFC, %dx
        out %eax, %dx
        ret
    ")]
    public extern void pci_cfg_write32 (int addr, int val);

    private int vgpu_found = 0;
    private int vgpu_common_base = 0;
    private int vgpu_notify_base = 0;
    private int vgpu_notify_mult = 0;
    private int vgpu_dev_base = 0;
    private int vgpu_features_lo = 0;
    private int vgpu_vq_page = 0;
    private int vgpu_cmd_page = 0;
    private int vgpu_qsize = 16;
    private int vgpu_q_notify_off = 0;
    private int vgpu_avail_idx = 0;
    private int vgpu_last_used = 0;
    private int vgpu_disp_w = 0;
    private int vgpu_disp_h = 0;
    private int vgpu_has_venus = 0;

    public class VirtioGpu : Object {
        private const int VENDOR_VIRTIO = 0x1AF4;
        private const int DEV_GPU       = 0x1050;

        // VirtIO status bits
        private const int ST_ACK         = 1;
        private const int ST_DRIVER      = 2;
        private const int ST_DRIVER_OK   = 4;
        private const int ST_FEATURES_OK = 8;

        // VirtIO-GPU feature bits (low 32)
        private const int F_VIRGL         = 1 << 0;
        private const int F_EDID          = 1 << 1;
        private const int F_RESOURCE_UUID = 1 << 2;
        private const int F_RESOURCE_BLOB = 1 << 3;
        private const int F_CONTEXT_INIT  = 1 << 4;

        // VirtIO-GPU commands & responses
        private const int CMD_GET_DISPLAY_INFO = 0x0100;
        private const int CMD_GET_CAPSET_INFO  = 0x0108;
        private const int RESP_OK_NODATA       = 0x1100;
        private const int RESP_OK_DISPLAY_INFO = 0x1101;
        private const int RESP_OK_CAPSET_INFO  = 0x1102;
        private const int CAPSET_VENUS         = 4;

        private static int cfg_addr (int dev, int reg) {
            return 0x80000000 | (dev << 11) | (reg & 0xFC);
        }

        private static int cfg_read8 (int dev, int reg) {
            int w = pci_cfg_read32 (cfg_addr (dev, reg));
            return (w >> ((reg & 3) * 8)) & 0xFF;
        }

        private static int cfg_read16 (int dev, int reg) {
            int w = pci_cfg_read32 (cfg_addr (dev, reg));
            return (w >> ((reg & 2) * 8)) & 0xFFFF;
        }

        private static int read_bar_addr (int dev, int bar_idx) {
            int raw = pci_cfg_read32 (cfg_addr (dev, 0x10 + bar_idx * 4));
            if ((raw & 0x01) != 0)
                return 0; // I/O BAR not used for modern MMIO
            return raw & 0xFFFFFFF0;
        }

        private static bool send_cmd (int req_bytes, int resp_bytes) {
            if (vgpu_vq_page == 0 || vgpu_cmd_page == 0)
                return false;
            int req_pa = vgpu_cmd_page;
            int resp_pa = vgpu_cmd_page + 2048;
            for (int i = 0; i < resp_bytes; i += 4)
                mmio_write32 (resp_pa + i, 0);

            int desc_base = vgpu_vq_page;
            int avail_base = vgpu_vq_page + 512;
            int used_base = vgpu_vq_page + 1024;

            // Descriptor 0: OUT request
            mmio_write64 (desc_base + 0, req_pa);
            mmio_write32 (desc_base + 8, req_bytes);
            mmio_write16 (desc_base + 12, 0x01); // NEXT
            mmio_write16 (desc_base + 14, 1);

            // Descriptor 1: IN response
            mmio_write64 (desc_base + 16, resp_pa);
            mmio_write32 (desc_base + 24, resp_bytes);
            mmio_write16 (desc_base + 28, 0x02); // WRITE
            mmio_write16 (desc_base + 30, 0);

            int ring_slot = vgpu_avail_idx % vgpu_qsize;
            mmio_write16 (avail_base + 4 + ring_slot * 2, 0);
            vgpu_avail_idx++;
            mmio_write16 (avail_base + 2, vgpu_avail_idx & 0xFFFF);

            mmio_write16 (vgpu_notify_base + vgpu_q_notify_off * vgpu_notify_mult, 0);

            for (int spin = 0; spin < 2000000; spin++) {
                int uidx = mmio_read32 (used_base) >> 16;
                if ((uidx & 0xFFFF) != (vgpu_last_used & 0xFFFF)) {
                    vgpu_last_used = uidx & 0xFFFF;
                    return true;
                }
            }
            return false;
        }

        public static bool init () {
            int found_dev = -1;
            for (int dev = 0; dev < 32; dev++) {
                int id = pci_cfg_read32 (cfg_addr (dev, 0));
                if ((id & 0xFFFF) == VENDOR_VIRTIO && ((id >> 16) & 0xFFFF) == DEV_GPU) {
                    found_dev = dev;
                    break;
                }
            }
            if (found_dev < 0)
                return false;

            // Enable Memory Space (bit 1) + Bus Mastering (bit 2)
            int cmd = pci_cfg_read32 (cfg_addr (found_dev, 0x04));
            pci_cfg_write32 (cfg_addr (found_dev, 0x04), cmd | 0x06);

            int status = cfg_read16 (found_dev, 0x06);
            if ((status & 0x10) == 0)
                return false;

            int cap_ptr = cfg_read8 (found_dev, 0x34) & 0xFC;
            while (cap_ptr != 0) {
                int cap_id = cfg_read8 (found_dev, cap_ptr);
                int next_ptr = cfg_read8 (found_dev, cap_ptr + 1) & 0xFC;
                if (cap_id == 0x09) { // VIRTIO_PCI_CAP
                    int cfg_type = cfg_read8 (found_dev, cap_ptr + 3);
                    int bar = cfg_read8 (found_dev, cap_ptr + 4);
                    int off = pci_cfg_read32 (cfg_addr (found_dev, cap_ptr + 8));
                    int bar_addr = read_bar_addr (found_dev, bar);
                    if (bar_addr != 0) {
                        Vmm.map_mmio_2m (bar_addr + off);
                        if (cfg_type == 1) {
                            vgpu_common_base = bar_addr + off;
                        } else if (cfg_type == 2) {
                            vgpu_notify_base = bar_addr + off;
                            vgpu_notify_mult = pci_cfg_read32 (cfg_addr (found_dev, cap_ptr + 16));
                        } else if (cfg_type == 4) {
                            vgpu_dev_base = bar_addr + off;
                        }
                    }
                }
                cap_ptr = next_ptr;
            }
            if (vgpu_common_base == 0 || vgpu_notify_base == 0)
                return false;

            // Reset & initialize VirtIO 1.0 device
            mmio_write8 (vgpu_common_base + 20, 0);
            mmio_write8 (vgpu_common_base + 20, ST_ACK);
            mmio_write8 (vgpu_common_base + 20, ST_ACK | ST_DRIVER);

            mmio_write32 (vgpu_common_base + 0, 0);
            vgpu_features_lo = mmio_read32 (vgpu_common_base + 4);
            mmio_write32 (vgpu_common_base + 0, 1);
            int features_hi = mmio_read32 (vgpu_common_base + 4);

            int want_lo = vgpu_features_lo & (F_VIRGL | F_EDID | F_RESOURCE_UUID | F_RESOURCE_BLOB | F_CONTEXT_INIT);
            int want_hi = features_hi & 1; // VIRTIO_F_VERSION_1 (bit 32)
            mmio_write32 (vgpu_common_base + 8, 0);
            mmio_write32 (vgpu_common_base + 12, want_lo);
            mmio_write32 (vgpu_common_base + 8, 1);
            mmio_write32 (vgpu_common_base + 12, want_hi);

            mmio_write8 (vgpu_common_base + 20, ST_ACK | ST_DRIVER | ST_FEATURES_OK);
            int st_chk = mmio_read32 (vgpu_common_base + 20) & 0xFF;
            if ((st_chk & ST_FEATURES_OK) == 0)
                return false;

            vgpu_vq_page = Pmm.alloc_frame ();
            vgpu_cmd_page = Pmm.alloc_frame ();
            if (vgpu_vq_page == 0 || vgpu_cmd_page == 0)
                return false;

            // Configure controlq (queue 0)
            mmio_write16 (vgpu_common_base + 22, 0);
            int max_q = mmio_read32 (vgpu_common_base + 24) & 0xFFFF;
            if (max_q < vgpu_qsize && max_q > 0)
                vgpu_qsize = max_q;
            mmio_write16 (vgpu_common_base + 24, vgpu_qsize);
            vgpu_q_notify_off = mmio_read32 (vgpu_common_base + 30) & 0xFFFF;

            mmio_write64 (vgpu_common_base + 32, vgpu_vq_page);        // desc
            mmio_write64 (vgpu_common_base + 40, vgpu_vq_page + 512);  // avail
            mmio_write64 (vgpu_common_base + 48, vgpu_vq_page + 1024); // used
            mmio_write16 (vgpu_common_base + 28, 1);                   // queue_enable

            mmio_write8 (vgpu_common_base + 20, ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK);
            vgpu_found = 1;

            // Query display info (24-byte hdr -> 24 + 16*24 = 408-byte resp)
            for (int i = 0; i < 64; i += 4)
                mmio_write32 (vgpu_cmd_page + i, 0);
            mmio_write32 (vgpu_cmd_page + 0, CMD_GET_DISPLAY_INFO);
            if (send_cmd (24, 408)) {
                int rtype = mmio_read32 (vgpu_cmd_page + 2048);
                if (rtype == RESP_OK_DISPLAY_INFO) {
                    vgpu_disp_w = mmio_read32 (vgpu_cmd_page + 2048 + 24 + 8);
                    vgpu_disp_h = mmio_read32 (vgpu_cmd_page + 2048 + 24 + 12);
                }
            }

            // Probe 3D capsets for CAPSET_VENUS (4) if device config reports capsets
            if (vgpu_dev_base != 0 && (vgpu_features_lo & F_VIRGL) != 0) {
                int num_capsets = mmio_read32 (vgpu_dev_base + 8);
                for (int ci = 0; ci < num_capsets && ci < 16; ci++) {
                    for (int i = 0; i < 32; i += 4)
                        mmio_write32 (vgpu_cmd_page + i, 0);
                    mmio_write32 (vgpu_cmd_page + 0, CMD_GET_CAPSET_INFO);
                    mmio_write32 (vgpu_cmd_page + 24, ci);
                    if (send_cmd (32, 40)) {
                        int rtype = mmio_read32 (vgpu_cmd_page + 2048);
                        if (rtype == RESP_OK_CAPSET_INFO) {
                            int cid = mmio_read32 (vgpu_cmd_page + 2048 + 24);
                            if (cid == CAPSET_VENUS)
                                vgpu_has_venus = 1;
                        }
                    }
                }
            }
            return true;
        }

        public static bool is_present () { return vgpu_found != 0; }
        public static bool has_virgl () { return (vgpu_features_lo & F_VIRGL) != 0; }
        public static bool has_blob () { return (vgpu_features_lo & F_RESOURCE_BLOB) != 0; }
        public static bool has_ctx_init () { return (vgpu_features_lo & F_CONTEXT_INIT) != 0; }
        public static bool has_venus () { return vgpu_has_venus != 0; }
        public static int display_width () { return vgpu_disp_w; }
        public static int display_height () { return vgpu_disp_h; }
    }
}
