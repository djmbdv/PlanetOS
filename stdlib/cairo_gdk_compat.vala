// Pure-Vala Cairo & Gdk compatibility layer for PlanetOS (zero C, zero .vapi).

using Planet;

namespace Cairo {

    [AsmBody(@"
        # __c_fill32(addr in rdi, val in rsi, count in rdx)
        # Rellena 'count' pixeles de 32 bits (ARGB) con 'val' en memoria contigua
        mov %rdx, %rcx
        test %rcx, %rcx
        jz _cf_done
        mov %esi, %eax
    _cf_loop:
        mov %eax, (%rdi)
        add $4, %rdi
        dec %rcx
        jnz _cf_loop
    _cf_done:
        ret
    ")]
    private extern void __c_fill32 (int addr, int val, int count);

    [AsmBody(@"
        # Escribe un pixel ARGB de 32 bits en la direccion 'addr' (rdi)
        mov %esi, (%rdi)
        ret
    ")]
    private extern void __c_poke32 (int addr, int val);

    [AsmBody(@"
        # Lee un pixel ARGB de 32 bits desde la direccion 'addr' (rdi)
        mov (%rdi), %eax
        ret
    ")]
    private extern int __c_peek32 (int addr);

    public enum Format {
        ARGB32,
        RGB24
    }

    public class ImageSurface : Object {
        public int width { get; private set; }
        public int height { get; private set; }
        public int buf_addr { get; private set; }

        public ImageSurface (Format fmt, int w, int h) {
            width = w;
            height = h;
            int bytes = w * h * 4;
            int pages = (bytes + 4095) / 4096;
            buf_addr = Sys.alloc_pages (pages);
        }

        public int get_width () { return width; }
        public int get_height () { return height; }
        public void flush () {}
    }

    public class Context : Object {
        private ImageSurface surf;
        private int src_r = 255;
        private int src_g = 255;
        private int src_b = 255;
        private int src_a = 255;
        private int line_w = 1;

        // Current path state (rect, circle/arc, or line)
        private int path_kind = 0; // 0=none, 1=rect, 2=circle, 3=line
        private int px = 0;
        private int py = 0;
        private int pw = 0;
        private int ph = 0;
        private int cur_x = 0;
        private int cur_y = 0;
        private int font_scale = 2;

        public Context (ImageSurface target) {
            surf = target;
        }

        private static int clamp255 (double v) {
            int iv = (int) (v * 255.0);
            if (iv < 0) return 0;
            if (iv > 255) return 255;
            return iv;
        }

        public void set_source_rgb (double r, double g, double b) {
            src_r = clamp255 (r);
            src_g = clamp255 (g);
            src_b = clamp255 (b);
            src_a = 255;
        }

        public void set_source_rgba (double r, double g, double b, double a) {
            src_r = clamp255 (r);
            src_g = clamp255 (g);
            src_b = clamp255 (b);
            src_a = clamp255 (a);
        }

        public void set_line_width (double w) {
            int iw = (int) w;
            line_w = (iw < 1) ? 1 : iw;
        }

        public void select_font_face (string family, int slant, int weight) {}

        public void set_font_size (double sz) {
            int s = (int) (sz / 8.0);
            font_scale = (s < 1) ? 1 : ((s > 4) ? 4 : s);
        }

        private void put_px (int x, int y) {
            if (x < 0 || y < 0 || x >= surf.width || y >= surf.height)
                return;
            int addr = surf.buf_addr + (y * surf.width + x) * 4;
            if (src_a == 255) {
                int col = (255 << 24) | (src_r << 16) | (src_g << 8) | src_b;
                __c_poke32 (addr, col);
                return;
            }
            if (src_a == 0)
                return;
            int dst = __c_peek32 (addr);
            int dr = (dst >> 16) & 0xFF;
            int dg = (dst >> 8) & 0xFF;
            int db = dst & 0xFF;
            int ia = 255 - src_a;
            int rr = (src_r * src_a + dr * ia) / 255;
            int rg = (src_g * src_a + dg * ia) / 255;
            int rb = (src_b * src_a + db * ia) / 255;
            __c_poke32 (addr, (255 << 24) | (rr << 16) | (rg << 8) | rb);
        }

        public void paint () {
            if (src_a == 255) {
                int col = (255 << 24) | (src_r << 16) | (src_g << 8) | src_b;
                __c_fill32 (surf.buf_addr, col, surf.width * surf.height);
                return;
            }
            for (int y = 0; y < surf.height; y++) {
                for (int x = 0; x < surf.width; x++) {
                    put_px (x, y);
                }
            }
        }

        public void rectangle (double x, double y, double w, double h) {
            path_kind = 1;
            px = (int) x;
            py = (int) y;
            pw = (int) w;
            ph = (int) h;
        }

        public void arc (double xc, double yc, double radius, double a1, double a2) {
            path_kind = 2;
            px = (int) xc;
            py = (int) yc;
            pw = (int) radius;
        }

        public void move_to (double x, double y) {
            cur_x = (int) x;
            cur_y = (int) y;
        }

        public void line_to (double x, double y) {
            path_kind = 3;
            px = cur_x;
            py = cur_y;
            pw = (int) x;
            ph = (int) y;
            cur_x = pw;
            cur_y = ph;
        }

        public void fill () {
            if (path_kind == 1) {
                int x0 = (px < 0) ? 0 : px;
                int y0 = (py < 0) ? 0 : py;
                int x1 = (px + pw > surf.width) ? surf.width : (px + pw);
                int y1 = (py + ph > surf.height) ? surf.height : (py + ph);
                if (src_a == 255 && x1 > x0) {
                    int col = (255 << 24) | (src_r << 16) | (src_g << 8) | src_b;
                    int span = x1 - x0;
                    for (int y = y0; y < y1; y++) {
                        __c_fill32 (surf.buf_addr + (y * surf.width + x0) * 4, col, span);
                    }
                } else {
                    for (int y = y0; y < y1; y++) {
                        for (int x = x0; x < x1; x++) {
                            put_px (x, y);
                        }
                    }
                }
            } else if (path_kind == 2) {
                int r = pw;
                int r2 = r * r;
                for (int dy = -r; dy <= r; dy++) {
                    for (int dx = -r; dx <= r; dx++) {
                        if (dx * dx + dy * dy <= r2)
                            put_px (px + dx, py + dy);
                    }
                }
            }
            path_kind = 0;
        }

        public void stroke () {
            if (path_kind == 1) {
                for (int t = 0; t < line_w; t++) {
                    for (int x = px; x < px + pw; x++) {
                        put_px (x, py + t);
                        put_px (x, py + ph - 1 - t);
                    }
                    for (int y = py; y < py + ph; y++) {
                        put_px (px + t, y);
                        put_px (px + pw - 1 - t, y);
                    }
                }
            } else if (path_kind == 2) {
                int r = pw;
                int r_out = r * r;
                int r_in = (r - line_w) * (r - line_w);
                if (r - line_w < 0) r_in = 0;
                for (int dy = -r; dy <= r; dy++) {
                    for (int dx = -r; dx <= r; dx++) {
                        int d2 = dx * dx + dy * dy;
                        if (d2 <= r_out && d2 >= r_in)
                            put_px (px + dx, py + dy);
                    }
                }
            } else if (path_kind == 3) {
                int x0 = px; int y0 = py;
                int x1 = pw; int y1 = ph;
                int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
                int dy = (y1 > y0) ? (y1 - y0) : (y0 - y1);
                int sx = (x0 < x1) ? 1 : -1;
                int sy = (y0 < y1) ? 1 : -1;
                int err = dx - dy;
                while (true) {
                    for (int ty = 0; ty < line_w; ty++)
                        for (int tx = 0; tx < line_w; tx++)
                            put_px (x0 + tx, y0 + ty);
                    if (x0 == x1 && y0 == y1) break;
                    int e2 = 2 * err;
                    if (e2 > -dy) { err = err - dy; x0 = x0 + sx; }
                    if (e2 < dx)  { err = err + dx; y0 = y0 + sy; }
                }
            }
            path_kind = 0;
        }

        // Compact 5x7 bitmap glyph rows (encoded as 7 rows of 5 bits) for ASCII 32..126
        private static int glyph_row (int ch, int row) {
            if (ch == ' ') return 0;
            if (ch == '!') return (row == 0 || row == 1 || row == 2 || row == 3 || row == 5) ? 4 : 0;
            if (ch == '%') return (row == 1) ? 25 : ((row == 2) ? 2 : ((row == 3) ? 4 : ((row == 4) ? 8 : ((row == 5) ? 19 : 0))));
            if (ch == '.') return (row == 6) ? 4 : 0;
            if (ch == ',') return (row == 5) ? 4 : ((row == 6) ? 8 : 0);
            if (ch == ':') return (row == 2 || row == 5) ? 4 : 0;
            if (ch == '-') return (row == 3) ? 14 : 0;
            if (ch == '+') return (row == 3) ? 14 : ((row >= 1 && row <= 5) ? 4 : 0);
            if (ch == '=') return (row == 2 || row == 4) ? 14 : 0;
            if (ch == '/') return 1 << (row < 5 ? (4 - row) : 0);
            if (ch == '(') return (row == 0 || row == 6) ? 2 : ((row == 1 || row == 5) ? 4 : 8);
            if (ch == ')') return (row == 0 || row == 6) ? 8 : ((row == 1 || row == 5) ? 4 : 2);
            if (ch >= '0' && ch <= '9') {
                if (ch == '0') return (row == 0 || row == 6) ? 14 : 17;
                if (ch == '1') return (row == 0) ? 4 : ((row == 1) ? 12 : ((row == 6) ? 14 : 4));
                if (ch == '2') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 1 : 16);
                if (ch == '3') return (row == 0 || row == 3 || row == 6) ? 14 : 1;
                if (ch == '4') return (row == 3) ? 31 : ((row < 3) ? 17 : 1);
                if (ch == '5') return (row == 0 || row == 3 || row == 6) ? 31 : ((row < 3) ? 16 : 1);
                if (ch == '6') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 16 : 17);
                if (ch == '7') return (row == 0) ? 31 : (1 << (4 - (row / 2)));
                if (ch == '8') return (row == 0 || row == 3 || row == 6) ? 14 : 17;
                if (ch == '9') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 17 : 1);
            }
            int u = (ch >= 'a' && ch <= 'z') ? (ch - 32) : ch;
            if (u == 'A') return (row == 0) ? 14 : ((row == 3) ? 31 : 17);
            if (u == 'B') return (row == 0 || row == 3 || row == 6) ? 30 : 17;
            if (u == 'C') return (row == 0 || row == 6) ? 14 : 16;
            if (u == 'D') return (row == 0 || row == 6) ? 30 : 17;
            if (u == 'E') return (row == 0 || row == 6) ? 31 : ((row == 3) ? 28 : 16);
            if (u == 'F') return (row == 0) ? 31 : ((row == 3) ? 28 : 16);
            if (u == 'G') return (row == 0 || row == 6) ? 14 : ((row == 3) ? 23 : ((row > 3) ? 17 : 16));
            if (u == 'H') return (row == 3) ? 31 : 17;
            if (u == 'I') return (row == 0 || row == 6) ? 14 : 4;
            if (u == 'J') return (row == 6) ? 14 : ((row > 4) ? 17 : 1);
            if (u == 'K') return (row == 3) ? 24 : ((row == 2 || row == 4) ? 20 : 18);
            if (u == 'L') return (row == 6) ? 31 : 16;
            if (u == 'M') return (row == 1) ? 27 : ((row == 2) ? 21 : 17);
            if (u == 'N') return (row == 1) ? 25 : ((row == 2) ? 21 : ((row == 3) ? 19 : 17));
            if (u == 'O') return (row == 0 || row == 6) ? 14 : 17;
            if (u == 'P') return (row == 0 || row == 3) ? 30 : ((row < 3) ? 17 : 16);
            if (u == 'Q') return (row == 0) ? 14 : ((row == 5) ? 18 : ((row == 6) ? 13 : 17));
            if (u == 'R') return (row == 0 || row == 3) ? 30 : ((row < 3) ? 17 : (16 | (1 << (6 - row))));
            if (u == 'S') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 16 : 1);
            if (u == 'T') return (row == 0) ? 31 : 4;
            if (u == 'U') return (row == 6) ? 14 : 17;
            if (u == 'V') return (row == 6) ? 4 : ((row == 5) ? 10 : 17);
            if (u == 'W') return (row == 5) ? 21 : ((row == 4) ? 21 : 17);
            if (u == 'X') return (row == 3) ? 4 : ((row == 2 || row == 4) ? 10 : 17);
            if (u == 'Y') return (row < 3) ? 17 : ((row == 3) ? 10 : 4);
            if (u == 'Z') return (row == 0 || row == 6) ? 31 : (1 << ((row <= 4) ? (row - 0) : 4));
            return (row == 0 || row == 6) ? 14 : 0;
        }

        public void show_text (string text) {
            int cx = cur_x;
            int cy = cur_y;
            int s = font_scale;
            for (int i = 0; i < text.length; i++) {
                int ch = (int) text[i];
                if (ch < 0x80) {
                    for (int r = 0; r < 7; r++) {
                        int bits = glyph_row (ch, r);
                        for (int c = 0; c < 5; c++) {
                            if ((bits & (16 >> c)) != 0) {
                                for (int sy = 0; sy < s; sy++)
                                    for (int sx = 0; sx < s; sx++)
                                        put_px (cx + c * s + sx, cy + r * s + sy);
                            }
                        }
                    }
                    cx = cx + 6 * s;
                }
            }
            cur_x = cx;
        }
    }
}

namespace Gdk {
    using Cairo;

    [AsmBody(@"
        mov (%rdi), %rax
        ret
    ")]
    private extern int __g_peek64 (int addr);

    public class RGBA : Object {
        public double red = 1.0;
        public double green = 1.0;
        public double blue = 1.0;
        public double alpha = 1.0;

        private static int hex_val (uint8 c) {
            if (c >= '0' && c <= '9') return (int) (c - '0');
            if (c >= 'a' && c <= 'f') return 10 + (int) (c - 'a');
            if (c >= 'A' && c <= 'F') return 10 + (int) (c - 'A');
            return 0;
        }

        public bool parse (string spec) {
            if (spec.length == 7 && spec[0] == '#') {
                int r = hex_val (spec[1]) * 16 + hex_val (spec[2]);
                int g = hex_val (spec[3]) * 16 + hex_val (spec[4]);
                int b = hex_val (spec[5]) * 16 + hex_val (spec[6]);
                red = (double) r / 255.0;
                green = (double) g / 255.0;
                blue = (double) b / 255.0;
                alpha = 1.0;
                return true;
            }
            return false;
        }
    }

    public void cairo_set_source_rgba (Context cr, RGBA c) {
        cr.set_source_rgba (c.red, c.green, c.blue, c.alpha);
    }

    public enum EventType {
        NONE,
        KEY_PRESS,
        BUTTON_PRESS,
        MOTION_NOTIFY
    }

    public class Event : Object {
        public EventType type = EventType.NONE;
        public int keyval = 0;
        public int x = 0;
        public int y = 0;
        public int button = 0;
    }

    public class Window : Object {
        public int width { get; private set; }
        public int height { get; private set; }
        public ImageSurface surface { get; private set; }
        private int mouse_buf = 0;
        private int last_mx = -1;
        private int last_my = -1;
        private int last_mb = 0;

        public Window (int w, int h) {
            width = w;
            height = h;
            surface = new ImageSurface (Format.ARGB32, w, h);
            mouse_buf = Sys.alloc_pages (1);
        }

        public Context create_cairo_context () {
            return new Context (surface);
        }

        public void present () {
            Sys.sys (22, surface.buf_addr, width, height);
        }

        public Event poll_event () {
            var ev = new Event ();
            int key = Sys.read_key ();
            if (key > 0) {
                ev.type = EventType.KEY_PRESS;
                ev.keyval = key;
                return ev;
            }
            Sys.sys (24, mouse_buf, 0, 0);
            int mx = __g_peek64 (mouse_buf + 0);
            int my = __g_peek64 (mouse_buf + 8);
            int mb = __g_peek64 (mouse_buf + 16);
            if (mb != 0 && last_mb == 0) {
                last_mb = mb;
                last_mx = mx;
                last_my = my;
                ev.type = EventType.BUTTON_PRESS;
                ev.x = mx;
                ev.y = my;
                ev.button = mb;
                return ev;
            }
            last_mb = mb;
            if (mx != last_mx || my != last_my) {
                last_mx = mx;
                last_my = my;
                ev.type = EventType.MOTION_NOTIFY;
                ev.x = mx;
                ev.y = my;
                return ev;
            }
            return ev;
        }

        public void close () {
            Sys.sys (23, 0, 0, 0);
            if (mouse_buf != 0) {
                Sys.free_page (mouse_buf);
                mouse_buf = 0;
            }
            if (surface.buf_addr != 0) {
                int pages = (width * height * 4 + 4095) / 4096;
                for (int p = 0; p < pages; p++) {
                    Sys.free_page (surface.buf_addr + p * 4096);
                }
            }
        }
    }

    public class Display : Object {
        public static Window? open_window (int w = 800, int h = 600) {
            int fb = Sys.sys (21, w, h, 0);
            if (fb == 0)
                return null;
            return new Window (w, h);
        }
    }
}
