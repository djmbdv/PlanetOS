// Primary ATA PIO LBA28 disk driver (ports 0x1F0..0x1F7).

namespace Planet.Kernel {

    [AsmBody(@"
        # ata_read_words(buf_addr in rdi, count in rsi) from port 0x1F0
        mov $0x1F0, %dx
        xor %rcx, %rcx
    _arw_loop:
        cmp %rsi, %rcx
        jge _arw_done
        in %dx, %ax
        mov %ax, (%rdi,%rcx,2)
        inc %rcx
        jmp _arw_loop
    _arw_done:
        ret
    ")]
    public extern void ata_read_words (int buf_addr, int count);

    [AsmBody(@"
        # ata_write_words(buf_addr in rdi, count in rsi) to port 0x1F0
        mov $0x1F0, %dx
        xor %rcx, %rcx
    _aww_loop:
        cmp %rsi, %rcx
        jge _aww_done
        mov (%rdi,%rcx,2), %ax
        out %ax, %dx
        inc %rcx
        jmp _aww_loop
    _aww_done:
        ret
    ")]
    public extern void ata_write_words (int buf_addr, int count);

    private int ata_present = 0;
    private int ata_sectors = 0;
    private int ata_lba48 = 0;

    public class Ata : Object {
        private const int BASE = 0x1F0;
        private const int CTRL = 0x3F6;

        public static void reset () {
            port_out8 (CTRL, 0x04); // SRST
            for (int i = 0; i < 4; i++)
                port_in8 (CTRL);
            port_out8 (CTRL, 0x00);
            for (int i = 0; i < 4; i++)
                port_in8 (CTRL);
            wait_not_bsy ();
        }

        public static bool init () {
            int buf = Pmm.alloc_frame ();
            if (buf == 0)
                return false;
            bool ok = identify (buf);
            if (!ok) {
                reset ();
                ok = identify (buf);
            }
            if (ok) {
                ata_present = 1;
                int w83 = (mmio_read32 (buf + 82 * 2) >> 16) & 0xFFFF;
                if ((w83 & 0x0400) != 0) {
                    ata_lba48 = 1;
                    int lo = mmio_read32 (buf + 100 * 2) & 0xFFFFFFFF;
                    int hi = mmio_read32 (buf + 102 * 2) & 0xFFFFFFFF;
                    ata_sectors = (hi << 32) | lo;
                } else {
                    ata_lba48 = 0;
                    ata_sectors = mmio_read32 (buf + 60 * 2) & 0xFFFFFFFF;
                }
            }
            Pmm.free_frame (buf);
            return ok;
        }

        public static int total_sectors () {
            return ata_sectors;
        }

        public static bool has_lba48 () {
            return ata_lba48 != 0;
        }

        public static bool is_present () {
            return ata_present != 0;
        }

        private static bool wait_not_bsy () {
            for (int i = 0; i < 100000; i++) {
                int st = port_in8 (BASE + 7);
                if (st == 0xFF)
                    return false;
                if ((st & 0x80) == 0)
                    return true;
            }
            return false;
        }

        private static bool wait_drq () {
            for (int i = 0; i < 100000; i++) {
                int st = port_in8 (BASE + 7);
                if ((st & 0x01) != 0)
                    return false;
                if ((st & 0x80) == 0 && (st & 0x08) != 0)
                    return true;
            }
            return false;
        }

        public static bool identify (int buf_addr) {
            port_out8 (BASE + 6, 0xA0);
            port_out8 (BASE + 2, 0);
            port_out8 (BASE + 3, 0);
            port_out8 (BASE + 4, 0);
            port_out8 (BASE + 5, 0);
            port_out8 (BASE + 7, 0xEC);
            int st = port_in8 (BASE + 7);
            if (st == 0 || st == 0xFF)
                return false;
            if (!wait_drq ())
                return false;
            ata_read_words (buf_addr, 256);
            return true;
        }

        public static bool flush_cache () {
            if (!wait_not_bsy ())
                return false;
            port_out8 (BASE + 6, 0xE0);
            port_out8 (BASE + 7, (ata_lba48 != 0) ? 0xEA : 0xE7);
            return wait_not_bsy ();
        }

        public static bool read_sectors (int lba, int count, int buf_addr) {
            int rem = count;
            int cur_lba = lba;
            int cur_buf = buf_addr;
            while (rem > 0) {
                int chunk = (rem > 128) ? 128 : rem;
                if (!wait_not_bsy ())
                    return false;
                if (ata_lba48 != 0 && cur_lba >= 0x10000000) {
                    port_out8 (BASE + 6, 0x40);
                    port_out8 (BASE + 2, (chunk >> 8) & 0xFF);
                    port_out8 (BASE + 3, (cur_lba >> 24) & 0xFF);
                    port_out8 (BASE + 4, (cur_lba >> 32) & 0xFF);
                    port_out8 (BASE + 5, (cur_lba >> 40) & 0xFF);
                    port_out8 (BASE + 2, chunk & 0xFF);
                    port_out8 (BASE + 3, cur_lba & 0xFF);
                    port_out8 (BASE + 4, (cur_lba >> 8) & 0xFF);
                    port_out8 (BASE + 5, (cur_lba >> 16) & 0xFF);
                    port_out8 (BASE + 7, 0x24); // READ SECTORS EXT
                } else {
                    port_out8 (BASE + 6, 0xE0 | ((cur_lba >> 24) & 0x0F));
                    port_out8 (BASE + 2, chunk & 0xFF);
                    port_out8 (BASE + 3, cur_lba & 0xFF);
                    port_out8 (BASE + 4, (cur_lba >> 8) & 0xFF);
                    port_out8 (BASE + 5, (cur_lba >> 16) & 0xFF);
                    port_out8 (BASE + 7, 0x20); // READ SECTORS
                }
                for (int s = 0; s < chunk; s++) {
                    if (!wait_drq ())
                        return false;
                    ata_read_words (cur_buf, 256);
                    cur_buf += 512;
                }
                cur_lba += chunk;
                rem -= chunk;
            }
            return true;
        }

        public static bool write_sectors (int lba, int count, int buf_addr) {
            int rem = count;
            int cur_lba = lba;
            int cur_buf = buf_addr;
            while (rem > 0) {
                int chunk = (rem > 128) ? 128 : rem;
                if (!wait_not_bsy ())
                    return false;
                if (ata_lba48 != 0 && cur_lba >= 0x10000000) {
                    port_out8 (BASE + 6, 0x40);
                    port_out8 (BASE + 2, (chunk >> 8) & 0xFF);
                    port_out8 (BASE + 3, (cur_lba >> 24) & 0xFF);
                    port_out8 (BASE + 4, (cur_lba >> 32) & 0xFF);
                    port_out8 (BASE + 5, (cur_lba >> 40) & 0xFF);
                    port_out8 (BASE + 2, chunk & 0xFF);
                    port_out8 (BASE + 3, cur_lba & 0xFF);
                    port_out8 (BASE + 4, (cur_lba >> 8) & 0xFF);
                    port_out8 (BASE + 5, (cur_lba >> 16) & 0xFF);
                    port_out8 (BASE + 7, 0x34); // WRITE SECTORS EXT
                } else {
                    port_out8 (BASE + 6, 0xE0 | ((cur_lba >> 24) & 0x0F));
                    port_out8 (BASE + 2, chunk & 0xFF);
                    port_out8 (BASE + 3, cur_lba & 0xFF);
                    port_out8 (BASE + 4, (cur_lba >> 8) & 0xFF);
                    port_out8 (BASE + 5, (cur_lba >> 16) & 0xFF);
                    port_out8 (BASE + 7, 0x30); // WRITE SECTORS
                }
                for (int s = 0; s < chunk; s++) {
                    if (!wait_drq ())
                        return false;
                    ata_write_words (cur_buf, 256);
                    cur_buf += 512;
                }
                cur_lba += chunk;
                rem -= chunk;
            }
            return flush_cache ();
        }

        public static bool read_sector (int lba, int buf_addr) {
            return read_sectors (lba, 1, buf_addr);
        }

        public static bool write_sector (int lba, int buf_addr) {
            return write_sectors (lba, 1, buf_addr);
        }
    }
}
