// Compositor window manager, damage tracking, input, shader, and rendering.
using GLib;
using Planet;
using Pango;
using PangoCairo;
using Spv;
using Cairo;
using Gdk;
using Gtk;
using Gsk;
using Wm;

namespace Wm {
    // Finds the first <path d="..."> of an SVG through GLib.MarkupParseContext,
    // so attribute order and extra elements do not matter.
    public class SvgPathProbe : Object {
        public string data = "";
        public bool found = false;

        public static SvgPathProbe? from_svg (string svg) {
            var probe = new SvgPathProbe ();
            MarkupStartElement on_start = (ctx, name, attr_names, attr_values) => {
                if (probe.found || name != "path")
                    return;
                for (int i = 0; i < attr_names.length; i++) {
                    if (attr_names[i] == "d") {
                        probe.data = attr_values[i];
                        probe.found = true;
                        return;
                    }
                }
            };
            var parser = new MarkupParser (on_start);
            var ctx = new MarkupParseContext (parser);
            try {
                ctx.parse (svg, -1);
                ctx.end_parse ();
            } catch (MarkupError e) {
                return probe.found ? probe : null;
            }
            return probe.found ? probe : null;
        }
    }

    public class Compositor : Object {
        private GenericArray<Win> wins;
        private Window screen;
        private Context? frame_cr = null;
        private uint8[] ext_hdr = new uint8[16];
        private bool attached = false;
        private int next_id = 1;
        private int ztop = 0;
        private int focused_id = 0;
        private bool dragging = false;
        private int drag_id = 0;
        private bool resizing = false;
        private int resize_id = 0;
        private int drag_ox = 0;
        private int drag_oy = 0;
        private int last_ptr_x = 0;
        private int last_ptr_y = 0;
        private bool quit = false;
        private int frames = 0;
        private int motions = 0;
        private int flush_ticks = 0;
        private int blit_ticks = 0;
        private int dirty_frames = 0;
        private int last_sec = -1;
        private Module shader;
        private bool shader_ok = false;
        private int backend_id = 0;
        // Default accent: Celestial Cerulean (#3897F0)
        private double acc_r = 0.450;
        private double acc_g = 0.455;
        private double acc_b = 0.470;
        private int[] dmg;
        private int[] last;
        private int last_n = 0;
        private bool last_full = true;
        private int ndmg = 0;
        private bool dmg_full = true;
        private int mods = 0;
        private int last_mx = -100;
        private int last_my = -100;
        private Module pattern;
        private ShaderNode? pattern_node = null;
        private bool pattern_ok = false;
        private int pat_step = PAT_STEP;
        private bool anim_on = false;
        private int anim_period_ms = 400;
        private int last_anim_tick = 0;
        private int anim_count = 0;
        private int occluded_skips = 0;
        private int bg_skips = 0;
        private PangoContext pctx;
        private Layout title_lay;
        private Layout dock_lay;
        private Layout notes_lay;

        // Cursor rasterised from cursor.svg at startup. The same 64x64 BGRA
        // image feeds the software blit and the VirtIO-GPU hardware cursor.
        private const int CURSOR_TEX = 64;
        private bool cursor_svg_ok = false;
        private bool cursor_markup_ok = false;
        private uint8[] cursor_pix;
        private int cursor_hot_x = 0;
        private int cursor_hot_y = 0;
        private int cursor_min_x = 0;
        private int cursor_min_y = 0;
        private int cursor_bw = 16;
        private int cursor_bh = 22;
        private Renderer gsk_renderer;

        // Calendar and places state. The zone comes from TZ/PLANET_TZ, and the
        // place list is read once at start-up (GLib.BookmarkFile + GLib.Uri),
        // with an HMAC-SHA256 sidecar proving it was not edited by hand.
        private const string QDATA_CAL_MONTH = "cal-month";
        private const string PLACES_FILE = "places.gbk";
        private const string PLACES_SIG = "places.sig";
        private const string PLACES_HMAC_KEY = "planetos-places-v1";
        private TimeZone zone;
        private BookmarkFile places;
        private bool places_signed = false;

        public Compositor () {
            wins = new GenericArray<Win> ();
            shader = new Module ();
            pattern = new Module ();
            gsk_renderer = new VulkanRenderer (1);
            dmg = new int[DMG_RECTS * 4];
            last = new int[DMG_RECTS * 4];
            pctx = new PangoContext ();
            title_lay = new Layout (pctx);
            dock_lay = new Layout (pctx);
            dock_lay.set_width (DOCK_BTN_W - 18);
            dock_lay.set_ellipsize (EllipsizeMode.END);
            notes_lay = new Layout (pctx);
            notes_lay.set_width (300);
            notes_lay.set_spacing (4);
            notes_lay.set_text ("notes\nopenbox interaction model\ngala style shadows + dock\n100% vala, no mutter\ngdk + cairo framebuffer\nspir-v accent pipeline");
            // highlight the last line ("spir-v accent pipeline")
            notes_lay.add_color_attribute (103, 125, 0.450, 0.455, 0.470);
            pattern_node = null;
            zone = TimeZone.new_local ();
            places = new BookmarkFile ();
            load_places ();
            load_cursor_svg ();
            load_wallpaper ();
            var mac = new uint8[6];
            net_connected = (Sys.net_mac (mac) == 0);
        }

        // --- calendar / places ----------------------------------------

        public string zone_id () { return zone.get_identifier (); }

        // True when cursor.svg was read through GLib.MarkupParseContext rather
        // than the fallback string scan.
        public bool cursor_via_markup () { return cursor_markup_ok; }

        public int places_count () { return places.get_size (); }

        public bool places_verified () { return places_signed; }

        private static uint8[] hmac_key () {
            var key = new uint8[PLACES_HMAC_KEY.length];
            for (int i = 0; i < PLACES_HMAC_KEY.length; i++)
                key[i] = (uint8) PLACES_HMAC_KEY[i];
            return key;
        }

        public static string sign_payload (string data) {
            return Hmac.compute_for_string (ChecksumType.SHA256, hmac_key (), data, -1);
        }

        public string places_signature () {
            size_t len = 0;
            string data = places.to_data (out len);
            return sign_payload (data);
        }

        // Accepts only a payload whose HMAC-SHA256 matches; a tampered places
        // file falls back to the built-in list.
        public bool verify_places_data (string data, string signature) {
            return sign_payload (data) == signature;
        }

        private void load_places () {
            bool loaded = false;
            try {
                if (places.load_from_file (PLACES_FILE)) {
                    loaded = places.get_size () > 0;
                    if (loaded)
                        places_signed = verify_places_signature ();
                }
            } catch (BookmarkFileError e) {
                loaded = false;
            }
            if (loaded)
                return;
            try {
                places.set_title ("file:///", "Root");
                places.set_mime_type ("file:///", "inode/directory");
                places.add_group ("file:///", "places");
                places.set_title ("file:///tmp", "Scratch");
                places.set_mime_type ("file:///tmp", "inode/directory");
                places.add_group ("file:///tmp", "places");
                places.set_title ("file:///test", "Test tree");
                places.set_mime_type ("file:///test", "inode/directory");
                places.add_group ("file:///test", "places");
            } catch (BookmarkFileError e) {
                print (@"compositor: places init failed: $(e.message)\n");
            }
        }

        private bool verify_places_signature () {
            string expected = "";
            if (!FileUtils.get_contents (PLACES_SIG, out expected))
                return false;
            return places_signature () == expected;
        }

        private int current_month_index () {
            var now = DateTime.now_utc ().to_timezone (zone);
            return (now.get_year () - 1970) * 12 + (now.get_month () - 1);
        }

        private void calendar_shift (Win w, int delta) {
            int base_months = current_month_index ();
            int months = w.has_data (QDATA_CAL_MONTH) ? w.get_data (QDATA_CAL_MONTH) : base_months;
            w.set_data (QDATA_CAL_MONTH, months + delta);
            damage_window (w.id);
        }

        private void calendar_reset (Win w) {
            w.set_data (QDATA_CAL_MONTH, current_month_index ());
            damage_window (w.id);
        }

        // Month shown by the calendar window, as months since 1970-01.
        public int calendar_month (int id) {
            var w = find (id);
            if (w == null || w.kind != Kind.CALENDAR)
                return -1;
            return w.has_data (QDATA_CAL_MONTH) ? w.get_data (QDATA_CAL_MONTH) : current_month_index ();
        }

        public void calendar_prev (int id) {
            var w = find (id);
            if (w != null && w.kind == Kind.CALENDAR)
                calendar_shift (w, -1);
        }

        public void calendar_next (int id) {
            var w = find (id);
            if (w != null && w.kind == Kind.CALENDAR)
                calendar_shift (w, 1);
        }

        private static string month_name (int mon) {
            switch (mon) {
                case 1: return "January";
                case 2: return "February";
                case 3: return "March";
                case 4: return "April";
                case 5: return "May";
                case 6: return "June";
                case 7: return "July";
                case 8: return "August";
                case 9: return "September";
                case 10: return "October";
                case 11: return "November";
                case 12: return "December";
                default: return "?";
            }
        }

        // --- plumbing -------------------------------------------------

        private bool hw_cursor = false;
        private bool net_connected = false;
        // One decoded wallpaper per process: a full-screen surface is 900
        // contiguous frames, and the self-test builds several compositors from
        // the same pool the test surfaces come from.
        private static ImageSurface? wallpaper_surf;
        private static bool wallpaper_ok = false;
        private static bool wallpaper_probed = false;

        private static uint8[]? read_bytes (string path) {
            int fd = Sys.open (path);
            if (fd < 0)
                return null;
            int sz = Sys.file_size (fd);
            if (sz <= 0 || sz > 8 * 1024 * 1024) {
                Sys.close (fd);
                return null;
            }
            var buf = new uint8[sz];
            int got = 0;
            var chunk = new uint8[4096];
            while (got < sz) {
                int want = sz - got;
                if (want > 4096) want = 4096;
                int r = Sys.read (fd, chunk, want);
                if (r <= 0) break;
                for (int i = 0; i < r; i++)
                    buf[got + i] = chunk[i];
                got += r;
            }
            Sys.close (fd);
            if (got != sz)
                return null;
            return buf;
        }

        private void load_wallpaper () {
            if (wallpaper_probed)
                return;
            wallpaper_probed = true;
            uint8[]? jpg = read_bytes ("winxp.jpg");
            if (jpg == null) {
                print ("compositor: wallpaper read_bytes(winxp.jpg) failed\n");
                return;
            }
            var surf = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
            if (!surf.is_valid ())
                return;
            int iw = 0;
            int ih = 0;
            if (!StbImage.decode_scaled_to_buf ((!) jpg, surf.buf_addr, SCREEN_W, SCREEN_H, out iw, out ih)) {
                string err = StbImage.stbi_failure_reason ();
                print (@"compositor: wallpaper decode failed bytes=$(((!) jpg).length) iw=$iw ih=$ih err=$err\n");
                surf.destroy ();
                return;
            }
            print (@"compositor: wallpaper ok $(iw)x$(ih)\n");
            wallpaper_surf = surf;
            wallpaper_ok = true;
        }

        private static string? read_text (string path) {
            int fd = Sys.open (path);
            if (fd < 0)
                return null;
            int sz = Sys.file_size (fd);
            if (sz <= 0 || sz > 65536) {
                Sys.close (fd);
                return null;
            }
            var sb = new StringBuilder ();
            var chunk = new uint8[512];
            int got = 0;
            while (got < sz) {
                int want = sz - got;
                if (want > 512)
                    want = 512;
                int r = Sys.read (fd, chunk, want);
                if (r <= 0)
                    break;
                for (int i = 0; i < r; i++)
                    sb.append_c ((char) chunk[i]);
                got += r;
            }
            Sys.close (fd);
            if (got != sz)
                return null;
            return sb.str;
        }

        private static string? svg_path_data (string svg) {
            int k = svg.index_of ("d=\"");
            if (k < 0)
                return null;
            k = k + 3;
            int e = svg.index_of ("\"", k);
            if (e <= k)
                return null;
            return svg[k:e];
        }

        // Rasterises cursor.svg once. The soft cursor and the GPU cursor share
        // the same BGRA image, so they cannot drift apart.
        private void load_cursor_svg () {
            string? svg = read_text ("cursor.svg");
            if (svg == null)
                return;
            string? d = null;
            var probe = SvgPathProbe.from_svg (svg);
            if (probe != null && probe.found) {
                d = probe.data;
                cursor_markup_ok = true;
            }
            if (d == null)
                d = svg_path_data (svg);
            if (d == null)
                return;
            var path = Path.parse (d);
            if (path == null)
                return;
            cursor_hot_x = (int) path.first_x;
            cursor_hot_y = (int) path.first_y;
            var surf = new ImageSurface (Format.ARGB32, CURSOR_TEX, CURSOR_TEX);
            if (surf.buf_addr == 0)
                return;
            var cr = new Context (surf);
            cr.clear ();
            cr.set_source_rgba (0.090, 0.090, 0.094, 0.85);
            path.fill_translated (cr, 1.2, 1.2);
            cr.set_source_rgba (0.920, 0.920, 0.925, 1.0);
            path.fill (cr);
            cursor_pix = new uint8[CURSOR_TEX * CURSOR_TEX * 4];
            int minx = CURSOR_TEX;
            int miny = CURSOR_TEX;
            int maxx = -1;
            int maxy = -1;
            for (int y = 0; y < CURSOR_TEX; y++) {
                for (int x = 0; x < CURSOR_TEX; x++) {
                    int px = cr.pixel_at (x, y);
                    int a = (px >> 24) & 0xFF;
                    if (a > 0) {
                        if (x < minx) minx = x;
                        if (y < miny) miny = y;
                        if (x > maxx) maxx = x;
                        if (y > maxy) maxy = y;
                    }
                    int off = (y * CURSOR_TEX + x) * 4;
                    cursor_pix[off + 0] = (uint8) (px & 0xFF);
                    cursor_pix[off + 1] = (uint8) ((px >> 8) & 0xFF);
                    cursor_pix[off + 2] = (uint8) ((px >> 16) & 0xFF);
                    cursor_pix[off + 3] = (uint8) a;
                }
            }
            if (maxx >= minx && maxy >= miny) {
                cursor_min_x = minx;
                cursor_min_y = miny;
                cursor_bw = maxx - minx + 1;
                cursor_bh = maxy - miny + 1;
            }
            cursor_svg_ok = true;
        }

        public bool cursor_from_svg () {
            return cursor_svg_ok;
        }

        public int cursor_hotspot_x () { return cursor_hot_x; }
        public int cursor_hotspot_y () { return cursor_hot_y; }

        public int cursor_alpha (int x, int y) {
            if (!cursor_svg_ok || x < 0 || y < 0 || x >= CURSOR_TEX || y >= CURSOR_TEX)
                return 0;
            return (int) cursor_pix[(y * CURSOR_TEX + x) * 4 + 3];
        }

        private void init_hw_cursor () {
            if ((Sys.gpu_info () & 1) == 0)
                return;
            if (cursor_svg_ok) {
                if (Sys.gpu_cursor_set (cursor_pix, cursor_hot_x, cursor_hot_y) == 0)
                    hw_cursor = true;
                return;
            }
            var cb = new uint8[16384]; // 64x64 BGRA
            // Crisp 12x18 arrow cursor with 1px dark outline
            for (int y = 0; y < 18; y++) {
                int span = (y < 12) ? (y + 1) : ((y == 12) ? 6 : (y - 7));
                if (y >= 13)
                    span = 4;
                int x0 = (y >= 13) ? (y - 9) : 0;
                int x1 = (y >= 13) ? (x0 + span) : span;
                for (int x = x0; x < x1 && x < 64; x++) {
                    bool edge = (x == x0 || x == x1 - 1 || y == 0 || y == 17 || (y == 11 && x >= 5));
                    int off = (y * 64 + x) * 4;
                    if (edge) {
                        cb[off + 0] = 20; cb[off + 1] = 24; cb[off + 2] = 36; cb[off + 3] = 255;
                    } else {
                        cb[off + 0] = 255; cb[off + 1] = 252; cb[off + 2] = 248; cb[off + 3] = 255;
                    }
                }
            }
            if (Sys.gpu_cursor_set (cb, 0, 0) == 0)
                hw_cursor = true;
        }

        public void attach (Window w, bool use_hw_cursor = false) {
            screen = w;
            frame_cr = null;
            attached = true;
            if (use_hw_cursor)
                init_hw_cursor ();
        }

        // Which pointer path is in use: the compositor draws the cursor into the
        // framebuffer unless the GPU takes it over.
        public bool hardware_cursor () {
            return hw_cursor;
        }

        public void shutdown () {
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive)
                    continue;
                if (w.kind == Kind.TERMINAL && w.term != null)
                    w.term.cancel_proc ();
                if (w.kind == Kind.EXT) {
                    if (w.ext_tid > 0) {
                        Sys.kill (w.ext_tid);
                        w.ext_tid = -1;
                    }
                    if (w.ext_file.length > 0) {
                        Sys.unlink (w.ext_file);
                        w.ext_file = "";
                    }
                    if (w.ext_ev_file.length > 0) {
                        Sys.unlink (w.ext_ev_file);
                        w.ext_ev_file = "";
                    }
                }
                release_shared (w);
            }
            frame_cr = null;
            if (attached)
                screen.close ();
        }

        public bool frame () {
            mods = Sys.key_mods ();
            bool had_motion = false;
            int mot_x = 0;
            int mot_y = 0;
            for (int i = 0; i < 32; i++) {
                var ev = screen.poll_event ();
                if (ev.type == EventType.NONE)
                    break;
                if (ev.type == EventType.KEY_PRESS) {
                    if (had_motion) {
                        pointer_motion (mot_x, mot_y);
                        had_motion = false;
                    }
                    key_press_mod (ev.keyval, mods);
                } else if (ev.type == EventType.BUTTON_PRESS) {
                    if (had_motion) {
                        pointer_motion (mot_x, mot_y);
                        had_motion = false;
                    }
                    pointer_press (ev.x, ev.y);
                } else if (ev.type == EventType.BUTTON_RELEASE) {
                    if (had_motion) {
                        pointer_motion (mot_x, mot_y);
                        had_motion = false;
                    }
                    pointer_release ();
                } else if (ev.type == EventType.MOTION_NOTIFY) {
                    mot_x = ev.x;
                    mot_y = ev.y;
                    had_motion = true;
                } else if (ev.type == EventType.SCROLL) {
                    if (had_motion) {
                        pointer_motion (mot_x, mot_y);
                        had_motion = false;
                    }
                    pointer_scroll (ev.x, ev.y, ev.scroll_dx, ev.scroll_dy);
                }
            }
            if (had_motion)
                pointer_motion (mot_x, mot_y);
            if (dragging) {
                if ((screen.pointer_mask () & 1) == 0)
                    pointer_release ();
                else
                    drag_to (screen.pointer_x (), screen.pointer_y ());
            }
            int mx = screen.pointer_x ();
            int my = screen.pointer_y ();
            if (anim_on && pattern_ok) {
                int now = Sys.ticks ();
                if (now - last_anim_tick >= (anim_period_ms / 10)) {
                    last_anim_tick = now;
                    animate_pattern ((double) (now % 800) / 100.0);
                }
            }
            // Sampling the header costs a few loads in shared memory, so it runs
            // every frame: the old file transport had to skip frames to amortise
            // its open/read/close syscalls, which added up to two frames of input
            // latency.
            poll_ext ();
            animate_damage (mx, my);
            bool was_full = dmg_full;
            last_n = ndmg;
            last_full = was_full;
            for (int i = 0; i < ndmg * 4; i++)
                last[i] = dmg[i];
            if (last_full || last_n > 0)
                dirty_frames = dirty_frames + 1;
            int t_flush0 = Sys.ticks ();
            // The surface is created once per Window, so the drawing context
            // can be reused instead of allocated (and finalised) every frame.
            Context cr = frame_cr ?? new Context (screen.surface);
            frame_cr = cr;
            flush (cr, mx, my);
            flush_ticks = flush_ticks + (Sys.ticks () - t_flush0);
            int t_blit0 = Sys.ticks ();
            if (was_full) {
                screen.present ();
            } else {
                for (int i = 0; i < last_n; i++)
                    screen.present_rect (last[i * 4 + 0], last[i * 4 + 1], last[i * 4 + 2], last[i * 4 + 3]);
            }
            blit_ticks = blit_ticks + (Sys.ticks () - t_blit0);
            frames = frames + 1;
            return !quit;
        }

        // --- damage tracking ------------------------------------------

        public void damage (int x, int y, int w, int h) {
            if (dmg_full || w <= 0 || h <= 0)
                return;
            if (x < 0) {
                w = w + x;
                x = 0;
            }
            if (y < 0) {
                h = h + y;
                y = 0;
            }
            if (x + w > SCREEN_W)
                w = SCREEN_W - x;
            if (y + h > SCREEN_H)
                h = SCREEN_H - y;
            if (w <= 0 || h <= 0)
                return;
            // Merge with a nearby rectangle: the cursor, the clock hands and its
            // digital readout usually collapse into a single repaint.
            for (int i = 0; i < ndmg; i++) {
                int ex = dmg[i * 4 + 0];
                int ey = dmg[i * 4 + 1];
                int ew = dmg[i * 4 + 2];
                int eh = dmg[i * 4 + 3];
                if (x < ex + ew + 8 && x + w + 8 > ex && y < ey + eh + 8 && y + h + 8 > ey) {
                    int nx = (x < ex) ? x : ex;
                    int ny = (y < ey) ? y : ey;
                    int nx1 = (x + w > ex + ew) ? x + w : ex + ew;
                    int ny1 = (y + h > ey + eh) ? y + h : ey + eh;
                    dmg[i * 4 + 0] = nx;
                    dmg[i * 4 + 1] = ny;
                    dmg[i * 4 + 2] = nx1 - nx;
                    dmg[i * 4 + 3] = ny1 - ny;
                    return;
                }
            }
            if (ndmg >= DMG_RECTS - 1) {
                dmg_full = true;
                ndmg = 0;
                return;
            }
            dmg[ndmg * 4 + 0] = x;
            dmg[ndmg * 4 + 1] = y;
            dmg[ndmg * 4 + 2] = w;
            dmg[ndmg * 4 + 3] = h;
            ndmg = ndmg + 1;
        }

        public void damage_window (int id) {
            var w = find (id);
            if (w == null)
                return;
            damage (w.x - 2, w.y - 2, w.w + SHADOW + 4, w.h + SHADOW + 4);
        }

        public void damage_full () {
            dmg_full = true;
            ndmg = 0;
        }

        public bool damage_is_full () { return dmg_full; }
        public int damage_count () { return ndmg; }

        private void clear_damage () {
            ndmg = 0;
            dmg_full = false;
        }

        public int damage_pixels () {
            if (dmg_full)
                return SCREEN_W * SCREEN_H;
            int total = 0;
            for (int i = 0; i < ndmg; i++)
                total = total + dmg[i * 4 + 2] * dmg[i * 4 + 3];
            return total;
        }

        // Repaints only the pending damage regions; every draw is clipped, so
        // the cost of a frame is proportional to what actually changed.
        public void flush (Context cr, int mx, int my) {
            if (!dmg_full && ndmg == 0)
                return;
            if (!dmg_full && ndmg > 1) {
                int dmg_px = 0;
                for (int i = 0; i < ndmg; i++) {
                    dmg_px += dmg[i * 4 + 2] * dmg[i * 4 + 3];
                }
                if (dmg_px * 2 >= SCREEN_W * SCREEN_H) {
                    dmg_full = true;
                }
            }
            if (dmg_full) {
                cr.reset_clip ();
                render (cr, mx, my);
                clear_damage ();
                return;
            }
            for (int i = 0; i < ndmg; i++) {
                int x = dmg[i * 4 + 0];
                int y = dmg[i * 4 + 1];
                int w = dmg[i * 4 + 2];
                int h = dmg[i * 4 + 3];
                cr.save ();
                cr.rectangle (x, y, w, h);
                cr.clip ();
                render (cr, mx, my);
                cr.restore ();
            }
            clear_damage ();
        }

        private void damage_cursor_at (int mx, int my) {
            if (cursor_svg_ok) {
                int x = mx - cursor_hot_x + cursor_min_x - 2;
                int y = my - cursor_hot_y + cursor_min_y - 2;
                damage (x, y, cursor_bw + 4, cursor_bh + 4);
            } else {
                damage (mx - 2, my - 2, 16, 22);
            }
        }

        private void animate_damage (int mx, int my) {
            if (mx != last_mx || my != last_my) {
                motions = motions + 1;
                if (hw_cursor && Sys.gpu_cursor_move (mx, my) != 0) {
                    // The host refused the cursor update (no cursorq support,
                    // or the queue timed out): stop relying on it and draw the
                    // pointer ourselves from now on.
                    hw_cursor = false;
                    damage_cursor_at (last_mx, last_my);
                    damage_cursor_at (mx, my);
                } else if (!hw_cursor) {
                    damage_cursor_at (last_mx, last_my);
                    damage_cursor_at (mx, my);
                }
                last_mx = mx;
                last_my = my;
            }
            // The analog clock and the seconds readout only change once per
            // second, so an idle desktop produces no damage at all.
            int sec = Sys.ticks () / 100;
            if (sec == last_sec)
                return;
            last_sec = sec;
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive)
                    continue;
                if (w.kind == Kind.CALENDAR) {
                    // The header carries the seconds readout.
                    int kx = w.x + BORDER;
                    int ky = w.content_y ();
                    damage (kx, ky, w.w - 2 * BORDER, w.content_h ());
                    continue;
                }
                if (w.kind != Kind.CLOCK)
                    continue;
                int cx = w.x + BORDER;
                int cy = w.content_y ();
                int cw = w.w - 2 * BORDER;
                int ch = w.content_h ();
                int rad = clock_radius (cw, ch);
                int ccx = cx + cw / 2;
                int ccy = cy + ch / 2;
                damage (ccx - rad - 2, ccy - rad - 2, rad * 2 + 4, rad * 2 + 4);
                damage (cx, cy + ch - 30, cw, 30);
            }
            damage (SCREEN_W - 440, 0, 440, TOP_H);
            damage (SCREEN_W - 180, SCREEN_H - DOCK_H, 180, DOCK_H);
        }

        // Culling: a window (or a bar) that does not touch the current clip is
        // skipped entirely, so repainting one damage rect costs only that rect.
        private static bool rect_hits (Context cr, int x, int y, int w, int h) {
            if (x + w <= cr.clip_left () || x >= cr.clip_right ())
                return false;
            if (y + h <= cr.clip_top () || y >= cr.clip_bottom ())
                return false;
            return true;
        }

        public int frame_count () { return frames; }
        public int dirty_frame_count () { return dirty_frames; }
        public int motion_count () { return motions; }
        public int avg_flush_ms () { return (dirty_frames > 0) ? (flush_ticks * 10 / dirty_frames) : 0; }
        public int avg_blit_ms () { return (dirty_frames > 0) ? (blit_ticks * 10 / dirty_frames) : 0; }
        public bool quit_requested () { return quit; }
        public bool dragging_active () { return dragging; }
        public int focus_id () { return focused_id; }
        public int accent_ir () { return (int) (acc_r * 255.0); }
        public int accent_ig () { return (int) (acc_g * 255.0); }
        public int accent_ib () { return (int) (acc_b * 255.0); }
        public bool shader_valid () { return shader_ok; }
        public int shader_words () { return shader.words; }
        public int shader_insns () { return shader.insns; }

        // --- model ----------------------------------------------------

        public int count () {
            int n = 0;
            for (int i = 0; i < wins.length; i++) {
                if (wins[i].alive)
                    n = n + 1;
            }
            return n;
        }

        public Win? find (int id) {
            for (int i = 0; i < wins.length; i++) {
                if (wins[i].id == id)
                    return wins[i];
            }
            return null;
        }

        public Win? nth (int idx) {
            int n = 0;
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive)
                    continue;
                if (n == idx)
                    return w;
                n = n + 1;
            }
            return null;
        }

        public Win? top_win () {
            Win? best = null;
            int bestz = -1;
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive)
                    continue;
                if (w.z > bestz) {
                    bestz = w.z;
                    best = w;
                }
            }
            return best;
        }

        public Win? top_at (int px, int py) {
            Win? best = null;
            int bestz = -1;
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive)
                    continue;
                if (!w.contains (px, py))
                    continue;
                if (w.z > bestz) {
                    bestz = w.z;
                    best = w;
                }
            }
            return best;
        }

        public int wx (int id) { int v = 0; var w = find (id); if (w != null) v = w.x; return v; }
        public int wy (int id) { int v = 0; var w = find (id); if (w != null) v = w.y; return v; }
        public int ww (int id) { int v = 0; var w = find (id); if (w != null) v = w.w; return v; }
        public int wh (int id) { int v = 0; var w = find (id); if (w != null) v = w.h; return v; }
        public bool alive (int id) { var w = find (id); return (w != null) ? w.alive : false; }
        public bool maximized (int id) { var w = find (id); return (w != null) ? w.maximized : false; }

        public int add (string title, int x, int y, int w, int h, Kind kind) {
            var win = new Win (next_id, title, x, y, w, h, kind);
            next_id = next_id + 1;
            ztop = ztop + 1;
            win.z = ztop;
            wins.add (win);
            focused_id = win.id;
            damage_full ();
            return win.id;
        }

        public void raise (int id) {
            var w = find (id);
            if (w == null)
                return;
            ztop = ztop + 1;
            w.z = ztop;
            damage_full ();
        }

        public void focus (int id) {
            if (find (id) == null)
                return;
            focused_id = id;
            raise (id);
        }

        public void close_win (int id) {
            var w = find (id);
            if (w == null)
                return;
            if (w.kind == Kind.TERMINAL && w.term != null)
                w.term.cancel_proc ();
            if (w.kind == Kind.EXT) {
                // Keep ext_tid: the reaper releases the shared block only after
                // the child actually stopped, because it still maps those frames.
                if (w.ext_tid > 0)
                    Sys.kill (w.ext_tid);
                if (w.ext_file.length > 0) {
                    Sys.unlink (w.ext_file);
                    w.ext_file = "";
                }
                if (w.ext_ev_file.length > 0) {
                    Sys.unlink (w.ext_ev_file);
                    w.ext_ev_file = "";
                }
            }
            w.alive = false;
            if (focused_id == id) {
                focused_id = 0;
                var t = top_win ();
                if (t != null)
                    focused_id = t.id;
            }
            damage_full ();
        }

        public void cycle () {
            int curz = -1;
            var cur = find (focused_id);
            if (cur != null)
                curz = cur.z;
            int nextz = -1;
            int nextid = 0;
            int lowz = -1;
            int lowid = 0;
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive || w.id == focused_id)
                    continue;
                if (lowz < 0 || w.z < lowz) {
                    lowz = w.z;
                    lowid = w.id;
                }
                if (w.z > curz && (nextz < 0 || w.z < nextz)) {
                    nextz = w.z;
                    nextid = w.id;
                }
            }
            if (nextid != 0)
                focus (nextid);
            else if (lowid != 0)
                focus (lowid);
        }

        public void focus_nth (int idx) {
            var w = nth (idx);
            if (w != null)
                focus (w.id);
        }

        public void maximize (int id) {
            var w = find (id);
            if (w == null)
                return;
            if (w.layout_state == LAYOUT_MAX) {
                restore_layout (id);
                return;
            }
            if (w.layout_state == LAYOUT_NORMAL) {
                w.rx = w.x;
                w.ry = w.y;
                w.rw = w.w;
                w.rh = w.h;
            }
            w.x = 0;
            w.y = TOP_H;
            w.w = SCREEN_W;
            w.h = WORK_H;
            w.maximized = true;
            w.layout_state = LAYOUT_MAX;
            damage_full ();
        }

        // Gala/GNOME-style tiling: Super+Left/Right fill half the work area.
        public void snap (int id, int side) {
            var w = find (id);
            if (w == null)
                return;
            if (w.layout_state == side) {
                restore_layout (id);
                return;
            }
            if (w.layout_state == LAYOUT_NORMAL) {
                w.rx = w.x;
                w.ry = w.y;
                w.rw = w.w;
                w.rh = w.h;
            }
            w.w = SCREEN_W / 2;
            w.h = WORK_H;
            w.y = TOP_H;
            w.x = (side == LAYOUT_RIGHT) ? SCREEN_W / 2 : 0;
            w.maximized = true;
            w.layout_state = side;
            damage_full ();
        }

        public void restore_layout (int id) {
            var w = find (id);
            if (w == null)
                return;
            if (w.layout_state == LAYOUT_NORMAL)
                return;
            w.x = w.rx;
            w.y = w.ry;
            w.w = w.rw;
            w.h = w.rh;
            w.maximized = false;
            w.layout_state = LAYOUT_NORMAL;
            damage_full ();
        }

        public int layout_of (int id) {
            var w = find (id);
            return (w != null) ? w.layout_state : LAYOUT_NORMAL;
        }

        public int clamp_x (int x, int w) {
            int minx = -(w - 80);
            if (x < minx)
                return minx;
            if (x > SCREEN_W - 80)
                return SCREEN_W - 80;
            return x;
        }

        public int clamp_y (int y, int h) {
            if (y < TOP_H)
                return TOP_H;
            if (y > SCREEN_H - DOCK_H - 24)
                return SCREEN_H - DOCK_H - 24;
            return y;
        }

        public void move_by (int id, int dx, int dy) {
            var w = find (id);
            if (w == null || w.maximized)
                return;
            damage_window (id);
            w.x = clamp_x (w.x + dx, w.w);
            w.y = clamp_y (w.y + dy, w.h);
            damage_window (id);
        }

        // --- input ----------------------------------------------------

        public int launch_gui_app (string exec_path, string title, int w, int h) {
            int id = add (title, 110, 84, w, h, Kind.EXT);
            var win = find (id);
            if (win != null) {
                Sys.mkdir ("/tmp");
                win.ext_seq = 0;
                int cw = w - BORDER * 2;
                int ch = h - BORDER * 2 - TITLE_H;
                if (cw < 64) cw = 64;
                if (ch < 64) ch = 64;
                Sys.setenv ("PLANET_WIN_W", @"$cw");
                Sys.setenv ("PLANET_WIN_H", @"$ch");
                if (attach_shared_surface (id, 0, cw, ch)) {
                    // The client draws straight into the shared block and the
                    // input ring lives in the same header, so neither the frame
                    // nor an event needs a file.
                    Sys.unsetenv ("PLANET_WIN_FILE");
                    Sys.unsetenv ("PLANET_WIN_EV");
                    Sys.setenv ("PLANET_WIN_SHM", @"$(win.ext_shm)");
                } else {
                    Sys.unsetenv ("PLANET_WIN_SHM");
                    win.ext_file = @"/tmp/_comp_w$id.argb";
                    win.ext_ev_file = @"/tmp/_comp_e$id.evt";
                    Sys.setenv ("PLANET_WIN_FILE", win.ext_file);
                    Sys.setenv ("PLANET_WIN_EV", win.ext_ev_file);
                }
                win.ext_tid = Sys.spawn (exec_path, "");
                // A2: the client may map the surface only because this grant
                // lists it; the address in PLANET_WIN_SHM is just a hint.
                if (win.ext_tid > 0 && win.ext_grant > 0)
                    Sys.grant_share (win.ext_grant, win.ext_tid);
            }
            return id;
        }

        // Allocates (base == 0) or adopts (base != 0) the block a client draws
        // into: one 4 KiB header page plus w*h*4 pixel bytes, identity mapped so
        // the client can attach it with SYS_MAP_USER_AT. A caller-supplied base
        // is what the self-test uses to feed a surface it owns.
        public bool attach_shared_surface (int id, int shm_base, int w, int h) {
            var win = find (id);
            if (win == null || w < 64 || h < 64)
                return false;
            int bytes = SharedSurface.bytes_for (w, h);
            int pages = SharedSurface.pages_for (w, h);
            if (bytes <= 0 || pages <= 0 || pages > 1024)
                return false;
            int shm = shm_base;
            if (shm == 0) {
                shm = Sys.alloc_pages (pages);
                if (shm <= 0)
                    return false;
            } else if (Sys.map_user_at (shm, bytes) != 0) {
                return false;
            }
            Unsafe.poke32 (shm + SharedSurface.OFF_MAGIC, SharedSurface.MAGIC);
            Unsafe.poke32 (shm + SharedSurface.OFF_WIDTH, w);
            Unsafe.poke32 (shm + SharedSurface.OFF_HEIGHT, h);
            Unsafe.poke32 (shm + SharedSurface.OFF_SEQ, 0);
            Unsafe.poke32 (shm + SharedSurface.OFF_DX, 0);
            Unsafe.poke32 (shm + SharedSurface.OFF_DY, 0);
            Unsafe.poke32 (shm + SharedSurface.OFF_DW, w);
            Unsafe.poke32 (shm + SharedSurface.OFF_DH, h);
            Unsafe.poke32 (shm + SharedSurface.OFF_DCOUNT, 1);
            Unsafe.poke32 (shm + SharedSurface.OFF_EV_SEQ, 0);
            Unsafe.poke32 (shm + SharedSurface.OFF_EV_ACK, 0);
            win.ext_shm = shm;
            win.ext_shm_px = shm + SharedSurface.pixel_offset ();
            win.ext_shm_pages = pages;
            // A2: the frames are ours, so they can be granted. The client maps
            // them through the ACL instead of naming a physical address.
            win.ext_grant = Sys.grant (shm, bytes);
            if (win.ext_grant > 0 && win.ext_tid > 0)
                Sys.grant_share (win.ext_grant, win.ext_tid);
            win.ext_shm_surf = new ImageSurface.wrap (win.ext_shm_px, w, h);
            win.ext_seq = 0;
            return true;
        }

        // Frees the frames of a window that no longer draws. The client must be
        // gone first: it keeps the same physical pages mapped in its own CR3.
        private void release_shared (Win w) {
            // The grant goes first: the kernel refuses to free frames a live
            // capability still covers.
            if (w.ext_grant > 0)
                Sys.close (w.ext_grant);
            w.ext_grant = 0;
            for (int p = 0; p < w.ext_shm_pages; p++)
                Sys.free_page (w.ext_shm + p * 4096);
            w.ext_shm = 0;
            w.ext_shm_px = 0;
            w.ext_shm_pages = 0;
            w.ext_shm_surf = null;
        }

        // Reclaims blocks whose window is closed once the child stopped running.
        private void reap_shared_surfaces () {
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (w.alive || w.ext_shm == 0)
                    continue;
                if (w.ext_tid > 0) {
                    if (Sys.wait_nb (w.ext_tid) == -2)
                        continue;
                    w.ext_tid = -1;
                }
                release_shared (w);
            }
        }

        // Damages only the rectangle the client published, so a keystroke
        // repaints one editor line instead of the whole window frame.
        private void damage_content (Win w, int dx, int dy, int dw, int dh) {
            damage (w.x + BORDER + dx, w.content_y () + dy, dw, dh);
        }

        private void poll_shared_surface (Win w) {
            int shm = w.ext_shm;
            if (Unsafe.peek32 (shm + SharedSurface.OFF_MAGIC) != SharedSurface.MAGIC)
                return;
            int seq = Unsafe.peek32 (shm + SharedSurface.OFF_SEQ);
            if (seq == 0 || seq == w.ext_seq)
                return;
            Unsafe.mfence ();
            w.ext_seq = seq;
            int n = Unsafe.peek32 (shm + SharedSurface.OFF_DCOUNT);
            if (n <= 0 || n > SharedSurface.MAX_RECTS)
                n = 1;
            for (int i = 0; i < n; i++) {
                int off = shm + SharedSurface.rect_off (i);
                int dx = Unsafe.peek32 (off + 0);
                int dy = Unsafe.peek32 (off + 4);
                int dw = Unsafe.peek32 (off + 8);
                int dh = Unsafe.peek32 (off + 12);
                if (dx < 0) {
                    dw = dw + dx;
                    dx = 0;
                }
                if (dy < 0) {
                    dh = dh + dy;
                    dy = 0;
                }
                if (w.ext_shm_surf != null) {
                    if (dx + dw > w.ext_shm_surf.width)
                        dw = w.ext_shm_surf.width - dx;
                    if (dy + dh > w.ext_shm_surf.height)
                        dh = w.ext_shm_surf.height - dy;
                }
                if (dw <= 0 || dh <= 0)
                    continue;
                w.ext_rects = w.ext_rects + 1;
                w.ext_damage_px = w.ext_damage_px + dw * dh;
                w.ext_last_dx = dx;
                w.ext_last_dy = dy;
                w.ext_last_dw = dw;
                w.ext_last_dh = dh;
                damage_content (w, dx, dy, dw, dh);
            }
        }

        // Polls every client surface once; the frame loop and the self-test share
        // this entry point so both observe exactly the same protocol.
        public void poll_ext () {
            poll_ext_surfaces ();
            reap_shared_surfaces ();
        }

        private static int le32 (uint8[] b, int off) {
            return ((int) b[off]) | (((int) b[off + 1]) << 8)
                | (((int) b[off + 2]) << 16) | (((int) b[off + 3]) << 24);
        }

        private void poll_ext_surfaces () {
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive)
                    continue;
                if (w.kind == Kind.TERMINAL && w.term != null && w.term.busy ()) {
                    if (w.term.poll_proc ())
                        damage_window (w.id);
                }
                if (w.kind != Kind.EXT || (w.ext_file.length == 0 && w.ext_shm == 0))
                    continue;
                if (w.ext_tid > 0) {
                    int rc = Sys.wait_nb (w.ext_tid);
                    if (rc != -2)
                        w.ext_tid = -1;
                }
                if (w.ext_shm != 0) {
                    poll_shared_surface (w);
                    continue;
                }
                int fd = Sys.open (w.ext_file);
                if (fd < 0)
                    continue;
                int hn = Sys.read (fd, ext_hdr, 16);
                if (hn == 16 && le32 (ext_hdr, 0) == 0x5057494E) {
                    int sw = le32 (ext_hdr, 4);
                    int sh = le32 (ext_hdr, 8);
                    int seq = le32 (ext_hdr, 12);
                    if (seq != 0 && seq != w.ext_seq && sw >= 64 && sw <= SCREEN_W && sh >= 64 && sh <= SCREEN_H) {
                        if (w.ext_surf == null || w.ext_surf.width != sw || w.ext_surf.height != sh)
                            w.ext_surf = new ImageSurface (Format.ARGB32, sw, sh);
                        int total = sw * sh * 4;
                        int off = 0;
                        while (off < total) {
                            int chunk = total - off;
                            if (chunk > 65536)
                                chunk = 65536;
                            int r = Sys.sys (7, fd, w.ext_surf.buf_addr + off, chunk);
                            if (r <= 0)
                                break;
                            off = off + r;
                        }
                        if (off == total) {
                            w.ext_seq = seq;
                            damage_window (w.id);
                        }
                    }
                }
                Sys.close (fd);
            }
        }

        private void flush_pending_gui (Win w) {
            if (w.pcm4_state != null && w.pcm4_state.want_gui_exec.length > 0) {
                string ex = w.pcm4_state.want_gui_exec;
                string tt = w.pcm4_state.want_gui_title;
                int gw = w.pcm4_state.want_gui_w;
                int gh = w.pcm4_state.want_gui_h;
                w.pcm4_state.want_gui_exec = "";
                if (ex == "pcm4.elf")
                    add ("pcm4", 130, 96, 680, 400, Kind.FILES);
                else
                    launch_gui_app (ex, tt, gw, gh);
            }
        }

        public int pointer_press (int px, int py) {
            if (py >= SCREEN_H - DOCK_H)
                return dock_press (px);
            var w = top_at (px, py);
            if (w == null)
                return ACT_NONE;
            int id = w.id;
            if (w.in_close (px, py)) {
                close_win (id);
                return ACT_CLOSE;
            }
            if (w.in_max (px, py)) {
                focus (id);
                maximize (id);
                return ACT_MAXIMIZE;
            }
            focus (id);
            last_ptr_x = px;
            last_ptr_y = py;
            if (w.in_title (px, py) && !w.maximized) {
                dragging = true;
                drag_id = id;
                drag_ox = px - w.x;
                drag_oy = py - w.y;
                return ACT_DRAG;
            }
            if (w.in_resize (px, py)) {
                resizing = true;
                resize_id = id;
                return ACT_DRAG;
            }
            if ((w.kind == Kind.GTK || w.kind == Kind.FILES) && w.gtk_root != null) {
                if (w.gtk_root.on_pointer_press (px, py, 1)) {
                    flush_pending_gui (w);
                    damage_window (id);
                }
            }
            if (w.kind == Kind.TERMINAL && w.term != null) {
                w.term.active = true;
                damage_window (id);
            }
            if (w.kind == Kind.EXT) {
                w.push_ext_event (2, px - (w.x + BORDER), py - w.content_y (), 1);
            }
            return ACT_FOCUS;
        }

        public void drag_to (int px, int py) {
            if (!dragging)
                return;
            var w = find (drag_id);
            if (w == null) {
                dragging = false;
                return;
            }
            damage_window (drag_id);
            w.x = clamp_x (px - drag_ox, w.w);
            w.y = clamp_y (py - drag_oy, w.h);
            damage_window (drag_id);
        }

        public void pointer_motion (int px, int py) {
            last_ptr_x = px;
            last_ptr_y = py;
            if (dragging) {
                drag_to (px, py);
                return;
            }
            if (resizing) {
                var rw = find (resize_id);
                if (rw != null && !rw.maximized) {
                    damage_window (resize_id);
                    int nw = px - rw.x;
                    int nh = py - rw.y;
                    if (nw < 220) nw = 220;
                    if (nh < 140) nh = 140;
                    if (rw.x + nw > SCREEN_W) nw = SCREEN_W - rw.x;
                    if (rw.y + nh > SCREEN_H - DOCK_H) nh = SCREEN_H - DOCK_H - rw.y;
                    rw.w = nw;
                    rw.h = nh;
                    damage_window (resize_id);
                }
                return;
            }
            var fw = find (focused_id);
            if (fw != null && (fw.kind == Kind.GTK || fw.kind == Kind.FILES) && fw.gtk_root != null) {
                if (fw.gtk_root.on_pointer_motion (px, py))
                    damage_window (fw.id);
            } else if (fw != null && fw.kind == Kind.EXT) {
                // The shared ring takes every sample; the file transport still
                // skips alternate frames to halve its syscalls.
                if (fw.ext_shm != 0 || (frames & 1) == 0) {
                    if (px >= fw.x + BORDER && px < fw.x + fw.w - BORDER
                        && py >= fw.content_y () && py < fw.y + fw.h - BORDER) {
                        fw.push_ext_event (4, px - (fw.x + BORDER), py - fw.content_y (), 0);
                    }
                }
            }
        }

        public void pointer_scroll (int px, int py, int dx, int dy) {
            var w = top_at (px, py);
            if (w == null)
                return;
            if ((w.kind == Kind.GTK || w.kind == Kind.FILES) && w.gtk_root != null) {
                if (w.gtk_root.on_scroll (px, py, dx, dy))
                    damage_window (w.id);
            } else if (w.kind == Kind.TERMINAL && w.term != null) {
                if (w.term.on_scroll (dy))
                    damage_window (w.id);
            } else if (w.kind == Kind.EXT) {
                w.push_ext_event (5, px - (w.x + BORDER), py - w.content_y (), ((dx & 0xFFFF) << 16) | (dy & 0xFFFF));
            }
        }

        public void pointer_release () {
            dragging = false;
            drag_id = 0;
            resizing = false;
            resize_id = 0;
            var fw = find (focused_id);
            if (fw != null && (fw.kind == Kind.GTK || fw.kind == Kind.FILES) && fw.gtk_root != null) {
                if (fw.gtk_root.on_pointer_release (last_ptr_x, last_ptr_y, 1))
                    damage_window (fw.id);
            } else if (fw != null && fw.kind == Kind.EXT) {
                fw.push_ext_event (3, last_ptr_x - (fw.x + BORDER), last_ptr_y - fw.content_y (), 1);
            }
        }

        public int dock_index_at (int px) {
            int slot = DOCK_BTN_W + DOCK_BTN_GAP;
            if (px < DOCK_X0)
                return -1;
            int idx = (px - DOCK_X0) / slot;
            if ((px - DOCK_X0) % slot >= DOCK_BTN_W)
                return -1;
            return idx;
        }

        private int dock_press (int px) {
            int idx = dock_index_at (px);
            if (idx < 0)
                return ACT_NONE;
            var w = nth (idx);
            if (w == null)
                return ACT_NONE;
            focus (w.id);
            return ACT_DOCK;
        }

        public void key_press (int k) {
            key_press_mod (k, mods);
        }

        // Alt+Tab cycles, Alt+Q closes, Super+arrows maximize/tile/restore.
        public void key_press_mod (int k, int m) {
            bool alt = (m & Sys.MOD_ALT) != 0;
            bool super = (m & Sys.MOD_SUPER) != 0;
            if (super && (k == 0x83 || k == 'h')) {
                if (focused_id != 0)
                    snap (focused_id, LAYOUT_LEFT);
                return;
            }
            if (super && (k == 0x84 || k == 'l')) {
                if (focused_id != 0)
                    snap (focused_id, LAYOUT_RIGHT);
                return;
            }
            if (super && (k == 0x81 || k == 'k')) {
                if (focused_id != 0)
                    maximize (focused_id);
                return;
            }
            if (super && (k == 0x82 || k == 'j')) {
                if (focused_id != 0)
                    restore_layout (focused_id);
                return;
            }
            if (alt && k == 9) {
                cycle ();
                return;
            }
            if (alt && (k == 'q' || k == 'Q')) {
                close_win (focused_id);
                return;
            }
            // Calendar month navigation: [ previous, ] next, t today.
            var cal_win = find (focused_id);
            if (cal_win != null && cal_win.kind == Kind.CALENDAR) {
                if (k == '[' || k == ',') {
                    calendar_shift (cal_win, -1);
                    return;
                }
                if (k == ']' || k == '.') {
                    calendar_shift (cal_win, 1);
                    return;
                }
                if (k == 't' || k == 'T') {
                    calendar_reset (cal_win);
                    return;
                }
            }
            if (k == 27) {
                quit = true;
                return;
            }
            var fw = find (focused_id);
            if (fw != null && (fw.kind == Kind.GTK || fw.kind == Kind.FILES) && fw.gtk_root != null) {
                if (fw.gtk_root.on_key_press (k)) {
                    flush_pending_gui (fw);
                    damage_window (fw.id);
                    return;
                }
            }
            if (fw != null && fw.kind == Kind.TERMINAL && fw.term != null) {
                if (fw.term.on_key_press (k)) {
                    if (fw.term.want_pcm4) {
                        fw.term.want_pcm4 = false;
                        add ("pcm4", 120, 90, 680, 400, Kind.FILES);
                    }
                    if (fw.term.want_gui_exec.length > 0) {
                        string ex = fw.term.want_gui_exec;
                        string tt = fw.term.want_gui_title;
                        fw.term.want_gui_exec = "";
                        int gw = (ex == "saturn.elf") ? 720 : ((ex == "doom.elf") ? 648 : 560);
                        int gh = (ex == "saturn.elf") ? 460 : ((ex == "doom.elf") ? 432 : 380);
                        launch_gui_app (ex, tt, gw, gh);
                    }
                    damage_window (fw.id);
                    return;
                }
            }
            if (fw != null && fw.kind == Kind.EXT) {
                fw.push_ext_event (1, k, m, 0);
                return;
            }
            if (k == 'q' || k == 'Q') {
                quit = true;
                return;
            }
            if (k == 'f' || k == 'F') {
                add ("pcm4", 120, 90, 680, 400, Kind.FILES);
                return;
            }
            if (k == 'g' || k == 'G') {
                add ("gtk-demo", 140, 110, 380, 230, Kind.GTK);
                return;
            }
            if (k == 'a' || k == 'A') {
                add ("calendar", 120, 90, 340, 300, Kind.CALENDAR);
                return;
            }
            if (k == 'b' || k == 'B') {
                add ("places", 140, 120, 400, 150, Kind.PLACES);
                return;
            }
            if (k == 9) {
                cycle ();
                return;
            }
            if (k == 'c' || k == 'C') {
                close_win (focused_id);
                return;
            }
            if (k == 'm' || k == 'M') {
                if (focused_id != 0)
                    maximize (focused_id);
                return;
            }
            if (k == 'n' || k == 'N') {
                add_demo ();
                return;
            }
            if (k >= '1' && k <= '9') {
                focus_nth (k - '1');
                return;
            }
            if (k == 0x81 || k == 'k') { move_by (focused_id, 0, -MOVE_STEP); return; }
            if (k == 0x82 || k == 'j') { move_by (focused_id, 0, MOVE_STEP); return; }
            if (k == 0x83 || k == 'h') { move_by (focused_id, -MOVE_STEP, 0); return; }
            if (k == 0x84 || k == 'l') { move_by (focused_id, MOVE_STEP, 0); return; }
        }

        // --- shader ---------------------------------------------------

        public int backend () { return backend_id; }

        public string gsk_backend () {
            return (gsk_renderer != null) ? gsk_renderer.backend_name () : "none";
        }

        public void render_gsk (RenderNode root, ImageSurface target) {
            if (gsk_renderer != null)
                gsk_renderer.render (root, target);
        }

        public void shutdown_gpu () {
            if (gsk_renderer is VulkanRenderer)
                ((VulkanRenderer) gsk_renderer).unrealize ();
        }

        // Vulkan backend seam. PlanetOS has no Vulkan ICD yet (decision D-13),
        // so selecting it fails and the caller stays on cairo/framebuffer. The
        // pieces a driver needs already exist: the ARGB surface this class
        // paints, the Spv.Module with the fragment pipeline, and the per-frame
        // window geometry/damage the scene is rebuilt from.
        public bool select_backend (int id) {
            if (id != BACKEND_CAIRO)
                return false;
            backend_id = id;
            return true;
        }

        public bool load_shader (string path) {
            shader = Module.load (path);
            shader_ok = shader.valid;
            if (!shader_ok)
                return false;
            acc_r = shader.r;
            acc_g = shader.g;
            acc_b = shader.b;
            return true;
        }

        // Bakes the per-pixel shader into coarse PAT_STEP blocks via Gsk.ShaderNode.
        public bool load_pattern (string path) {
            pattern = Module.load (path);
            if (!pattern.valid || !pattern.has_input ())
                return false;
            pattern_node = new ShaderNode (new Gsk.Rect (0, 0, SCREEN_W, SCREEN_H), pattern, pat_step);
            pattern_ok = true;
            bake_pattern (0.0);
            damage_full ();
            return true;
        }

        // Runs the fragment stage over every block sample with the current
        // push-constant values.
        public void bake_pattern (double time) {
            if (!pattern_ok || pattern_node == null)
                return;
            pattern_node.set_time (time);
            pattern_node.bake ();
        }

        // Re-bakes the background with a new time uniform. Only meaningful for
        // modules that read push constants; the whole screen has to repaint.
        public bool animate_pattern (double time) {
            if (!pattern_ok || !pattern.has_uniforms ())
                return false;
            bake_pattern (time);
            anim_count = anim_count + 1;
            damage_full ();
            return true;
        }

        public bool pattern_has_uniforms () { return pattern_ok && pattern.has_uniforms (); }
        public int pattern_step () { return pat_step; }

        // Coarser blocks trade detail for a cheaper bake (animated backgrounds).
        public void set_pattern_step (int step) {
            pat_step = (step < 2) ? 2 : ((step > 32) ? 32 : step);
            if (pattern_node != null)
                pattern_node.set_step (pat_step);
        }
        public int animation_count () { return anim_count; }

        public void set_animation (bool on, int period_ms) {
            anim_on = on;
            anim_period_ms = (period_ms < 40) ? 40 : period_ms;
        }

        public bool has_pattern () { return pattern_ok; }
        public int pattern_samples () { return (pattern_ok && pattern_node != null) ? pattern_node.baked_blocks () : 0; }

        public int pattern_at (int x, int y) {
            if (!pattern_ok || pattern_node == null)
                return 0;
            return pattern_node.color_at_pixel (x, y);
        }

        // --- scene ----------------------------------------------------

        public void seed () {
            TextHelper.load_ttf ("Tahoma.ttf");
            TextHelper.load_mono_ttf ("Consolas-Regular.ttf");
            add ("terminal", 48, 56, 560, 360, Kind.TERMINAL);
            add ("calendar", 880, 56, 340, 300, Kind.CALENDAR);
            focus_nth (0);
        }

        public int add_demo () {
            int n = count ();
            Kind k = Kind.NOTES;
            if (n % 4 == 0)
                k = Kind.TERMINAL;
            else if (n % 4 == 1)
                k = Kind.CLOCK;
            else if (n % 4 == 2)
                k = Kind.SHADER;
            string title = "notes";
            if (k == Kind.TERMINAL) title = "terminal";
            else if (k == Kind.CLOCK) title = "clock";
            else if (k == Kind.SHADER) title = "shader";
            int ox = 40 + (n % 6) * 34;
            int oy = TOP_H + 30 + (n % 6) * 26;
            return add (@"$title $(n + 1)", ox, oy, 340, 220, k);
        }

        // --- rendering ------------------------------------------------

        private static string pad2 (int n) {
            return (n < 10) ? @"0$(n)" : @"$(n)";
        }

        public void render (Context cr, int mx, int my) {
            occluded_skips = 0;
            bool bg_occluded = false;
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (w.alive && w.maximized) {
                    bg_occluded = true;
                    break;
                }
            }
            // A damage rectangle that lies inside an opaque window never shows
            // the desktop, so the gradient or the pattern blocks underneath are
            // painted and then completely covered: skip that pass.
            if (!bg_occluded)
                bg_occluded = clip_covered (cr);
            if (bg_occluded)
                bg_skips = bg_skips + 1;
            else
                draw_background (cr);
            draw_windows (cr);
            draw_dock (cr);
            draw_top_bar (cr);
            if (!hw_cursor)
                draw_cursor (cr, mx, my);
        }

        private bool clip_covered (Context cr) {
            int cx0 = cr.clip_left ();
            int cy0 = cr.clip_top ();
            int cx1 = cr.clip_right ();
            int cy1 = cr.clip_bottom ();
            if (cx1 <= cx0 || cy1 <= cy0)
                return false;
            for (int i = 0; i < wins.length; i++) {
                var w = wins[i];
                if (!w.alive)
                    continue;
                if (w.x <= cx0 && w.y <= cy0 && w.x + w.w >= cx1 && w.y + w.h >= cy1)
                    return true;
            }
            return false;
        }

        public int background_skips () { return bg_skips; }

        private void draw_background (Context cr) {
            if (wallpaper_ok && wallpaper_surf != null) {
                cr.blit_surface ((!) wallpaper_surf, 0, 0, SCREEN_W, SCREEN_H);
                cr.set_source_rgba (acc_r, acc_g, acc_b, 0.14);
                cr.rectangle (0, TOP_H, SCREEN_W, 2);
                cr.fill ();
                return;
            }
            if (pattern_ok) {
                draw_pattern (cr);
                return;
            }
            int bands = 24;
            for (int i = 0; i < bands; i++) {
                double t = (double) i / (double) (bands - 1);
                // Obsidian Orbit (#0F1419) to Slate Atmosphere (#182028)
                double r = 0.085 + 0.045 * t;
                double g = 0.085 + 0.045 * t;
                double b = 0.090 + 0.048 * t;
                cr.set_source_rgb (r, g, b);
                cr.rectangle (0, (double) (i * SCREEN_H) / (double) bands, SCREEN_W,
                              (double) SCREEN_H / (double) bands + 1.0);
                cr.fill ();
            }
            cr.set_source_rgba (acc_r, acc_g, acc_b, 0.14);
            cr.rectangle (0, TOP_H, SCREEN_W, 2);
            cr.fill ();
        }

        // Blits the baked shader pattern via Gsk.ShaderNode, visiting only
        // the blocks that fall inside the current clip (a damage rect).
        private void draw_pattern (Context cr) {
            if (pattern_node != null)
                pattern_node.draw_cairo (cr);
            cr.set_source_rgba (acc_r, acc_g, acc_b, 0.14);
            cr.rectangle (0, TOP_H, SCREEN_W, 2);
            cr.fill ();
        }

        private void draw_top_bar (Context cr) {
            if (!rect_hits (cr, 0, 0, SCREEN_W, TOP_H))
                return;
            // Obsidian Orbit (#0F1419)
            cr.set_source_rgb (0.090, 0.090, 0.094);
            cr.rectangle (0, 0, SCREEN_W, TOP_H);
            cr.fill ();
            cr.set_source_rgb (acc_r, acc_g, acc_b);
            cr.rectangle (0, TOP_H - 2, SCREEN_W, 2);
            cr.fill ();

            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.920, 0.920, 0.925);
            TextHelper.draw_text (cr, "PlanetOS", 14, 6, 15.0);

            string t = "desktop";
            var w = find (focused_id);
            if (w != null)
                t = w.title;
            cr.set_source_rgb (acc_r, acc_g, acc_b);
            TextHelper.draw_text (cr, t, 110, 6, 15.0);

            // Titanium Mist (#8B9BB0)
            cr.set_source_rgb (0.600, 0.600, 0.615);
            TextHelper.draw_mono (cr, @"$(count ()) win", SCREEN_W - 190, 6, 14.0);
            // Wall-clock date and time in the configured zone (TZ/PLANET_TZ).
            int now_s = (int) get_real_time_seconds ();
            var dt = DateTime.now_utc ().to_timezone (zone);
            string stamp = @"$(dt.format ("%a %d %b %H:%M:%S")) $(zone.get_abbreviation (now_s))";
            TextHelper.draw_mono (cr, stamp, SCREEN_W - 420, 6, 14.0);
        }

        private void draw_windows (Context cr) {
            int total = count ();
            int drawn = 0;
            int lastz = -1;
            while (drawn < total) {
                Win? pick = null;
                int pickz = 1 << 29;
                for (int i = 0; i < wins.length; i++) {
                    var w = wins[i];
                    if (!w.alive || w.z <= lastz)
                        continue;
                    if (w.z < pickz) {
                        pickz = w.z;
                        pick = w;
                    }
                }
                if (pick == null)
                    break;
                if (!rect_hits (cr, pick.x - 1, pick.y - 1, pick.w + SHADOW + 2, pick.h + SHADOW + 2)) {
                    lastz = pickz;
                    drawn = drawn + 1;
                    continue;
                }
                if (covered (pick)) {
                    occluded_skips = occluded_skips + 1;
                    lastz = pickz;
                    drawn = drawn + 1;
                    continue;
                }
                draw_window (cr, pick);
                lastz = pickz;
                drawn = drawn + 1;
            }
        }

        // Occlusion culling: a lower window whose frame (shadow included) is
        // completely inside a higher one is not painted at all.
        private bool covered (Win w) {
            for (int i = 0; i < wins.length; i++) {
                var o = wins[i];
                if (!o.alive || o.id == w.id || o.z <= w.z)
                    continue;
                if (o.x <= w.x && o.y <= w.y
                    && o.x + o.w + SHADOW >= w.x + w.w + SHADOW
                    && o.y + o.h + SHADOW >= w.y + w.h + SHADOW)
                    return true;
            }
            return false;
        }

        public int occluded_count () { return occluded_skips; }

        private void draw_window (Context cr, Win w) {
            bool foc = (w.id == focused_id);

            // Subtle flat 2px drop shadow (opaque for fast SSE2 fill)
            cr.set_source_rgb (0.035, 0.047, 0.060);
            cr.rectangle (w.x + w.w, w.y + SHADOW, SHADOW, w.h);
            cr.fill ();
            cr.rectangle (w.x + SHADOW, w.y + w.h, w.w, SHADOW);
            cr.fill ();

            // Window body: Slate Atmosphere (#182028)
            cr.set_source_rgb (0.130, 0.130, 0.135);
            cr.rectangle (w.x, w.y, w.w, w.h);
            cr.fill ();

            // Clip content cleanly inside window frame
            cr.save ();
            cr.rectangle (w.x + BORDER, w.content_y (), w.w - 2 * BORDER, w.content_h ());
            cr.clip ();
            draw_content (cr, w);
            cr.restore ();

            // Title bar: Elevated Surface (#212B36) focused, Slate Atmosphere (#182028) unfocused
            if (foc) {
                cr.set_source_rgb (0.175, 0.175, 0.182);
            } else {
                cr.set_source_rgb (0.130, 0.130, 0.135);
            }
            cr.rectangle (w.x + 1, w.y + 1, w.w - 2, TITLE_H);
            cr.fill ();

            // 1px titlebar bottom separator: Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rectangle (w.x + 1, w.y + TITLE_H, w.w - 2, 1);
            cr.fill ();

            // Title text: Lunar White (#F0F4F8) focused, Titanium Mist (#8B9BB0) unfocused
            if (foc)
                cr.set_source_rgb (0.920, 0.920, 0.925);
            else
                cr.set_source_rgb (0.600, 0.600, 0.615);
            TextHelper.draw_text (cr, w.title, w.x + 12, w.y + BORDER + 4, 15.0);

            int by = w.btn_y ();
            // Maximize: Elevated Surface (#212B36), Close: Crimson Alert (#EF4444)
            cr.set_source_rgb (0.175, 0.175, 0.182);
            cr.rectangle (w.max_x (), by, BTN, BTN);
            cr.fill ();
            cr.set_source_rgb (0.937, 0.267, 0.267);
            cr.rectangle (w.close_x (), by, BTN, BTN);
            cr.fill ();

            // Crisp 1px border: Celestial Cerulean (#3897F0) focused, Stratosphere Line (#26323F) unfocused
            if (foc)
                cr.set_source_rgb (0.450, 0.455, 0.470);
            else
                cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.set_line_width (1);
            cr.rectangle (w.x, w.y, w.w, w.h);
            cr.stroke ();
            // Button icons: Lunar White (#F0F4F8)
            cr.set_source_rgb (0.920, 0.920, 0.925);
            cr.set_line_width (1);
            int mx0 = w.max_x () + 4;
            cr.rectangle (mx0, by + 4, 8, 8);
            cr.stroke ();

            int cx0 = w.close_x () + 4;
            cr.move_to (cx0, by + 4);
            cr.line_to (cx0 + 8, by + 12);
            cr.stroke ();
            cr.move_to (cx0 + 8, by + 4);
            cr.line_to (cx0, by + 12);
            cr.stroke ();
        }

        private static int clock_radius (int cw, int ch) {
            int rad = ch / 2 - 18;
            if (rad > cw / 2 - 16)
                rad = cw / 2 - 16;
            if (rad < 20)
                rad = 20;
            return rad;
        }

        private void draw_title (Context cr, Win w, int x, int y) {
            int tw = w.w - 96;
            if (tw < 40)
                tw = 40;
            title_lay.set_width (tw);
            title_lay.set_text (w.title);
            show_layout_at (cr, title_lay, x, y);
        }

        private void draw_dock_label (Context cr, string title, int x, int y) {
            TextHelper.draw_text (cr, title, x, y - 1, 14.0);
        }

        private void draw_content (Context cr, Win w) {
            int cx = w.x + BORDER;
            int cy = w.content_y ();
            int cw = w.w - 2 * BORDER;
            int ch = w.content_h ();
            if (ch <= 0 || cw <= 0)
                return;
            if (!rect_hits (cr, cx, cy, cw, ch))
                return;

            if (w.kind == Kind.TERMINAL && w.term != null) {
                w.term.draw (cr, cx, cy, cw, ch, w.id == focused_id, acc_r, acc_g, acc_b);
            } else if (w.kind == Kind.CLOCK) {
                // Slate Atmosphere (#182028)
                cr.set_source_rgb (0.130, 0.130, 0.135);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                int rad = clock_radius (cw, ch);
                int ccx = cx + cw / 2;
                int ccy = cy + ch / 2;
                // Stratosphere Line (#26323F)
                cr.set_source_rgb (0.210, 0.210, 0.218);
                cr.set_line_width (2);
                cr.arc (ccx, ccy, rad, 0, 6.28);
                cr.stroke ();
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                cr.set_line_width (1);
                cr.arc (ccx, ccy, rad - 3, 0, 6.28);
                cr.stroke ();

                int total = Sys.ticks () / 100;
                int sec = total % 60;
                int min = (total / 60) % 60;
                // minute hand: 6 degrees per minute (Lunar White #F0F4F8)
                int ang = min * 6;
                int hx = hand_x (ccx, ang, rad - 10);
                int hy = hand_y (ccy, ang, rad - 10);
                cr.set_source_rgb (0.920, 0.920, 0.925);
                cr.set_line_width (2);
                cr.move_to (ccx, ccy);
                cr.line_to (hx, hy);
                cr.stroke ();
                int sx = hand_x (ccx, sec * 6, rad - 5);
                int sy = hand_y (ccy, sec * 6, rad - 5);
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                cr.set_line_width (1);
                cr.move_to (ccx, ccy);
                cr.line_to (sx, sy);
                cr.stroke ();
                cr.set_source_rgb (0.920, 0.920, 0.925);
                cr.arc (ccx, ccy, 3, 0, 6.28);
                cr.fill ();

                // Titanium Mist (#8B9BB0)
                cr.set_source_rgb (0.600, 0.600, 0.615);
                TextHelper.draw_mono (cr, @"T+$(pad2 (min)):$(pad2 (sec))", cx + 12, cy + ch - 28, 15.0);
            } else if (w.kind == Kind.SHADER) {
                // Slate Atmosphere (#182028)
                cr.set_source_rgb (0.130, 0.130, 0.135);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                cr.rectangle (cx + 14, cy + 16, 56, 56);
                cr.fill ();
                cr.set_line_width (1);
                // Stratosphere Line (#26323F)
                cr.set_source_rgb (0.210, 0.210, 0.218);
                cr.rectangle (cx + 14, cy + 16, 56, 56);
                cr.stroke ();

                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.920, 0.920, 0.925);
                TextHelper.draw_text (cr, "spir-v frag", cx + 84, cy + 18, 16.0);
                // Titanium Mist (#8B9BB0)
                cr.set_source_rgb (0.600, 0.600, 0.615);
                if (shader_ok)
                    TextHelper.draw_mono (cr, @"words $(shader.words)", cx + 84, cy + 38, 14.0);
                else
                    TextHelper.draw_mono (cr, "no module", cx + 84, cy + 38, 14.0);
                if (shader_ok)
                    TextHelper.draw_mono (cr, @"insns $(shader.insns)", cx + 84, cy + 56, 14.0);
                else
                    TextHelper.draw_mono (cr, "cpu accent", cx + 84, cy + 56, 14.0);
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                TextHelper.draw_mono (cr, @"rgba $(accent_ir ()) $(accent_ig ()) $(accent_ib ())", cx + 14, cy + 92, 14.0);
                // Teal Shield (#14B8A6) for system/GPU capability status
                cr.set_source_rgb (0.078, 0.722, 0.651);
                int gcaps = Sys.gpu_info ();
                string gmsg = "gpu: bga + spv/simd (no virtio)";
                if ((gcaps & 16) != 0)
                    gmsg = "gpu: virtio-gpu venus (CAPSET_VENUS)";
                else if ((gcaps & 2) != 0)
                    gmsg = "gpu: virtio-gpu 3d (virgl) + spv";
                else if ((gcaps & 1) != 0)
                    gmsg = "gpu: virtio-gpu 2d + spv/simd";
                TextHelper.draw_mono (cr, gmsg, cx + 14, cy + 116, 14.0);
            } else if ((w.kind == Kind.GTK || w.kind == Kind.FILES) && w.gtk_root != null) {
                // Slate Atmosphere (#182028)
                cr.set_source_rgb (0.130, 0.130, 0.135);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                int gx = cx + 12;
                int gy = cy + 12;
                int gw = (cw > 24) ? (cw - 24) : 0;
                int gh = (ch > 24) ? (ch - 24) : 0;
                // Only lay the tree out when its rectangle moved or resized; the
                // scrolled containers re-check their own content on draw.
                if (gx != w.gtk_alloc_x || gy != w.gtk_alloc_y
                        || gw != w.gtk_alloc_w || gh != w.gtk_alloc_h) {
                    w.gtk_root.allocate (gx, gy, gw, gh);
                    w.gtk_alloc_x = gx;
                    w.gtk_alloc_y = gy;
                    w.gtk_alloc_w = gw;
                    w.gtk_alloc_h = gh;
                }
                w.gtk_root.draw (cr);
            } else if (w.kind == Kind.EXT) {
                // Slate Atmosphere (#182028)
                cr.set_source_rgb (0.130, 0.130, 0.135);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                if (w.ext_shm_surf != null) {
                    cr.blit_surface (w.ext_shm_surf, cx, cy, cw, ch);
                } else if (w.ext_surf != null) {
                    cr.blit_surface (w.ext_surf, cx, cy, cw, ch);
                } else {
                    // Titanium Mist (#8B9BB0)
                    cr.set_source_rgb (0.600, 0.600, 0.615);
                    TextHelper.draw_mono (cr, "Starting GUI app...", cx + 16, cy + 20, 14.0);
                }
            } else if (w.kind == Kind.CALENDAR) {
                draw_calendar (cr, w, cx, cy, cw, ch);
            } else if (w.kind == Kind.PLACES) {
                draw_places (cr, w, cx, cy, cw, ch);
            } else {
                // Slate Atmosphere (#182028)
                cr.set_source_rgb (0.130, 0.130, 0.135);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                // One Pango layout with a colour attribute run on the last line.
                // Titanium Mist (#8B9BB0)
                cr.set_source_rgb (0.600, 0.600, 0.615);
                show_layout_at (cr, notes_lay, cx + 14, cy + 12);
            }
        }

        // Month grid for the window's month (GLib.Date) plus the current
        // date/time in the configured zone (GLib.TimeZone + GLib.DateTime).
        private void draw_calendar (Context cr, Win w, int cx, int cy, int cw, int ch) {
            // Slate Atmosphere (#182028)
            cr.set_source_rgb (0.130, 0.130, 0.135);
            cr.rectangle (cx, cy, cw, ch);
            cr.fill ();
            if (cw < 220 || ch < 190)
                return;
            int now_s = (int) get_real_time_seconds ();
            var now = DateTime.now_utc ().to_timezone (zone);
            int base_months = (now.get_year () - 1970) * 12 + (now.get_month () - 1);
            int months = w.has_data (QDATA_CAL_MONTH) ? w.get_data (QDATA_CAL_MONTH) : base_months;
            int year = 1970 + months / 12;
            int mon = (months % 12) + 1;
            if (mon < 1) {
                mon = mon + 12;
                year = year - 1;
            }

            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.920, 0.920, 0.925);
            TextHelper.draw_text (cr, @"$(month_name (mon)) $(year)", cx + 12, cy + 8, 16.0);
            // Titanium Mist (#8B9BB0)
            cr.set_source_rgb (0.600, 0.600, 0.615);
            TextHelper.draw_mono (cr, @"$(zone.get_identifier ()) $(zone.offset_string (now_s))", cx + 12, cy + 30, 13.0);

            string[] labels = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
            int grid_x = cx + 12;
            int grid_y = cy + 56;
            int cell_w = (cw - 24) / 7;
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            for (int i = 0; i < 7; i++)
                TextHelper.draw_mono (cr, labels[i], grid_x + i * cell_w + 4, grid_y, 12.0);

            var first = Date.dmy (1, mon, year);
            int offset = ((int) first.get_weekday ()) - 1;
            int dim = first.get_days_in_month ();
            int today = (now.get_month () == mon && now.get_year () == year) ? now.get_day_of_month () : -1;
            int row_y = grid_y + 20;
            for (int cell = 0; cell < 42; cell++) {
                int day = cell - offset + 1;
                if (day < 1 || day > dim)
                    continue;
                int col = cell % 7;
                int cxx = grid_x + col * cell_w + 4;
                int cyy = row_y + (cell / 7) * 24;
                if (cyy > cy + ch - 36)
                    break;
                if (day == today) {
                    cr.set_source_rgb (acc_r, acc_g, acc_b);
                    cr.rectangle (grid_x + col * cell_w, cyy - 3, cell_w - 2, 21);
                    cr.fill ();
                    // Obsidian Orbit (#0F1419) for contrast on the accent.
                    cr.set_source_rgb (0.090, 0.090, 0.094);
                } else {
                    // Lunar White
                    cr.set_source_rgb (0.827, 0.851, 0.878);
                }
                TextHelper.draw_mono (cr, day.to_string (), cxx, cyy, 13.0);
            }

            // Footer: full date, time and zone abbreviation.
            cr.set_source_rgb (acc_r, acc_g, acc_b);
            string footer = @"$(now.format ("%a %d %b %Y %H:%M:%S")) $(zone.get_abbreviation (now_s))";
            TextHelper.draw_mono (cr, footer, cx + 12, cy + ch - 26, 13.0);
        }

        // Places list read from `places.gbk` (GLib.BookmarkFile); the path
        // shown is the one GLib.Uri extracts from the bookmark's file URI.
        private void draw_places (Context cr, Win w, int cx, int cy, int cw, int ch) {
            cr.set_source_rgb (0.130, 0.130, 0.135);
            cr.rectangle (cx, cy, cw, ch);
            cr.fill ();
            cr.set_source_rgb (0.920, 0.920, 0.925);
            string head = places_signed ? "Places (hmac ok)" : "Places";
            TextHelper.draw_text (cr, head, cx + 12, cy + 8, 15.0);
            var uris = places.get_uris ();
            int y = cy + 34;
            for (int i = 0; i < uris.length && y < cy + ch - 18; i++) {
                string title = uris[i];
                try {
                    title = places.get_title (uris[i]);
                } catch (BookmarkFileError e) {
                    title = uris[i];
                }
                string path = uris[i];
                try {
                    var u = Uri.parse (uris[i]);
                    if (u.get_path ().length > 0)
                        path = u.get_path ();
                } catch (UriError e) {
                    path = uris[i];
                }
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                TextHelper.draw_mono (cr, @"$(i + 1)", cx + 12, y, 13.0);
                cr.set_source_rgb (0.827, 0.851, 0.878);
                TextHelper.draw_mono (cr, path, cx + 36, y, 13.0);
                // Titanium Mist (#8B9BB0)
                cr.set_source_rgb (0.600, 0.600, 0.615);
                TextHelper.draw_mono (cr, title, cx + 200, y, 13.0);
                y += 20;
            }
        }

        private static int hand_x (int ccx, int deg, int len) {
            int d = deg % 360;
            int q = d / 90;
            int r = d % 90;
            int dx = len - (r * r * len) / 8100;
            if (q == 0) return ccx + dx;
            if (q == 1) return ccx - (r * len) / 90;
            if (q == 2) return ccx - dx;
            return ccx + (r * len) / 90;
        }

        private static int hand_y (int ccy, int deg, int len) {
            int d = deg % 360;
            int q = d / 90;
            int r = d % 90;
            int dy = len - (r * r * len) / 8100;
            if (q == 0) return ccy + (r * len) / 90;
            if (q == 1) return ccy + dy;
            if (q == 2) return ccy - (r * len) / 90;
            return ccy - dy;
        }

        private void draw_dock (Context cr) {
            int y0 = SCREEN_H - DOCK_H;
            if (!rect_hits (cr, 0, y0, SCREEN_W, DOCK_H))
                return;
            // Dock surface: Slate Atmosphere (#182028)
            cr.set_source_rgb (0.130, 0.130, 0.135);
            cr.rectangle (0, y0, SCREEN_W, DOCK_H);
            cr.fill ();
            // 1px divider: Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rectangle (0, y0, SCREEN_W, 1);
            cr.fill ();

            int n = count ();
            for (int i = 0; i < n; i++) {
                var w = nth (i);
                if (w == null)
                    continue;
                bool foc = (w.id == focused_id);
                int bx = DOCK_X0 + i * (DOCK_BTN_W + DOCK_BTN_GAP);
                int by = y0 + 5;
                if (foc)
                    // Elevated Surface (#212B36)
                    cr.set_source_rgb (0.175, 0.175, 0.182);
                else
                    // Obsidian Orbit (#0F1419)
                    cr.set_source_rgb (0.090, 0.090, 0.094);
                cr.rectangle (bx, by, DOCK_BTN_W, DOCK_H - 10);
                cr.fill ();
                if (foc) {
                    // Celestial Cerulean (#3897F0)
                    cr.set_source_rgb (0.450, 0.455, 0.470);
                    cr.rectangle (bx, by + DOCK_H - 12, DOCK_BTN_W, 2);
                    cr.fill ();
                }
                cr.set_font_size (16);
                if (foc)
                    // Lunar White (#F0F4F8)
                    cr.set_source_rgb (0.920, 0.920, 0.925);
                else
                    // Titanium Mist (#8B9BB0)
                    cr.set_source_rgb (0.600, 0.600, 0.615);
                draw_dock_label (cr, w.title, bx + 10, by + 5);
            }

            // Right side of bottom bar: Network status icon + Clock
            int nx = SCREEN_W - 154;
            int ny = y0 + 12;
            if (net_connected) {
                cr.set_source_rgb (0.250, 0.780, 0.420);
            } else {
                cr.set_source_rgb (0.780, 0.280, 0.280);
            }
            // 3 signal bars
            cr.rectangle (nx + 0, ny + 10, 4, 6);
            cr.fill ();
            cr.rectangle (nx + 6, ny + 6, 4, 10);
            cr.fill ();
            cr.rectangle (nx + 12, ny + 2, 4, 14);
            cr.fill ();
            if (!net_connected) {
                cr.set_line_width (2);
                cr.move_to (nx - 1, ny + 15);
                cr.line_to (nx + 17, ny + 1);
                cr.stroke ();
            }
            cr.set_source_rgb (0.600, 0.600, 0.615);
            TextHelper.draw_mono (cr, net_connected ? "NET" : "OFF", nx + 22, y0 + 12, 12.0);

            var dt = DateTime.now_utc ().to_timezone (zone);
            string tstr = dt.format ("%H:%M:%S");
            cr.set_source_rgb (0.920, 0.920, 0.925);
            TextHelper.draw_mono (cr, tstr, SCREEN_W - 92, y0 + 11, 14.0);
        }

        private void draw_cursor (Context cr, int mx, int my) {
            int x = (mx < 0) ? 0 : ((mx >= SCREEN_W) ? (SCREEN_W - 1) : mx);
            int y = (my < 0) ? 0 : ((my >= SCREEN_H) ? (SCREEN_H - 1) : my);
            if (cursor_svg_ok) {
                cr.draw_rgba (cursor_pix, CURSOR_TEX, CURSOR_TEX,
                              x - cursor_hot_x, y - cursor_hot_y);
                return;
            }
            cr.set_source_rgba (0.0, 0.0, 0.0, 0.55);
            cr.set_line_width (1);
            cr.move_to (x + 1, y + 1);
            cr.line_to (x + 1, y + 15);
            cr.stroke ();
            cr.move_to (x + 1, y + 15);
            cr.line_to (x + 6, y + 11);
            cr.stroke ();
            cr.move_to (x + 6, y + 11);
            cr.line_to (x + 10, y + 17);
            cr.stroke ();
            cr.set_source_rgb (0.920, 0.920, 0.925);
            cr.move_to (x, y);
            cr.line_to (x, y + 14);
            cr.stroke ();
            cr.move_to (x, y + 14);
            cr.line_to (x + 5, y + 10);
            cr.stroke ();
            cr.move_to (x + 5, y + 10);
            cr.line_to (x + 9, y + 16);
            cr.stroke ();
        }
    }
}
