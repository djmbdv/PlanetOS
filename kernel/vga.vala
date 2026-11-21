// VGA 80x25 color text mode console driver (0xB8000).

namespace Planet.Kernel {

    [AsmBody(@"
        # vga_hw_cursor(pos in rdi)
        mov %rdi, %rcx
        mov $0x3D4, %dx
        mov $0x0F, %al
        out %al, %dx
        mov $0x3D5, %dx
        mov %cl, %al
        out %al, %dx
        mov $0x3D4, %dx
        mov $0x0E, %al
        out %al, %dx
        mov $0x3D5, %dx
        mov %ch, %al
        out %al, %dx
        ret
    ")]
    public extern void vga_hw_cursor (int pos);

    public sealed class Vga : Object {
        private static int vga_row = 0;
        private static int vga_col = 0;
        private static int vga_ready = 0;
        private static int vga_attr = 0x07;
        private static int vga_esc = 0;
        private static int vga_esc_val = 0;
        private static int vga_esc_p0 = 0;
        private static bool vga_esc_has_p0 = false;
        private static int vga_utf8_cp = 0;
        private static int vga_utf8_rem = 0;
        private const int VGA_BASE = 0xB8000;
        private const int COLS = 80;
        private const int ROWS = 25;
        private const int ATTR = 0x07; // light gray on black

        private static void update_cursor () {
            vga_hw_cursor (vga_row * COLS + vga_col);
        }

        private static void clear () {
            int blank = (0x07 << 8) | ' ';
            for (int i = 0; i < ROWS * COLS; i++) {
                mmio_write16 (VGA_BASE + i * 2, blank);
            }
            vga_row = 0;
            vga_col = 0;
            vga_attr = 0x07;
            vga_esc = 0;
            update_cursor ();
        }

        public static void init () {
            clear ();
            vga_ready = 1;
            if (VirtioGpu.is_present ())
                VirtioGpu.init_console (vga_row, vga_col);
        }

        public static void activate_virtio_console () {
            if (VirtioGpu.is_present ())
                VirtioGpu.init_console (vga_row, vga_col);
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
            if (VirtioGpu.is_console_active ())
                VirtioGpu.console_redraw_all (vga_row, vga_col);
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
            if (cp == 0x2022) return 0x07; // •
            return '?';
        }

        private static void apply_sgr (int code) {
            if (code == 0) vga_attr = 0x07;
            else if (code == 1) vga_attr = vga_attr | 0x08;
            else if (code == 30) vga_attr = 0x00;
            else if (code == 31) vga_attr = 0x04;
            else if (code == 32) vga_attr = 0x02;
            else if (code == 33) vga_attr = 0x06;
            else if (code == 34) vga_attr = 0x01;
            else if (code == 35) vga_attr = 0x05;
            else if (code == 36) vga_attr = 0x03;
            else if (code == 37) vga_attr = 0x07;
            else if (code == 7) vga_attr = 0x70;
            else if (code == 90) vga_attr = 0x08;
            else if (code == 91) vga_attr = 0x0C;
            else if (code == 92) vga_attr = 0x0A;
            else if (code == 93) vga_attr = 0x0E;
            else if (code == 94) vga_attr = 0x09;
            else if (code == 95) vga_attr = 0x0D;
            else if (code == 96) vga_attr = 0x0B;
            else if (code == 97) vga_attr = 0x0F;
        }

        private static void put_glyph (int glyph) {
            int r0 = vga_row;
            int c0 = vga_col;
            mmio_write16 (VGA_BASE + (r0 * COLS + c0) * 2, (vga_attr << 8) | (glyph & 0xFF));
            vga_col = vga_col + 1;
            if (vga_col >= COLS) {
                vga_col = 0;
                vga_row = vga_row + 1;
            }
            if (vga_row >= ROWS) {
                scroll_up ();
            } else if (VirtioGpu.is_console_active ()) {
                VirtioGpu.console_flush_cell (r0, c0, vga_row, vga_col, (glyph == '>'));
            }
            update_cursor ();
        }

        public static void write_byte (int ch) {
            if (vga_ready == 0)
                return;
            int b = ch & 0xFF;
            if (vga_esc == 1) {
                vga_esc = (b == '[') ? 2 : 0;
                vga_esc_val = 0;
                vga_esc_p0 = 0;
                vga_esc_has_p0 = false;
                return;
            }
            if (vga_esc == 2) {
                if (b >= '0' && b <= '9') {
                    vga_esc_val = vga_esc_val * 10 + (b - '0');
                } else {
                    switch (b) {
                        case ';':
                            vga_esc_p0 = vga_esc_val;
                            vga_esc_has_p0 = true;
                            vga_esc_val = 0;
                            break;
                        case 'm':
                            if (vga_esc_has_p0)
                                apply_sgr (vga_esc_p0);
                            apply_sgr (vga_esc_val);
                            vga_esc = 0;
                            break;
                        case 'J':
                            if (vga_esc_val == 2) {
                                clear ();
                                if (VirtioGpu.is_console_active ())
                                    VirtioGpu.console_redraw_all (vga_row, vga_col);
                            }
                            vga_esc = 0;
                            break;
                        case 'H', 'f':
                            int r = vga_esc_has_p0 ? ((vga_esc_p0 > 0) ? vga_esc_p0 - 1 : 0) : 0;
                            int c = (vga_esc_val > 0) ? vga_esc_val - 1 : 0;
                            if (r >= ROWS) r = ROWS - 1;
                            if (c >= COLS) c = COLS - 1;
                            vga_row = r;
                            vga_col = c;
                            update_cursor ();
                            if (VirtioGpu.is_console_active ())
                                VirtioGpu.console_flush_cell (-1, -1, vga_row, vga_col, true);
                            vga_esc = 0;
                            break;
                        case 'K':
                            int blank = (vga_attr << 8) | ' ';
                            for (int c = vga_col; c < COLS; c++)
                                mmio_write16 (VGA_BASE + (vga_row * COLS + c) * 2, blank);
                            if (VirtioGpu.is_console_active ())
                                VirtioGpu.console_flush_cell (vga_row, vga_col, vga_row, COLS - 1, true);
                            vga_esc = 0;
                            break;
                        default:
                            vga_esc = 0;
                            break;
                    }
                }
                return;
            }
            if (b == 27) {
                vga_esc = 1;
                return;
            }
            if (b < 0x80) {
                vga_utf8_rem = 0;
                if (b == '\n') {
                    vga_col = 0;
                    vga_row = vga_row + 1;
                } else if (b == '\r') {
                    vga_col = 0;
                } else if (b == '\t') {
                    int next_col = (vga_col + 4) & ~3;
                    if (next_col > COLS)
                        next_col = COLS;
                    while (vga_col < next_col)
                        put_glyph (' ');
                    return;
                } else if (b == 8) {
                    if (vga_col > 0) {
                        vga_col = vga_col - 1;
                        mmio_write16 (VGA_BASE + (vga_row * COLS + vga_col) * 2, (ATTR << 8) | ' ');
                        if (VirtioGpu.is_console_active ())
                            VirtioGpu.console_flush_cell (vga_row, vga_col, vga_row, vga_col, true);
                    }
                } else {
                    put_glyph (b);
                    return;
                }
                if (vga_row >= ROWS)
                    scroll_up ();
                else if (VirtioGpu.is_console_active ())
                    VirtioGpu.console_flush_cell (-1, -1, vga_row, vga_col, (b == '\n' || b == '\r'));
                update_cursor ();
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
