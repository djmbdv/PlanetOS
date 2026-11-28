// Pure-Vala Gdk.Window framebuffer/compositor surface and input polling for PlanetOS.

using Planet;

namespace Gdk {
    using Cairo;

    [AsmBody(@"
        # __gdk_copy_dwords(dst in rdi, src in rsi, count in rdx)
        mov %rdx, %rcx
        test %rcx, %rcx
        jle _gcd_done
    _gcd_sse:
        cmp $4, %rcx
        jb _gcd_tail
        .byte 0xf3, 0x0f, 0x6f, 0x06
        .byte 0xf3, 0x0f, 0x7f, 0x07
        add $16, %rsi
        add $16, %rdi
        sub $4, %rcx
        jmp _gcd_sse
    _gcd_tail:
        test %rcx, %rcx
        jle _gcd_done
        .byte 0xf3, 0xa5
    _gcd_done:
        ret
    ")]
    private extern void __gdk_copy_dwords (int dst, int src, int count);

    /**
     * Layout of the compositor shared window block (PLANET_WIN_SHM).
     *
     * One 4 KiB header page followed by the ARGB pixels. The compositor owns the
     * memory: it allocates the frames and exports the base address, and because
     * the kernel identity-maps user pages the client attaches the very same
     * address with Sys.map_user_at. The client only ever writes the damage
     * rectangle and the sequence number; the pixels are written straight into
     * the shared buffer, so a frame costs no copy and no file rewrite.
     */
    public class SharedSurface : Object {
        public const int MAGIC = 0x4D48534F; // "OSHM"
        public const int HDR_BYTES = 4096;
        public const int OFF_MAGIC = 0;
        public const int OFF_WIDTH = 4;
        public const int OFF_HEIGHT = 8;
        public const int OFF_SEQ = 12;
        public const int OFF_DX = 16;
        public const int OFF_DY = 20;
        public const int OFF_DW = 24;
        public const int OFF_DH = 28;
        // Up to four damage rectangles per published frame; rectangle 0 reuses
        // the offsets above, the rest follow the count word.
        public const int OFF_DCOUNT = 32;
        public const int OFF_RECT1 = 36;
        public const int MAX_RECTS = 4;
        // Input ring. The compositor writes a slot and then bumps OFF_EV_SEQ; the
        // client copies up to that sequence and acknowledges with OFF_EV_ACK, so
        // the two ends never need a syscall to exchange an event.
        public const int OFF_EV_SEQ = 84;
        public const int OFF_EV_ACK = 88;
        public const int OFF_EV_SLOT = 92;
        public const int EV_SLOTS = 16;
        public const int EV_WORDS = 4;      // type, p1, p2, p3

        public static int pixel_offset () {
            return HDR_BYTES;
        }

        public static int ev_slot (int idx) {
            return OFF_EV_SLOT + idx * EV_WORDS * 4;
        }

        public static int rect_off (int idx) {
            return (idx == 0) ? OFF_DX : OFF_RECT1 + (idx - 1) * 16;
        }

        public static int bytes_for (int w, int h) {
            if (w <= 0 || h <= 0 || w > Window.MAX_DIM || h > Window.MAX_DIM)
                return 0;
            int64 total = (int64) HDR_BYTES + (int64) w * (int64) h * 4;
            if (total > 0x7FFFFFFF)
                return 0;
            return (int) total;
        }

        public static int pages_for (int w, int h) {
            int bytes = bytes_for (w, h);
            if (bytes <= 0)
                return 0;
            return (bytes + 4095) / 4096;
        }
    }

    /**
     * Window backed by either the kernel linear framebuffer, a compositor PWIN
     * file, or a compositor shared surface.
     */
    public class Window : Object {
        public const int MIN_DIM = 1;
        public const int MAX_DIM = 8192;
        private const int COMP_CHUNK = 65536;

        public int width { get; private set; }
        public int height { get; private set; }
        public ImageSurface surface { get; private set; }
        public string comp_file = "";
        public string comp_ev_file = "";
        public int comp_shm = 0;
        public bool closed { get; private set; }
        private int comp_shm_seq = 0;

        private int mouse_buf = 0;
        private int last_mx = -1;
        private int last_my = -1;
        private int last_mb = 0;
        private int last_wheel = 0;
        private int comp_seq = 0;
        private uint8[] comp_hdr;
        private int32 last_ev_seq = 0;
        private int32[] ev_q;
        private int16 ev_q_len = 0;
        private int16 ev_q_pos = 0;
        private uint8[] ev_read_buf;

        private int cur_x = 0;
        private int cur_y = 0;
        private int cur_mask = 0;
        private int cur_wheel = 0;

        private static int clamp_dim (int d) {
            if (d < MIN_DIM) return MIN_DIM;
            if (d > MAX_DIM) return MAX_DIM;
            return d;
        }

        private static int32 read_le32 (uint8[] buf, int off) {
            int v = ((int) buf[off + 0])
                  | (((int) buf[off + 1]) << 8)
                  | (((int) buf[off + 2]) << 16)
                  | (((int) buf[off + 3]) << 24);
            return (int32) v;
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

        public Window.compositor_surface (int w, int h, string file_path, string ev_path = "") {
            width = clamp_dim (w);
            height = clamp_dim (h);
            closed = false;
            comp_file = file_path;
            comp_ev_file = ev_path;
            surface = new ImageSurface (Format.ARGB32, width, height);
            comp_hdr = new uint8[16];
            ev_q = new int32[64];
            ev_read_buf = new uint8[324];
        }

        /**
         * Shared-surface client: attaches the block the compositor allocated and
         * draws straight into its pixel buffer. An attach that fails leaves the
         * window invalid so Display can fall back to the PWIN file transport.
         */
        public Window.compositor_shared (int w, int h, int shm_base, string ev_path = "") {
            width = clamp_dim (w);
            height = clamp_dim (h);
            closed = false;
            comp_file = "";
            comp_ev_file = ev_path;
            comp_hdr = new uint8[16];
            ev_q = new int32[64];
            ev_read_buf = new uint8[324];
            int px = 0;
            int bytes = SharedSurface.bytes_for (width, height);
            if (shm_base > 0 && bytes > 0 && Sys.map_user_at (shm_base, bytes) == 0) {
                if (Unsafe.peek32 (shm_base + SharedSurface.OFF_MAGIC) == SharedSurface.MAGIC) {
                    px = shm_base + SharedSurface.pixel_offset ();
                    comp_shm = shm_base;
                    comp_shm_seq = Unsafe.peek32 (shm_base + SharedSurface.OFF_SEQ);
                }
            }
            surface = new ImageSurface.wrap (px, width, height);
        }

        ~Window () {
            close ();
        }

        public bool is_valid () {
            return !closed && surface != null && surface.buf_addr != 0;
        }

        // True when the pixels live in a compositor surface, so the window must
        // not draw its own cursor nor touch the kernel framebuffer.
        public bool composited () {
            return comp_shm != 0 || comp_file.length > 0;
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

        // Publishes a damage rectangle. The pixels are already in the shared
        // buffer, so this only records the rect and bumps the sequence number,
        // which the compositor reads as "frame N is complete".
        private void publish_shared (int dx, int dy, int dw, int dh) {
            if (comp_shm == 0)
                return;
            if (dx < 0) {
                dw = dw + dx;
                dx = 0;
            }
            if (dy < 0) {
                dh = dh + dy;
                dy = 0;
            }
            if (dx + dw > width)
                dw = width - dx;
            if (dy + dh > height)
                dh = height - dy;
            if (dw <= 0 || dh <= 0)
                return;
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_DX, dx);
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_DY, dy);
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_DW, dw);
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_DH, dh);
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_DCOUNT, 1);
            Unsafe.mfence ();
            comp_shm_seq = comp_shm_seq + 1;
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_SEQ, comp_shm_seq);
        }

        // Publishes several rectangles at once: distant changes stay separate, so
        // the compositor never repaints the gap between an edited line and a
        // status label in a far corner.
        private void publish_shared_rects (int[] xs, int[] ys, int[] ws, int[] hs, int n) {
            if (comp_shm == 0)
                return;
            int out_n = 0;
            int last_x = 0;
            int last_y = 0;
            int last_w = 0;
            int last_h = 0;
            for (int i = 0; i < n; i++) {
                int x = xs[i];
                int y = ys[i];
                int w = ws[i];
                int h = hs[i];
                if (x < 0) {
                    w = w + x;
                    x = 0;
                }
                if (y < 0) {
                    h = h + y;
                    y = 0;
                }
                if (x + w > width)
                    w = width - x;
                if (y + h > height)
                    h = height - y;
                if (w <= 0 || h <= 0)
                    continue;
                if (out_n < SharedSurface.MAX_RECTS) {
                    int off = comp_shm + SharedSurface.rect_off (out_n);
                    Unsafe.poke32 (off + 0, x);
                    Unsafe.poke32 (off + 4, y);
                    Unsafe.poke32 (off + 8, w);
                    Unsafe.poke32 (off + 12, h);
                    last_x = x;
                    last_y = y;
                    last_w = w;
                    last_h = h;
                    out_n = out_n + 1;
                } else {
                    int x0 = (x < last_x) ? x : last_x;
                    int y0 = (y < last_y) ? y : last_y;
                    int x1 = (x + w > last_x + last_w) ? (x + w) : (last_x + last_w);
                    int y1 = (y + h > last_y + last_h) ? (y + h) : (last_y + last_h);
                    last_x = x0;
                    last_y = y0;
                    last_w = x1 - x0;
                    last_h = y1 - y0;
                    int off = comp_shm + SharedSurface.rect_off (SharedSurface.MAX_RECTS - 1);
                    Unsafe.poke32 (off + 0, last_x);
                    Unsafe.poke32 (off + 4, last_y);
                    Unsafe.poke32 (off + 8, last_w);
                    Unsafe.poke32 (off + 12, last_h);
                }
            }
            if (out_n == 0)
                return;
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_DCOUNT, out_n);
            Unsafe.mfence ();
            comp_shm_seq = comp_shm_seq + 1;
            Unsafe.poke32 (comp_shm + SharedSurface.OFF_SEQ, comp_shm_seq);
        }

        public void present_rects (int[] xs, int[] ys, int[] ws, int[] hs, int n) {
            if (!is_valid ())
                return;
            if (comp_shm != 0) {
                publish_shared_rects (xs, ys, ws, hs, n);
                return;
            }
            if (comp_file.length > 0) {
                flush_to_comp_file ();
                return;
            }
            for (int i = 0; i < n; i++)
                present_rect (xs[i], ys[i], ws[i], hs[i]);
        }

        public void present () {
            if (!is_valid ())
                return;
            if (comp_shm != 0) {
                publish_shared (0, 0, width, height);
                return;
            }
            if (comp_file.length > 0) {
                flush_to_comp_file ();
                return;
            }
            Sys.sys (22, surface.buf_addr, width, height);
        }

        /**
         * Presents an external 32-bit ARGB buffer (`src_w` x `src_h`).
         * Standalone windows blit directly from `src_addr` (zero copy);
         * composited windows copy into their shared/file surface and publish.
         */
        public void present_argb32 (int src_addr, int src_w, int src_h) {
            if (!is_valid () || src_addr == 0 || src_w <= 0 || src_h <= 0)
                return;
            if (!composited () && width == src_w && height == src_h) {
                Sys.sys (22, src_addr, src_w, src_h);
                return;
            }
            int dst = surface.buf_addr;
            if (width == src_w && height == src_h) {
                __gdk_copy_dwords (dst, src_addr, src_w * src_h);
            } else {
                int cw = (width < src_w) ? width : src_w;
                int ch = (height < src_h) ? height : src_h;
                for (int y = 0; y < ch; y++)
                    __gdk_copy_dwords (dst + y * width * 4, src_addr + y * src_w * 4, cw);
            }
            present ();
        }

        /**
         * Blits one dirty rectangle instead of the whole surface (SYS_FB_BLIT_RECT).
         * Clips coordinates against [0, width) x [0, height).
         */
        public void present_rect (int x, int y, int w, int h) {
            if (!is_valid ())
                return;
            if (comp_shm != 0) {
                publish_shared (x, y, w, h);
                return;
            }
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
            cur_x = Unsafe.peek64 (mouse_buf + 0);
            cur_y = Unsafe.peek64 (mouse_buf + 8);
            cur_mask = Unsafe.peek64 (mouse_buf + 16);
            cur_wheel = Unsafe.peek64 (mouse_buf + 48);
        }

        // Cached pointer position/mask, refreshed by poll_event() or read_pointer().
        public int pointer_x () { return cur_x; }
        public int pointer_y () { return cur_y; }
        public int pointer_mask () { return cur_mask; }
        public int pointer_wheel () { return cur_wheel; }

        public void read_pointer () {
            refresh_pointer ();
        }

        private Event pop_comp_event () {
            var ev = new Event ();
            int base_i = (int) ev_q_pos * 4;
            int32 etype = ev_q[base_i + 0];
            int32 p1 = ev_q[base_i + 1];
            int32 p2 = ev_q[base_i + 2];
            int32 p3 = ev_q[base_i + 3];
            ev_q_pos++;
            if (etype == 1) {
                ev.type = EventType.KEY_PRESS;
                ev.keyval = p1;
                ev.state = (uint8) p2;
            } else if (etype == 2) {
                ev.type = EventType.BUTTON_PRESS;
                ev.x = p1;
                ev.y = p2;
                ev.button = (int8) p3;
                ev.state = (uint8) p3;
                cur_x = (int) p1;
                cur_y = (int) p2;
                cur_mask = (int) p3;
            } else if (etype == 3) {
                ev.type = EventType.BUTTON_RELEASE;
                ev.x = p1;
                ev.y = p2;
                ev.button = (int8) p3;
                ev.state = 0;
                cur_x = (int) p1;
                cur_y = (int) p2;
                cur_mask = 0;
            } else if (etype == 4) {
                ev.type = EventType.MOTION_NOTIFY;
                ev.x = p1;
                ev.y = p2;
                ev.state = (uint8) cur_mask;
                cur_x = (int) p1;
                cur_y = (int) p2;
            } else if (etype == 5) {
                int packed = (int) p3;
                int dx = (packed >> 16) & 0xFFFF;
                int dy = packed & 0xFFFF;
                if (dx >= 32768) dx -= 65536;
                if (dy >= 32768) dy -= 65536;
                ev.type = EventType.SCROLL;
                ev.x = p1;
                ev.y = p2;
                ev.scroll_dx = (int16) dx;
                ev.scroll_dy = (int16) dy;
                ev.button = (int8) ((dy < 0) ? 4 : 5);
                ev.state = (uint8) cur_mask;
            }
            return ev;
        }

        private Event poll_comp_event () {
            if (ev_q_pos < ev_q_len)
                return pop_comp_event ();
            if (comp_shm != 0)
                return poll_shared_event ();
            if (comp_ev_file.length == 0)
                return new Event ();
            int fd = Sys.open (comp_ev_file);
            if (fd < 0)
                return new Event ();
            if (ev_read_buf == null || ev_read_buf.length < 324)
                ev_read_buf = new uint8[324];
            int nr = Sys.read (fd, ev_read_buf, 324);
            Sys.close (fd);
            if (nr < 4)
                return new Event ();
            int cnt = (int) read_le32 (ev_read_buf, 0);
            if (cnt <= 0 || cnt > 16 || 4 + cnt * 20 > nr)
                return new Event ();
            if (ev_q == null || ev_q.length < 64)
                ev_q = new int32[64];
            ev_q_len = 0;
            ev_q_pos = 0;
            for (int i = 0; i < cnt; i++) {
                int off = 4 + i * 20;
                int32 seq = read_le32 (ev_read_buf, off + 0);
                if (seq > last_ev_seq) {
                    last_ev_seq = seq;
                    int dst = (int) ev_q_len * 4;
                    ev_q[dst + 0] = read_le32 (ev_read_buf, off + 4);
                    ev_q[dst + 1] = read_le32 (ev_read_buf, off + 8);
                    ev_q[dst + 2] = read_le32 (ev_read_buf, off + 12);
                    ev_q[dst + 3] = read_le32 (ev_read_buf, off + 16);
                    ev_q_len++;
                }
            }
            if (ev_q_pos < ev_q_len)
                return pop_comp_event ();
            return new Event ();
        }

        // Shared input ring: read everything the compositor wrote since the last
        // acknowledgement, then ack it so those slots can be reused.
        private Event poll_shared_event () {
            int shm = comp_shm;
            int written = Unsafe.peek32 (shm + SharedSurface.OFF_EV_SEQ);
            int ack = Unsafe.peek32 (shm + SharedSurface.OFF_EV_ACK);
            if (written <= ack) {
                if (written < ack)
                    Unsafe.mfence ();
            Unsafe.poke32 (shm + SharedSurface.OFF_EV_ACK, written);
                return new Event ();
            }
            // Overrun: the compositor reused slots, so jump to the oldest event
            // that is still intact instead of mixing stale payloads.
            if (written - ack > SharedSurface.EV_SLOTS)
                ack = written - SharedSurface.EV_SLOTS;
            if (ev_q == null || ev_q.length < 64)
                ev_q = new int32[64];
            ev_q_len = 0;
            ev_q_pos = 0;
            int mask = SharedSurface.EV_SLOTS - 1;
            for (int s = ack + 1; s <= written && ev_q_len < SharedSurface.EV_SLOTS; s++) {
                int off = shm + SharedSurface.ev_slot (s & mask);
                int dst = (int) ev_q_len * 4;
                ev_q[dst + 0] = Unsafe.peek32 (off + 0);
                ev_q[dst + 1] = Unsafe.peek32 (off + 4);
                ev_q[dst + 2] = Unsafe.peek32 (off + 8);
                ev_q[dst + 3] = Unsafe.peek32 (off + 12);
                ev_q_len++;
            }
            Unsafe.mfence ();
            Unsafe.poke32 (shm + SharedSurface.OFF_EV_ACK, written);
            if (ev_q_pos < ev_q_len)
                return pop_comp_event ();
            return new Event ();
        }

        public Event poll_event () {
            var ev = new Event ();
            if (closed)
                return ev;
            if (composited ())
                return poll_comp_event ();
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
            } else if (comp_shm == 0) {
                Sys.sys (23, 0, 0, 0);
            }
            // The shared block belongs to the compositor: drop the reference but
            // never release frames the client does not own.
            comp_shm = 0;
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
