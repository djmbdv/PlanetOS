// Top-level GtkWindow and event loop over Gdk.Window.poll_event().
using Planet;
using Cairo;
using Gdk;

namespace Gtk {

    private bool gtk_running = false;

    public void init (string[] args) {
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
        private Window? gdk_win = null;
        private Context? cr = null;
        private int cur_mx = -1;
        private int cur_my = -1;

        public GtkWindow (int w = 640, int h = 420) {
            width = (w < 64) ? 64 : w;
            height = (h < 64) ? 64 : h;
        }

        ~GtkWindow () {
            if (gdk_win != null) {
                gdk_win.close ();
                gdk_win = null;
            }
        }

        public void set_title (string t) {
            title = t;
        }

        public void set_default_size (int w, int h) {
            width = (w < 64) ? 64 : w;
            height = (h < 64) ? 64 : h;
        }

        public void add (Widget w) {
            child = w;
        }

        public void set_child (Widget? w) {
            child = w;
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
            if (child != null) {
                int cw = (width > 40) ? (width - 40) : 0;
                int ch = (height > 76) ? (height - 76) : 0;
                child.allocate (20, 56, cw, ch);
            }
            redraw ();
            return true;
        }

        public void redraw () {
            if (cr == null || gdk_win == null || !gdk_win.is_valid ())
                return;
            paint ();
            gdk_win.present ();
            // A full repaint already covers anything a widget queued while it
            // changed, so drop that damage instead of repainting it again.
            if (child != null) {
                child.gather_damage ();
                child.clear_damage ();
            }
        }

        // Repaints and publishes every pending rectangle (at most four, the
        // protocol ceiling). Distant changes stay separate instead of collapsing
        // into one bounding box that would repaint everything in between.
        private void redraw_damage () {
            if (child == null || cr == null || gdk_win == null || !gdk_win.is_valid ())
                return;
            child.gather_damage ();
            int n = child.damage_rect_count ();
            if (n <= 0)
                return;
            int[] xs = new int[n];
            int[] ys = new int[n];
            int[] ws = new int[n];
            int[] hs = new int[n];
            for (int i = 0; i < n; i++)
                child.damage_rect_at (i, out xs[i], out ys[i], out ws[i], out hs[i]);
            child.clear_damage ();
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

            // Minimalist headerbar (Elevated Surface #212B36 -> Slate Atmosphere #182028)
            cr.fill_gradient_v (0.0, 0.0, (double) width, 38.0, 0.129, 0.169, 0.212, 0.094, 0.125, 0.157);
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.rectangle (0.0, 38.0, (double) width, 1.0);
            cr.fill ();
            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.941, 0.957, 0.973);
            TextHelper.draw_text (cr, title, 14, 10, 16.0);

            if (child != null)
                child.draw (cr);

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
            while (gtk_running && gdk_win != null) {
                bool dirty = false;
                bool had_motion = false;
                int mot_x = 0;
                int mot_y = 0;
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
                        if (child != null && child.on_pointer_motion (mot_x, mot_y))
                            dirty = true;
                        had_motion = false;
                    }
                    if (ev.type == EventType.KEY_PRESS) {
                        if (ev.keyval == 27) {
                            main_quit ();
                            break;
                        }
                        if (child != null && child.handle_key (ev.keyval))
                            dirty = true;
                    } else if (ev.type == EventType.BUTTON_PRESS) {
                        cur_mx = ev.x;
                        cur_my = ev.y;
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
                    if (child != null && child.on_pointer_motion (mot_x, mot_y))
                        dirty = true;
                }
                if (!gtk_running)
                    break;
                int dn = 0;
                if (child != null) {
                    child.gather_damage ();
                    dn = child.damage_rect_count ();
                }
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

    public class GtkApplication : Object {
        public string application_id;
        private GtkWindow? active_win = null;

        public signal void activate ();

        public GtkApplication (string app_id = "org.planetos.App") {
            application_id = app_id;
        }

        public void add_window (GtkWindow w) {
            active_win = w;
        }

        public GtkWindow? get_active_window () {
            return active_win;
        }

        public int run (string[] args) {
            init (args);
            activate ();
            if (active_win != null)
                active_win.run (false);
            return 0;
        }
    }
}
