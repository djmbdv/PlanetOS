// PlanetOS compositor -- an Openbox-style window manager with Gala-inspired
// visuals, written in 100% Vala.
//
// There is no Mutter, no X11 and no Wayland here. Window management is a pure
// Vala model (Win/Compositor) and the screen is painted through Gdk + Cairo
// into the framebuffer. The fragment stage is fed by the SPIR-V module
// (frag.spv) through Module: the same IR a Vulkan backend will upload once
// an ICD exists (docs/planc/slice-38.md, decision D-13).
//
// Usage:
//   compositor.elf                 interactive session (framebuffer)
//   compositor.elf --self-test     headless model + render smoke test
//   compositor.elf --no-shader     ignore frag.spv, use the built-in accent
//   compositor.elf --shader FILE   load another SPIR-V fragment module

using GLib;
using Planet;
using Pango;
using PangoCairo;
using Spv;
using Cairo;
using Gdk;
using Gtk;
using Wm;

namespace Wm {
    public const int SCREEN_W = 1280;
    public const int SCREEN_H = 720;
    public const int TOP_H = 26;
    public const int DOCK_H = 34;
    public const int TITLE_H = 26;
    public const int BORDER = 1;
    public const int SHADOW = 6;
    public const int BTN = 16;
    public const int BTN_GAP = 4;
    public const int DOCK_X0 = 10;
    public const int DOCK_BTN_W = 132;
    public const int DOCK_BTN_GAP = 6;
    public const int MOVE_STEP = 8;
    public const int WORK_H = 540; // SCREEN_H - TOP_H - DOCK_H

    public const int ACT_NONE = 0;
    public const int ACT_FOCUS = 1;
    public const int ACT_DRAG = 2;
    public const int ACT_CLOSE = 3;
    public const int ACT_MAXIMIZE = 4;
    public const int ACT_DOCK = 5;

    public const int BACKEND_CAIRO = 0;
    public const int BACKEND_VULKAN = 1;

    public const int LAYOUT_NORMAL = 0;
    public const int LAYOUT_MAX = 1;
    public const int LAYOUT_LEFT = 2;
    public const int LAYOUT_RIGHT = 3;

    public const int DMG_RECTS = 32;
    public const int PAT_STEP = 8;

    public enum Kind { TERMINAL, CLOCK, SHADER, NOTES, GTK }

    public class GtkCompState : Object {
        public int clicks = 0;
    }

    public class VteTerminal : Object {
        public GenericArray<string> lines;
        public string input = "";
        public bool active = false;

        public VteTerminal () {
            lines = new GenericArray<string> ();
            lines.add ("PlanetOS VTE v0.1 (click & type 'help')");
        }

        private void push_line (string s) {
            lines.add (s);
            if (lines.length > 64)
                lines.remove_index (0);
        }

        private static string bytes_to_str (uint8[] buf, int off, int len) {
            var sb = new StringBuilder ("");
            for (int i = 0; i < len; i++) {
                uint8 c = buf[off + i];
                if (c >= 32 && c < 127)
                    sb.append_c ((char) c);
            }
            return sb.str;
        }

        private static string trim_str (string s) {
            int a = 0;
            int b = s.length;
            while (a < b && s[a] == ' ') a++;
            while (b > a && s[b - 1] == ' ') b--;
            return s.substring (a, b - a);
        }

        private void run_cmd (string raw) {
            string cmd = trim_str (raw);
            push_line ("planet> " + cmd);
            if (cmd == "")
                return;
            if (cmd == "help") {
                push_line ("cmds: help ls cat ticks uname echo clear");
            } else if (cmd == "clear") {
                lines.length = 0;
            } else if (cmd == "uname") {
                push_line ("PlanetOS x86_64 Long Mode (Ring 3 + VTE)");
            } else if (cmd == "ticks") {
                push_line (@"ticks: $(Sys.ticks ())");
            } else if (cmd.has_prefix ("echo ")) {
                push_line (cmd.substring (5, cmd.length - 5));
            } else if (cmd == "ls") {
                var buf = new uint8[2048];
                int n = Sys.readdir_path ("/", buf, 2048);
                if (n <= 0) {
                    push_line ("(empty)");
                    return;
                }
                string cur = "";
                int start = 0;
                for (int i = 0; i <= n; i++) {
                    if (i == n || buf[i] == 0 || buf[i] == '\n') {
                        if (i > start) {
                            string name = bytes_to_str (buf, start, i - start);
                            if (cur.length + name.length + 1 > 40) {
                                push_line (cur);
                                cur = name;
                            } else {
                                cur = (cur.length > 0) ? (cur + " " + name) : name;
                            }
                        }
                        start = i + 1;
                    }
                }
                if (cur.length > 0)
                    push_line (cur);
            } else if (cmd.has_prefix ("cat ")) {
                string path = trim_str (cmd.substring (4, cmd.length - 4));
                int fd = Sys.open (path);
                if (fd < 0) {
                    push_line (@"cat: not found: $path");
                } else {
                    var fbuf = new uint8[512];
                    int nr = Sys.read (fd, fbuf, 511);
                    Sys.close (fd);
                    if (nr > 0) {
                        int st = 0;
                        for (int i = 0; i <= nr; i++) {
                            if (i == nr || fbuf[i] == '\n') {
                                if (i > st)
                                    push_line (bytes_to_str (fbuf, st, i - st));
                                st = i + 1;
                            }
                        }
                    }
                }
            } else {
                push_line (@"unknown: $cmd");
            }
        }

        public bool on_key_press (int key) {
            if (!active)
                return false;
            if (key == '\n' || key == '\r') {
                string cmd = input.substring (0, input.length);
                input = "";
                run_cmd (cmd);
                return true;
            }
            if (key == 8 || key == 127) {
                if (input.length > 0)
                    input = input.substring (0, input.length - 1);
                return true;
            }
            if (key >= 32 && key < 127) {
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                input = input + ascii.substring (key - 32, 1);
                return true;
            }
            return false;
        }

        public void draw (Context cr, int cx, int cy, int cw, int ch, bool focused, double ar, double ag, double ab) {
            cr.set_source_rgb (0.051, 0.063, 0.090);
            cr.rectangle (cx, cy, cw, ch);
            cr.fill ();
            int row_h = 18;
            int max_rows = (ch - 12) / row_h;
            if (max_rows < 2) max_rows = 2;
            int hist_rows = max_rows - 1;
            int start = (lines.length > hist_rows) ? (lines.length - hist_rows) : 0;
            int y = cy + 8;
            cr.set_source_rgb (0.78, 0.83, 0.90);
            for (int i = start; i < lines.length; i++) {
                TextHelper.draw_text (cr, lines[i], cx + 10, y, 14.0);
                y += row_h;
            }
            cr.set_source_rgb (ar, ag, ab);
            string prompt = "planet> " + input + (focused ? "_" : "");
            TextHelper.draw_text (cr, prompt, cx + 10, y, 14.0);
        }
    }

    public class Win : Object {
        public int id;
        public string title;
        public Kind kind;
        public int x;
        public int y;
        public int w;
        public int h;
        public int z;
        public bool alive = true;
        public bool maximized = false;
        public int layout_state = 0;
        public int rx;
        public int ry;
        public int rw;
        public int rh;
        public Box? gtk_root = null;
        public VteTerminal? term = null;

        public Win (int id, string title, int x, int y, int w, int h, Kind kind) {
            this.id = id;
            this.title = title;
            this.x = x;
            this.y = y;
            this.w = w;
            this.h = h;
            this.kind = kind;
            if (kind == Kind.TERMINAL) {
                term = new VteTerminal ();
            } else if (kind == Kind.GTK) {
                var box = new Box (Orientation.VERTICAL, 8);
                var lbl = new Label ("GTK + TrueType (7)");
                lbl.font_size = 18.0;
                var ent = new Entry ("PlanetOS 7");
                var chk = new CheckButton ("Auto-progress", true);
                var pbar = new ProgressBar ();
                pbar.set_text ("0%");
                var st_lbl = new Label ("Clicks: 0");
                var gst = new GtkCompState ();
                var btn = new Button ("Increment (+1)");
                btn.clicked.connect ((sender) => {
                    gst.clicks = gst.clicks + 1;
                    st_lbl.set_text (@"Clicks: $(gst.clicks) | $(ent.get_text ())");
                    if (chk.get_active ()) {
                        int pct = (gst.clicks * 10) % 110;
                        if (pct > 100) pct = 100;
                        pbar.set_fraction ((double) pct / 100.0);
                        pbar.set_text (@"$pct%");
                    }
                });
                box.pack_start (lbl);
                box.pack_start (ent);
                box.pack_start (chk);
                box.pack_start (pbar);
                box.pack_start (new Separator ());
                box.pack_start (btn);
                box.pack_start (st_lbl);
                gtk_root = box;
            }
        }

        public bool contains (int px, int py) {
            return px >= x && px < x + w && py >= y && py < y + h;
        }

        public bool in_title (int px, int py) {
            return px >= x + BORDER && px < x + w - BORDER
                && py >= y + BORDER && py < y + BORDER + TITLE_H;
        }

        public int close_x () { return x + w - BORDER - BTN_GAP - BTN; }
        public int max_x () { return x + w - BORDER - BTN_GAP - BTN - BTN_GAP - BTN; }
        public int btn_y () { return y + BORDER + (TITLE_H - BTN) / 2; }

        public bool in_close (int px, int py) {
            int bx = close_x ();
            int by = btn_y ();
            return px >= bx && px < bx + BTN && py >= by && py < by + BTN;
        }

        public bool in_max (int px, int py) {
            int bx = max_x ();
            int by = btn_y ();
            return px >= bx && px < bx + BTN && py >= by && py < by + BTN;
        }

        public bool in_resize (int px, int py) {
            return !maximized && px >= x + w - 14 && px < x + w && py >= y + h - 14 && py < y + h;
        }

        public int content_y () { return y + BORDER + TITLE_H; }
        public int content_h () { return h - TITLE_H - 2 * BORDER; }
    }

    public class Compositor : Object {
        private GenericArray<Win> wins;
        private Window screen;
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
        private int flush_ticks = 0;
        private int blit_ticks = 0;
        private int dirty_frames = 0;
        private int last_sec = -1;
        private Module shader;
        private bool shader_ok = false;
        private int backend_id = 0;
        private double acc_r = 0.227;
        private double acc_g = 0.518;
        private double acc_b = 0.882;
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
        private bool pattern_ok = false;
        private int[] pat;
        private int pat_w = 0;
        private int pat_h = 0;
        private int pat_step = PAT_STEP;
        private bool anim_on = false;
        private int anim_period_ms = 400;
        private int last_anim_tick = 0;
        private int anim_count = 0;
        private int occluded_skips = 0;
        private PangoContext pctx;
        private Layout title_lay;
        private Layout dock_lay;
        private Layout notes_lay;

        public Compositor () {
            wins = new GenericArray<Win> ();
            shader = new Module ();
            pattern = new Module ();
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
            notes_lay.add_color_attribute (103, 125, 0.22, 0.74, 0.97);
            pat = new int[1];
        }

        // --- plumbing -------------------------------------------------

        private bool hw_cursor = false;

        private void init_hw_cursor () {
            if ((Sys.gpu_info () & 1) == 0)
                return;
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
            attached = true;
            if (use_hw_cursor)
                init_hw_cursor ();
        }

        public void shutdown () {
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
            animate_damage (mx, my);
            bool was_full = dmg_full;
            last_n = ndmg;
            last_full = was_full;
            for (int i = 0; i < ndmg * 4; i++)
                last[i] = dmg[i];
            if (last_full || last_n > 0)
                dirty_frames = dirty_frames + 1;
            int t_flush0 = Sys.ticks ();
            var cr = new Context (screen.surface);
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
            damage (w.x - 1, w.y - 1, w.w + SHADOW + 2, w.h + SHADOW + 2);
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
                cr.rectangle (x, y, w, h);
                cr.clip ();
                render (cr, mx, my);
                cr.reset_clip ();
            }
            clear_damage ();
        }

        private void animate_damage (int mx, int my) {
            if (mx != last_mx || my != last_my) {
                if (hw_cursor) {
                    Sys.gpu_cursor_move (mx, my);
                } else {
                    damage (last_mx - 2, last_my - 2, 16, 22);
                    damage (mx - 2, my - 2, 16, 22);
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
                if (!w.alive || w.kind != Kind.CLOCK)
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
            damage (SCREEN_W - 200, 0, 200, TOP_H);
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
            if (w.kind == Kind.GTK && w.gtk_root != null) {
                if (w.gtk_root.on_pointer_press (px, py, 1))
                    damage_window (id);
            }
            if (w.kind == Kind.TERMINAL && w.term != null) {
                w.term.active = true;
                damage_window (id);
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
            if (fw != null && fw.kind == Kind.GTK && fw.gtk_root != null) {
                if (fw.gtk_root.on_pointer_motion (px, py))
                    damage_window (fw.id);
            }
        }

        public void pointer_release () {
            dragging = false;
            drag_id = 0;
            resizing = false;
            resize_id = 0;
            var fw = find (focused_id);
            if (fw != null && fw.kind == Kind.GTK && fw.gtk_root != null) {
                if (fw.gtk_root.on_pointer_release (last_ptr_x, last_ptr_y, 1))
                    damage_window (fw.id);
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
            if (k == 27) {
                quit = true;
                return;
            }
            var fw = find (focused_id);
            if (fw != null && fw.kind == Kind.GTK && fw.gtk_root != null) {
                if (fw.gtk_root.on_key_press (k)) {
                    damage_window (fw.id);
                    return;
                }
            }
            if (fw != null && fw.kind == Kind.TERMINAL && fw.term != null) {
                if (fw.term.on_key_press (k)) {
                    damage_window (fw.id);
                    return;
                }
            }
            if (k == 'q' || k == 'Q') {
                quit = true;
                return;
            }
            if (k == 'g' || k == 'G') {
                add ("gtk-demo", 140, 110, 380, 230, Kind.GTK);
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

        // Bakes the per-pixel shader into coarse PAT_STEP blocks. The fragment
        // stage runs on the CPU (no ICD), so evaluating 100x75 samples once is
        // the practical equivalent of a full-screen Vulkan draw.
        public bool load_pattern (string path) {
            pattern = Module.load (path);
            if (!pattern.valid || !pattern.has_input ())
                return false;
            pat_w = (SCREEN_W + pat_step - 1) / pat_step;
            pat_h = (SCREEN_H + pat_step - 1) / pat_step;
            pat = new int[pat_w * pat_h];
            pattern_ok = true;
            bake_pattern (0.0);
            damage_full ();
            return true;
        }

        // Runs the fragment stage over every block sample with the current
        // push-constant values.
        public void bake_pattern (double time) {
            if (!pattern_ok)
                return;
            pattern.set_uniforms (time, (double) SCREEN_W, (double) SCREEN_H);
            for (int by = 0; by < pat_h; by++) {
                for (int bx = 0; bx < pat_w; bx++) {
                    pattern.pixel (bx * pat_step + pat_step / 2, by * pat_step + pat_step / 2);
                    int rr = pattern.ir ();
                    int gg = pattern.ig ();
                    int bb = pattern.ib ();
                    pat[by * pat_w + bx] = (rr << 16) | (gg << 8) | bb;
                }
            }
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
        }
        public int animation_count () { return anim_count; }

        public void set_animation (bool on, int period_ms) {
            anim_on = on;
            anim_period_ms = (period_ms < 40) ? 40 : period_ms;
        }

        public bool has_pattern () { return pattern_ok; }
        public int pattern_samples () { return pattern_ok ? (pat_w * pat_h) : 0; }

        public int pattern_at (int x, int y) {
            if (!pattern_ok)
                return 0;
            int bx = x / pat_step;
            int by = y / pat_step;
            if (bx < 0 || by < 0 || bx >= pat_w || by >= pat_h)
                return 0;
            return pat[by * pat_w + bx];
        }

        // --- scene ----------------------------------------------------

        public void seed () {
            TextHelper.load_ttf ("Ubuntu-Regular.ttf");
            add ("terminal", 48, 56, 420, 260, Kind.TERMINAL);
            add ("shader", 500, 56, 360, 230, Kind.SHADER);
            add ("clock", 900, 56, 320, 230, Kind.CLOCK);
            add ("gtk-demo", 80, 340, 480, 280, Kind.GTK);
            focus_nth (3);
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
            draw_background (cr);
            draw_windows (cr);
            draw_dock (cr);
            draw_top_bar (cr);
            if (!hw_cursor)
                draw_cursor (cr, mx, my);
        }

        private void draw_background (Context cr) {
            if (pattern_ok) {
                draw_pattern (cr);
                return;
            }
            int bands = 24;
            for (int i = 0; i < bands; i++) {
                double t = (double) i / (double) (bands - 1);
                double r = 0.043 + 0.058 * t;
                double g = 0.055 + 0.078 * t;
                double b = 0.086 + 0.115 * t;
                cr.set_source_rgb (r, g, b);
                cr.rectangle (0, (double) (i * SCREEN_H) / (double) bands, SCREEN_W,
                              (double) SCREEN_H / (double) bands + 1.0);
                cr.fill ();
            }
            cr.set_source_rgba (acc_r, acc_g, acc_b, 0.14);
            cr.rectangle (0, TOP_H, SCREEN_W, 2);
            cr.fill ();
        }

        // Blits the baked shader pattern, visiting only the blocks that fall
        // inside the current clip (a damage rect) instead of the whole screen.
        private void draw_pattern (Context cr) {
            int x0 = cr.clip_left ();
            int y0 = cr.clip_top ();
            int x1 = cr.clip_right ();
            int y1 = cr.clip_bottom ();
            int by = y0 / pat_step;
            while (by * pat_step < y1) {
                if (by >= 0 && by < pat_h) {
                    int bx = x0 / pat_step;
                    while (bx * pat_step < x1) {
                        if (bx >= 0 && bx < pat_w) {
                            int col = pat[by * pat_w + bx];
                            cr.set_source_rgb ((double) ((col >> 16) & 0xFF) / 255.0,
                                               (double) ((col >> 8) & 0xFF) / 255.0,
                                               (double) (col & 0xFF) / 255.0);
                            cr.rectangle (bx * pat_step, by * pat_step, pat_step, pat_step);
                            cr.fill ();
                        }
                        bx = bx + 1;
                    }
                }
                by = by + 1;
            }
            cr.set_source_rgba (acc_r, acc_g, acc_b, 0.14);
            cr.rectangle (0, TOP_H, SCREEN_W, 2);
            cr.fill ();
        }

        private void draw_top_bar (Context cr) {
            if (!rect_hits (cr, 0, 0, SCREEN_W, TOP_H))
                return;
            cr.set_source_rgb (0.071, 0.086, 0.125);
            cr.rectangle (0, 0, SCREEN_W, TOP_H);
            cr.fill ();
            cr.set_source_rgb (acc_r, acc_g, acc_b);
            cr.rectangle (0, TOP_H - 2, SCREEN_W, 2);
            cr.fill ();

            cr.set_source_rgb (0.86, 0.90, 0.96);
            TextHelper.draw_text (cr, "PlanetOS", 14, 6, 15.0);

            string t = "desktop";
            var w = find (focused_id);
            if (w != null)
                t = w.title;
            cr.set_source_rgb (acc_r, acc_g, acc_b);
            TextHelper.draw_text (cr, t, 110, 6, 15.0);

            cr.set_source_rgb (0.55, 0.62, 0.73);
            TextHelper.draw_text (cr, @"$(count ()) win", SCREEN_W - 190, 6, 14.0);
            int total = Sys.ticks () / 100;
            TextHelper.draw_text (cr, @"T+$(pad2 ((total / 60) % 60)):$(pad2 (total % 60))", SCREEN_W - 110, 6, 14.0);
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

            // Shadow only along the right/bottom bands so we don't blend hidden interior pixels
            cr.set_source_rgba (0.0, 0.0, 0.0, 0.35);
            cr.rectangle (w.x + w.w, w.y + SHADOW, SHADOW, w.h - 4);
            cr.fill ();
            cr.rectangle (w.x + SHADOW, w.y + w.h, w.w - 4, SHADOW);
            cr.fill ();

            // Rounded window body
            cr.set_source_rgb (0.113, 0.133, 0.176);
            cr.rounded_rectangle (w.x, w.y, w.w, w.h, 8.0);
            cr.fill ();

            // Clip content cleanly inside rounded bottom
            cr.save ();
            cr.rectangle (w.x + BORDER, w.content_y (), w.w - 2 * BORDER, w.content_h () - 4);
            cr.clip ();
            draw_content (cr, w);
            cr.restore ();

            // Rounded title bar
            if (foc) {
                cr.set_source_rgb (acc_r * 0.36 + 0.06, acc_g * 0.36 + 0.07, acc_b * 0.36 + 0.11);
            } else {
                cr.set_source_rgb (0.15, 0.17, 0.22);
            }
            cr.rounded_rectangle (w.x + 2, w.y + 2, w.w - 4, TITLE_H, 6.0);
            cr.fill ();
            cr.rectangle (w.x + 2, w.y + TITLE_H - 4, w.w - 4, 6);
            cr.fill ();

            if (foc)
                cr.set_source_rgb (0.97, 0.98, 1.0);
            else
                cr.set_source_rgb (0.71, 0.76, 0.84);
            TextHelper.draw_text (cr, w.title, w.x + 12, w.y + BORDER + 4, 15.0);

            int by = w.btn_y ();
            cr.set_source_rgba (1.0, 1.0, 1.0, 0.14);
            cr.rounded_rectangle (w.max_x (), by, BTN, BTN, 4.0);
            cr.fill ();
            cr.set_source_rgba (0.88, 0.32, 0.34, 0.85);
            cr.rounded_rectangle (w.close_x (), by, BTN, BTN, 4.0);
            cr.fill ();

            // Outer rounded 1px border drawn last so corners stay crisp
            if (foc)
                cr.set_source_rgb (acc_r, acc_g, acc_b);
            else
                cr.set_source_rgb (0.243, 0.275, 0.341);
            cr.set_line_width (1);
            cr.rounded_rectangle (w.x, w.y, w.w, w.h, 8.0);
            cr.stroke ();
            cr.set_source_rgb (0.90, 0.93, 0.97);
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

        // Pango layout cache: reflow only when the text or the width changes.
        private void draw_title (Context cr, Win w, int x, int y) {
            int tw = w.w - 96;
            if (tw < 40)
                tw = 40;
            if (title_lay.current_width () != tw)
                title_lay.set_width (tw);
            if (title_lay.current_text () != w.title)
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
                cr.set_source_rgb (0.086, 0.102, 0.137);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                int rad = clock_radius (cw, ch);
                int ccx = cx + cw / 2;
                int ccy = cy + ch / 2;
                cr.set_source_rgb (0.20, 0.24, 0.31);
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
                // minute hand: 6 degrees per minute
                int ang = min * 6;
                int hx = hand_x (ccx, ang, rad - 10);
                int hy = hand_y (ccy, ang, rad - 10);
                cr.set_source_rgb (0.93, 0.95, 0.98);
                cr.set_line_width (2);
                cr.move_to (ccx, ccy);
                cr.line_to (hx, hy);
                cr.stroke ();
                int sx = hand_x (ccx, sec * 6, rad - 5);
                int sy = hand_y (ccy, sec * 6, rad - 5);
                cr.set_source_rgb (acc_r * 1.15, acc_g * 1.10, acc_b);
                cr.set_line_width (1);
                cr.move_to (ccx, ccy);
                cr.line_to (sx, sy);
                cr.stroke ();
                cr.set_source_rgb (0.97, 0.98, 1.0);
                cr.arc (ccx, ccy, 3, 0, 6.28);
                cr.fill ();

                cr.set_source_rgb (0.72, 0.78, 0.86);
                TextHelper.draw_text (cr, @"T+$(pad2 (min)):$(pad2 (sec))", cx + 12, cy + ch - 28, 15.0);
            } else if (w.kind == Kind.SHADER) {
                cr.set_source_rgb (0.086, 0.102, 0.137);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                cr.set_source_rgba (acc_r, acc_g, acc_b, 1.0);
                cr.rounded_rectangle (cx + 14, cy + 16, 56, 56, 6.0);
                cr.fill ();
                cr.set_line_width (1);
                cr.set_source_rgb (0.30, 0.34, 0.42);
                cr.rounded_rectangle (cx + 14, cy + 16, 56, 56, 6.0);
                cr.stroke ();

                cr.set_source_rgb (0.90, 0.93, 0.97);
                TextHelper.draw_text (cr, "spir-v frag", cx + 84, cy + 18, 16.0);
                cr.set_source_rgb (0.66, 0.72, 0.81);
                if (shader_ok)
                    TextHelper.draw_text (cr, @"words $(shader.words)", cx + 84, cy + 38, 14.0);
                else
                    TextHelper.draw_text (cr, "no module", cx + 84, cy + 38, 14.0);
                if (shader_ok)
                    TextHelper.draw_text (cr, @"insns $(shader.insns)", cx + 84, cy + 56, 14.0);
                else
                    TextHelper.draw_text (cr, "cpu accent", cx + 84, cy + 56, 14.0);
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                TextHelper.draw_text (cr, @"rgba $(accent_ir ()) $(accent_ig ()) $(accent_ib ())", cx + 14, cy + 92, 14.0);
                cr.set_source_rgb (0.45, 0.52, 0.62);
                TextHelper.draw_text (cr, "vulkan backend: pending", cx + 14, cy + 116, 14.0);
            } else if (w.kind == Kind.GTK && w.gtk_root != null) {
                cr.set_source_rgb (0.09, 0.11, 0.14);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                w.gtk_root.allocate (cx + 12, cy + 12, cw - 24, ch - 24);
                w.gtk_root.draw (cr);
            } else {
                cr.set_source_rgb (0.086, 0.102, 0.137);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                // One Pango layout with a colour attribute run on the last line.
                cr.set_source_rgb (0.62, 0.69, 0.78);
                show_layout_at (cr, notes_lay, cx + 14, cy + 12);
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
            cr.set_source_rgb (0.031, 0.039, 0.059);
            cr.rectangle (0, y0, SCREEN_W, DOCK_H);
            cr.fill ();
            cr.set_source_rgba (acc_r, acc_g, acc_b, 0.30);
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
                    cr.set_source_rgba (acc_r, acc_g, acc_b, 0.24);
                else
                    cr.set_source_rgba (1.0, 1.0, 1.0, 0.07);
                cr.rounded_rectangle (bx, by, DOCK_BTN_W, DOCK_H - 10, 6.0);
                cr.fill ();
                if (foc) {
                    cr.set_source_rgb (acc_r, acc_g, acc_b);
                    cr.rectangle (bx, by + DOCK_H - 12, DOCK_BTN_W, 2);
                    cr.fill ();
                }
                cr.set_font_size (16);
                if (foc)
                    cr.set_source_rgb (0.96, 0.98, 1.0);
                else
                    cr.set_source_rgb (0.68, 0.74, 0.83);
                draw_dock_label (cr, w.title, bx + 10, by + 5);
            }
        }

        private void draw_cursor (Context cr, int mx, int my) {
            int x = (mx < 0) ? 0 : ((mx >= SCREEN_W) ? (SCREEN_W - 1) : mx);
            int y = (my < 0) ? 0 : ((my >= SCREEN_H) ? (SCREEN_H - 1) : my);
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
            cr.set_source_rgb (0.97, 0.98, 1.0);
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

// --- self test ---------------------------------------------------------

private int st_checks = 0;
private int st_fails = 0;

private void check (bool ok, string name) {
    st_checks = st_checks + 1;
    if (ok)
        return;
    st_fails = st_fails + 1;
    print (@"compositor: FAIL $name\n");
}

private int top_id (Compositor comp) {
    int id = 0;
    var t = comp.top_win ();
    if (t != null)
        id = t.id;
    return id;
}

private int at_id (Compositor comp, int px, int py) {
    int id = 0;
    var t = comp.top_at (px, py);
    if (t != null)
        id = t.id;
    return id;
}

private int self_test_run (Compositor comp) {
    // stack ordering and hit testing
    int a = comp.add ("alpha", 100, 80, 320, 200, Kind.TERMINAL);
    int b = comp.add ("beta", 180, 150, 300, 180, Kind.CLOCK);
    int c = comp.add ("gamma", 420, 100, 260, 160, Kind.NOTES);
    check (a == 1 && b == 2 && c == 3, "ids-sequential");
    check (comp.count () == 3, "count-is-3");
    check (top_id (comp) == 3, "top-is-last-added");
    check (comp.focus_id () == 3, "focus-is-last-added");
    check (at_id (comp, 150, 100) == 1, "hit-alpha");
    check (at_id (comp, 200, 160) == 2, "hit-topmost-on-overlap");
    check (at_id (comp, 770, 400) == 0, "hit-desktop-empty");
    check (comp.pointer_press (150, 200) == ACT_FOCUS, "click-content-focus");
    check (comp.focus_id () == 1, "click-raises-focus");
    check (top_id (comp) == 1, "click-raises-z");
    check (comp.pointer_press (770, 400) == ACT_NONE, "click-desktop-noop");
    check (comp.focus_id () == 1, "click-desktop-keeps-focus");

    // drag, clamp, close button
    var drag = new Compositor ();
    int p = drag.add ("p", 60, 60, 300, 200, Kind.TERMINAL);
    int q = drag.add ("q", 420, 300, 300, 200, Kind.CLOCK);
    check (drag.pointer_press (100, 70) == ACT_DRAG, "title-starts-drag");
    check (drag.dragging_active (), "drag-active");
    drag.drag_to (140, 90);
    check (drag.wx (p) == 100 && drag.wy (p) == 80, "drag-moves-window");
    drag.drag_to (-5000, -5000);
    check (drag.wx (p) == -220, "drag-clamps-left");
    check (drag.wy (p) == TOP_H, "drag-clamps-top");
    drag.pointer_release ();
    check (!drag.dragging_active (), "release-ends-drag");
    int cxp = -220 + 300 - BORDER - BTN_GAP - BTN + 2;
    int cyp = TOP_H + BORDER + (TITLE_H - BTN) / 2 + 2;
    check (drag.pointer_press (cxp, cyp) == ACT_CLOSE, "close-button-hit");
    check (!drag.alive (p), "close-button-closes");
    check (drag.count () == 1, "count-after-close");
    check (drag.focus_id () == q, "focus-falls-back-to-top");

    // maximize, keyboard moves, cycling, dock
    var kb = new Compositor ();
    int k1 = kb.add ("one", 50, 50, 300, 200, Kind.TERMINAL);
    int k2 = kb.add ("two", 380, 60, 300, 200, Kind.CLOCK);
    int k3 = kb.add ("three", 100, 320, 300, 180, Kind.NOTES);
    kb.key_press ('m');
    check (kb.maximized (k3) && kb.ww (k3) == SCREEN_W, "maximize-sizes");
    check (kb.wy (k3) == TOP_H, "maximize-offsets-top-bar");
    kb.key_press ('m');
    check (!kb.maximized (k3) && kb.ww (k3) == 300 && kb.wy (k3) == 320, "maximize-restores");
    kb.focus_nth (0);
    check (kb.focus_id () == k1, "focus-nth-first");
    kb.key_press ('l');
    check (kb.wx (k1) == 58, "key-moves-right");
    kb.key_press ('j');
    check (kb.wy (k1) == 58, "key-moves-down");
    kb.key_press (0x84);
    check (kb.wx (k1) == 66, "arrow-key-moves-right");
    int order1 = kb.focus_id ();
    kb.key_press (9);
    check (kb.focus_id () != order1, "tab-changes-focus");
    kb.key_press (9);
    kb.key_press (9);
    check (kb.focus_id () == order1, "tab-wraps-around");
    int dockx = DOCK_X0 + (DOCK_BTN_W + DOCK_BTN_GAP) + 10;
    check (kb.pointer_press (dockx, SCREEN_H - 10) == ACT_DOCK, "dock-button-hit");
    check (kb.focus_id () == k2, "dock-focuses-second");
    kb.key_press ('c');
    check (!kb.alive (k2) && kb.count () == 2, "key-closes-focused");

    // rendering smoke test (no framebuffer needed)
    var surf = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
    check (surf.buf_addr != 0, "surface-alloc");
    var cr = new Context (surf);
    kb.render (cr, 200, 200);
    check (surf.buf_addr != 0 && kb.count () == 2, "render-survives");

    // spir-v accent pipeline
    check (comp.shader_valid (), "shader-module-valid");
    check (comp.shader_words () > 0, "shader-words");
    check (comp.accent_ir () >= 0 && comp.accent_ir () <= 255, "accent-in-range");
    check (!comp.select_backend (BACKEND_VULKAN), "vulkan-needs-icd");
    check (comp.select_backend (BACKEND_CAIRO) && comp.backend () == BACKEND_CAIRO, "cairo-backend");

    // per-pixel SPIR-V background (gl_FragCoord) baked into PAT_STEP blocks
    check (comp.has_pattern (), "pattern-valid");
    int ps = comp.pattern_step ();
    check (comp.pattern_samples () == ((SCREEN_W + ps - 1) / ps) * ((SCREEN_H + ps - 1) / ps), "pattern-samples");
    check (comp.pattern_at (100, 100) != comp.pattern_at (700, 500), "pattern-varies-per-pixel");
    check (comp.pattern_has_uniforms (), "pattern-uniforms");
    int col_before = comp.pattern_at (400, 100);
    check (comp.animate_pattern (4.0), "pattern-animate-runs");
    check (comp.pattern_at (400, 100) != col_before, "pattern-animates-with-time");
    check (comp.animation_count () == 1, "animate-count");

    // damage merging and occlusion culling
    var mg = new Compositor ();
    var surf4 = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
    check (surf4.buf_addr != 0, "merge-surface-alloc");
    var cr4 = new Context (surf4);
    mg.flush (cr4, 0, 0);
    mg.damage (10, 10, 20, 20);
    mg.damage (25, 25, 20, 20);
    check (mg.damage_count () == 1, "damage-merges");
    check (mg.damage_pixels () == 35 * 35, "damage-merge-area");
    mg.damage (500, 400, 20, 20);
    check (mg.damage_count () == 2, "damage-keeps-distant");
    mg.flush (cr4, 0, 0);
    check (mg.damage_count () == 0, "merge-flush-clears");

    var occ = new Compositor ();
    occ.add ("low", 100, 100, 300, 200, Kind.TERMINAL);
    occ.add ("high", 60, 60, 420, 320, Kind.NOTES);
    var surv5 = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
    var cr5 = new Context (surv5);
    occ.flush (cr5, 0, 0);
    check (occ.occluded_count () == 1, "occlusion-skips-covered");
    occ.focus_nth (0);
    occ.flush (cr5, 0, 0);
    check (occ.occluded_count () == 0, "occlusion-none-when-raised");

    // damage tracking: only the dirty region is repainted
    var dmgc = new Compositor ();
    dmgc.add ("d", 200, 200, 200, 150, Kind.NOTES);
    check (dmgc.damage_is_full (), "add-damages-all");
    var surf2 = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
    check (surf2.buf_addr != 0, "damage-surface-alloc");
    var cr2 = new Context (surf2);
    dmgc.flush (cr2, 0, 0);
    check (!dmgc.damage_is_full () && dmgc.damage_count () == 0, "flush-clears-damage");
    cr2.set_source_rgb (1.0, 0.0, 1.0);
    cr2.paint ();
    dmgc.damage (300, 300, 40, 40);
    check (dmgc.damage_count () == 1 && dmgc.damage_pixels () == 1600, "damage-recorded");
    dmgc.flush (cr2, 0, 0);
    check (cr2.pixel_at (310, 310) != ((255 << 24) | (255 << 16) | (0 << 8) | 255), "damage-repaints-inside");
    check (cr2.pixel_at (700, 100) == ((255 << 24) | (255 << 16) | (0 << 8) | 255), "damage-keeps-outside");

    // modifiers: Alt+Tab, Alt+Q and Super+arrows
    var mod = new Compositor ();
    int m1 = mod.add ("m1", 40, 40, 260, 180, Kind.TERMINAL);
    int m2 = mod.add ("m2", 340, 60, 260, 180, Kind.CLOCK);
    int m3 = mod.add ("m3", 120, 300, 260, 160, Kind.NOTES);
    check (mod.focus_id () == m3, "mods-focus-last");
    mod.key_press_mod (9, Sys.MOD_ALT);
    check (mod.focus_id () != m3, "alt-tab-cycles");
    mod.focus_nth (1);
    check (mod.focus_id () == m2, "focus-second-window");
    mod.key_press_mod (0x84, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_RIGHT, "super-right-tiles");
    check (mod.ww (m2) == SCREEN_W / 2 && mod.wx (m2) == SCREEN_W / 2, "super-right-geometry");
    mod.key_press_mod (0x83, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_LEFT && mod.wx (m2) == 0, "super-left-tiles");
    mod.key_press_mod (0x81, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_MAX && mod.ww (m2) == SCREEN_W, "super-up-maximizes");
    mod.key_press_mod (0x82, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_NORMAL && mod.ww (m2) == 260, "super-down-restores");
    mod.key_press_mod ('q', Sys.MOD_ALT);
    check (!mod.alive (m2), "alt-q-closes-focused");
    check (mod.focus_id () != m2, "alt-q-moves-focus");

    // quit handling
    var qq = new Compositor ();
    qq.add ("x", 10, 40, 200, 150, Kind.NOTES);
    check (!qq.quit_requested (), "no-quit-by-default");
    qq.key_press (27);
    check (qq.quit_requested (), "esc-quits");

    // GTK window widget click + entry typing
    var gtkc = new Compositor ();
    int gw = gtkc.add ("gtk", 100, 100, 380, 240, Kind.GTK);
    var gsurf = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
    var gcr = new Context (gsurf);
    gtkc.flush (gcr, 0, 0);
    // Click Entry (around y = 100 + 24 + 12 + 30 = 166) and type 'x'
    gtkc.pointer_press (150, 166);
    gtkc.pointer_release ();
    gtkc.key_press ('x');
    // Click Increment button (around y = 205)
    gtkc.pointer_press (150, 205);
    gtkc.pointer_release ();
    gtkc.flush (gcr, 799, 599);
    check (gtkc.alive (gw), "gtk-win-alive-after-input");

    // VTE terminal typing
    var termc = new Compositor ();
    int tw = termc.add ("term", 40, 50, 400, 240, Kind.TERMINAL);
    termc.pointer_press (100, 120);
    termc.key_press ('h');
    termc.key_press ('e');
    termc.key_press ('l');
    termc.key_press ('p');
    termc.key_press ('\n');
    check (termc.alive (tw), "vte-term-alive");

    print (@"compositor:summary checks=$st_checks failures=$st_fails\n");
    return (st_fails == 0) ? 0 : 1;
}

// --- interactive -------------------------------------------------------

private int interactive (Compositor comp) {
    var win = Display.open_window (SCREEN_W, SCREEN_H);
    if (win == null) {
        print ("compositor: no framebuffer available\n");
        return 1;
    }
    comp.attach (win);
    var loop = new MainLoop ();
    timeout_add (16, () => {
        if (!comp.frame ()) {
            loop.quit ();
            return false;
        }
        return true;
    });
    loop.run ();
    comp.shutdown ();
    print (@"compositor: frames=$(comp.frame_count ()) windows=$(comp.count ()) dirty=$(comp.dirty_frame_count ()) flush_ms=$(comp.avg_flush_ms ()) blit_ms=$(comp.avg_blit_ms ())\n");
    return 0;
}

int main (string[] args) {
    bool self_test = false;
    bool want_shader = true;
    bool want_vulkan = false;
    bool want_pattern = true;
    bool want_animate = false;
    string shader_path = "frag.spv";
    string pattern_path = "frag_pattern.spv";
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--self-test") {
            self_test = true;
        } else if (args[i] == "--no-shader") {
            want_shader = false;
        } else if (args[i] == "--no-pattern") {
            want_pattern = false;
        } else if (args[i] == "--animate") {
            want_animate = true;
        } else if (args[i] == "--vulkan") {
            want_vulkan = true;
        } else if (args[i] == "--pattern") {
            if (i + 1 < args.length) {
                i = i + 1;
                pattern_path = args[i];
            }
        } else if (args[i] == "--shader") {
            if (i + 1 < args.length) {
                i = i + 1;
                shader_path = args[i];
            }
        } else {
            shader_path = args[i];
        }
    }

    var comp = new Compositor ();
    if (want_shader) {
        bool ok = comp.load_shader (shader_path);
        print (@"compositor: shader=$shader_path ok=$(ok ? 1 : 0) rgba=$(comp.accent_ir ()),$(comp.accent_ig ()),$(comp.accent_ib ())\n");
    }
    if (want_vulkan) {
        bool ok = comp.select_backend (BACKEND_VULKAN);
        print (@"compositor: backend=vulkan ok=$(ok ? 1 : 0) (no ICD yet, cairo fallback)\n");
    }
    if (want_animate)
        comp.set_pattern_step (16);
    if (want_pattern) {
        bool pok = comp.load_pattern (pattern_path);
        print (@"compositor: pattern=$pattern_path ok=$(pok ? 1 : 0) samples=$(comp.pattern_samples ()) uniforms=$(comp.pattern_has_uniforms () ? 1 : 0)\n");
        if (want_animate)
            comp.set_animation (true, 400);
        print (@"compositor: animate=$(want_animate ? 1 : 0) period_ms=400\n");
    }
    if (self_test)
        return self_test_run (comp);

    comp.seed ();
    print ("compositor: keys: tab cycle  drag=move  m max  c close  n new  1-9 focus  q quit\n");
    return interactive (comp);
}
