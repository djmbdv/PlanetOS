// Layout container (Box) for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public class Box : Widget {
        public Orientation orientation = Orientation.VERTICAL;
        public int spacing = 8;
        public GenericArray<Widget> children;
        private GenericArray<bool> expands;
        private GenericArray<bool> fills;
        private GenericArray<int> paddings;

        public Box (Orientation orient = Orientation.VERTICAL, int sp = 8) {
            orientation = orient;
            spacing = (sp < 0) ? 0 : sp;
            children = new GenericArray<Widget> ();
            expands = new GenericArray<bool> ();
            fills = new GenericArray<bool> ();
            paddings = new GenericArray<int> ();
        }

        public void pack_start (Widget child, bool expand = false, bool fill = true, int padding = 0) {
            children.add (child);
            expands.add (expand);
            fills.add (fill);
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
                    fills.remove_index (i);
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
                    int alloc_w = fills[i] ? width : ((cw < width) ? cw : width);
                    c.allocate (cx, cy + pad, alloc_w, alloc_h);
                    cy += alloc_h + pad * 2 + spacing;
                } else {
                    int alloc_w = cw + bonus;
                    int alloc_h = fills[i] ? height : ((ch < height) ? ch : height);
                    c.allocate (cx + pad, cy, alloc_w, alloc_h);
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

        public override void gather_damage () {
            for (int i = 0; i < children.length; i++) {
                children[i].gather_damage ();
                int n = children[i].damage_rect_count ();
                for (int j = 0; j < n; j++) {
                    int x = 0;
                    int y = 0;
                    int w = 0;
                    int h = 0;
                    if (children[i].damage_rect_at (j, out x, out y, out w, out h))
                        damage_box (x, y, w, h);
                }
                children[i].clear_damage ();
            }
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive)
                return false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].handle_key (key))
                    return true;
            }
            return on_key_press (key);
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

        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive)
                return false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].on_scroll (mx, my, dx, dy))
                    return true;
            }
            return false;
        }
    }

    /**
     * Single-child container with an optional titled border.
     */
    public class Frame : Widget {
        public string? label = null;
        public Widget? child = null;
        public int pad = 8;

        public Frame (string? title = null) {
            label = title;
        }

        public void set_child (Widget? w) {
            child = w;
        }

        public void set_label (string? title) {
            label = title;
        }

        private int header_height () {
            return (label != null && label.length > 0) ? 22 : 4;
        }

        public override void measure (out int min_w, out int min_h) {
            int cw = 40;
            int ch = 20;
            if (child != null && child.visible)
                child.measure (out cw, out ch);
            int hh = header_height ();
            min_w = cw + pad * 2 + 2;
            min_h = ch + hh + pad * 2 + 2;
            if (req_w > min_w) min_w = req_w;
            if (req_h > min_h) min_h = req_h;
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
            if (child != null) {
                int hh = header_height ();
                int cw = width - pad * 2;
                int ch = height - hh - pad;
                if (cw < 0) cw = 0;
                if (ch < 0) ch = 0;
                child.allocate (x + pad, y + hh, cw, ch);
            }
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            cr.set_source_rgb (0.98, 0.98, 0.99);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 6.0);
            cr.fill ();
            cr.set_source_rgb (0.80, 0.82, 0.86);
            cr.set_line_width (1.0);
            cr.rounded_rectangle ((double) x + 0.5, (double) y + 0.5, (double) (width - 1), (double) (height - 1), 6.0);
            cr.stroke ();
            if (label != null && label.length > 0) {
                cr.set_source_rgb (0.25, 0.28, 0.34);
                TextHelper.draw_text (cr, label, x + pad, y + 4, 13.0);
            }
            if (child != null)
                child.draw (cr);
        }

        public override void gather_damage () {
            if (child == null)
                return;
            child.gather_damage ();
            int n = child.damage_rect_count ();
            for (int j = 0; j < n; j++) {
                int x = 0;
                int y = 0;
                int w = 0;
                int h = 0;
                if (child.damage_rect_at (j, out x, out y, out w, out h))
                    damage_box (x, y, w, h);
            }
            child.clear_damage ();
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive || child == null)
                return false;
            if (child.handle_key (key))
                return true;
            return on_key_press (key);
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.on_pointer_motion (mx, my);
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.on_pointer_press (mx, my, button);
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (child == null)
                return false;
            return child.on_pointer_release (mx, my, button);
        }

        public override bool on_key_press (int key) {
            if (child == null)
                return false;
            return child.on_key_press (key);
        }

        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.on_scroll (mx, my, dx, dy);
        }
    }
}
