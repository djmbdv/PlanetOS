// VGA 80x25 color text mode console driver (0xB8000).

namespace Planet.Kernel {

    private int vga_row = 0;
    private int vga_col = 0;
    private int vga_ready = 0;
    private int vga_utf8_cp = 0;
    private int vga_utf8_rem = 0;

    public class Vga : Object {
        private const int VGA_BASE = 0xB8000;
        private const int COLS = 80;
        private const int ROWS = 25;
        private const int ATTR = 0x07; // light gray on black

        private static void clear () {
            int blank = (ATTR << 8) | ' ';
            for (int i = 0; i < ROWS * COLS; i++) {
                mmio_write16 (VGA_BASE + i * 2, blank);
            }
            vga_row = 0;
            vga_col = 0;
        }

        public static void init () {
            clear ();
            vga_ready = 1;
        }

        private static void scroll_up () {
            for (int r = 1; r < ROWS; r++) {
                for (int c = 0; c < COLS; c++) {
                    int src = VGA_BASE + (r * COLS + c) * 2;
                    int dst = VGA_BASE + ((r - 1) * COLS + c) * 2;
                    int cell = mmio_read32 (src & ~3);
                    int val = ((src & 2) != 0) ? ((cell >> 16) & 0xFFFF) : (cell & 0xFFFF);
                    mmio_write16 (dst, val);
                }
            }
            int blank = (ATTR << 8) | ' ';
            for (int c = 0; c < COLS; c++) {
                mmio_write16 (VGA_BASE + ((ROWS - 1) * COLS + c) * 2, blank);
            }
            vga_row = ROWS - 1;
        }

        private static int cp437_from_unicode (int cp) {
            if (cp < 0x80) return cp;
            if (cp == 0x00E1) return 0xA0; // á
            if (cp == 0x00E9) return 0x82; // é
            if (cp == 0x00ED) return 0xA1; // í
            if (cp == 0x00F3) return 0xA2; // ó
            if (cp == 0x00FA) return 0xA3; // ú
            if (cp == 0x00F1) return 0xA4; // ñ
            if (cp == 0x00D1) return 0xA5; // Ñ
            if (cp == 0x00FC) return 0x81; // ü
            if (cp == 0x00DC) return 0x9A; // Ü
            if (cp == 0x00BF) return 0xA8; // ¿
            if (cp == 0x00A1) return 0xAD; // ¡
            if (cp == 0x00B0) return 0xF8; // °
            return '?';
        }

        private static void put_glyph (int glyph) {
            mmio_write16 (VGA_BASE + (vga_row * COLS + vga_col) * 2, (ATTR << 8) | (glyph & 0xFF));
            vga_col = vga_col + 1;
            if (vga_col >= COLS) {
                vga_col = 0;
                vga_row = vga_row + 1;
            }
            if (vga_row >= ROWS)
                scroll_up ();
        }

        public static void write_byte (int ch) {
            if (vga_ready == 0)
                return;
            int b = ch & 0xFF;
            if (b < 0x80) {
                vga_utf8_rem = 0;
                if (b == '\n') {
                    vga_col = 0;
                    vga_row = vga_row + 1;
                } else if (b == '\r') {
                    vga_col = 0;
                } else if (b == 8) {
                    if (vga_col > 0) {
                        vga_col = vga_col - 1;
                        mmio_write16 (VGA_BASE + (vga_row * COLS + vga_col) * 2, (ATTR << 8) | ' ');
                    }
                } else {
                    put_glyph (b);
                    return;
                }
                if (vga_row >= ROWS)
                    scroll_up ();
                return;
            }
            if ((b & 0xE0) == 0xC0) {
                vga_utf8_cp = b & 0x1F;
                vga_utf8_rem = 1;
            } else if ((b & 0xF0) == 0xE0) {
                vga_utf8_cp = b & 0x0F;
                vga_utf8_rem = 2;
            } else if ((b & 0xF8) == 0xF0) {
                vga_utf8_cp = b & 0x07;
                vga_utf8_rem = 3;
            } else if ((b & 0xC0) == 0x80 && vga_utf8_rem > 0) {
                vga_utf8_cp = (vga_utf8_cp << 6) | (b & 0x3F);
                vga_utf8_rem = vga_utf8_rem - 1;
                if (vga_utf8_rem == 0)
                    put_glyph (cp437_from_unicode (vga_utf8_cp));
            } else {
                vga_utf8_rem = 0;
                put_glyph ('?');
            }
        }
    }
}
