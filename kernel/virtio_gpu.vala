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
    private int vgpu_scanout_active = 0;
    private int vgpu_fb_pa = 0;
    private int vgpu_fb_pages = 0;
    private int vgpu_con_active = 0;
    private int vgpu_con_cur_r = -1;
    private int vgpu_con_cur_c = -1;
    private int vgpu_con_dirty_r0 = 25;
    private int vgpu_con_dirty_r1 = -1;
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

            // Probe 3D capsets for CAPSET_VENUS (4) (num_capsets is at device_cfg + 12)
            if (vgpu_dev_base != 0 && (vgpu_features_lo & F_VIRGL) != 0) {
                int num_capsets = mmio_read32 (vgpu_dev_base + 12);
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
            if (vgpu_scanout_active != 0 && vgpu_scanout_w == w && vgpu_scanout_h == h)
                return vgpu_fb_pa;
            if (vgpu_scanout_active != 0)
                close_scanout ();

            int fb_bytes = w * h * 4;
            int pages = (fb_bytes + 4095) / 4096;
            if (vgpu_fb_pa != 0 && pages > vgpu_fb_pages) {
                for (int p = 0; p < vgpu_fb_pages; p++)
                    Pmm.free_frame (vgpu_fb_pa + p * 4096);
                vgpu_fb_pa = 0;
                vgpu_fb_pages = 0;
            }
            if (vgpu_fb_pa == 0) {
                int alloc_pages = (pages < 1000) ? 1000 : pages; // 1280x800x4 max without realloc
                vgpu_fb_pa = Pmm.alloc_contiguous (alloc_pages);
                if (vgpu_fb_pa == 0) {
                    vgpu_fb_pa = Pmm.alloc_contiguous (pages);
                    alloc_pages = pages;
                }
                if (vgpu_fb_pa == 0)
                    return 0;
                vgpu_fb_pages = alloc_pages;
            }

            // 1. RESOURCE_CREATE_2D (40 bytes)
            clear_cmd (40);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_CREATE_2D);
            mmio_write32 (vgpu_cmd_page + 24, RES_SCANOUT);
            mmio_write32 (vgpu_cmd_page + 28, FMT_B8G8R8X8_UNORM);
            mmio_write32 (vgpu_cmd_page + 32, w);
            mmio_write32 (vgpu_cmd_page + 36, h);
            if (!send_cmd (40, 24) || resp_type () != RESP_OK_NODATA) {
                print (@"virtio_gpu: create_2d failed resp=$(resp_type ())\n");
                return 0;
            }

            // 2. RESOURCE_ATTACH_BACKING (48 bytes)
            clear_cmd (48);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_ATTACH_BACKING);
            mmio_write32 (vgpu_cmd_page + 24, RES_SCANOUT);
            mmio_write32 (vgpu_cmd_page + 28, 1);
            mmio_write64 (vgpu_cmd_page + 32, vgpu_fb_pa);
            mmio_write32 (vgpu_cmd_page + 40, fb_bytes);
            if (!send_cmd (48, 24) || resp_type () != RESP_OK_NODATA) {
                print (@"virtio_gpu: attach_backing failed resp=$(resp_type ())\n");
                return 0;
            }

            // 3. SET_SCANOUT (48 bytes)
            clear_cmd (48);
            mmio_write32 (vgpu_cmd_page + 0, CMD_SET_SCANOUT);
            mmio_write32 (vgpu_cmd_page + 32, w);
            mmio_write32 (vgpu_cmd_page + 36, h);
            mmio_write32 (vgpu_cmd_page + 40, 0); // scanout_id
            mmio_write32 (vgpu_cmd_page + 44, RES_SCANOUT);
            if (!send_cmd (48, 24) || resp_type () != RESP_OK_NODATA) {
                print (@"virtio_gpu: set_scanout failed resp=$(resp_type ())\n");
                return 0;
            }

            vgpu_scanout_w = w;
            vgpu_scanout_h = h;
            vgpu_scanout_active = 1;
            return vgpu_fb_pa;
        }

        private static void flush_scanout_rect (int rx, int ry, int rw, int rh) {
            if (vgpu_vq_page == 0 || vgpu_cmd_page == 0)
                return;
            // Batch TRANSFER_TO_HOST_2D (req0 at +0, resp0 at +2048) and
            // RESOURCE_FLUSH (req1 at +128, resp1 at +2112) in one doorbell.
            int req0 = vgpu_cmd_page;
            int req1 = vgpu_cmd_page + 128;
            int resp0 = vgpu_cmd_page + 2048;
            int resp1 = vgpu_cmd_page + 2112;
            for (int i = 0; i < 64; i += 4) {
                mmio_write32 (req0 + i, 0);
                mmio_write32 (req1 + i, 0);
            }
            for (int i = 0; i < 24; i += 4) {
                mmio_write32 (resp0 + i, 0);
                mmio_write32 (resp1 + i, 0);
            }

            mmio_write32 (req0 + 0, CMD_TRANSFER_TO_HOST_2D);
            mmio_write32 (req0 + 24, rx);
            mmio_write32 (req0 + 28, ry);
            mmio_write32 (req0 + 32, rw);
            mmio_write32 (req0 + 36, rh);
            mmio_write64 (req0 + 40, (ry * vgpu_scanout_w + rx) * 4);
            mmio_write32 (req0 + 48, RES_SCANOUT);

            mmio_write32 (req1 + 0, CMD_RESOURCE_FLUSH);
            mmio_write32 (req1 + 24, rx);
            mmio_write32 (req1 + 28, ry);
            mmio_write32 (req1 + 32, rw);
            mmio_write32 (req1 + 36, rh);
            mmio_write32 (req1 + 40, RES_SCANOUT);

            int desc_base = vgpu_vq_page;
            int avail_base = vgpu_vq_page + 512;
            int used_base = vgpu_vq_page + 1024;

            // Chain 0: TRANSFER_TO_HOST_2D (desc 0 -> desc 1)
            mmio_write64 (desc_base + 0, req0);
            mmio_write32 (desc_base + 8, 56);
            mmio_write16 (desc_base + 12, 0x01);
            mmio_write16 (desc_base + 14, 1);

            mmio_write64 (desc_base + 16, resp0);
            mmio_write32 (desc_base + 24, 24);
            mmio_write16 (desc_base + 28, 0x02);
            mmio_write16 (desc_base + 30, 0);

            // Chain 1: RESOURCE_FLUSH (desc 2 -> desc 3)
            mmio_write64 (desc_base + 32, req1);
            mmio_write32 (desc_base + 40, 48);
            mmio_write16 (desc_base + 44, 0x01);
            mmio_write16 (desc_base + 46, 3);

            mmio_write64 (desc_base + 48, resp1);
            mmio_write32 (desc_base + 56, 24);
            mmio_write16 (desc_base + 60, 0x02);
            mmio_write16 (desc_base + 62, 0);

            int target_used = (vgpu_last_used + 2) & 0xFFFF;
            int s0 = vgpu_avail_idx % vgpu_qsize;
            mmio_write16 (avail_base + 4 + s0 * 2, 0);
            vgpu_avail_idx++;
            int s1 = vgpu_avail_idx % vgpu_qsize;
            mmio_write16 (avail_base + 4 + s1 * 2, 2);
            vgpu_avail_idx++;
            mmio_write16 (avail_base + 2, vgpu_avail_idx & 0xFFFF);

            mmio_write16 (vgpu_notify_base + vgpu_q_notify_off * vgpu_notify_mult, 0);

            for (int spin = 0; spin < 2000000; spin++) {
                int uidx = mmio_read32 (used_base) >> 16;
                if ((uidx & 0xFFFF) == target_used) {
                    vgpu_last_used = target_used;
                    return;
                }
            }
            vgpu_last_used = mmio_read32 (used_base) >> 16;
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

            if (rx == 0 && rw == vgpu_scanout_w) {
                Fb.copy_fast (vgpu_fb_pa + ry * vgpu_scanout_w * 4,
                              src_buf + ry * vgpu_scanout_w * 4,
                              rw * rh);
            } else {
                for (int row = 0; row < rh; row++) {
                    int off = ((ry + row) * vgpu_scanout_w + rx) * 4;
                    Fb.copy_fast (vgpu_fb_pa + off, src_buf + off, rw);
                }
            }

            flush_scanout_rect (rx, ry, rw, rh);
        }

        public static void present_full (int src_buf, int w, int h) {
            if (vgpu_fb_pa == 0 || src_buf == 0 || vgpu_scanout_w <= 0)
                return;
            int cw = (w < vgpu_scanout_w) ? w : vgpu_scanout_w;
            int ch = (h < vgpu_scanout_h) ? h : vgpu_scanout_h;
            if (cw <= 0 || ch <= 0)
                return;
            if (w == vgpu_scanout_w) {
                Fb.copy_fast (vgpu_fb_pa, src_buf, cw * ch);
            } else {
                for (int row = 0; row < ch; row++) {
                    Fb.copy_fast (vgpu_fb_pa + row * vgpu_scanout_w * 4, src_buf + row * w * 4, cw);
                }
            }
            flush_scanout_rect (0, 0, cw, ch);
        }

        public static void close_scanout () {
            if (vgpu_found == 0 || vgpu_scanout_active == 0)
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
            vgpu_scanout_active = 0;
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

        public static int create_blob_mapped (int ctx_id, int res_id, int size) {
            if (vgpu_found == 0 || !has_blob () || ctx_id <= 0 || res_id <= 0 || size <= 0)
                return 0;
            int pages = (size + 4095) / 4096;
            if (pages > 256)
                pages = 256; // cap at 1 MiB per blob
            int aligned = pages * 4096;
            int pa = Pmm.alloc_contiguous (pages);
            if (pa == 0)
                return 0;
            // VIRTIO_GPU_CMD_RESOURCE_CREATE_BLOB (56B) + 1 mem_entry (16B) = 72B
            // blob_mem = 1 (BLOB_MEM_GUEST), blob_flags = 1 (USE_MAPPABLE), nr_entries = 1
            clear_cmd (72);
            mmio_write32 (vgpu_cmd_page + 0, CMD_RESOURCE_CREATE_BLOB);
            mmio_write32 (vgpu_cmd_page + 16, ctx_id);
            mmio_write32 (vgpu_cmd_page + 24, res_id);
            mmio_write32 (vgpu_cmd_page + 28, 1);       // BLOB_MEM_GUEST
            mmio_write32 (vgpu_cmd_page + 32, 1);       // BLOB_FLAG_USE_MAPPABLE
            mmio_write32 (vgpu_cmd_page + 36, 1);       // nr_entries = 1
            mmio_write64 (vgpu_cmd_page + 40, aligned); // size
            mmio_write64 (vgpu_cmd_page + 48, 0);       // blob_id = 0 for GUEST
            mmio_write64 (vgpu_cmd_page + 56, pa);      // mem_entry[0].addr
            mmio_write32 (vgpu_cmd_page + 64, aligned); // mem_entry[0].length
            if (!send_cmd (72, 24) || resp_type () != RESP_OK_NODATA) {
                for (int p = 0; p < pages; p++)
                    Pmm.free_frame (pa + p * 4096);
                return 0;
            }
            ctx_attach (ctx_id, res_id);
            int ucr3 = Sched.current_cr3 ();
            if (ucr3 != 0 && ucr3 != Vmm.KERNEL_CR3)
                Vmm.map_user_range (ucr3, pa, aligned);
            return pa;
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

        // --- Phase 2b: VirtIO-GPU 80x25 Text Console Mirror (for -vga none) ---

        // Compact 8x8 ASCII 32..126 font packed as 64-bit MSB-first bitmaps (row 0 in top byte)
        private static int font8x8 (int ch) {
            if (ch == ' ') return 0x0000000000000000;
            if (ch == '!') return 0x1818181818001800;
            if (ch == '"') return 0x6666660000000000;
            if (ch == '#') return 0x6666FF66FF666600;
            if (ch == '$') return 0x183E603C067C1800;
            if (ch == '%') return 0x6264081026460000;
            if (ch == '&') return 0x384C386C4C463B00;
            if (ch == '\'') return 0x1818300000000000;
            if (ch == '(') return 0x0C18303030180C00;
            if (ch == ')') return 0x30180C0C0C183000;
            if (ch == '*') return 0x00663CFF3C660000;
            if (ch == '+') return 0x0018187E18180000;
            if (ch == ',') return 0x0000000000181830;
            if (ch == '-') return 0x0000007E00000000;
            if (ch == '.') return 0x0000000000181800;
            if (ch == '/') return 0x0204081020408000;
            if (ch == '0') return 0x3C666E7666663C00;
            if (ch == '1') return 0x1838181818187E00;
            if (ch == '2') return 0x3C66060C18307E00;
            if (ch == '3') return 0x3C66061C06663C00;
            if (ch == '4') return 0x0C1C3C6C7E0C0C00;
            if (ch == '5') return 0x7E607C0606663C00;
            if (ch == '6') return 0x1C30607C66663C00;
            if (ch == '7') return 0x7E060C1830303000;
            if (ch == '8') return 0x3C66663C66663C00;
            if (ch == '9') return 0x3C66663E060C3800;
            if (ch == ':') return 0x0018180018180000;
            if (ch == ';') return 0x0018180018183000;
            if (ch == '<') return 0x0C18306030180C00;
            if (ch == '=') return 0x00007E007E000000;
            if (ch == '>') return 0x6030180C18306000;
            if (ch == '?') return 0x3C66061C18001800;
            if (ch == '@') return 0x3C666E6A6E603C00;
            if (ch == 'A') return 0x183C66667E666600;
            if (ch == 'B') return 0x7C66667C66667C00;
            if (ch == 'C') return 0x3C66606060663C00;
            if (ch == 'D') return 0x786C6666666C7800;
            if (ch == 'E') return 0x7E60607860607E00;
            if (ch == 'F') return 0x7E60607860606000;
            if (ch == 'G') return 0x3C66606E66663E00;
            if (ch == 'H') return 0x6666667E66666600;
            if (ch == 'I') return 0x3C18181818183C00;
            if (ch == 'J') return 0x1E0C0C0C0C6C3800;
            if (ch == 'K') return 0x666C7870786C6600;
            if (ch == 'L') return 0x6060606060607E00;
            if (ch == 'M') return 0x63777F6B63636300;
            if (ch == 'N') return 0x66767E7E6E666600;
            if (ch == 'O') return 0x3C66666666663C00;
            if (ch == 'P') return 0x7C66667C60606000;
            if (ch == 'Q') return 0x3C6666666A6C3600;
            if (ch == 'R') return 0x7C66667C6C666600;
            if (ch == 'S') return 0x3C66603C06663C00;
            if (ch == 'T') return 0x7E18181818181800;
            if (ch == 'U') return 0x6666666666663C00;
            if (ch == 'V') return 0x66666666663C1800;
            if (ch == 'W') return 0x6363636B7F776300;
            if (ch == 'X') return 0x66663C183C666600;
            if (ch == 'Y') return 0x6666663C18181800;
            if (ch == 'Z') return 0x7E060C1830607E00;
            if (ch == '[') return 0x3C30303030303C00;
            if (ch == '\\') return 0x4020100804020000;
            if (ch == ']') return 0x3C0C0C0C0C0C3C00;
            if (ch == '^') return 0x183C660000000000;
            if (ch == '_') return 0x000000000000FF00;
            if (ch == '`') return 0x30180C0000000000;
            if (ch == 'a') return 0x00003C063E663E00;
            if (ch == 'b') return 0x60607C6666667C00;
            if (ch == 'c') return 0x00003C6660663C00;
            if (ch == 'd') return 0x06063E6666663E00;
            if (ch == 'e') return 0x00003C667E603C00;
            if (ch == 'f') return 0x1C307C3030303000;
            if (ch == 'g') return 0x00003E66663E063C;
            if (ch == 'h') return 0x60607C6666666600;
            if (ch == 'i') return 0x1800381818183C00;
            if (ch == 'j') return 0x0C001C0C0C0C6C38;
            if (ch == 'k') return 0x6060666C786C6600;
            if (ch == 'l') return 0x3818181818183C00;
            if (ch == 'm') return 0x0000667F7F6B6300;
            if (ch == 'n') return 0x00007C6666666600;
            if (ch == 'o') return 0x00003C6666663C00;
            if (ch == 'p') return 0x00007C66667C6060;
            if (ch == 'q') return 0x00003E66663E0606;
            if (ch == 'r') return 0x00007C6660606000;
            if (ch == 's') return 0x00003E603C067C00;
            if (ch == 't') return 0x30307C3030301C00;
            if (ch == 'u') return 0x0000666666663E00;
            if (ch == 'v') return 0x00006666663C1800;
            if (ch == 'w') return 0x000063636B7F3600;
            if (ch == 'x') return 0x0000663C183C6600;
            if (ch == 'y') return 0x00006666663E063C;
            if (ch == 'z') return 0x00007E0C18307E00;
            if (ch == '{') return 0x1C30306030301C00;
            if (ch == '|') return 0x1818181818181800;
            if (ch == '}') return 0x380C0C060C0C3800;
            if (ch == '~') return 0x0000366C00000000;
            return 0x7E42424242427E00;
        }

        private static int vga_fg_rgb (int attr) {
            int c = attr & 0x0F;
            if (c == 0) return 0xFF0F131A;
            if (c == 1) return 0xFF3B82F6;
            if (c == 2) return 0xFF22C55E;
            if (c == 3) return 0xFF38BDF8;
            if (c == 4) return 0xFFEF4444;
            if (c == 5) return 0xFFA855F7;
            if (c == 6) return 0xFFF59E0B;
            if (c == 8) return 0xFF64748B;
            if (c == 9) return 0xFF60A5FA;
            if (c == 10) return 0xFF4ADE80;
            if (c == 11) return 0xFF7DD3FC;
            if (c == 12) return 0xFFF87171;
            if (c == 14) return 0xFFFBBF24;
            if (c == 15) return 0xFFF8FAFC;
            return 0xFFE2E8F0;
        }

        public static void set_console_active (bool on) {
            vgpu_con_active = on ? 1 : 0;
        }

        public static bool is_console_active () {
            return vgpu_con_active != 0;
        }

        public static void console_draw_cell (int row, int col, int ch, int attr, bool cursor) {
            if (vgpu_con_active == 0 || vgpu_fb_pa == 0 || row < 0 || row >= 25 || col < 0 || col >= 80)
                return;
            int fg = cursor ? 0xFF0F131A : vga_fg_rgb (attr);
            int bg = cursor ? 0xFF38BDF8 : 0xFF0F131A;
            int x0 = 240 + col * 10;
            int y0 = 110 + row * 20;
            int glyph = ch & 0xFF;
            for (int q = 0; q < 4; q++) {
                int packed = ConsoleFont.pack (glyph, q);
                for (int r = 0; r < 5; r++) {
                    int rbits = (packed >> (r * 10)) & 0x3FF;
                    int py = y0 + q * 5 + r;
                    int off = (py * 1280 + x0) * 4;
                    for (int c = 0; c < 10; c++) {
                        int px = ((rbits & (1 << (9 - c))) != 0) ? fg : bg;
                        mmio_write32 (vgpu_fb_pa + off + c * 4, px);
                    }
                }
            }
        }

        public static void console_redraw_all (int cur_r, int cur_c) {
            if (vgpu_con_active == 0 || vgpu_fb_pa == 0)
                return;
            for (int r = 0; r < 25; r++) {
                for (int c = 0; c < 80; c++) {
                    int addr = 0xB8000 + (r * 80 + c) * 2;
                    int w = mmio_read32 (addr & ~3);
                    int cell = ((addr & 2) != 0) ? ((w >> 16) & 0xFFFF) : (w & 0xFFFF);
                    console_draw_cell (r, c, cell & 0xFF, (cell >> 8) & 0xFF, (r == cur_r && c == cur_c));
                }
            }
            vgpu_con_cur_r = cur_r;
            vgpu_con_cur_c = cur_c;
            flush_scanout_rect (240, 110, 800, 500);
        }

        public static void console_flush_dirty () {
            if (vgpu_con_active == 0 || vgpu_fb_pa == 0 || vgpu_con_dirty_r1 < vgpu_con_dirty_r0)
                return;
            int r0 = vgpu_con_dirty_r0;
            int r1 = vgpu_con_dirty_r1;
            if (r0 < 0) r0 = 0;
            if (r1 >= 25) r1 = 24;
            vgpu_con_dirty_r0 = 25;
            vgpu_con_dirty_r1 = -1;
            flush_scanout_rect (240, 110 + r0 * 20, 800, (r1 - r0 + 1) * 20);
        }

        private static void mark_dirty_row (int r) {
            if (r < 0 || r >= 25)
                return;
            if (r < vgpu_con_dirty_r0) vgpu_con_dirty_r0 = r;
            if (r > vgpu_con_dirty_r1) vgpu_con_dirty_r1 = r;
        }

        public static void console_flush_cell (int row, int col, int cur_r, int cur_c, bool flush_now) {
            if (vgpu_con_active == 0 || vgpu_fb_pa == 0)
                return;
            if (vgpu_con_cur_r >= 0 && vgpu_con_cur_c >= 0 && (vgpu_con_cur_r != cur_r || vgpu_con_cur_c != cur_c)) {
                int oa = 0xB8000 + (vgpu_con_cur_r * 80 + vgpu_con_cur_c) * 2;
                int ow = mmio_read32 (oa & ~3);
                int oc = ((oa & 2) != 0) ? ((ow >> 16) & 0xFFFF) : (ow & 0xFFFF);
                console_draw_cell (vgpu_con_cur_r, vgpu_con_cur_c, oc & 0xFF, (oc >> 8) & 0xFF, false);
                mark_dirty_row (vgpu_con_cur_r);
            }
            vgpu_con_cur_r = cur_r;
            vgpu_con_cur_c = cur_c;
            if (row >= 0 && row < 25 && col >= 0 && col < 80) {
                int addr = 0xB8000 + (row * 80 + col) * 2;
                int w = mmio_read32 (addr & ~3);
                int cell = ((addr & 2) != 0) ? ((w >> 16) & 0xFFFF) : (w & 0xFFFF);
                console_draw_cell (row, col, cell & 0xFF, (cell >> 8) & 0xFF, (row == cur_r && col == cur_c));
                mark_dirty_row (row);
            }
            if (cur_r >= 0 && cur_r < 25 && cur_c >= 0 && cur_c < 80) {
                int ca = 0xB8000 + (cur_r * 80 + cur_c) * 2;
                int cw = mmio_read32 (ca & ~3);
                int cc = ((ca & 2) != 0) ? ((cw >> 16) & 0xFFFF) : (cw & 0xFFFF);
                console_draw_cell (cur_r, cur_c, cc & 0xFF, (cc >> 8) & 0xFF, true);
                mark_dirty_row (cur_r);
            }
            if (flush_now)
                console_flush_dirty ();
        }

        public static void init_console (int cur_r, int cur_c) {
            if (vgpu_found == 0)
                return;
            if (init_scanout (1280, 720) == 0)
                return;
            for (int i = 0; i < 1280 * 720 * 4; i += 4)
                mmio_write32 (vgpu_fb_pa + i, 0xFF0F131A);
            vgpu_con_active = 1;
            flush_scanout_rect (0, 0, 1280, 720);
            console_redraw_all (cur_r, cur_c);
        }
    }
}
