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

        public void show_all () {
            if (gdk_win == null) {
                gdk_win = Display.open_window (width, height);
                if (gdk_win == null)
                    gdk_win = new Window (width, height);
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
        }

        public void redraw () {
            if (cr == null || gdk_win == null || !gdk_win.is_valid ())
                return;
            // elementary OS Granite light window surface (#F5F5F5)
            cr.set_source_rgb (0.96, 0.96, 0.96);
            cr.paint ();

            // Minimalist headerbar (#F2F2F2 -> #E5E5E5)
            cr.fill_gradient_v (0.0, 0.0, (double) width, 38.0, 0.95, 0.95, 0.95, 0.90, 0.90, 0.90);
            cr.set_source_rgb (0.78, 0.78, 0.78);
            cr.rectangle (0.0, 38.0, (double) width, 1.0);
            cr.fill ();
            cr.set_source_rgb (0.20, 0.20, 0.20);
            TextHelper.draw_text (cr, title, 14, 10, 16.0);

            if (child != null)
                child.draw (cr);

            if (cur_mx >= 0 && cur_my >= 0) {
                cr.set_source_rgb (1.0, 1.0, 1.0);
                cr.rectangle ((double) cur_mx, (double) cur_my, 8.0, 12.0);
                cr.fill ();
                cr.set_source_rgb (0.1, 0.1, 0.1);
                cr.set_line_width (1.0);
                cr.rectangle ((double) cur_mx, (double) cur_my, 8.0, 12.0);
                cr.stroke ();
            }
            gdk_win.present ();
        }

        public void run (bool once = false) {
            gtk_running = true;
            show_all ();
            if (once) {
                if (gdk_win != null) {
                    gdk_win.close ();
                    gdk_win = null;
                }
                return;
            }
            while (gtk_running && gdk_win != null) {
                bool dirty = false;
                while (true) {
                    var ev = gdk_win.poll_event ();
                    if (ev.type == EventType.NONE)
                        break;
                    if (ev.type == EventType.KEY_PRESS) {
                        if (ev.keyval == 27) {
                            main_quit ();
                            break;
                        }
                        if (child != null && child.on_key_press (ev.keyval))
                            dirty = true;
                    } else if (ev.type == EventType.MOTION_NOTIFY) {
                        cur_mx = ev.x;
                        cur_my = ev.y;
                        if (child != null && child.on_pointer_motion (ev.x, ev.y))
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
                if (!gtk_running)
                    break;
                if (dirty)
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
