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
using Spv;
using Cairo;
using Gdk;
using Wm;

namespace Wm {
    public const int SCREEN_W = 800;
    public const int SCREEN_H = 600;
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

    public enum Kind { TERMINAL, CLOCK, SHADER, NOTES }

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
        public int rx;
        public int ry;
        public int rw;
        public int rh;

        public Win (int id, string title, int x, int y, int w, int h, Kind kind) {
            this.id = id;
            this.title = title;
            this.x = x;
            this.y = y;
            this.w = w;
            this.h = h;
            this.kind = kind;
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
        private int drag_ox = 0;
        private int drag_oy = 0;
        private bool quit = false;
        private int frames = 0;
        private Module shader;
        private bool shader_ok = false;
        private int backend_id = 0;
        private double acc_r = 0.227;
        private double acc_g = 0.518;
        private double acc_b = 0.882;

        public Compositor () {
            wins = new GenericArray<Win> ();
            shader = new Module ();
        }

        // --- plumbing -------------------------------------------------

        public void attach (Window w) {
            screen = w;
            attached = true;
        }

        public void shutdown () {
            if (attached)
                screen.close ();
        }

        public bool frame () {
            for (int i = 0; i < 16; i++) {
                var ev = screen.poll_event ();
                if (ev.type == EventType.NONE)
                    break;
                if (ev.type == EventType.KEY_PRESS) {
                    key_press (ev.keyval);
                } else if (ev.type == EventType.BUTTON_PRESS) {
                    pointer_press (ev.x, ev.y);
                } else if (ev.type == EventType.MOTION_NOTIFY) {
                    if (dragging)
                        drag_to (ev.x, ev.y);
                }
            }
            if (dragging) {
                if ((screen.pointer_mask () & 1) == 0)
                    pointer_release ();
                else
                    drag_to (screen.pointer_x (), screen.pointer_y ());
            }
            var cr = new Context (screen.surface);
            render (cr, screen.pointer_x (), screen.pointer_y ());
            screen.present ();
            frames = frames + 1;
            return !quit;
        }

        public int frame_count () { return frames; }
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
            return win.id;
        }

        public void raise (int id) {
            var w = find (id);
            if (w == null)
                return;
            ztop = ztop + 1;
            w.z = ztop;
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
            if (!w.maximized) {
                w.rx = w.x;
                w.ry = w.y;
                w.rw = w.w;
                w.rh = w.h;
                w.x = 0;
                w.y = TOP_H;
                w.w = SCREEN_W;
                w.h = WORK_H;
                w.maximized = true;
            } else {
                w.x = w.rx;
                w.y = w.ry;
                w.w = w.rw;
                w.h = w.rh;
                w.maximized = false;
            }
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
            w.x = clamp_x (w.x + dx, w.w);
            w.y = clamp_y (w.y + dy, w.h);
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
            if (w.in_title (px, py) && !w.maximized) {
                dragging = true;
                drag_id = id;
                drag_ox = px - w.x;
                drag_oy = py - w.y;
                return ACT_DRAG;
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
            w.x = clamp_x (px - drag_ox, w.w);
            w.y = clamp_y (py - drag_oy, w.h);
        }

        public void pointer_motion (int px, int py) {
            if (dragging)
                drag_to (px, py);
        }

        public void pointer_release () {
            dragging = false;
            drag_id = 0;
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
            if (k == 27 || k == 'q' || k == 'Q') {
                quit = true;
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

        // --- scene ----------------------------------------------------

        public void seed () {
            add ("terminal", 96, 90, 360, 220, Kind.TERMINAL);
            add ("shader", 300, 190, 340, 210, Kind.SHADER);
            add ("clock", 520, 120, 230, 200, Kind.CLOCK);
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
            draw_background (cr);
            draw_windows (cr);
            draw_dock (cr);
            draw_top_bar (cr);
            draw_cursor (cr, mx, my);
        }

        private void draw_background (Context cr) {
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

        private void draw_top_bar (Context cr) {
            cr.set_source_rgb (0.071, 0.086, 0.125);
            cr.rectangle (0, 0, SCREEN_W, TOP_H);
            cr.fill ();
            cr.set_source_rgb (acc_r, acc_g, acc_b);
            cr.rectangle (0, TOP_H - 2, SCREEN_W, 2);
            cr.fill ();

            cr.set_font_size (16);
            cr.set_source_rgb (0.86, 0.90, 0.96);
            cr.move_to (12, 6);
            cr.show_text ("PLANETOS");

            string t = "desktop";
            var w = find (focused_id);
            if (w != null)
                t = w.title;
            cr.set_source_rgb (acc_r, acc_g, acc_b);
            cr.move_to (110, 6);
            cr.show_text_n (t, 26);

            cr.set_source_rgb (0.55, 0.62, 0.73);
            cr.move_to (SCREEN_W - 190, 6);
            cr.show_text (@"$(count ()) win");
            cr.move_to (SCREEN_W - 120, 6);
            cr.show_text (@"t=$(Sys.ticks ())");
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
                draw_window (cr, pick);
                lastz = pickz;
                drawn = drawn + 1;
            }
        }

        private void draw_window (Context cr, Win w) {
            bool foc = (w.id == focused_id);

            // Shadow only along the right/bottom bands: the inner area is
            // overwritten by the window body, so blending it would be wasted.
            cr.set_source_rgba (0.0, 0.0, 0.0, 0.45);
            cr.rectangle (w.x + w.w, w.y + SHADOW, SHADOW, w.h);
            cr.fill ();
            cr.rectangle (w.x + SHADOW, w.y + w.h, w.w, SHADOW);
            cr.fill ();

            cr.set_source_rgb (0.113, 0.133, 0.176);
            cr.rectangle (w.x, w.y, w.w, w.h);
            cr.fill ();

            draw_content (cr, w);

            if (foc)
                cr.set_source_rgb (acc_r, acc_g, acc_b);
            else
                cr.set_source_rgb (0.243, 0.275, 0.341);
            cr.set_line_width (1);
            cr.rectangle (w.x, w.y, w.w, w.h);
            cr.stroke ();

            if (foc)
                cr.set_source_rgb (acc_r * 0.40 + 0.06, acc_g * 0.40 + 0.07, acc_b * 0.40 + 0.10);
            else
                cr.set_source_rgb (0.161, 0.184, 0.239);
            cr.rectangle (w.x + BORDER, w.y + BORDER, w.w - 2 * BORDER, TITLE_H);
            cr.fill ();

            cr.set_font_size (16);
            if (foc)
                cr.set_source_rgb (0.97, 0.98, 1.0);
            else
                cr.set_source_rgb (0.71, 0.76, 0.84);
            int maxc = (w.w - 96) / 12;
            if (maxc < 4)
                maxc = 4;
            cr.move_to (w.x + 10, w.y + BORDER + 7);
            cr.show_text_n (w.title, maxc);

            int by = w.btn_y ();
            cr.set_source_rgba (1.0, 1.0, 1.0, 0.12);
            cr.rectangle (w.max_x (), by, BTN, BTN);
            cr.fill ();
            cr.rectangle (w.close_x (), by, BTN, BTN);
            cr.fill ();
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

        private void draw_content (Context cr, Win w) {
            int cx = w.x + BORDER;
            int cy = w.content_y ();
            int cw = w.w - 2 * BORDER;
            int ch = w.content_h ();
            if (ch <= 0 || cw <= 0)
                return;

            if (w.kind == Kind.TERMINAL) {
                cr.set_source_rgb (0.051, 0.063, 0.090);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                cr.set_font_size (16);
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                cr.move_to (cx + 12, cy + 12);
                cr.show_text ("planetsh /");
                cr.set_source_rgb (0.72, 0.78, 0.86);
                cr.move_to (cx + 12, cy + 34);
                cr.show_text ("id  " + @"$(w.id)");
                cr.move_to (cx + 12, cy + 52);
                cr.show_text ("pos " + @"$(w.x),$(w.y)");
                cr.move_to (cx + 12, cy + 70);
                cr.show_text ("size " + @"$(w.w)x$(w.h)");
                cr.set_source_rgb (0.45, 0.52, 0.62);
                cr.move_to (cx + 12, cy + 96);
                cr.show_text ("tab cycle  drag move");
                cr.move_to (cx + 12, cy + 114);
                cr.show_text ("m max  c close  q quit");
            } else if (w.kind == Kind.CLOCK) {
                cr.set_source_rgb (0.086, 0.102, 0.137);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                int rad = ch / 2 - 18;
                if (rad > cw / 2 - 16)
                    rad = cw / 2 - 16;
                if (rad < 20)
                    rad = 20;
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

                cr.set_font_size (16);
                cr.set_source_rgb (0.72, 0.78, 0.86);
                cr.move_to (cx + 10, cy + ch - 26);
                cr.show_text (@"T+$(pad2 (min)):$(pad2 (sec))");
            } else if (w.kind == Kind.SHADER) {
                cr.set_source_rgb (0.086, 0.102, 0.137);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                cr.set_source_rgba (acc_r, acc_g, acc_b, 1.0);
                cr.rectangle (cx + 14, cy + 16, 56, 56);
                cr.fill ();
                cr.set_line_width (1);
                cr.set_source_rgb (0.30, 0.34, 0.42);
                cr.rectangle (cx + 14, cy + 16, 56, 56);
                cr.stroke ();

                cr.set_font_size (16);
                cr.set_source_rgb (0.90, 0.93, 0.97);
                cr.move_to (cx + 84, cy + 20);
                cr.show_text ("spir-v frag");
                cr.set_source_rgb (0.66, 0.72, 0.81);
                cr.move_to (cx + 84, cy + 40);
                if (shader_ok)
                    cr.show_text (@"words $(shader.words)");
                else
                    cr.show_text ("no module");
                cr.move_to (cx + 84, cy + 58);
                if (shader_ok)
                    cr.show_text (@"insns $(shader.insns)");
                else
                    cr.show_text ("cpu accent");
                cr.move_to (cx + 14, cy + 92);
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                cr.show_text (@"rgba $(accent_ir ()) $(accent_ig ()) $(accent_ib ())");
                cr.set_source_rgb (0.45, 0.52, 0.62);
                cr.move_to (cx + 14, cy + 118);
                cr.show_text ("vulkan backend: pending");
            } else {
                cr.set_source_rgb (0.086, 0.102, 0.137);
                cr.rectangle (cx, cy, cw, ch);
                cr.fill ();
                cr.set_font_size (16);
                cr.set_source_rgb (0.90, 0.93, 0.97);
                cr.move_to (cx + 14, cy + 14);
                cr.show_text ("notes");
                cr.set_source_rgb (0.62, 0.69, 0.78);
                cr.move_to (cx + 14, cy + 38);
                cr.show_text ("openbox interaction model");
                cr.move_to (cx + 14, cy + 56);
                cr.show_text ("gala style shadows + dock");
                cr.move_to (cx + 14, cy + 74);
                cr.show_text ("100% vala, no mutter");
                cr.move_to (cx + 14, cy + 92);
                cr.show_text ("gdk + cairo framebuffer");
                cr.set_source_rgb (acc_r, acc_g, acc_b);
                cr.move_to (cx + 14, cy + 116);
                cr.show_text ("spir-v accent pipeline");
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
                cr.rectangle (bx, by, DOCK_BTN_W, DOCK_H - 10);
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
                cr.move_to (bx + 10, by + 5);
                cr.show_text_n (w.title, 18);
            }
        }

        private void draw_cursor (Context cr, int mx, int my) {
            int x = (mx > 0 && mx < SCREEN_W) ? mx : SCREEN_W / 2;
            int y = (my > 0 && my < SCREEN_H) ? my : SCREEN_H / 2;
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

    // quit handling
    var qq = new Compositor ();
    qq.add ("x", 10, 40, 200, 150, Kind.NOTES);
    check (!qq.quit_requested (), "no-quit-by-default");
    qq.key_press (27);
    check (qq.quit_requested (), "esc-quits");

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
    timeout_add (33, () => {
        if (!comp.frame ()) {
            loop.quit ();
            return false;
        }
        return true;
    });
    loop.run ();
    comp.shutdown ();
    print (@"compositor: frames=$(comp.frame_count ()) windows=$(comp.count ())\n");
    return 0;
}

int main (string[] args) {
    bool self_test = false;
    bool want_shader = true;
    bool want_vulkan = false;
    string shader_path = "frag.spv";
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--self-test") {
            self_test = true;
        } else if (args[i] == "--no-shader") {
            want_shader = false;
        } else if (args[i] == "--vulkan") {
            want_vulkan = true;
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
    if (self_test)
        return self_test_run (comp);

    comp.seed ();
    print ("compositor: keys: tab cycle  drag=move  m max  c close  n new  1-9 focus  q quit\n");
    return interactive (comp);
}
