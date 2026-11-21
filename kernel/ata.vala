// Hardened Primary ATA PIO LBA28/LBA48 disk driver (ports 0x1F0..0x1F7).
// Features: rep insw/outsw block transfers, bounds checks, error register
// capture, automatic reset+retry on transient errors, and Klog diagnostics.

namespace Planet.Kernel {

    [AsmBody(@"
        # ata_read_words(buf_addr in rdi, count in rsi) from port 0x1F0 via rep insw
        mov %rsi, %rcx
        test %rcx, %rcx
        jle _arw_done
        mov $0x1F0, %dx
        .byte 0xfc
        .byte 0xf3, 0x66, 0x6d
    _arw_done:
        ret
    ")]
    public extern void ata_read_words (int buf_addr, int count);

    [AsmBody(@"
        # ata_write_words(buf_addr in rdi, count in rsi) to port 0x1F0 via rep outsw
        mov %rsi, %rcx
        test %rcx, %rcx
        jle _aww_done
        mov %rdi, %rsi
        mov $0x1F0, %dx
        .byte 0xfc
        .byte 0xf3, 0x66, 0x6f
    _aww_done:
        ret
    ")]
    public extern void ata_write_words (int buf_addr, int count);

    public sealed class Ata : Object {
        private static int ata_present = 0;
        private static int ata_sectors = 0;
        private static int ata_lba48 = 0;
        private static int ata_last_err = 0;
        private static int ata_retries = 0;
        private const int BASE = 0x1F0;
        private const int CTRL = 0x3F6;
        private const int MAX_RETRIES = 2;

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

        public static int total_sectors () { return ata_sectors; }
        public static bool has_lba48 () { return ata_lba48 != 0; }
        public static bool is_present () { return ata_present != 0; }
        public static int last_error () { return ata_last_err; }
        public static int retry_count () { return ata_retries; }

        private static bool range_ok (int lba, int count, int buf_addr) {
            if (ata_present == 0 || buf_addr == 0 || lba < 0 || count <= 0)
                return false;
            if (ata_sectors > 0 && (lba > ata_sectors || count > ata_sectors - lba))
                return false;
            return true;
        }

        private static bool wait_not_bsy () {
            for (int i = 0; i < 200000; i++) {
                int st = port_in8 (BASE + 7);
                if (st == 0xFF)
                    return false;
                if ((st & 0x80) == 0)
                    return true;
            }
            return false;
        }

        private static bool wait_drq () {
            // 400ns delay via Alternate Status reads (ATA spec)
            for (int d = 0; d < 4; d++)
                port_in8 (CTRL);
            for (int i = 0; i < 200000; i++) {
                int st = port_in8 (BASE + 7);
                if (st == 0xFF)
                    return false;
                if ((st & 0x21) != 0) { // ERR (bit 0) or DF (bit 5)
                    ata_last_err = port_in8 (BASE + 1);
                    return false;
                }
                if ((st & 0x80) == 0 && (st & 0x08) != 0)
                    return true;
            }
            return false;
        }

        public static bool identify (int buf_addr) {
            if (buf_addr == 0)
                return false;
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
            if (ata_present == 0 || !wait_not_bsy ())
                return false;
            port_out8 (BASE + 6, 0xE0);
            port_out8 (BASE + 7, (ata_lba48 != 0) ? 0xEA : 0xE7);
            return wait_not_bsy ();
        }

        private static void issue_rw_cmd (int lba, int chunk, bool is_write) {
            if (ata_lba48 != 0 && lba >= 0x10000000) {
                port_out8 (BASE + 6, 0x40);
                port_out8 (BASE + 2, (chunk >> 8) & 0xFF);
                port_out8 (BASE + 3, (lba >> 24) & 0xFF);
                port_out8 (BASE + 4, (lba >> 32) & 0xFF);
                port_out8 (BASE + 5, (lba >> 40) & 0xFF);
                port_out8 (BASE + 2, chunk & 0xFF);
                port_out8 (BASE + 3, lba & 0xFF);
                port_out8 (BASE + 4, (lba >> 8) & 0xFF);
                port_out8 (BASE + 5, (lba >> 16) & 0xFF);
                port_out8 (BASE + 7, is_write ? 0x34 : 0x24);
            } else {
                port_out8 (BASE + 6, 0xE0 | ((lba >> 24) & 0x0F));
                port_out8 (BASE + 2, chunk & 0xFF);
                port_out8 (BASE + 3, lba & 0xFF);
                port_out8 (BASE + 4, (lba >> 8) & 0xFF);
                port_out8 (BASE + 5, (lba >> 16) & 0xFF);
                port_out8 (BASE + 7, is_write ? 0x30 : 0x20);
            }
        }

        private static bool read_chunk_once (int lba, int chunk, int buf_addr) {
            if (!wait_not_bsy ())
                return false;
            issue_rw_cmd (lba, chunk, false);
            int cur_buf = buf_addr;
            for (int s = 0; s < chunk; s++) {
                if (!wait_drq ())
                    return false;
                ata_read_words (cur_buf, 256);
                cur_buf += 512;
            }
            return true;
        }

        private static bool write_chunk_once (int lba, int chunk, int buf_addr) {
            if (!wait_not_bsy ())
                return false;
            issue_rw_cmd (lba, chunk, true);
            int cur_buf = buf_addr;
            for (int s = 0; s < chunk; s++) {
                if (!wait_drq ())
                    return false;
                ata_write_words (cur_buf, 256);
                cur_buf += 512;
            }
            return true;
        }

        public static bool read_sectors (int lba, int count, int buf_addr) {
            if (!range_ok (lba, count, buf_addr))
                return false;
            int rem = count;
            int cur_lba = lba;
            int cur_buf = buf_addr;
            while (rem > 0) {
                int chunk = (rem > 128) ? 128 : rem;
                bool ok = false;
                for (int attempt = 0; attempt <= MAX_RETRIES; attempt++) {
                    if (read_chunk_once (cur_lba, chunk, cur_buf)) {
                        ok = true;
                        break;
                    }
                    ata_retries++;
                    reset ();
                }
                if (!ok) {
                    Klog.error (Klog.CAT_VFS, @"ata: read_err lba=$cur_lba cnt=$chunk err=$ata_last_err");
                    return false;
                }
                cur_lba += chunk;
                cur_buf += chunk * 512;
                rem -= chunk;
            }
            return true;
        }

        public static bool write_sectors (int lba, int count, int buf_addr) {
            if (!range_ok (lba, count, buf_addr))
                return false;
            int rem = count;
            int cur_lba = lba;
            int cur_buf = buf_addr;
            while (rem > 0) {
                int chunk = (rem > 128) ? 128 : rem;
                bool ok = false;
                for (int attempt = 0; attempt <= MAX_RETRIES; attempt++) {
                    if (write_chunk_once (cur_lba, chunk, cur_buf)) {
                        ok = true;
                        break;
                    }
                    ata_retries++;
                    reset ();
                }
                if (!ok) {
                    Klog.error (Klog.CAT_VFS, @"ata: write_err lba=$cur_lba cnt=$chunk err=$ata_last_err");
                    return false;
                }
                cur_lba += chunk;
                cur_buf += chunk * 512;
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
