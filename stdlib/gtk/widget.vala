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

        // Single focus owner per window. Clicking the editor must take the
        // arrows away from a focused list, and clicking a toolbar button must not
        // clear the text focus just because the button was pressed.
        private static Widget? focus_owner;

        public bool has_focus () {
            return focus_owner == this;
        }

        public void grab_focus () {
            var prev = focus_owner;
            if (prev != null && prev != this)
                prev.drop_focus ();
            focus_owner = this;
            if (!focused) {
                focused = true;
                damage_self ();
            }
        }

        public void drop_focus () {
            if (focus_owner == this)
                focus_owner = null;
            if (!focused)
                return;
            focused = false;
            damage_self ();
        }

        private string measured_text = "";
        private double measured_size_px = -1.0;
        private int measured_w = 0;
        private int measured_h = 0;

        private const int DMG_MAX = 4;
        private int dmg_n = 0;
        private int[] dmg_rx = new int[4];
        private int[] dmg_ry = new int[4];
        private int[] dmg_rw = new int[4];
        private int[] dmg_rh = new int[4];

        /**
         * Records a rectangle this widget changed since the last repaint.
         *
         * Rectangles are kept apart when they are far from each other, so a
         * keystroke that touches an editor line and a status label in a distant
         * corner repaints both, not everything in between. Four rectangles is
         * the protocol ceiling; beyond that they collapse into one bounding box.
         */
        protected void damage_box (int bx, int by, int bw, int bh) {
            if (bw <= 0 || bh <= 0)
                return;
            for (int i = 0; i < dmg_n; i++) {
                if (bx < dmg_rx[i] + dmg_rw[i] + 4 && bx + bw + 4 > dmg_rx[i]
                        && by < dmg_ry[i] + dmg_rh[i] + 4 && by + bh + 4 > dmg_ry[i]) {
                    int x0 = (bx < dmg_rx[i]) ? bx : dmg_rx[i];
                    int y0 = (by < dmg_ry[i]) ? by : dmg_ry[i];
                    int x1 = (bx + bw > dmg_rx[i] + dmg_rw[i]) ? bx + bw : dmg_rx[i] + dmg_rw[i];
                    int y1 = (by + bh > dmg_ry[i] + dmg_rh[i]) ? by + bh : dmg_ry[i] + dmg_rh[i];
                    dmg_rx[i] = x0;
                    dmg_ry[i] = y0;
                    dmg_rw[i] = x1 - x0;
                    dmg_rh[i] = y1 - y0;
                    return;
                }
            }
            if (dmg_n < DMG_MAX) {
                dmg_rx[dmg_n] = bx;
                dmg_ry[dmg_n] = by;
                dmg_rw[dmg_n] = bw;
                dmg_rh[dmg_n] = bh;
                dmg_n = dmg_n + 1;
                return;
            }
            int mx0 = bx;
            int my0 = by;
            int mx1 = bx + bw;
            int my1 = by + bh;
            for (int i = 0; i < dmg_n; i++) {
                if (dmg_rx[i] < mx0) mx0 = dmg_rx[i];
                if (dmg_ry[i] < my0) my0 = dmg_ry[i];
                if (dmg_rx[i] + dmg_rw[i] > mx1) mx1 = dmg_rx[i] + dmg_rw[i];
                if (dmg_ry[i] + dmg_rh[i] > my1) my1 = dmg_ry[i] + dmg_rh[i];
            }
            dmg_rx[0] = mx0;
            dmg_ry[0] = my0;
            dmg_rw[0] = mx1 - mx0;
            dmg_rh[0] = my1 - my0;
            dmg_n = 1;
        }

        protected void damage_self () {
            damage_box (x, y, width, height);
        }

        public bool has_damage () {
            return dmg_n > 0;
        }

        public int damage_rect_count () {
            return dmg_n;
        }

        public bool damage_rect_at (int i, out int dx, out int dy, out int dw, out int dh) {
            dx = 0;
            dy = 0;
            dw = 0;
            dh = 0;
            if (i < 0 || i >= dmg_n)
                return false;
            dx = dmg_rx[i];
            dy = dmg_ry[i];
            dw = dmg_rw[i];
            dh = dmg_rh[i];
            return true;
        }

        public void clear_damage () {
            dmg_n = 0;
        }

        // Pulls a subtree's pending rectangles into this widget. Leaves keep
        // their own; containers override this to hoist their children's.
        public virtual void gather_damage () {
        }

        /**
         * Routes a key to the widget that owns focus.
         *
         * A widget that acts on keys without owning focus (a ScrolledWindow
         * scrolling itself) must not steal them from the focused editor, so the
         * window walks the tree for the focused widget first and only then falls
         * back to the legacy on_key_press chain.
         */
        public virtual bool handle_key (int key) {
            if (!visible || !sensitive || focus_owner != this)
                return false;
            return on_key_press (key);
        }

        // Bounding box of the pending damage, consumed on read. Kept for callers
        // that only need one rectangle (tests, single-region widgets).
        public virtual bool take_damage (out int dx, out int dy, out int dw, out int dh) {
            dx = 0;
            dy = 0;
            dw = 0;
            dh = 0;
            if (dmg_n == 0)
                return false;
            int x0 = dmg_rx[0];
            int y0 = dmg_ry[0];
            int x1 = dmg_rx[0] + dmg_rw[0];
            int y1 = dmg_ry[0] + dmg_rh[0];
            for (int i = 1; i < dmg_n; i++) {
                if (dmg_rx[i] < x0) x0 = dmg_rx[i];
                if (dmg_ry[i] < y0) y0 = dmg_ry[i];
                if (dmg_rx[i] + dmg_rw[i] > x1) x1 = dmg_rx[i] + dmg_rw[i];
                if (dmg_ry[i] + dmg_rh[i] > y1) y1 = dmg_ry[i] + dmg_rh[i];
            }
            dx = x0;
            dy = y0;
            dw = x1 - x0;
            dh = y1 - y0;
            clear_damage ();
            return true;
        }

        // Every frame re-measures the same strings; keep the last result so a
        // repaint does not walk the glyph cache for text that did not change.
        public void measure_text_cached (string text, double size_px, out int tw, out int th) {
            if (size_px == measured_size_px && text == measured_text) {
                tw = measured_w;
                th = measured_h;
                return;
            }
            TextHelper.measure_text (text, size_px, out measured_w, out measured_h);
            measured_text = text;
            measured_size_px = size_px;
            tw = measured_w;
            th = measured_h;
        }

        public void set_size_request (int w, int h) {
            req_w = (w < 0) ? 0 : w;
            req_h = (h < 0) ? 0 : h;
        }

        public void set_visible (bool v) {
            visible = v;
            if (!v) {
                hovered = false;
                pressed = false;
                drop_focus ();
            }
        }

        public void set_sensitive (bool s) {
            sensitive = s;
            if (!s) {
                hovered = false;
                pressed = false;
                drop_focus ();
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

        // Hover is drawn by the widgets that care (Button, CheckButton, Switch,
        // ListView row); a plain widget would repaint itself for nothing.
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
