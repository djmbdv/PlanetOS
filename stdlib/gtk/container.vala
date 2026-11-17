// Layout container (Box) for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public class Box : Widget {
        public Orientation orientation = Orientation.VERTICAL;
        public int spacing = 8;
        public GenericArray<Widget> children;

        public Box (Orientation orient = Orientation.VERTICAL, int sp = 8) {
            orientation = orient;
            spacing = sp;
            children = new GenericArray<Widget> ();
        }

        public void pack_start (Widget child, bool expand = false, bool fill = true, int padding = 0) {
            children.add (child);
        }

        public void add (Widget child) {
            children.add (child);
        }

        public override void measure (out int min_w, out int min_h) {
            int total_w = 0;
            int total_h = 0;
            int vis_count = 0;
            for (int i = 0; i < children.length; i++) {
                var c = children[i];
                if (!c.visible)
                    continue;
                int cw = 0;
                int ch = 0;
                c.measure (out cw, out ch);
                if (orientation == Orientation.VERTICAL) {
                    if (cw > total_w) total_w = cw;
                    total_h += ch;
                } else {
                    total_w += cw;
                    if (ch > total_h) total_h = ch;
                }
                vis_count++;
            }
            if (vis_count > 1) {
                if (orientation == Orientation.VERTICAL)
                    total_h += (vis_count - 1) * spacing;
                else
                    total_w += (vis_count - 1) * spacing;
            }
            min_w = (req_w > total_w) ? req_w : total_w;
            min_h = (req_h > total_h) ? req_h : total_h;
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = aw;
            height = ah;
            int cx = ax;
            int cy = ay;
            for (int i = 0; i < children.length; i++) {
                var c = children[i];
                if (!c.visible)
                    continue;
                int cw = 0;
                int ch = 0;
                c.measure (out cw, out ch);
                if (orientation == Orientation.VERTICAL) {
                    c.allocate (cx, cy, aw, ch);
                    cy += ch + spacing;
                } else {
                    c.allocate (cx, cy, cw, ah);
                    cx += cw + spacing;
                }
            }
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            for (int i = 0; i < children.length; i++) {
                children[i].draw (cr);
            }
        }

        public override bool on_pointer_motion (int mx, int my) {
            bool changed = false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].on_pointer_motion (mx, my))
                    changed = true;
            }
            return changed;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            bool hit = false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].on_pointer_press (mx, my, button))
                    hit = true;
            }
            return hit;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            bool hit = false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].on_pointer_release (mx, my, button))
                    hit = true;
            }
            return hit;
        }

        public override bool on_key_press (int key) {
            for (int i = 0; i < children.length; i++) {
                if (children[i].on_key_press (key))
                    return true;
            }
            return false;
        }
    }
}
