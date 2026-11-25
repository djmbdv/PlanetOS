// VirtIO-BLK PCI driver (Modern VirtIO 1.0 MMIO transport, queue 0).
// C2: the block path is IRQ-driven. A request is a 16-byte header, the data
// buffer and a status byte published on the avail ring; the device sends its
// MSI-X message for queue 0, the handler drains the used ring, publishes the
// completion word and wakes the waiting task, so no caller spins on the
// hardware.

namespace Planet.Kernel {

    [AsmBody(@"
        # VirtIO-BLK IRQ: save the caller-saved set, call the handler, EOI, return.
        cld
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
        call virtio_blk_irq_entry
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
    public extern void isr_blk ();

    [AsmBody(@"
        lea isr_blk(%rip), %rax
        ret
    ")]
    public extern int addr_isr_blk ();

    public static void virtio_blk_irq_entry () {
        VirtioBlk.irq_handler ();
        Hal.lapic_eoi ();
    }

    public sealed class VirtioBlk : Object {
        private static int blk_found = 0;
        private static int blk_common_base = 0;
        private static int blk_notify_base = 0;
        private static int blk_notify_mult = 0;
        private static int blk_dev_base = 0;
        // One page holds desc (512) + avail (512..1023) + used (1024..2047).
        private static int blk_vq_page = 0;
        // Request header at +0, status byte at +16, completion word at +20.
        private static int blk_req_page = 0;
        private static int blk_qsize = 8;
        private static int blk_q_notify_off = 0;
        private static int blk_avail_idx = 0;
        private static int blk_last_used = 0;
        private static int blk_irqs = 0;
        private static int blk_irq_wakes = 0;
        private static int blk_irq_late = 0;
        private static int blk_issue_tick = 0;
        private static int blk_status = 0;
        private static int blk_capacity = 0;
        private static int blk_irq_line = 255;
        private static int blk_msix_ready = 0;
        private const int BLK_VECTOR = 64;

        private const int VENDOR_VIRTIO = 0x1AF4;
        private const int DEV_BLK_MODERN = 0x1042;
        private const int DEV_BLK_LEGACY = 0x1001;

        private const int ST_ACK = 1;
        private const int ST_DRIVER = 2;
        private const int ST_FEATURES_OK = 8;
        private const int ST_DRIVER_OK = 4;

        private const int BLK_T_IN = 0;
        private const int DESC_F_NEXT = 0x01;
        private const int DESC_F_WRITE = 0x02;

        // --- 8259 helpers ---------------------------------------------------
        private static void pic_unmask (int irq) {
            if (irq < 8) {
                int mask = port_in8 (0x21);
                port_out8 (0x21, mask & ~(1 << irq));
            } else {
                int mask = port_in8 (0xA1);
                port_out8 (0xA1, mask & ~(1 << (irq - 8)));
                int mmask = port_in8 (0x21);
                port_out8 (0x21, mmask & ~(1 << 2));
            }
        }

        // --- PCI ------------------------------------------------------------
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

        public static bool is_present () { return blk_found != 0; }
        public static int capacity_sectors () { return blk_capacity; }
        public static int irq_count () { return blk_irqs; }
        public static int irq_wakes () { return blk_irq_wakes; }
        public static int irq_late () { return blk_irq_late; }

        public static bool init () {
            int found_dev = -1;
            int dev_id = 0;
            for (int dev = 0; dev < 32; dev++) {
                int id = pci_cfg_read32 (cfg_addr (dev, 0));
                int vendor = id & 0xFFFF;
                int device = (id >> 16) & 0xFFFF;
                if (vendor == VENDOR_VIRTIO) {
                    if (device == DEV_BLK_MODERN) {
                        found_dev = dev;
                        dev_id = device;
                        break;
                    }
                    if (device == DEV_BLK_LEGACY) {
                        found_dev = dev;
                        dev_id = device;
                    }
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
                            blk_common_base = bar_addr + off;
                        if (cfg_type == 2) {
                            blk_notify_base = bar_addr + off;
                            blk_notify_mult = pci_cfg_read32 (cfg_addr (found_dev, cap_ptr + 16));
                        }
                        if (cfg_type == 4)
                            blk_dev_base = bar_addr + off;
                    }
                }
                cap_ptr = next_ptr;
            }
            if (blk_common_base == 0)
                return false;
            if (blk_notify_base == 0)
                return false;

            blk_irq_line = cfg_read8 (found_dev, 0x3F);
            if (blk_irq_line > 15)
                blk_irq_line = 11;

            // MSI-X: point table entry 0 at this LAPIC and enable the capability.
            // Table offset/BIR share one dword (bits 2:0 are the BAR, the rest
            // the offset); the PBA has its own at +8.
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
                    mmio_write32 (entry + 8, BLK_VECTOR);
                    // Vector control: bit 0 masks this entry, so 0 leaves it live.
                    mmio_write32 (entry + 12, 0);
                    // Message Control sits in bytes 2..3 of the capability dword:
                    // bit 15 enables MSI-X, bit 14 masks the whole function, and
                    // bits 10:0 carry the table size (read-only).
                    int ctrl = pci_cfg_read32 (cfg_addr (found_dev, msix_cap));
                    int tsize = (ctrl >> 16) & 0x7FF;
                    ctrl = (ctrl & 0xFFFF) | ((tsize | 0x8000) << 16);
                    pci_cfg_write32 (cfg_addr (found_dev, msix_cap), ctrl);
                    ctrl = pci_cfg_read32 (cfg_addr (found_dev, msix_cap));
                    if ((ctrl & 0x80000000) != 0) {
                        blk_msix_ready = 1;
                        // A function that delivers MSI-X must not also drive INTx.
                        int cmd_msix = pci_cfg_read32 (cfg_addr (found_dev, 0x04));
                        pci_cfg_write32 (cfg_addr (found_dev, 0x04), cmd_msix | 0x400);
                    }
                }
            }
            Hal.set_idt_gate_dpl (BLK_VECTOR, addr_isr_blk (), 0);

            mmio_write8 (blk_common_base + 20, 0);
            mmio_write8 (blk_common_base + 20, ST_ACK);
            mmio_write8 (blk_common_base + 20, ST_ACK | ST_DRIVER);

            mmio_write32 (blk_common_base + 0, 0);
            int features_lo = mmio_read32 (blk_common_base + 4);
            mmio_write32 (blk_common_base + 0, 1);
            int features_hi = mmio_read32 (blk_common_base + 4);
            int want_hi = features_hi & 1; // VIRTIO_F_VERSION_1
            mmio_write32 (blk_common_base + 8, 0);
            mmio_write32 (blk_common_base + 12, 0);
            mmio_write32 (blk_common_base + 8, 1);
            mmio_write32 (blk_common_base + 12, want_hi);
            mmio_write8 (blk_common_base + 20, ST_ACK | ST_DRIVER | ST_FEATURES_OK);
            int st_chk = read_u8 (blk_common_base + 20);
            if ((st_chk & ST_FEATURES_OK) == 0)
                return false;

            blk_vq_page = Pmm.alloc_frame ();
            blk_req_page = Pmm.alloc_frame ();
            if (blk_vq_page == 0 || blk_req_page == 0)
                return false;
            // Clear the queue page so avail/used start from zero.
            int i = 0;
            while (i < 4096) {
                mmio_write32 (blk_vq_page + i, 0);
                i = i + 4;
            }

            mmio_write16 (blk_common_base + 22, 0);
            int max_q = mmio_read32 (blk_common_base + 24) & 0xFFFF;
            if (max_q > 0) {
                if (max_q < blk_qsize)
                    blk_qsize = max_q;
            }
            mmio_write16 (blk_common_base + 24, blk_qsize);
            blk_q_notify_off = mmio_read32 (blk_common_base + 30) & 0xFFFF;
            mmio_write64 (blk_common_base + 32, blk_vq_page);
            mmio_write64 (blk_common_base + 40, blk_vq_page + 512);
            mmio_write64 (blk_common_base + 48, blk_vq_page + 1024);
            // MSI-X: config and queue 0 use table entry 0 (0xFFFF = none).
            if (blk_msix_ready != 0) {
                mmio_write16 (blk_common_base + 16, 0);
                mmio_write16 (blk_common_base + 26, 0);
            } else {
                mmio_write16 (blk_common_base + 16, 0xFFFF);
                mmio_write16 (blk_common_base + 26, 0xFFFF);
            }
            mmio_write16 (blk_common_base + 28, 1);

            mmio_write8 (blk_common_base + 20,
                         ST_ACK | ST_DRIVER | ST_FEATURES_OK | ST_DRIVER_OK);

            if (blk_dev_base != 0) {
                int cap_lo = mmio_read32 (blk_dev_base);
                int cap_hi = mmio_read32 (blk_dev_base + 4);
                if (cap_hi == 0)
                    blk_capacity = cap_lo;
                else
                    blk_capacity = 0x7FFFFFFF;
            }

            // Only the legacy fallback needs the 8259 line; with MSI-X enabled
            // INTx is disabled and the line stays quiet.
            if (blk_msix_ready == 0)
                pic_unmask (blk_irq_line);

            blk_found = 1;
            return true;
        }

        // --- request path ---------------------------------------------------
        private static void issue_read (int lba, int buf, int count) {
            int desc = blk_vq_page;
            int avail = blk_vq_page + 512;
            int used = blk_vq_page + 1024;
            int req = blk_req_page;
            blk_issue_tick = (int) mmio_read64 (KernelLayout.TICK);

            mmio_write32 (req + 0, BLK_T_IN);   // type
            mmio_write32 (req + 4, 0);          // reserved
            mmio_write64 (req + 8, lba);        // sector
            mmio_write8 (req + 16, 0xFF);       // status: not written yet
            mmio_write32 (req + 20, 0);         // completion word

            // Descriptor 0: header, descriptor 1: data, descriptor 2: status.
            mmio_write64 (desc + 0, req);
            mmio_write32 (desc + 8, 16);
            mmio_write16 (desc + 12, DESC_F_NEXT);
            mmio_write16 (desc + 14, 1);

            mmio_write64 (desc + 16, buf);
            mmio_write32 (desc + 24, count * 512);
            mmio_write16 (desc + 28, DESC_F_NEXT | DESC_F_WRITE);
            mmio_write16 (desc + 30, 2);

            mmio_write64 (desc + 32, req + 16);
            mmio_write32 (desc + 40, 1);
            mmio_write16 (desc + 44, DESC_F_WRITE);
            mmio_write16 (desc + 46, 0);

            int slot = blk_avail_idx % blk_qsize;
            mmio_write16 (avail + 4 + slot * 2, 0);
            blk_avail_idx = blk_avail_idx + 1;
            mmio_write16 (avail + 2, blk_avail_idx & 0xFFFF);

            mmio_write16 (blk_notify_base + blk_q_notify_off * blk_notify_mult, 0);
            // The used ring lives at `used`; keep the reference explicit.
        }

        // Waits for completion. The device publishes it through the MSI-X
        // message, whose handler sets `word`; the parked timer is only a
        // watchdog for a device that never signals. The used ring is read on a
        // watchdog expiry alone, never on a spurious wake, so a slow interrupt
        // can only lose the race to a one-second timeout and no caller ever
        // spins on the hardware (IO-06).
        private static bool await_completion (int deadline) {
            int addr = blk_req_page + 20;
            int used = blk_vq_page + 1024;
            while (true) {
                if (mmio_read32 (addr) != 0)
                    return true;
                int slice = (int) mmio_read64 (KernelLayout.TICK) + 100;
                Sched.block_on (addr, slice);
                cpu_sti ();
                cpu_hlt ();
                Sched.unblock_self ();
                if (mmio_read32 (addr) != 0)
                    return true;
                if ((int) mmio_read64 (KernelLayout.TICK) < slice)
                    continue;
                int uidx = read_u16 (used + 2);
                if (uidx != blk_last_used) {
                    blk_last_used = uidx;
                    blk_status = read_u8 (blk_req_page + 16);
                    mmio_write32 (addr, 1);
                    return true;
                }
                if (deadline != 0 && (int) mmio_read64 (KernelLayout.TICK) >= deadline)
                    return false;
            }
        }

        public static bool read (int lba, int buf, int count) {
            if (blk_found == 0 || buf == 0 || count <= 0)
                return false;
            int deadline = (int) mmio_read64 (KernelLayout.TICK) + 200; // 2 s
            issue_read (lba, buf, count);
            if (!await_completion (deadline)) {
                int dstat = read_u8 (blk_common_base + 20);
                int uidx = read_u16 (blk_vq_page + 1026);
                print (@"blk:timeout dstat=$dstat uidx=$uidx aidx=$blk_avail_idx qs=$blk_qsize noff=$blk_q_notify_off nmult=$blk_notify_mult\n");
                return false;
            }
            if (blk_status != 0) {
                print (@"blk:status=$blk_status used=$(read_u16 (blk_vq_page + 1026))\n");
                return false;
            }
            return true;
        }

        // Called from the IRQ stub: drain the used ring and wake the waiter.
        public static void irq_handler () {
            blk_irqs = blk_irqs + 1;
            if (blk_found == 0)
                return;
            int used = blk_vq_page + 1024;
            int used_idx = read_u16 (used + 2);
            if (used_idx == blk_last_used) {
                // The waiter already took this completion through the watchdog,
                // so this interrupt has nothing to wake. `now - issue` is the
                // delivery delay in ticks: that number is the only way to tell a
                // slow host from a message that never came.
                blk_irq_late = blk_irq_late + 1;
                int late_now = (int) mmio_read64 (KernelLayout.TICK) - blk_issue_tick;
                print (@"blk:lateirq delay=$late_now\n");
                return;
            }
            blk_last_used = used_idx;
            blk_status = read_u8 (blk_req_page + 16);
            blk_irq_wakes = blk_irq_wakes + 1;
            mmio_write32 (blk_req_page + 20, 1);
            Sched.wake_word (blk_req_page + 20, 1);
        }

        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        private static int read_u16 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 2) * 8)) & 0xFFFF;
        }
    }
}
