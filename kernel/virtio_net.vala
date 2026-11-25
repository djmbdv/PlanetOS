// VirtIO-NET PCI driver (Modern VirtIO 1.0 MMIO transport, RX queue 0 + TX queue 1).
namespace Planet.Kernel {

    [AsmBody(@"
        push %rax
        push %rcx
        push %rdx
        push %rsi
        push %rdi
        push %r8
        push %r9
        push %r10
        push %r11
        mov %rsp, %rax
        and $-16, %rsp
        push %rax
        call virtio_net_irq_entry
        pop %rax
        mov %rax, %rsp
        pop %r11
        pop %r10
        pop %r9
        pop %r8
        pop %rdi
        pop %rsi
        pop %rdx
        pop %rcx
        pop %rax
        iretq
    ")]
    public extern void isr_net ();

    [AsmBody(@"
        lea isr_net(%rip), %rax
        ret
    ")]
    public extern int addr_isr_net ();

    public static void virtio_net_irq_entry () {
        VirtioNet.irq_handler ();
        Hal.lapic_eoi ();
    }

    public sealed class VirtioNet : Object {
        private static int net_found = 0;
        private static int net_common_base = 0;
        private static int net_notify_base = 0;
        private static int net_notify_mult = 0;
        private static int net_dev_base = 0;

        private static int net_rx_vq_page = 0;
        private static int net_tx_vq_page = 0;
        private static int net_tx_buf_page = 0;
        private static int net_rx_buf_pages = 0; // 1 page = 2 * 2048 B slots

        private static int net_rx_qsize = 2;
        private static int net_tx_qsize = 8;
        private static int net_rx_notify_off = 0;
        private static int net_tx_notify_off = 0;
        private static int net_rx_avail_idx = 0;
        private static int net_rx_last_used = 0;
        private static int net_tx_avail_idx = 0;
        private static int net_tx_last_used = 0;
        private static int net_irqs = 0;
        private static int net_msix_ready = 0;
        private static int net_mac_lo = 0;
        private static int net_mac_hi = 0;

        private const int NET_VECTOR = 65;
        private const int VENDOR_VIRTIO = 0x1AF4;
        private const int DEV_NET_MODERN = 0x1041;
        private const int DEV_NET_LEGACY = 0x1000;
        private const int HDR_SIZE = 12; // virtio_net_hdr_v1

        private const int ST_ACK = 1;
        private const int ST_DRIVER = 2;
        private const int ST_FEATURES_OK = 8;
        private const int ST_DRIVER_OK = 4;
        private const int DESC_F_NEXT = 0x01;
        private const int DESC_F_WRITE = 0x02;

        private static int read_u8 (int addr) {
            return (mmio_read32 (addr & ~3) >> ((addr & 3) * 8)) & 0xFF;
        }

        private static int read_u16 (int addr) {
            return (mmio_read32 (addr & ~3) >> ((addr & 2) * 8)) & 0xFFFF;
        }

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

        public static bool is_present () { return net_found != 0; }
        public static int irq_count () { return net_irqs; }

        public static int mac_byte (int idx) {
            if (idx < 0 || idx >= 6)
                return 0;
            if (idx < 4)
                return (net_mac_lo >> (idx * 8)) & 0xFF;
            return (net_mac_hi >> ((idx - 4) * 8)) & 0xFF;
        }

        private static void zero_page (int page) {
            int i = 0;
            while (i < 4096) {
                mmio_write32 (page + i, 0);
                i = i + 4;
            }
        }

        public static bool init () {
            int found_dev = -1;
            for (int dev = 0; dev < 32; dev++) {
                int id = pci_cfg_read32 (cfg_addr (dev, 0));
                int vendor = id & 0xFFFF;
                int device = (id >> 16) & 0xFFFF;
                if (vendor == VENDOR_VIRTIO) {
                    if (device == DEV_NET_MODERN) {
                        found_dev = dev;
                        break;
                    }
                    if (device == DEV_NET_LEGACY)
                        found_dev = dev;
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
            int msix_cap = 0;
            while (cap_ptr != 0) {
                int cap_id = cfg_read8 (found_dev, cap_ptr);
                int next_ptr = cfg_read8 (found_dev, cap_ptr + 1) & 0xFC;
                if (cap_id == 0x11)
                    msix_cap = cap_ptr;
                if (cap_id == 0x09) {
                    int cfg_type = cfg_read8 (found_dev, cap_ptr + 3);
                    int bar = cfg_read8 (found_dev, cap_ptr + 4);
                    int off = pci_cfg_read32 (cfg_addr (found_dev, cap_ptr + 8));
                    int bar_addr = read_bar_addr (found_dev, bar);
                    if (bar_addr != 0) {
                        Vmm.map_mmio_2m (bar_addr + off);
                        if (cfg_type == 1)
                            net_common_base = bar_addr + off;
                        if (cfg_type == 2) {
                            net_notify_base = bar_addr + off;
                            net_notify_mult = pci_cfg_read32 (cfg_addr (found_dev, cap_ptr + 16));
                        }
                        if (cfg_type == 4)
                            net_dev_base = bar_addr + off;
                    }
                }
                cap_ptr = next_ptr;
            }
            if (net_common_base == 0 || net_notify_base == 0)
                return false;

            if (msix_cap != 0) {
                int tbl = pci_cfg_read32 (cfg_addr (found_dev, msix_cap + 4));
                int bir = tbl & 0x7;
                int tbl_off = tbl & 0xFFFFFFF8;
                int msix_bar = read_bar_addr (found_dev, bir);
                if (msix_bar != 0) {
                    Vmm.map_mmio_2m (msix_bar + tbl_off);
                    int entry = msix_bar + tbl_off;
                    int msg_addr = 0xFEE00000 | (Hal.lapic_id () << 12);
                    mmio_write32 (entry + 0, msg_addr);
                    mmio_write32 (entry + 4, 0);
                    mmio_write32 (entry + 8, NET_VECTOR);
                    mmio_write32 (entry + 12, 0);
                    int ctrl = pci_cfg_read32 (cfg_addr (found_dev, msix_cap));
                    int tsize = (ctrl >> 16) & 0x7FF;
                    ctrl = (ctrl & 0xFFFF) | ((tsize | 0x8000) << 16);
                    pci_cfg_write32 (cfg_addr (found_dev, msix_cap), ctrl);
                    ctrl = pci_cfg_read32 (cfg_addr (found_dev, msix_cap));
                    if ((ctrl & 0x80000000) != 0) {
                        net_msix_ready = 1;
                        int cmd_msix = pci_cfg_read32 (cfg_addr (found_dev, 0x04));
                        pci_cfg_write32 (cfg_addr (found_dev, 0x04), cmd_msix | 0x400);
                    }
                }
            }
            Hal.set_idt_gate_dpl (NET_VECTOR, addr_isr_net (), 0);

            mmio_write8 (net_common_base + 20, 0);
            mmio_write8 (net_common_base + 20, ST_ACK);
            mmio_write8 (net_common_base + 20, ST_ACK | ST_DRIVER);

            mmio_write32 (net_common_base + 0, 0);
            int features_lo = mmio_read32 (net_common_base + 4);
            mmio_write32 (net_common_base + 0, 1);
            int features_hi = mmio_read32 (net_common_base + 4);
            int want_lo = features_lo & 0x20; // VIRTIO_NET_F_MAC
            int want_hi = features_hi & 1;    // VIRTIO_F_VERSION_1
            mmio_write32 (net_common_base + 8, 0);
            mmio_write32 (net_common_base + 12, want_lo);
            mmio_write32 (net_common_base + 8, 1);
            mmio_write32 (net_common_base + 12, want_hi);
            mmio_write8 (net_common_base + 20, ST_ACK | ST_DRIVER | ST_FEATURES_OK);
            int st_chk = read_u8 (net_common_base + 20);
            if ((st_chk & ST_FEATURES_OK) == 0)
                return false;

            net_rx_vq_page = Pmm.alloc_frame ();
            net_tx_vq_page = Pmm.alloc_frame ();
            net_tx_buf_page = Pmm.alloc_frame ();
            net_rx_buf_pages = Pmm.alloc_frame ();
            if (net_rx_vq_page == 0 || net_tx_vq_page == 0
                || net_tx_buf_page == 0 || net_rx_buf_pages == 0)
                return false;
            zero_page (net_rx_vq_page);
            zero_page (net_tx_vq_page);
            zero_page (net_tx_buf_page);

            // Queue 0: RX
            mmio_write16 (net_common_base + 22, 0);
            int max_rx = mmio_read32 (net_common_base + 24) & 0xFFFF;
            if (max_rx > 0 && max_rx < net_rx_qsize)
                net_rx_qsize = max_rx;
            mmio_write16 (net_common_base + 24, net_rx_qsize);
            net_rx_notify_off = mmio_read32 (net_common_base + 30) & 0xFFFF;
            mmio_write64 (net_common_base + 32, net_rx_vq_page);
            mmio_write64 (net_common_base + 40, net_rx_vq_page + 512);
            mmio_write64 (net_common_base + 48, net_rx_vq_page + 1024);
            if (net_msix_ready != 0) {
                mmio_write16 (net_common_base + 16, 0);
                mmio_write16 (net_common_base + 26, 0);
            } else {
                mmio_write16 (net_common_base + 16, 0xFFFF);
                mmio_write16 (net_common_base + 26, 0xFFFF);
            }
            mmio_write16 (net_common_base + 28, 1);

            // Queue 1: TX
            mmio_write16 (net_common_base + 22, 1);
            int max_tx = mmio_read32 (net_common_base + 24) & 0xFFFF;
            if (max_tx > 0 && max_tx < net_tx_qsize)
                net_tx_qsize = max_tx;
            mmio_write16 (net_common_base + 24, net_tx_qsize);
            net_tx_notify_off = mmio_read32 (net_common_base + 30) & 0xFFFF;
            mmio_write64 (net_common_base + 32, net_tx_vq_page);
            mmio_write64 (net_common_base + 40, net_tx_vq_page + 512);
            mmio_write64 (net_common_base + 48, net_tx_vq_page + 1024);
            mmio_write16 (net_common_base + 26, (net_msix_ready != 0) ? 0 : 0xFFFF);
            mmio_write16 (net_common_base + 28, 1);

            mmio_write8 (net_common_base + 20,
                         ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK);

            if (net_dev_base != 0) {
                net_mac_lo = mmio_read32 (net_dev_base);
                net_mac_hi = mmio_read32 (net_dev_base + 4) & 0xFFFF;
            }

            // Pre-populate RX queue descriptors with 2048-byte device-writable buffers.
            int rx_desc = net_rx_vq_page;
            int rx_avail = net_rx_vq_page + 512;
            for (int i = 0; i < net_rx_qsize; i++) {
                int baddr = net_rx_buf_pages + i * 2048;
                mmio_write64 (rx_desc + i * 16 + 0, baddr);
                mmio_write32 (rx_desc + i * 16 + 8, 2048);
                mmio_write16 (rx_desc + i * 16 + 12, DESC_F_WRITE);
                mmio_write16 (rx_desc + i * 16 + 14, 0);
                mmio_write16 (rx_avail + 4 + i * 2, i);
            }
            net_rx_avail_idx = net_rx_qsize;
            mmio_write16 (rx_avail + 2, net_rx_avail_idx & 0xFFFF);
            mmio_write16 (net_notify_base + net_rx_notify_off * net_notify_mult, 0);

            net_found = 1;
            return true;
        }

        public static bool has_rx () {
            if (net_found == 0)
                return false;
            int uidx = read_u16 (net_rx_vq_page + 1026);
            return uidx != net_rx_last_used;
        }

        public static int rx (int buf, int max_len) {
            if (net_found == 0 || buf == 0 || max_len <= 0)
                return 0;
            int rx_used = net_rx_vq_page + 1024;
            int uidx = read_u16 (rx_used + 2);
            if (uidx == net_rx_last_used)
                return 0;
            int slot = net_rx_last_used % net_rx_qsize;
            int elem = rx_used + 4 + slot * 8;
            int did = mmio_read32 (elem + 0);
            int total_len = mmio_read32 (elem + 4);
            net_rx_last_used = (net_rx_last_used + 1) & 0xFFFF;
            if (did < 0 || did >= net_rx_qsize)
                return 0;
            if (total_len > 2048)
                total_len = 2048;

            int frame_len = total_len - HDR_SIZE;
            if (frame_len < 0)
                frame_len = 0;
            int copy_len = (frame_len < max_len) ? frame_len : max_len;
            int src = net_rx_buf_pages + did * 2048 + HDR_SIZE;
            for (int i = 0; i < copy_len; i++)
                mmio_write8 (buf + i, read_u8 (src + i));

            // Re-post buffer to RX avail ring.
            int rx_avail = net_rx_vq_page + 512;
            int aslot = net_rx_avail_idx % net_rx_qsize;
            mmio_write16 (rx_avail + 4 + aslot * 2, did);
            net_rx_avail_idx = (net_rx_avail_idx + 1) & 0xFFFF;
            mmio_write16 (rx_avail + 2, net_rx_avail_idx & 0xFFFF);
            mmio_write16 (net_notify_base + net_rx_notify_off * net_notify_mult, 0);
            return copy_len;
        }

        public static bool tx (int buf, int len) {
            if (net_found == 0 || buf == 0 || len <= 0 || len > 1514)
                return false;
            int tx_desc = net_tx_vq_page;
            int tx_avail = net_tx_vq_page + 512;
            int tx_used = net_tx_vq_page + 1024;

            // Copy payload into identity-mapped TX buffer after 12-byte header.
            for (int i = 0; i < HDR_SIZE; i++)
                mmio_write8 (net_tx_buf_page + i, 0);
            for (int i = 0; i < len; i++)
                mmio_write8 (net_tx_buf_page + HDR_SIZE + i, read_u8 (buf + i));
            mmio_write32 (net_tx_buf_page + 2048, 0);

            mmio_write64 (tx_desc + 0, net_tx_buf_page);
            mmio_write32 (tx_desc + 8, HDR_SIZE + len);
            mmio_write16 (tx_desc + 12, 0);
            mmio_write16 (tx_desc + 14, 0);

            int aslot = net_tx_avail_idx % net_tx_qsize;
            mmio_write16 (tx_avail + 4 + aslot * 2, 0);
            net_tx_avail_idx = (net_tx_avail_idx + 1) & 0xFFFF;
            mmio_write16 (tx_avail + 2, net_tx_avail_idx & 0xFFFF);
            mmio_write16 (net_notify_base + net_tx_notify_off * net_notify_mult, 1);

            int wake_addr = net_tx_buf_page + 2048;
            int deadline = (int) mmio_read64 (KernelLayout.TICK) + 50;
            while (mmio_read32 (wake_addr) == 0 && read_u16 (tx_used + 2) == net_tx_last_used) {
                if ((int) mmio_read64 (KernelLayout.TICK) >= deadline)
                    return false;
                Sched.block_on (wake_addr, deadline);
                cpu_sti ();
                cpu_hlt ();
                Sched.unblock_self ();
            }
            net_tx_last_used = read_u16 (tx_used + 2);
            return true;
        }

        public static void irq_handler () {
            net_irqs = net_irqs + 1;
            if (net_found == 0 || net_tx_vq_page == 0 || net_tx_buf_page == 0)
                return;
            int tx_used = net_tx_vq_page + 1024;
            if (read_u16 (tx_used + 2) != net_tx_last_used) {
                int wake_addr = net_tx_buf_page + 2048;
                mmio_write32 (wake_addr, 1);
                Sched.wake_word (wake_addr, 1);
            }
        }
    }
}
