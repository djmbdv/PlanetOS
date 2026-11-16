// Pure-Vala Gdk compatibility layer for PlanetOS (zero C, zero .vapi).

using Planet;

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
