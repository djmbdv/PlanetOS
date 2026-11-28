// Base Widget class and Orientation enum for PlanetOS Gtk.
using Cairo;
using Gsk;

namespace Gtk {

    private class WidgetRenderNode : RenderNode {
        private weak Widget target;

        public WidgetRenderNode (Widget w) {
            target = w;
        }

        public override void draw_cairo (Context cr) {
            if (target != null)
                target.draw (cr);
        }
    }

    public enum Orientation {
        HORIZONTAL,
        VERTICAL
    }

    public enum Align {
        FILL,
        START,
        END,
        CENTER,
        BASELINE
    }

    public enum PolicyType {
        ALWAYS,
        AUTOMATIC,
        NEVER,
        EXTERNAL
    }

    public enum SizeRequestMode {
        HEIGHT_FOR_WIDTH,
        WIDTH_FOR_HEIGHT,
        CONSTANT_SIZE
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
        public bool hexpand = false;
        public bool vexpand = false;
        public Align halign = Align.FILL;
        public Align valign = Align.FILL;
        public int margin_top = 0;
        public int margin_bottom = 0;
        public int margin_start = 0;
        public int margin_end = 0;
        public bool can_focus = true;
        public bool focusable = true;
        public double opacity = 1.0;
        public string name = "";
        public string? tooltip_text = null;

        private weak Widget? parent_widget = null;
        private bool layout_dirty = false;

        // Single focus owner per window. Clicking the editor must take the
        // arrows away from a focused list, and clicking a toolbar button must not
        // clear the text focus just because the button was pressed.
        private static weak Widget? focus_owner;

        ~Widget () {
            drop_focus ();
            parent_widget = null;
        }

        public Widget? get_parent () {
            return parent_widget;
        }

        public void set_parent (Widget? parent) {
            parent_widget = parent;
        }

        public void unparent () {
            parent_widget = null;
            drop_focus ();
        }

        public bool has_focus () {
            return focus_owner == this;
        }

        public void grab_focus () {
            if (!can_focus || !focusable || !visible || !sensitive)
                return;
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

        protected void hoist_child_damage (Widget? child) {
            if (child == null)
                return;
            child.gather_damage ();
            int n = child.damage_rect_count ();
            for (int j = 0; j < n; j++) {
                int cx = 0;
                int cy = 0;
                int cw = 0;
                int ch = 0;
                if (child.damage_rect_at (j, out cx, out cy, out cw, out ch))
                    damage_box (cx, cy, cw, ch);
            }
            child.clear_damage ();
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
            var (mw, mh) = TextHelper.measure_text_size (text, size_px);
            measured_w = mw;
            measured_h = mh;
            measured_text = text;
            measured_size_px = size_px;
            tw = measured_w;
            th = measured_h;
        }

        public void set_size_request (int w, int h) {
            req_w = (w < 0) ? 0 : w;
            req_h = (h < 0) ? 0 : h;
        }

        public void get_size_request (out int w, out int h) {
            w = req_w;
            h = req_h;
        }

        public int get_width () { return width; }
        public int get_height () { return height; }
        public int get_allocated_width () { return width; }
        public int get_allocated_height () { return height; }

        public bool get_visible () { return visible; }

        public void show () { set_visible (true); }
        public void hide () { set_visible (false); }

        public void set_visible (bool v) {
            if (visible == v)
                return;
            visible = v;
            if (!v) {
                hovered = false;
                pressed = false;
                drop_focus ();
            }
            damage_self ();
        }

        public bool get_sensitive () { return sensitive; }

        public bool is_sensitive () {
            if (!sensitive)
                return false;
            var p = parent_widget;
            while (p != null) {
                if (!p.sensitive)
                    return false;
                p = p.parent_widget;
            }
            return true;
        }

        public void set_sensitive (bool s) {
            if (sensitive == s)
                return;
            sensitive = s;
            if (!s) {
                hovered = false;
                pressed = false;
                drop_focus ();
            }
            damage_self ();
        }

        public void set_hexpand (bool expand) {
            if (hexpand != expand) { hexpand = expand; queue_resize (); }
        }
        public bool get_hexpand () { return hexpand; }
        public void set_vexpand (bool expand) {
            if (vexpand != expand) { vexpand = expand; queue_resize (); }
        }
        public bool get_vexpand () { return vexpand; }

        public void set_halign (Align align) {
            if (halign != align) { halign = align; queue_resize (); }
        }
        public Align get_halign () { return halign; }
        public void set_valign (Align align) {
            if (valign != align) { valign = align; queue_resize (); }
        }
        public Align get_valign () { return valign; }

        public void set_margin_top (int m) {
            int nm = (m < 0) ? 0 : m;
            if (margin_top != nm) { margin_top = nm; queue_resize (); }
        }
        public int get_margin_top () { return margin_top; }
        public void set_margin_bottom (int m) {
            int nm = (m < 0) ? 0 : m;
            if (margin_bottom != nm) { margin_bottom = nm; queue_resize (); }
        }
        public int get_margin_bottom () { return margin_bottom; }
        public void set_margin_start (int m) {
            int nm = (m < 0) ? 0 : m;
            if (margin_start != nm) { margin_start = nm; queue_resize (); }
        }
        public int get_margin_start () { return margin_start; }
        public void set_margin_end (int m) {
            int nm = (m < 0) ? 0 : m;
            if (margin_end != nm) { margin_end = nm; queue_resize (); }
        }
        public int get_margin_end () { return margin_end; }

        public void set_can_focus (bool cf) {
            can_focus = cf;
            if (!cf) drop_focus ();
        }
        public bool get_can_focus () { return can_focus; }
        public void set_focusable (bool f) {
            focusable = f;
            if (!f) drop_focus ();
        }
        public bool get_focusable () { return focusable; }

        public void set_opacity (double op) {
            double clamped = (op < 0.0) ? 0.0 : ((op > 1.0) ? 1.0 : op);
            if (clamped != opacity) {
                opacity = clamped;
                damage_self ();
            }
        }
        public double get_opacity () { return opacity; }

        public void set_name (string n) { name = n; }
        public string get_name () { return name; }
        public void set_tooltip_text (string? text) { tooltip_text = text; }
        public string? get_tooltip_text () { return tooltip_text; }

        public void queue_draw () { damage_self (); }
        public void queue_resize () {
            layout_dirty = true;
            var p = parent_widget;
            while (p != null) {
                p.layout_dirty = true;
                p = p.parent_widget;
            }
            damage_self ();
        }

        public bool take_layout_dirty () {
            bool d = layout_dirty;
            layout_dirty = false;
            return d;
        }

        // GTK4-compatible orientation-based measurement.
        public virtual SizeRequestMode get_request_mode () {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public virtual void measure_for (Orientation orientation, int for_size,
                                         out int minimum, out int natural,
                                         out int minimum_baseline, out int natural_baseline) {
            int mw = 0;
            int mh = 0;
            measure (out mw, out mh);
            minimum = (orientation == Orientation.HORIZONTAL) ? mw : mh;
            natural = minimum;
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        public void measure_height_for_width (int for_width, out int min_h, out int nat_h) {
            int mb = 0;
            int nb = 0;
            measure_for (Orientation.VERTICAL, for_width, out min_h, out nat_h, out mb, out nb);
        }

        public void measure_width_for_height (int for_height, out int min_w, out int nat_w) {
            int mb = 0;
            int nb = 0;
            measure_for (Orientation.HORIZONTAL, for_height, out min_w, out nat_w, out mb, out nb);
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

        public void render (Context cr) {
            if (!visible || opacity <= 0.0)
                return;
            if (opacity >= 1.0) {
                draw (cr);
                return;
            }
            cr.save ();
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.clip ();
            var op_node = new Gsk.OpacityNode (new WidgetRenderNode (this), opacity);
            op_node.draw_cairo (cr);
            cr.restore ();
        }

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

        public virtual void collect_focusables (GenericArray<Widget> out_list) {
            if (visible && sensitive && can_focus && focusable)
                out_list.add (this);
        }
    }
}
