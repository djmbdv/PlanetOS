// Base Widget class and Orientation enum for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public enum Orientation {
        HORIZONTAL,
        VERTICAL
    }

    public class Widget : Object {
        public int x = 0;
        public int y = 0;
        public int width = 0;
        public int height = 0;
        public int req_w = 0;
        public int req_h = 0;
        public bool visible = true;
        public bool sensitive = true;
        public bool hovered = false;
        public bool pressed = false;
        public bool focused = false;

        public void set_size_request (int w, int h) {
            req_w = (w < 0) ? 0 : w;
            req_h = (h < 0) ? 0 : h;
        }

        public void set_visible (bool v) {
            visible = v;
            if (!v) {
                hovered = false;
                pressed = false;
                focused = false;
            }
        }

        public void set_sensitive (bool s) {
            sensitive = s;
            if (!s) {
                hovered = false;
                pressed = false;
                focused = false;
            }
        }

        public bool contains (int px, int py) {
            return width > 0 && height > 0 && px >= x && px < (x + width) && py >= y && py < (y + height);
        }

        public virtual void measure (out int min_w, out int min_h) {
            min_w = req_w;
            min_h = req_h;
        }

        public virtual void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
        }

        public virtual void draw (Context cr) {}

        public virtual bool on_pointer_motion (int mx, int my) {
            bool prev = hovered;
            hovered = visible && sensitive && contains (mx, my);
            return hovered != prev;
        }

        public virtual bool on_pointer_press (int mx, int my, int button) {
            return false;
        }

        public virtual bool on_pointer_release (int mx, int my, int button) {
            return false;
        }

        public virtual bool on_key_press (int key) {
            return false;
        }

        public virtual bool on_scroll (int mx, int my, int dx, int dy) {
            return false;
        }
    }
}
