// VGA 80x25 color text mode console driver (0xB8000).

namespace Planet.Kernel {

    private int vga_row = 0;
    private int vga_col = 0;
    private int vga_ready = 0;

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

        public static void write_byte (int ch) {
            if (vga_ready == 0)
                return;
            int b = ch & 0xFF;
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
                mmio_write16 (VGA_BASE + (vga_row * COLS + vga_col) * 2, (ATTR << 8) | b);
                vga_col = vga_col + 1;
                if (vga_col >= COLS) {
                    vga_col = 0;
                    vga_row = vga_row + 1;
                }
            }
            if (vga_row >= ROWS)
                scroll_up ();
        }
    }
}
