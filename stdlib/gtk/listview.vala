// ListBox, ListBoxRow, and ListView widgets for PlanetOS Gtk.
using Cairo;
using Gio;

namespace Gtk {

    public enum SelectionMode {
        NONE,
        SINGLE,
        BROWSE,
        MULTIPLE
    }

    public class ListBoxRow : Widget {
        public Widget? child = null;
        public bool selected = false;
        public int index = -1;

        public ListBoxRow () {}

        public void set_child (Widget? w) {
            if (child != null)
                child.unparent ();
            child = w;
            if (child != null)
                child.set_parent (this);
            queue_resize ();
        }

        public Widget? get_child () {
            return child;
        }

        public bool is_selected () {
            return selected;
        }

        public int get_index () {
            return index;
        }

        public override SizeRequestMode get_request_mode () {
            if (child != null && child.visible)
                return child.get_request_mode ();
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure_for (Orientation measure_orient, int for_size,
                                          out int minimum, out int natural,
                                          out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (measure_orient == Orientation.VERTICAL && for_size >= 0 && child != null && child.visible) {
                int avail_w = (for_size > 12) ? (for_size - 12) : 0;
                int ch_min = 0;
                int ch_nat = 0;
                child.measure_height_for_width (avail_w, out ch_min, out ch_nat);
                int total = ch_min + 6;
                minimum = (req_h > total) ? req_h : total;
                natural = minimum;
                return;
            }
            int mw = 0;
            int mh = 0;
            measure (out mw, out mh);
            minimum = (measure_orient == Orientation.HORIZONTAL) ? mw : mh;
            natural = minimum;
        }

        public override void measure (out int min_w, out int min_h) {
            int cw = 80;
            int ch = 26;
            if (child != null && child.visible)
                child.measure (out cw, out ch);
            min_w = (req_w > (cw + 12)) ? req_w : (cw + 12);
            min_h = (req_h > (ch + 6)) ? req_h : (ch + 6);
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
            if (child != null)
                child.allocate (ax + 6, ay + 3, (width > 12) ? (width - 12) : 0, (height > 6) ? (height - 6) : 0);
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            if (selected) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.220, 0.592, 0.941);
                cr.rectangle ((double) x, (double) y, (double) width, (double) height);
                cr.fill ();
            } else if (hovered) {
                // Elevated Surface (#212B36)
                cr.set_source_rgb (0.129, 0.169, 0.212);
                cr.rectangle ((double) x, (double) y, (double) width, (double) height);
                cr.fill ();
            }
            if (child != null)
                child.render (cr);
        }

        public override void gather_damage () {
            hoist_child_damage (child);
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive)
                return false;
            if (child != null && child.handle_key (key))
                return true;
            return base.handle_key (key);
        }

        public override bool on_pointer_motion (int mx, int my) {
            bool changed = base.on_pointer_motion (mx, my);
            if (visible && sensitive && child != null && child.on_pointer_motion (mx, my))
                changed = true;
            return changed;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.on_pointer_press (mx, my, button);
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.on_pointer_release (mx, my, button);
        }

        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.on_scroll (mx, my, dx, dy);
        }
    }

    public class ListBox : Widget {
        private GenericArray<ListBoxRow> rows;
        public SelectionMode selection_mode = SelectionMode.SINGLE;
        private int selected_index = -1;

        public signal void row_selected (ListBoxRow? row);
        public signal void row_activated (ListBoxRow row);

        public ListBox () {
            rows = new GenericArray<ListBoxRow> ();
        }

        public void set_selection_mode (SelectionMode mode) {
            selection_mode = mode;
            if (mode == SelectionMode.NONE)
                unselect_all ();
        }

        public SelectionMode get_selection_mode () {
            return selection_mode;
        }

        private void reindex () {
            for (int i = 0; i < rows.length; i++)
                rows[i].index = i;
        }

        private ListBoxRow wrap_row (Widget child) {
            ListBoxRow row;
            if (child is ListBoxRow) {
                row = (ListBoxRow) child;
            } else {
                row = new ListBoxRow ();
                row.set_child (child);
            }
            row.set_parent (this);
            return row;
        }

        public void append (Widget child) {
            rows.add (wrap_row (child));
            reindex ();
            queue_resize ();
        }

        public void prepend (Widget child) {
            insert (child, 0);
        }

        public void insert (Widget child, int position) {
            var row = wrap_row (child);
            if (position < 0 || position >= rows.length) {
                rows.add (row);
                reindex ();
                return;
            }
            var nr = new GenericArray<ListBoxRow> ();
            for (int i = 0; i < rows.length; i++) {
                if (i == position)
                    nr.add (row);
                nr.add (rows[i]);
            }
            rows = nr;
            if (selected_index >= position)
                selected_index++;
            reindex ();
            queue_resize ();
        }

        public void unselect_all () {
            bool changed = false;
            for (int i = 0; i < rows.length; i++) {
                if (rows[i].selected) {
                    rows[i].selected = false;
                    changed = true;
                }
            }
            if (selected_index != -1) {
                selected_index = -1;
                changed = true;
            }
            if (changed) {
                row_selected (null);
                damage_self ();
            }
        }

        public void unselect_row (ListBoxRow row) {
            if (!row.selected)
                return;
            row.selected = false;
            if (selected_index >= 0 && selected_index < rows.length && rows[selected_index] == row)
                selected_index = -1;
            row_selected (null);
            damage_self ();
        }

        public void remove (Widget child) {
            for (int i = 0; i < rows.length; i++) {
                if (rows[i] == child || rows[i].get_child () == child) {
                    rows[i].unparent ();
                    rows.remove_index (i);
                    if (selected_index == i)
                        selected_index = -1;
                    else if (selected_index > i)
                        selected_index--;
                    reindex ();
                    damage_self ();
                    return;
                }
            }
        }

        public void remove_all () {
            for (int i = 0; i < rows.length; i++)
                rows[i].unparent ();
            rows = new GenericArray<ListBoxRow> ();
            selected_index = -1;
            damage_self ();
        }

        public int get_count () {
            return rows.length;
        }

        public ListBoxRow? get_row_at_index (int idx) {
            if (idx < 0 || idx >= rows.length)
                return null;
            return rows[idx];
        }

        public ListBoxRow? get_selected_row () {
            if (selected_index < 0 || selected_index >= rows.length)
                return null;
            return rows[selected_index];
        }

        public GenericArray<ListBoxRow> get_selected_rows () {
            var res = new GenericArray<ListBoxRow> ();
            for (int i = 0; i < rows.length; i++) {
                if (rows[i].selected)
                    res.add (rows[i]);
            }
            return res;
        }

        public void select_row (ListBoxRow? row) {
            if (selection_mode == SelectionMode.NONE)
                return;
            if (selection_mode == SelectionMode.MULTIPLE) {
                if (row == null)
                    return;
                for (int i = 0; i < rows.length; i++) {
                    if (rows[i] == row) {
                        row.selected = !row.selected;
                        selected_index = row.selected ? i : -1;
                        row_selected (row);
                        damage_self ();
                        return;
                    }
                }
                return;
            }
            for (int i = 0; i < rows.length; i++)
                rows[i].selected = false;
            selected_index = -1;
            if (row != null) {
                for (int i = 0; i < rows.length; i++) {
                    if (rows[i] == row) {
                        row.selected = true;
                        selected_index = i;
                        break;
                    }
                }
            }
            row_selected (row);
            damage_self ();
        }

        public override void gather_damage () {
            for (int i = 0; i < rows.length; i++)
                hoist_child_damage (rows[i]);
        }

        public override bool handle_key (int key) {
            for (int i = 0; i < rows.length; i++) {
                if (rows[i].handle_key (key))
                    return true;
            }
            return on_key_press (key);
        }

        public override SizeRequestMode get_request_mode () {
            for (int i = 0; i < rows.length; i++) {
                if (rows[i].visible && rows[i].get_request_mode () == SizeRequestMode.HEIGHT_FOR_WIDTH)
                    return SizeRequestMode.HEIGHT_FOR_WIDTH;
            }
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure_for (Orientation measure_orient, int for_size,
                                          out int minimum, out int natural,
                                          out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (measure_orient == Orientation.VERTICAL && for_size >= 0) {
                int total_h = 0;
                for (int i = 0; i < rows.length; i++) {
                    if (!rows[i].visible)
                        continue;
                    int rh = 0;
                    int rh_nat = 0;
                    rows[i].measure_height_for_width (for_size, out rh, out rh_nat);
                    total_h += rh;
                }
                minimum = (req_h > total_h) ? req_h : total_h;
                natural = minimum;
                return;
            }
            int mw = 0;
            int mh = 0;
            measure (out mw, out mh);
            minimum = (measure_orient == Orientation.HORIZONTAL) ? mw : mh;
            natural = minimum;
        }

        public override void measure (out int min_w, out int min_h) {
            int max_w = 120;
            int total_h = 0;
            for (int i = 0; i < rows.length; i++) {
                if (!rows[i].visible)
                    continue;
                int rw = 0;
                int rh = 0;
                rows[i].measure (out rw, out rh);
                if (rw > max_w) max_w = rw;
                total_h += rh;
            }
            min_w = (req_w > max_w) ? req_w : max_w;
            min_h = (req_h > total_h) ? req_h : total_h;
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
            int cy = ay;
            for (int i = 0; i < rows.length; i++) {
                if (!rows[i].visible)
                    continue;
                int rh = 0;
                int rh_nat = 0;
                rows[i].measure_height_for_width (width, out rh, out rh_nat);
                rows[i].allocate (ax, cy, width, rh);
                cy += rh;
            }
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            for (int i = 0; i < rows.length; i++)
                rows[i].render (cr);
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (!visible || !sensitive)
                return false;
            bool ch = false;
            for (int i = 0; i < rows.length; i++) {
                if (rows[i].on_pointer_motion (mx, my))
                    ch = true;
            }
            return ch;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1)
                return false;
            for (int i = 0; i < rows.length; i++) {
                if (rows[i].visible && rows[i].contains (mx, my)) {
                    grab_focus ();
                    bool already = (selected_index == i);
                    select_row (rows[i]);
                    if (already)
                        row_activated (rows[i]);
                    return true;
                }
            }
            return false;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive || rows.length == 0)
                return false;
            if (key == 0x81 || key == 0xFF52) { // Up
                int nxt = (selected_index > 0) ? (selected_index - 1) : 0;
                select_row (rows[nxt]);
                return true;
            }
            if (key == 0x82 || key == 0xFF54) { // Down
                int nxt = (selected_index + 1 < rows.length) ? (selected_index + 1) : (rows.length - 1);
                select_row (rows[nxt]);
                return true;
            }
            if (key == '\n' || key == '\r') {
                if (selected_index >= 0 && selected_index < rows.length) {
                    row_activated (rows[selected_index]);
                    return true;
                }
            }
            return false;
        }
    }

    public class ListView : Widget {
        private GenericArray<string> labels;
        private GenericArray<string> icon_names;
        private Gio.ListStore<string>? bound_model = null;
        public int row_height = 28;
        public bool single_click_activate = false;
        private int selected_index = -1;
        private int hovered_index = -1;
        public double font_size = 14.0;

        public signal void selection_changed (int position);
        public signal void activate (int position);

        public ListView () {
            labels = new GenericArray<string> ();
            icon_names = new GenericArray<string> ();
        }

        public void set_single_click_activate (bool sca) { single_click_activate = sca; }
        public bool get_single_click_activate () { return single_click_activate; }

        public void set_model (Gio.ListStore<string>? model) {
            bound_model = model;
            sync_from_model ();
            if (model != null) {
                weak ListView? self_weak = this;
                model.items_changed.connect ((sender, pos, rem, add) => {
                    if (self_weak == null || self_weak.bound_model != model)
                        return;
                    if (rem == 0 && add == 1 && pos == self_weak.labels.length) {
                        self_weak.labels.add (model.get_item (pos));
                        self_weak.queue_resize ();
                    } else {
                        self_weak.sync_from_model ();
                    }
                });
            }
        }

        private void sync_from_model () {
            var next = new GenericArray<string> ();
            if (bound_model != null) {
                int n = bound_model.get_n_items ();
                for (int i = 0; i < n; i++)
                    next.add (bound_model.get_item (i));
            }
            set_items (next, null);
        }

        public void set_items (GenericArray<string> items, GenericArray<string>? icons = null) {
            labels = items;
            icon_names = new GenericArray<string> ();
            if (icons != null) {
                for (int i = 0; i < icons.length; i++)
                    icon_names.add (icons[i]);
            }
            if (selected_index >= labels.length)
                selected_index = -1;
            hovered_index = -1;
            damage_self ();
        }

        public int get_count () {
            return labels.length;
        }

        public int get_selected () {
            return selected_index;
        }

        public void set_selected (int idx) {
            if (idx < -1 || idx >= labels.length)
                return;
            if (selected_index != idx) {
                selected_index = idx;
                damage_self ();
                selection_changed (idx);
            }
        }

        public void scroll_to (int pos) {
            if (pos < 0 || pos >= labels.length)
                return;
            set_selected (pos);
            var p = get_parent ();
            if (p != null && p is ScrolledWindow) {
                ((ScrolledWindow) p).ensure_visible (pos * row_height, row_height);
            }
        }

        public override void measure (out int min_w, out int min_h) {
            int total_h = labels.length * row_height;
            min_w = (req_w > 180) ? req_w : 180;
            min_h = (req_h > total_h) ? req_h : total_h;
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0 || row_height <= 0 || labels.length == 0)
                return;
            cr.save ();
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.clip ();
            int i0 = (cr.clip_top () - y) / row_height;
            int i1 = (cr.clip_bottom () - y) / row_height;
            if (i0 < 0) i0 = 0;
            if (i1 >= labels.length) i1 = labels.length - 1;
            for (int i = i0; i <= i1; i++) {
                int ry = y + i * row_height;
                if (i == selected_index) {
                    // Celestial Cerulean (#3897F0)
                    cr.set_source_rgb (0.220, 0.592, 0.941);
                    cr.rectangle ((double) x, (double) ry, (double) width, (double) row_height);
                    cr.fill ();
                } else if (i == hovered_index) {
                    // Elevated Surface (#212B36)
                    cr.set_source_rgb (0.129, 0.169, 0.212);
                    cr.rectangle ((double) x, (double) ry, (double) width, (double) row_height);
                    cr.fill ();
                }
                int tx = x + 10;
                if (i < icon_names.length && icon_names[i].length > 0) {
                    Image.draw_builtin_icon (cr, icon_names[i], x + 8, ry + 5, row_height - 10);
                    tx = x + row_height + 4;
                }
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.941, 0.957, 0.973);
                TextHelper.draw_text (cr, labels[i], tx, ry + (row_height - 16) / 2, font_size);
            }
            cr.restore ();
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (!visible || !sensitive || row_height <= 0)
                return false;
            int nh = -1;
            if (contains (mx, my)) {
                int idx = (my - y) / row_height;
                if (idx >= 0 && idx < labels.length)
                    nh = idx;
            }
            if (nh != hovered_index) {
                hovered_index = nh;
                damage_self ();
                return true;
            }
            return false;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1 || row_height <= 0 || !contains (mx, my))
                return false;
            int idx = (my - y) / row_height;
            if (idx >= 0 && idx < labels.length) {
                grab_focus ();
                bool already = (selected_index == idx);
                set_selected (idx);
                if (already || single_click_activate)
                    activate (idx);
                return true;
            }
            return false;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive || labels.length == 0)
                return false;
            if (key == 0x81 || key == 0xFF52) {
                set_selected ((selected_index > 0) ? (selected_index - 1) : 0);
                return true;
            }
            if (key == 0x82 || key == 0xFF54) {
                set_selected ((selected_index + 1 < labels.length) ? (selected_index + 1) : (labels.length - 1));
                return true;
            }
            if (key == 0x85) {
                set_selected (0);
                return true;
            }
            if (key == 0x86) {
                set_selected (labels.length - 1);
                return true;
            }
            if ((key == '\n' || key == '\r') && selected_index >= 0) {
                activate (selected_index);
                return true;
            }
            return false;
        }
    }
}
