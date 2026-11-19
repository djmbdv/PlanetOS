// Pure-Vala Gdk.Window framebuffer/compositor surface and input polling for PlanetOS.

using Planet;

namespace Gdk {
    using Cairo;

    [AsmBody(@"
        mov (%rdi), %rax
        ret
    ")]
    private extern int __g_peek64 (int addr);

    /**
     * Window backed by either the kernel linear framebuffer or a compositor PWIN file.
     */
    public class Window : Object {
        private const int MIN_DIM = 1;
        private const int MAX_DIM = 8192;
        private const int COMP_CHUNK = 65536;

        public int width { get; private set; }
        public int height { get; private set; }
        public ImageSurface surface { get; private set; }
        public string comp_file = "";
        public bool closed { get; private set; }

        private int mouse_buf = 0;
        private int last_mx = -1;
        private int last_my = -1;
        private int last_mb = 0;
        private int last_wheel = 0;
        private int comp_seq = 0;
        private uint8[] comp_hdr;

        private int cur_x = 0;
        private int cur_y = 0;
        private int cur_mask = 0;
        private int cur_wheel = 0;

        private static int clamp_dim (int d) {
            if (d < MIN_DIM) return MIN_DIM;
            if (d > MAX_DIM) return MAX_DIM;
            return d;
        }

        private static void write_le32 (uint8[] buf, int off, int val) {
            buf[off + 0] = (uint8) (val & 0xFF);
            buf[off + 1] = (uint8) ((val >> 8) & 0xFF);
            buf[off + 2] = (uint8) ((val >> 16) & 0xFF);
            buf[off + 3] = (uint8) ((val >> 24) & 0xFF);
        }

        public Window (int w, int h) {
            width = clamp_dim (w);
            height = clamp_dim (h);
            closed = false;
            surface = new ImageSurface (Format.ARGB32, width, height);
            mouse_buf = Sys.alloc_pages (1);
            comp_hdr = new uint8[0];
        }

        public Window.compositor_surface (int w, int h, string file_path) {
            width = clamp_dim (w);
            height = clamp_dim (h);
            closed = false;
            comp_file = file_path;
            surface = new ImageSurface (Format.ARGB32, width, height);
            comp_hdr = new uint8[16];
        }

        public bool is_valid () {
            return !closed && surface != null && surface.buf_addr != 0;
        }

        public Context create_cairo_context () {
            return new Context (surface);
        }

        private void flush_to_comp_file () {
            if (!is_valid () || comp_file.length == 0)
                return;
            string tmp_file = comp_file + ".tmp";
            int fd = Sys.create (tmp_file);
            if (fd < 0)
                return;
            comp_seq = comp_seq + 1;
            if (comp_hdr.length < 16)
                comp_hdr = new uint8[16];
            // Write complete frame to .tmp and atomically rename into place.
            comp_hdr[0] = 0x4E;
            comp_hdr[1] = 0x49;
            comp_hdr[2] = 0x57;
            comp_hdr[3] = 0x50;
            write_le32 (comp_hdr, 4, width);
            write_le32 (comp_hdr, 8, height);
            write_le32 (comp_hdr, 12, comp_seq);
            if (Sys.write (fd, comp_hdr, 16) != 16) {
                Sys.close (fd);
                Sys.unlink (tmp_file);
                return;
            }
            int total = width * height * 4;
            int off = 0;
            while (off < total) {
                int chunk = total - off;
                if (chunk > COMP_CHUNK)
                    chunk = COMP_CHUNK;
                int w = Sys.sys (15, fd, surface.buf_addr + off, chunk);
                if (w <= 0)
                    break;
                off = off + w;
            }
            Sys.close (fd);
            if (off == total) {
                Sys.unlink (comp_file);
                Sys.rename (tmp_file, comp_file);
            } else {
                Sys.unlink (tmp_file);
            }
        }

        public void present () {
            if (!is_valid ())
                return;
            if (comp_file.length > 0) {
                flush_to_comp_file ();
                return;
            }
            Sys.sys (22, surface.buf_addr, width, height);
        }

        /**
         * Blits one dirty rectangle instead of the whole surface (SYS_FB_BLIT_RECT).
         * Clips coordinates against [0, width) x [0, height).
         */
        public void present_rect (int x, int y, int w, int h) {
            if (!is_valid ())
                return;
            if (comp_file.length > 0) {
                flush_to_comp_file ();
                return;
            }
            if (x < 0) {
                w = w + x;
                x = 0;
            }
            if (y < 0) {
                h = h + y;
                y = 0;
            }
            if (w <= 0 || h <= 0 || x >= width || y >= height)
                return;
            if (x + w > width)
                w = width - x;
            if (y + h > height)
                h = height - y;
            if (w <= 0 || h <= 0)
                return;
            Sys.sys (26, surface.buf_addr, (x << 16) | (y & 0xFFFF), (w << 16) | (h & 0xFFFF));
        }

        // Refreshes the cached pointer state (one SYS_MOUSE_READ).
        private void refresh_pointer () {
            if (closed || mouse_buf <= 0)
                return;
            if (Sys.sys (24, mouse_buf, 0, 0) < 0)
                return;
            cur_x = __g_peek64 (mouse_buf + 0);
            cur_y = __g_peek64 (mouse_buf + 8);
            cur_mask = __g_peek64 (mouse_buf + 16);
            cur_wheel = __g_peek64 (mouse_buf + 48);
        }

        // Cached pointer position/mask, refreshed by poll_event() or read_pointer().
        public int pointer_x () { return cur_x; }
        public int pointer_y () { return cur_y; }
        public int pointer_mask () { return cur_mask; }
        public int pointer_wheel () { return cur_wheel; }

        public void read_pointer () {
            refresh_pointer ();
        }

        public Event poll_event () {
            var ev = new Event ();
            if (closed || comp_file.length > 0)
                return ev;
            int key = Sys.read_key ();
            if (key > 0) {
                ev.type = EventType.KEY_PRESS;
                ev.keyval = key;
                ev.state = cur_mask;
                return ev;
            }
            refresh_pointer ();
            int mx = cur_x;
            int my = cur_y;
            int mb = cur_mask;
            if (mb != 0 && last_mb == 0) {
                last_mb = mb;
                last_mx = mx;
                last_my = my;
                ev.type = EventType.BUTTON_PRESS;
                ev.x = mx;
                ev.y = my;
                ev.button = mb;
                ev.state = mb;
                return ev;
            }
            if (mb == 0 && last_mb != 0) {
                int rel_btn = last_mb;
                last_mb = 0;
                last_mx = mx;
                last_my = my;
                ev.type = EventType.BUTTON_RELEASE;
                ev.x = mx;
                ev.y = my;
                ev.button = rel_btn;
                ev.state = 0;
                return ev;
            }
            last_mb = mb;
            if (cur_wheel != last_wheel) {
                int dw = cur_wheel - last_wheel;
                last_wheel = cur_wheel;
                ev.type = EventType.SCROLL;
                ev.x = mx;
                ev.y = my;
                ev.scroll_dx = 0;
                ev.scroll_dy = dw;
                ev.button = (dw < 0) ? 4 : 5;
                ev.state = mb;
                return ev;
            }
            if (mx != last_mx || my != last_my) {
                last_mx = mx;
                last_my = my;
                ev.type = EventType.MOTION_NOTIFY;
                ev.x = mx;
                ev.y = my;
                ev.state = mb;
                return ev;
            }
            return ev;
        }

        public void close () {
            if (closed)
                return;
            closed = true;
            if (comp_file.length > 0) {
                Sys.unlink (comp_file);
            } else {
                Sys.sys (23, 0, 0, 0);
            }
            if (mouse_buf > 0) {
                Sys.free_page (mouse_buf);
                mouse_buf = 0;
            }
            if (surface != null) {
                surface.destroy ();
            }
        }
    }
}
