// Top-level GtkWindow and event loop over Gdk.Window.poll_event().
using Planet;
using Cairo;
using Gdk;
using GLib;
using Gio;

namespace Gtk {

    private bool gtk_running = false;

    public void init (string[]? args = null) {
        gtk_running = true;
    }

    public void main_quit () {
        gtk_running = false;
    }

    public bool load_ttf (string path) {
        return TextHelper.load_ttf (path);
    }

    public class GtkWindow : Widget {
        public string title = "PlanetOS";
        public Widget? child = null;
        public Widget? titlebar = null;
        public bool resizable = true;
        public bool decorated = true;
        public weak GtkApplication? app_owner = null;
        private int default_w = 640;
        private int default_h = 420;
        private Window? gdk_win = null;
        private Context? cr = null;
        private int cur_mx = -1;
        private int cur_my = -1;

        public signal bool close_request ();

        public GtkWindow (int w = 640, int h = 420) {
            default_w = (w < 64) ? 64 : w;
            default_h = (h < 64) ? 64 : h;
            width = default_w;
            height = default_h;
        }

        ~GtkWindow () {
            destroy ();
        }

        public void set_title (string? t) {
            string nt = (t != null) ? t : "";
            if (nt == title)
                return;
            title = nt;
            damage_box (0, 0, width, 38);
        }

        public string get_title () {
            return title;
        }

        public void set_default_size (int w, int h) {
            default_w = (w < 64) ? 64 : w;
            default_h = (h < 64) ? 64 : h;
            width = default_w;
            height = default_h;
        }

        public void get_default_size (out int w, out int h) {
            w = default_w;
            h = default_h;
        }

        public void set_resizable (bool r) { resizable = r; }
        public bool get_resizable () { return resizable; }
        public void set_decorated (bool d) {
            if (decorated != d) {
                decorated = d;
                damage_self ();
            }
        }
        public bool get_decorated () { return decorated; }

        public void set_titlebar (Widget? tb) {
            if (titlebar != null)
                titlebar.unparent ();
            titlebar = tb;
            if (titlebar != null)
                titlebar.set_parent (this);
            damage_box (0, 0, width, 38);
        }

        public Widget? get_titlebar () {
            return titlebar;
        }

        public void add (Widget w) {
            set_child (w);
        }

        public void set_child (Widget? w) {
            if (child != null)
                child.unparent ();
            child = w;
            if (child != null)
                child.set_parent (this);
        }

        public Widget? get_child () {
            return child;
        }

        public void present () {
            show_all ();
        }

        public void close () {
            if (close_request ())
                return;
            destroy ();
            if (app_owner != null) {
                var app = app_owner;
                app.remove_window (this);
                if (app.get_windows ().length == 0)
                    main_quit ();
            } else {
                main_quit ();
            }
        }

        private bool focus_next (bool backward) {
            var flist = new GenericArray<Widget> ();
            if (titlebar != null)
                titlebar.collect_focusables (flist);
            if (child != null)
                child.collect_focusables (flist);
            if (flist.length == 0)
                return false;
            int cur = -1;
            for (int i = 0; i < flist.length; i++) {
                if (flist[i].has_focus ()) {
                    cur = i;
                    break;
                }
            }
            int next = 0;
            if (cur >= 0)
                next = backward ? ((cur + flist.length - 1) % flist.length) : ((cur + 1) % flist.length);
            else if (backward)
                next = flist.length - 1;
            flist[next].grab_focus ();
            return true;
        }

        public void destroy () {
            if (child != null) {
                child.unparent ();
                child = null;
            }
            if (titlebar != null) {
                titlebar.unparent ();
                titlebar = null;
            }
            if (gdk_win != null) {
                gdk_win.close ();
                gdk_win = null;
            }
            cr = null;
        }

        private void allocate_children () {
            int top_y = decorated ? 56 : 16;
            if (titlebar != null)
                titlebar.allocate (0, 0, width, 38);
            if (child != null) {
                int cw = (width > 40) ? (width - 40) : 0;
                int ch = (height > top_y + 20) ? (height - top_y - 20) : 0;
                child.allocate (20, top_y, cw, ch);
            }
        }

        public bool show_all () {
            if (gdk_win == null) {
                gdk_win = Display.open_window (width, height);
                if (gdk_win == null) {
                    print ("gtk: failed to open window (framebuffer busy or out of memory)\n");
                    gtk_running = false;
                    return false;
                }
                width = gdk_win.width;
                height = gdk_win.height;
                cr = gdk_win.create_cairo_context ();
            }
            allocate_children ();
            redraw ();
            return true;
        }

        public override void gather_damage () {
            hoist_child_damage (titlebar);
            hoist_child_damage (child);
        }

        public void redraw () {
            if (cr == null || gdk_win == null || !gdk_win.is_valid ())
                return;
            paint ();
            gdk_win.present ();
            // A full repaint already covers anything a widget queued while it
            // changed, so drop that damage instead of repainting it again.
            gather_damage ();
            clear_damage ();
        }

        // Repaints and publishes every pending rectangle (at most four, the
        // protocol ceiling). Distant changes stay separate instead of collapsing
        // into one bounding box that would repaint everything in between.
        private void redraw_damage () {
            if (cr == null || gdk_win == null || !gdk_win.is_valid ())
                return;
            gather_damage ();
            int n = damage_rect_count ();
            if (n <= 0)
                return;
            int[] xs = new int[n];
            int[] ys = new int[n];
            int[] ws = new int[n];
            int[] hs = new int[n];
            for (int i = 0; i < n; i++)
                damage_rect_at (i, out xs[i], out ys[i], out ws[i], out hs[i]);
            clear_damage ();
            for (int i = 0; i < n; i++) {
                cr.save ();
                cr.rectangle ((double) xs[i], (double) ys[i], (double) ws[i], (double) hs[i]);
                cr.clip ();
                paint ();
                cr.restore ();
            }
            gdk_win.present_rects (xs, ys, ws, hs, n);
        }

        /**
         * Repaints one damaged rectangle. The painter is the same, clipped, and
         * the compositor is told only that rectangle changed, so a keystroke
         * costs one editor line instead of the whole window.
         */
        public void redraw_area (int dx, int dy, int dw, int dh) {
            if (cr == null || gdk_win == null || !gdk_win.is_valid () || dw <= 0 || dh <= 0)
                return;
            cr.save ();
            cr.rectangle ((double) dx, (double) dy, (double) dw, (double) dh);
            cr.clip ();
            paint ();
            cr.restore ();
            gdk_win.present_rect (dx, dy, dw, dh);
        }

        private void paint () {
            if (cr == null || gdk_win == null)
                return;
            // Slate Atmosphere (#182028) window surface
            cr.set_source_rgb (0.094, 0.125, 0.157);
            cr.paint ();

            if (decorated) {
                if (titlebar != null) {
                    titlebar.render (cr);
                } else {
                    // Minimalist headerbar (Elevated Surface #212B36 -> Slate Atmosphere #182028)
                    cr.fill_gradient_v (0.0, 0.0, (double) width, 38.0, 0.129, 0.169, 0.212, 0.094, 0.125, 0.157);
                    // Stratosphere Line (#26323F)
                    cr.set_source_rgb (0.149, 0.196, 0.247);
                    cr.rectangle (0.0, 38.0, (double) width, 1.0);
                    cr.fill ();
                    // Lunar White (#F0F4F8)
                    cr.set_source_rgb (0.941, 0.957, 0.973);
                    TextHelper.draw_text (cr, title, 14, 10, 16.0);
                }
            }

            if (child != null)
                child.render (cr);

            if (!gdk_win.composited () && cur_mx >= 0 && cur_my >= 0) {
                cr.set_source_rgb (0.941, 0.957, 0.973);
                cr.rectangle ((double) cur_mx, (double) cur_my, 8.0, 12.0);
                cr.fill ();
                cr.set_source_rgb (0.059, 0.078, 0.098);
                cr.set_line_width (1.0);
                cr.rectangle ((double) cur_mx, (double) cur_my, 8.0, 12.0);
                cr.stroke ();
            }
        }

        public void run (bool once = false) {
            gtk_running = true;
            if (!show_all ())
                return;
            if (once) {
                if (gdk_win != null) {
                    gdk_win.close ();
                    gdk_win = null;
                }
                return;
            }
            var main_ctx = MainContext.default_ ();
            while (gtk_running && gdk_win != null) {
                bool dirty = false;
                bool had_motion = false;
                int mot_x = 0;
                int mot_y = 0;
                while (main_ctx.pending ()) {
                    if (!main_ctx.iteration (false))
                        break;
                    dirty = true;
                }
                while (true) {
                    var ev = gdk_win.poll_event ();
                    if (ev.type == EventType.NONE)
                        break;
                    if (ev.type == EventType.MOTION_NOTIFY) {
                        mot_x = ev.x;
                        mot_y = ev.y;
                        had_motion = true;
                        continue;
                    }
                    if (had_motion) {
                        cur_mx = mot_x;
                        cur_my = mot_y;
                        if (titlebar != null && titlebar.on_pointer_motion (mot_x, mot_y))
                            dirty = true;
                        if (child != null && child.on_pointer_motion (mot_x, mot_y))
                            dirty = true;
                        had_motion = false;
                    }
                    if (ev.type == EventType.KEY_PRESS) {
                        if (ev.keyval == 27) {
                            close ();
                            break;
                        }
                        if (ev.keyval == 9 || ev.keyval == 0xFF09) {
                            if (focus_next ((ev.state & 1) != 0))
                                dirty = true;
                            continue;
                        }
                        if (child != null && child.handle_key (ev.keyval))
                            dirty = true;
                    } else if (ev.type == EventType.BUTTON_PRESS) {
                        cur_mx = ev.x;
                        cur_my = ev.y;
                        if (titlebar != null) {
                            if (titlebar.on_pointer_motion (ev.x, ev.y))
                                dirty = true;
                            if (titlebar.on_pointer_press (ev.x, ev.y, ev.button))
                                dirty = true;
                        }
                        if (child != null) {
                            if (child.on_pointer_motion (ev.x, ev.y))
                                dirty = true;
                            if (child.on_pointer_press (ev.x, ev.y, ev.button))
                                dirty = true;
                        }
                    } else if (ev.type == EventType.SCROLL) {
                        cur_mx = ev.x;
                        cur_my = ev.y;
                        if (child != null) {
                            if (child.on_scroll (ev.x, ev.y, ev.scroll_dx, ev.scroll_dy))
                                dirty = true;
                            else if (child.on_pointer_press (ev.x, ev.y, ev.button))
                                dirty = true;
                        }
                    } else if (ev.type == EventType.BUTTON_RELEASE) {
                        cur_mx = ev.x;
                        cur_my = ev.y;
                        if (titlebar != null) {
                            if (titlebar.on_pointer_motion (ev.x, ev.y))
                                dirty = true;
                            if (titlebar.on_pointer_release (ev.x, ev.y, ev.button))
                                dirty = true;
                        }
                        if (child != null) {
                            if (child.on_pointer_motion (ev.x, ev.y))
                                dirty = true;
                            if (child.on_pointer_release (ev.x, ev.y, ev.button))
                                dirty = true;
                        }
                    }
                }
                if (had_motion && gtk_running) {
                    cur_mx = mot_x;
                    cur_my = mot_y;
                    if (titlebar != null && titlebar.on_pointer_motion (mot_x, mot_y))
                        dirty = true;
                    if (child != null && child.on_pointer_motion (mot_x, mot_y))
                        dirty = true;
                }
                if (!gtk_running)
                    break;
                if (gdk_win.width != width || gdk_win.height != height) {
                    width = gdk_win.width;
                    height = gdk_win.height;
                    allocate_children ();
                    dirty = true;
                }
                if (take_layout_dirty ()) {
                    allocate_children ();
                    dirty = true;
                }
                gather_damage ();
                int dn = damage_rect_count ();
                if (dn > 0)
                    redraw_damage ();
                else if (dirty)
                    redraw ();
                else
                    Sys.yield_cpu ();
            }
            if (gdk_win != null) {
                gdk_win.close ();
                gdk_win = null;
            }
        }
    }

    public class GtkApplicationWindow : GtkWindow {
        public GtkApplication? application = null;

        public GtkApplicationWindow (GtkApplication app, int w = 800, int h = 520) : base (w, h) {
            application = app;
            app.add_window (this);
        }
    }

    public class GtkApplication : Application {
        private GenericArray<GtkWindow> windows;

        public GtkApplication (string app_id = "org.planetos.App") : base (app_id, ApplicationFlags.FLAGS_NONE) {
            windows = new GenericArray<GtkWindow> ();
        }

        public void add_window (GtkWindow w) {
            for (int i = 0; i < windows.length; i++) {
                if (windows[i] == w)
                    return;
            }
            windows.add (w);
            w.app_owner = this;
            hold ();
        }

        public void remove_window (GtkWindow w) {
            for (int i = 0; i < windows.length; i++) {
                if (windows[i] == w) {
                    w.app_owner = null;
                    windows.remove_index (i);
                    release ();
                    return;
                }
            }
        }

        public GenericArray<GtkWindow> get_windows () {
            return windows;
        }

        public GtkWindow? get_active_window () {
            if (windows.length == 0)
                return null;
            return windows[windows.length - 1];
        }

        public void quit () {
            main_quit ();
        }

        public override int run (string[]? args = null) {
            init (args);
            activate ();
            var win = get_active_window ();
            if (win != null)
                win.run (false);
            return 0;
        }
    }
}
