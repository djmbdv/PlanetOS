// Layout container (Box) for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public class Box : Widget {
        public Orientation orientation = Orientation.VERTICAL;
        public int spacing = 8;
        public GenericArray<Widget> children;
        private GenericArray<bool> expands;
        private GenericArray<int> paddings;

        public Box (Orientation orient = Orientation.VERTICAL, int sp = 8) {
            orientation = orient;
            spacing = (sp < 0) ? 0 : sp;
            children = new GenericArray<Widget> ();
            expands = new GenericArray<bool> ();
            paddings = new GenericArray<int> ();
        }

        public void pack_start (Widget child, bool expand = false, bool fill = true, int padding = 0) {
            children.add (child);
            expands.add (expand);
            paddings.add ((padding < 0) ? 0 : padding);
        }

        public void add (Widget child) {
            pack_start (child, false, true, 0);
        }

        public bool remove (Widget child) {
            for (int i = 0; i < children.length; i++) {
                if (children[i] == child) {
                    children.remove_index (i);
                    expands.remove_index (i);
                    paddings.remove_index (i);
                    return true;
                }
            }
            return false;
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
                int pad = paddings[i] * 2;
                if (orientation == Orientation.VERTICAL) {
                    if (cw > total_w) total_w = cw;
                    total_h += ch + pad;
                } else {
                    total_w += cw + pad;
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
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;

            int min_w = 0;
            int min_h = 0;
            measure (out min_w, out min_h);
            int exp_count = 0;
            for (int i = 0; i < children.length; i++) {
                if (children[i].visible && expands[i])
                    exp_count++;
            }
            int extra = 0;
            if (exp_count > 0) {
                int avail = (orientation == Orientation.VERTICAL) ? (height - min_h) : (width - min_w);
                if (avail > 0)
                    extra = avail / exp_count;
            }

            int cx = ax;
            int cy = ay;
            for (int i = 0; i < children.length; i++) {
                var c = children[i];
                if (!c.visible)
                    continue;
                int cw = 0;
                int ch = 0;
                c.measure (out cw, out ch);
                int pad = paddings[i];
                int bonus = expands[i] ? extra : 0;
                if (orientation == Orientation.VERTICAL) {
                    int alloc_h = ch + bonus;
                    c.allocate (cx, cy + pad, width, alloc_h);
                    cy += alloc_h + pad * 2 + spacing;
                } else {
                    int alloc_w = cw + bonus;
                    c.allocate (cx + pad, cy, alloc_w, height);
                    cx += alloc_w + pad * 2 + spacing;
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
            if (!visible || !sensitive)
                return false;
            bool changed = false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].on_pointer_motion (mx, my))
                    changed = true;
            }
            return changed;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive)
                return false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].on_pointer_press (mx, my, button))
                    return true;
            }
            return false;
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
