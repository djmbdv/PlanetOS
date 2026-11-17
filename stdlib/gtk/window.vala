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
            width = w;
            height = h;
        }

        public void set_title (string t) {
            title = t;
        }

        public void set_default_size (int w, int h) {
            width = w;
            height = h;
        }

        public void add (Widget w) {
            child = w;
        }

        public void show_all () {
            if (gdk_win == null) {
                gdk_win = Display.open_window (width, height);
                if (gdk_win == null)
                    gdk_win = new Window (width, height);
                cr = gdk_win.create_cairo_context ();
            }
            if (child != null)
                child.allocate (20, 56, width - 40, height - 76);
            redraw ();
        }

        public void redraw () {
            if (cr == null || gdk_win == null)
                return;
            cr.set_source_rgb (0.09, 0.11, 0.14);
            cr.paint ();

            cr.fill_gradient_v (0.0, 0.0, (double) width, 38.0, 0.16, 0.19, 0.25, 0.12, 0.14, 0.19);
            cr.set_source_rgb (0.28, 0.33, 0.42);
            cr.rectangle (0.0, 38.0, (double) width, 1.0);
            cr.fill ();
            cr.set_source_rgb (0.94, 0.96, 0.98);
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
            show_all ();
            if (once) {
                if (gdk_win != null)
                    gdk_win.close ();
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
                        if (child != null)
                            child.on_pointer_motion (ev.x, ev.y);
                        dirty = true;
                    } else if (ev.type == EventType.BUTTON_PRESS) {
                        cur_mx = ev.x;
                        cur_my = ev.y;
                        if (child != null) {
                            child.on_pointer_motion (ev.x, ev.y);
                            child.on_pointer_press (ev.x, ev.y, ev.button);
                        }
                        dirty = true;
                    } else if (ev.type == EventType.BUTTON_RELEASE) {
                        cur_mx = ev.x;
                        cur_my = ev.y;
                        if (child != null) {
                            child.on_pointer_motion (ev.x, ev.y);
                            child.on_pointer_release (ev.x, ev.y, ev.button);
                        }
                        dirty = true;
                    }
                }
                if (!gtk_running)
                    break;
                if (dirty)
                    redraw ();
                else
                    Sys.yield_cpu ();
            }
            if (gdk_win != null)
                gdk_win.close ();
        }
    }
}
