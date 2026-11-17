// VirtIO-GPU PCI driver (Modern VirtIO 1.0 MMIO transport + controlq + cursorq).
// Phase 1: PCI probe, Modern capability discovery, feature negotiation
//          (VIRGL, RESOURCE_BLOB, CONTEXT_INIT), GET_DISPLAY_INFO, GET_CAPSET_INFO.
// Phase 2: 2D scanout (RESOURCE_CREATE_2D, RESOURCE_ATTACH_BACKING, SET_SCANOUT,
//          TRANSFER_TO_HOST_2D, RESOURCE_FLUSH) & hardware cursorq (UPDATE/MOVE_CURSOR).
// Phase 3: 3D/Venus contexts & submission (CTX_CREATE, CTX_DESTROY, CTX_ATTACH_RESOURCE,
//          RESOURCE_CREATE_BLOB, SUBMIT_3D with fences).

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

    // Queue 0 (controlq)
    private int vgpu_vq_page = 0;
    private int vgpu_cmd_page = 0;
    private int vgpu_qsize = 16;
    private int vgpu_q_notify_off = 0;
    private int vgpu_avail_idx = 0;
    private int vgpu_last_used = 0;

    // Queue 1 (cursorq)
    private int vgpu_cq_page = 0;
    private int vgpu_ccmd_page = 0;
    private int vgpu_cqsize = 16;
    private int vgpu_cq_notify_off = 0;
    private int vgpu_cavail_idx = 0;
    private int vgpu_clast_used = 0;
    private int vgpu_cursor_pa = 0;
    private int vgpu_cursor_ready = 0;

    // Display & 2D scanout state
    private int vgpu_disp_w = 0;
    private int vgpu_disp_h = 0;
    private int vgpu_has_venus = 0;
    private int vgpu_scanout_w = 0;
    private int vgpu_scanout_h = 0;
    private int vgpu_fb_pa = 0;
    private int vgpu_fence_seq = 1;

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
        private const int CMD_GET_DISPLAY_INFO        = 0x0100;
        private const int CMD_RESOURCE_CREATE_2D      = 0x0101;
        private const int CMD_RESOURCE_UNREF          = 0x0102;
        private const int CMD_SET_SCANOUT             = 0x0103;
        private const int CMD_RESOURCE_FLUSH          = 0x0104;
        private const int CMD_TRANSFER_TO_HOST_2D     = 0x0105;
        private const int CMD_RESOURCE_ATTACH_BACKING = 0x0106;
        private const int CMD_GET_CAPSET_INFO         = 0x0108;
        private const int CMD_RESOURCE_CREATE_BLOB    = 0x010A;
        private const int CMD_CTX_CREATE              = 0x0200;
        private const int CMD_CTX_DESTROY             = 0x0201;
        private const int CMD_CTX_ATTACH_RESOURCE     = 0x0202;
        private const int CMD_SUBMIT_3D               = 0x0207;
        private const int CMD_UPDATE_CURSOR           = 0x0300;
        private const int CMD_MOVE_CURSOR             = 0x0301;

        private const int RESP_OK_NODATA       = 0x1100;
        private const int RESP_OK_DISPLAY_INFO = 0x1101;
        private const int RESP_OK_CAPSET_INFO  = 0x1102;

        private const int FMT_B8G8R8A8_UNORM = 1;
        private const int FMT_B8G8R8X8_UNORM = 2;
        private const int FLAG_FENCE         = 1;
        private const int CAPSET_VENUS       = 4;

        private const int RES_SCANOUT = 1;
        private const int RES_CURSOR  = 2;

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
                return 0;
            return raw & 0xFFFFFFF0;
        }

        private static void clear_cmd (int bytes) {
            for (int i = 0; i < bytes; i += 4)
                mmio_write32 (vgpu_cmd_page + i, 0);
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

        private static bool send_cmd_payload (int hdr_bytes, int pay_pa, int pay_bytes, int resp_bytes) {
            if (vgpu_vq_page == 0 || vgpu_cmd_page == 0)
                return false;
            int req_pa = vgpu_cmd_page;
            int resp_pa = vgpu_cmd_page + 2048;
            for (int i = 0; i < resp_bytes; i += 4)
                mmio_write32 (resp_pa + i, 0);

            int desc_base = vgpu_vq_page;
            int avail_base = vgpu_vq_page + 512;
            int used_base = vgpu_vq_page + 1024;

            // Descriptor 0: OUT header
            mmio_write64 (desc_base + 0, req_pa);
            mmio_write32 (desc_base + 8, hdr_bytes);
            mmio_write16 (desc_base + 12, 0x01); // NEXT
            mmio_write16 (desc_base + 14, 1);

            // Descriptor 1: OUT payload
            mmio_write64 (desc_base + 16, pay_pa);
            mmio_write32 (desc_base + 24, pay_bytes);
            mmio_write16 (desc_base + 28, 0x01); // NEXT
            mmio_write16 (desc_base + 30, 2);

            // Descriptor 2: IN response
            mmio_write64 (desc_base + 32, resp_pa);
            mmio_write32 (desc_base + 40, resp_bytes);
            mmio_write16 (desc_base + 44, 0x02); // WRITE
            mmio_write16 (desc_base + 46, 0);

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

        private static bool send_cursor_cmd (int req_bytes) {
            if (vgpu_cq_page == 0 || vgpu_ccmd_page == 0)
                return false;
            int req_pa = vgpu_ccmd_page;
            int resp_pa = vgpu_ccmd_page + 2048;
            for (int i = 0; i < 24; i += 4)
                mmio_write32 (resp_pa + i, 0);

            int desc_base = vgpu_cq_page;
            int avail_base = vgpu_cq_page + 512;
            int used_base = vgpu_cq_page + 1024;

            mmio_write64 (desc_base + 0, req_pa);
            mmio_write32 (desc_base + 8, req_bytes);
            mmio_write16 (desc_base + 12, 0x01);
            mmio_write16 (desc_base + 14, 1);

            mmio_write64 (desc_base + 16, resp_pa);
            mmio_write32 (desc_base + 24, 24);
            mmio_write16 (desc_base + 28, 0x02);
            mmio_write16 (desc_base + 30, 0);

            int ring_slot = vgpu_cavail_idx % vgpu_cqsize;
            mmio_write16 (avail_base + 4 + ring_slot * 2, 0);
            vgpu_cavail_idx++;
            mmio_write16 (avail_base + 2, vgpu_cavail_idx & 0xFFFF);

            mmio_write16 (vgpu_notify_base + vgpu_cq_notify_off * vgpu_notify_mult, 1);

            for (int spin = 0; spin < 500000; spin++) {
                int uidx = mmio_read32 (used_base) >> 16;
                if ((uidx & 0xFFFF) != (vgpu_clast_used & 0xFFFF)) {
                    vgpu_clast_used = uidx & 0xFFFF;
                    return true;
                }
            }
            return false;
        }

        private static int resp_type () {
            return mmio_read32 (vgpu_cmd_page + 2048);
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

            int cmd = pci_cfg_read32 (cfg_addr (found_dev, 0x04));
            pci_cfg_write32 (cfg_addr (found_dev, 0x04), cmd | 0x06);

            int status = cfg_read16 (found_dev, 0x06);
            if ((status & 0x10) == 0)
                return false;

            int cap_ptr = cfg_read8 (found_dev, 0x34) & 0xFC;
            while (cap_ptr != 0) {
                int cap_id = cfg_read8 (found_dev, cap_ptr);
                int next_ptr = cfg_read8 (found_dev, cap_ptr + 1) & 0xFC;
                if (cap_id == 0x09) {
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

            mmio_write8 (vgpu_common_base + 20, 0);
            mmio_write8 (vgpu_common_base + 20, ST_ACK);
            mmio_write8 (vgpu_common_base + 20, ST_ACK | ST_DRIVER);

            mmio_write32 (vgpu_common_base + 0, 0);
            vgpu_features_lo = mmio_read32 (vgpu_common_base + 4);
            mmio_write32 (vgpu_common_base + 0, 1);
            int features_hi = mmio_read32 (vgpu_common_base + 4);

            int want_lo = vgpu_features_lo & (F_VIRGL | F_EDID | F_RESOURCE_UUID | F_RESOURCE_BLOB | F_CONTEXT_INIT);
            int want_hi = features_hi & 1; // VIRTIO_F_VERSION_1
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
            vgpu_cq_page = Pmm.alloc_frame ();
            vgpu_ccmd_page = Pmm.alloc_frame ();
            if (vgpu_vq_page == 0 || vgpu_cmd_page == 0)
                return false;

            // Configure controlq (queue 0)
            mmio_write16 (vgpu_common_base + 22, 0);
            int max_q = mmio_read32 (vgpu_common_base + 24) & 0xFFFF;
            if (max_q < vgpu_qsize && max_q > 0)
                vgpu_qsize = max_q;
            mmio_write16 (vgpu_common_base + 24, vgpu_qsize);
            vgpu_q_notify_off = mmio_read32 (vgpu_common_base + 30) & 0xFFFF;
            mmio_write64 (vgpu_common_base + 32, vgpu_vq_page);
            mmio_write64 (vgpu_common_base + 40, vgpu_vq_page + 512);
            mmio_write64 (vgpu_common_base + 48, vgpu_vq_page + 1024);
            mmio_write16 (vgpu_common_base + 28, 1);

            // Configure cursorq (queue 1)
            if (vgpu_cq_page != 0 && vgpu_ccmd_page != 0) {
                mmio_write16 (vgpu_common_base + 22, 1);
                int max_cq = mmio_read32 (vgpu_common_base + 24) & 0xFFFF;
                if (max_cq > 0) {
                    if (max_cq < vgpu_cqsize)
                        vgpu_cqsize = max_cq;
                    mmio_write16 (vgpu_common_base + 24, vgpu_cqsize);
                    vgpu_cq_notify_off = mmio_read32 (vgpu_common_base + 30) & 0xFFFF;
                    mmio_write64 (vgpu_common_base + 32, vgpu_cq_page);
                    mmio_write64 (vgpu_common_base + 40, vgpu_cq_page + 512);
                    mmio_write64 (vgpu_common_base + 48, vgpu_cq_page + 1024);
                    mmio_write16 (vgpu_common_base + 28, 1);
                }
            }

            mmio_write8 (vgpu_common_base + 20, ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK);
            vgpu_found = 1;

            // Query display info
            clear_cmd (64);
            mmio_write32 (vgpu_cmd_page + 0, CMD_GET_DISPLAY_INFO);
            if (send_cmd (24, 408) && resp_type () == RESP_OK_DISPLAY_INFO) {
                vgpu_disp_w = mmio_read32 (vgpu_cmd_page + 2048 + 24 + 8);
                vgpu_disp_h = mmio_read32 (vgpu_cmd_page + 2048 + 24 + 12);
            }

            // Probe 3D capsets for CAPSET_VENUS (4)
            if (vgpu_dev_base != 0 && (vgpu_features_lo & F_VIRGL) != 0) {
                int num_capsets = mmio_read32 (vgpu_dev_base + 8);
                for (int ci = 0; ci < num_capsets && ci < 16; ci++) {
                    clear_cmd (32);
                    mmio_write32 (vgpu_cmd_page + 0, CMD_GET_CAPSET_INFO);
                    mmio_write32 (vgpu_cmd_page + 24, ci);
                    if (send_cmd (32, 40) && resp_type () == RESP_OK_CAPSET_INFO) {
                        int cid = mmio_read32 (vgpu_cmd_page + 2048 + 24);
                        if (cid == CAPSET_VENUS)
                            vgpu_has_venus = 1;
                    }
                }
            }
            return true;
        }

        // --- Phase 2: 2D Scanout & Hardware Cursor ---

        public static int init_scanout (int w, int h) {
            if (vgpu_found == 0 || w <= 0 || h <= 0)
                return 0;
            if (vgpu_fb_pa != 0 && vgpu_scanout_w == w && vgpu_scanout_h == h)
                return vgpu_fb_pa;

            int fb_bytes = w * h * 4;
            int pages = (fb_bytes + 4095) / 4096;
            if (vgpu_fb_pa == 0) {
                vgpu_fb_pa = Pmm.alloc_contiguous (pages);
                if (vgpu_fb_pa == 0)
                    return 0;
            }

            // 1. RESOURCE_CREATE_2D (40 bytes)
            clear_cmd (40);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_CREATE_2D);
            mmio_write32 (vgpu_cmd_page + 24, RES_SCANOUT);
            mmio_write32 (vgpu_cmd_page + 28, FMT_B8G8R8X8_UNORM);
            mmio_write32 (vgpu_cmd_page + 32, w);
            mmio_write32 (vgpu_cmd_page + 36, h);
            if (!send_cmd (40, 24) || resp_type () != RESP_OK_NODATA)
                return 0;

            // 2. RESOURCE_ATTACH_BACKING (48 bytes)
            clear_cmd (48);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_ATTACH_BACKING);
            mmio_write32 (vgpu_cmd_page + 24, RES_SCANOUT);
            mmio_write32 (vgpu_cmd_page + 28, 1);
            mmio_write64 (vgpu_cmd_page + 32, vgpu_fb_pa);
            mmio_write32 (vgpu_cmd_page + 40, fb_bytes);
            if (!send_cmd (48, 24) || resp_type () != RESP_OK_NODATA)
                return 0;

            // 3. SET_SCANOUT (48 bytes)
            clear_cmd (48);
            mmio_write32 (vgpu_cmd_page + 0, CMD_SET_SCANOUT);
            mmio_write32 (vgpu_cmd_page + 32, w);
            mmio_write32 (vgpu_cmd_page + 36, h);
            mmio_write32 (vgpu_cmd_page + 40, 0); // scanout_id
            mmio_write32 (vgpu_cmd_page + 44, RES_SCANOUT);
            if (!send_cmd (48, 24) || resp_type () != RESP_OK_NODATA)
                return 0;

            vgpu_scanout_w = w;
            vgpu_scanout_h = h;
            return vgpu_fb_pa;
        }

        public static void present_rect (int src_buf, int rx, int ry, int rw, int rh) {
            if (vgpu_fb_pa == 0 || src_buf == 0 || vgpu_scanout_w <= 0)
                return;
            if (rx < 0) rx = 0;
            if (ry < 0) ry = 0;
            if (rx + rw > vgpu_scanout_w) rw = vgpu_scanout_w - rx;
            if (ry + rh > vgpu_scanout_h) rh = vgpu_scanout_h - ry;
            if (rw <= 0 || rh <= 0)
                return;

            for (int row = 0; row < rh; row++) {
                int off = ((ry + row) * vgpu_scanout_w + rx) * 4;
                fb_copy_dwords (vgpu_fb_pa + off, src_buf + off, rw);
            }

            // TRANSFER_TO_HOST_2D (56 bytes)
            clear_cmd (56);
            mmio_write32 (vgpu_cmd_page + 0, CMD_TRANSFER_TO_HOST_2D);
            mmio_write32 (vgpu_cmd_page + 24, rx);
            mmio_write32 (vgpu_cmd_page + 28, ry);
            mmio_write32 (vgpu_cmd_page + 32, rw);
            mmio_write32 (vgpu_cmd_page + 36, rh);
            mmio_write64 (vgpu_cmd_page + 40, (ry * vgpu_scanout_w + rx) * 4);
            mmio_write32 (vgpu_cmd_page + 48, RES_SCANOUT);
            send_cmd (56, 24);

            // RESOURCE_FLUSH (48 bytes)
            clear_cmd (48);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_FLUSH);
            mmio_write32 (vgpu_cmd_page + 24, rx);
            mmio_write32 (vgpu_cmd_page + 28, ry);
            mmio_write32 (vgpu_cmd_page + 32, rw);
            mmio_write32 (vgpu_cmd_page + 36, rh);
            mmio_write32 (vgpu_cmd_page + 40, RES_SCANOUT);
            send_cmd (48, 24);
        }

        public static void present_full (int src_buf, int w, int h) {
            int cw = (w < vgpu_scanout_w) ? w : vgpu_scanout_w;
            int ch = (h < vgpu_scanout_h) ? h : vgpu_scanout_h;
            present_rect (src_buf, 0, 0, cw, ch);
        }

        public static void close_scanout () {
            if (vgpu_found == 0 || vgpu_fb_pa == 0)
                return;
            clear_cmd (48);
            mmio_write32 (vgpu_cmd_page + 0, CMD_SET_SCANOUT);
            mmio_write32 (vgpu_cmd_page + 40, 0);
            mmio_write32 (vgpu_cmd_page + 44, 0);
            send_cmd (48, 24);

            clear_cmd (32);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_UNREF);
            mmio_write32 (vgpu_cmd_page + 24, RES_SCANOUT);
            send_cmd (32, 24);

            vgpu_scanout_w = 0;
            vgpu_scanout_h = 0;
        }

        public static bool set_cursor (int rgba_buf, int hot_x, int hot_y) {
            if (vgpu_found == 0 || rgba_buf == 0 || vgpu_cq_page == 0)
                return false;
            if (vgpu_cursor_pa == 0) {
                vgpu_cursor_pa = Pmm.alloc_contiguous (4); // 64x64x4 = 16 KiB
                if (vgpu_cursor_pa == 0)
                    return false;
                clear_cmd (40);
                mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_CREATE_2D);
                mmio_write32 (vgpu_cmd_page + 24, RES_CURSOR);
                mmio_write32 (vgpu_cmd_page + 28, FMT_B8G8R8A8_UNORM);
                mmio_write32 (vgpu_cmd_page + 32, 64);
                mmio_write32 (vgpu_cmd_page + 36, 64);
                if (!send_cmd (40, 24) || resp_type () != RESP_OK_NODATA)
                    return false;

                clear_cmd (48);
                mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_ATTACH_BACKING);
                mmio_write32 (vgpu_cmd_page + 24, RES_CURSOR);
                mmio_write32 (vgpu_cmd_page + 28, 1);
                mmio_write64 (vgpu_cmd_page + 32, vgpu_cursor_pa);
                mmio_write32 (vgpu_cmd_page + 40, 16384);
                if (!send_cmd (48, 24) || resp_type () != RESP_OK_NODATA)
                    return false;
            }
            fb_copy_dwords (vgpu_cursor_pa, rgba_buf, 4096);

            clear_cmd (56);
            mmio_write32 (vgpu_cmd_page + 0, CMD_TRANSFER_TO_HOST_2D);
            mmio_write32 (vgpu_cmd_page + 32, 64);
            mmio_write32 (vgpu_cmd_page + 36, 64);
            mmio_write32 (vgpu_cmd_page + 48, RES_CURSOR);
            send_cmd (56, 24);

            for (int i = 0; i < 56; i += 4)
                mmio_write32 (vgpu_ccmd_page + i, 0);
            mmio_write32 (vgpu_ccmd_page + 0, CMD_UPDATE_CURSOR);
            mmio_write32 (vgpu_ccmd_page + 40, RES_CURSOR);
            mmio_write32 (vgpu_ccmd_page + 44, hot_x);
            mmio_write32 (vgpu_ccmd_page + 48, hot_y);
            vgpu_cursor_ready = 1;
            return send_cursor_cmd (56);
        }

        public static bool move_cursor (int x, int y) {
            if (vgpu_found == 0 || vgpu_cursor_ready == 0 || vgpu_cq_page == 0)
                return false;
            for (int i = 0; i < 56; i += 4)
                mmio_write32 (vgpu_ccmd_page + i, 0);
            mmio_write32 (vgpu_ccmd_page + 0, CMD_MOVE_CURSOR);
            mmio_write32 (vgpu_ccmd_page + 28, x);
            mmio_write32 (vgpu_ccmd_page + 32, y);
            mmio_write32 (vgpu_ccmd_page + 40, RES_CURSOR);
            return send_cursor_cmd (56);
        }

        // --- Phase 3: 3D Contexts, Blobs & SUBMIT_3D (VirGL / Venus) ---

        public static bool ctx_create (int ctx_id, int capset_id) {
            if (vgpu_found == 0 || (vgpu_features_lo & F_VIRGL) == 0 || ctx_id <= 0)
                return false;
            clear_cmd (96);
            mmio_write32 (vgpu_cmd_page + 0, CMD_CTX_CREATE);
            mmio_write32 (vgpu_cmd_page + 16, ctx_id);
            mmio_write32 (vgpu_cmd_page + 24, 8); // nlen ("planetos")
            if (has_ctx_init () && capset_id > 0)
                mmio_write32 (vgpu_cmd_page + 28, capset_id);
            mmio_write32 (vgpu_cmd_page + 32, 0x6E616C70); // "plan"
            mmio_write32 (vgpu_cmd_page + 36, 0x736F7465); // "etos"
            return send_cmd (96, 24) && resp_type () == RESP_OK_NODATA;
        }

        public static bool ctx_destroy (int ctx_id) {
            if (vgpu_found == 0 || ctx_id <= 0)
                return false;
            clear_cmd (24);
            mmio_write32 (vgpu_cmd_page + 0, CMD_CTX_DESTROY);
            mmio_write32 (vgpu_cmd_page + 16, ctx_id);
            return send_cmd (24, 24) && resp_type () == RESP_OK_NODATA;
        }

        public static bool ctx_attach (int ctx_id, int res_id) {
            if (vgpu_found == 0 || ctx_id <= 0 || res_id <= 0)
                return false;
            clear_cmd (32);
            mmio_write32 (vgpu_cmd_page + 0, CMD_CTX_ATTACH_RESOURCE);
            mmio_write32 (vgpu_cmd_page + 16, ctx_id);
            mmio_write32 (vgpu_cmd_page + 24, res_id);
            return send_cmd (32, 24) && resp_type () == RESP_OK_NODATA;
        }

        public static bool create_blob (int res_id, int ctx_id, int blob_mem, int blob_flags, int size, int blob_id) {
            if (vgpu_found == 0 || !has_blob () || res_id <= 0 || size <= 0)
                return false;
            clear_cmd (56);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_CREATE_BLOB);
            mmio_write32 (vgpu_cmd_page + 16, ctx_id);
            mmio_write32 (vgpu_cmd_page + 24, res_id);
            mmio_write32 (vgpu_cmd_page + 28, blob_mem);
            mmio_write32 (vgpu_cmd_page + 32, blob_flags);
            mmio_write64 (vgpu_cmd_page + 40, size);
            mmio_write64 (vgpu_cmd_page + 48, blob_id);
            return send_cmd (56, 24) && resp_type () == RESP_OK_NODATA;
        }

        public static bool submit_3d (int ctx_id, int cmd_buf_pa, int cmd_bytes, bool with_fence) {
            if (vgpu_found == 0 || (vgpu_features_lo & F_VIRGL) == 0 || cmd_buf_pa == 0 || cmd_bytes <= 0)
                return false;
            clear_cmd (32);
            mmio_write32 (vgpu_cmd_page + 0, CMD_SUBMIT_3D);
            if (with_fence) {
                mmio_write32 (vgpu_cmd_page + 4, FLAG_FENCE);
                mmio_write64 (vgpu_cmd_page + 8, vgpu_fence_seq);
                vgpu_fence_seq++;
            }
            mmio_write32 (vgpu_cmd_page + 16, ctx_id);
            mmio_write32 (vgpu_cmd_page + 24, cmd_bytes);
            return send_cmd_payload (32, cmd_buf_pa, cmd_bytes, 24) && resp_type () == RESP_OK_NODATA;
        }

        public static bool is_present () { return vgpu_found != 0; }
        public static bool has_virgl () { return (vgpu_features_lo & F_VIRGL) != 0; }
        public static bool has_blob () { return (vgpu_features_lo & F_RESOURCE_BLOB) != 0; }
        public static bool has_ctx_init () { return (vgpu_features_lo & F_CONTEXT_INIT) != 0; }
        public static bool has_venus () { return vgpu_has_venus != 0; }
        public static int display_width () { return vgpu_disp_w; }
        public static int display_height () { return vgpu_disp_h; }
        public static int packed_caps () {
            int f = vgpu_found;
            if (has_virgl ()) f |= 2;
            if (has_blob ()) f |= 4;
            if (has_ctx_init ()) f |= 8;
            if (has_venus ()) f |= 16;
            return f | ((vgpu_disp_w & 0xFFFF) << 16) | ((vgpu_disp_h & 0xFFFF) << 32);
        }
    }
}
