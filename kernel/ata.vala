// Primary ATA PIO LBA28 disk driver (ports 0x1F0..0x1F7).

namespace Planet.Kernel {

    [AsmBody(@"
        mov %edi, %edx
        in %dx, %al
        movzbl %al, %eax
        ret
    ")]
    public extern int port_in8 (int port);

    [AsmBody(@"
        mov %edi, %edx
        mov %esi, %eax
        out %al, %dx
        ret
    ")]
    public extern void port_out8 (int port, int val);

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

    public class Ata : Object {
        private const int BASE = 0x1F0;

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

        public static bool read_sector (int lba, int buf_addr) {
            if (!wait_not_bsy ())
                return false;
            port_out8 (BASE + 6, 0xE0 | ((lba >> 24) & 0x0F));
            port_out8 (BASE + 2, 1);
            port_out8 (BASE + 3, lba & 0xFF);
            port_out8 (BASE + 4, (lba >> 8) & 0xFF);
            port_out8 (BASE + 5, (lba >> 16) & 0xFF);
            port_out8 (BASE + 7, 0x20);
            if (!wait_drq ())
                return false;
            ata_read_words (buf_addr, 256);
            return true;
        }

        public static bool write_sector (int lba, int buf_addr) {
            if (!wait_not_bsy ())
                return false;
            port_out8 (BASE + 6, 0xE0 | ((lba >> 24) & 0x0F));
            port_out8 (BASE + 2, 1);
            port_out8 (BASE + 3, lba & 0xFF);
            port_out8 (BASE + 4, (lba >> 8) & 0xFF);
            port_out8 (BASE + 5, (lba >> 16) & 0xFF);
            port_out8 (BASE + 7, 0x30);
            if (!wait_drq ())
                return false;
            ata_write_words (buf_addr, 256);
            port_out8 (BASE + 7, 0xE7); // CACHE FLUSH
            wait_not_bsy ();
            return true;
        }
    }
}
