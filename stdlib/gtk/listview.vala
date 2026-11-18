// ListBox, ListBoxRow, and ListView widgets for PlanetOS Gtk.
using Cairo;

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
            child = w;
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
                cr.set_source_rgb (0.18, 0.34, 0.56);
                cr.rectangle ((double) x, (double) y, (double) width, (double) height);
                cr.fill ();
            } else if (hovered) {
                cr.set_source_rgb (0.15, 0.19, 0.25);
                cr.rectangle ((double) x, (double) y, (double) width, (double) height);
                cr.fill ();
            }
            if (child != null)
                child.draw (cr);
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
        }

        private void reindex () {
            for (int i = 0; i < rows.length; i++)
                rows[i].index = i;
        }

        public void append (Widget child) {
            ListBoxRow row;
            if (child is ListBoxRow) {
                row = (ListBoxRow) child;
            } else {
                row = new ListBoxRow ();
                row.set_child (child);
            }
            rows.add (row);
            reindex ();
        }

        public void remove (Widget child) {
            for (int i = 0; i < rows.length; i++) {
                if (rows[i] == child || rows[i].get_child () == child) {
                    rows.remove_index (i);
                    if (selected_index == i)
                        selected_index = -1;
                    else if (selected_index > i)
                        selected_index--;
                    reindex ();
                    return;
                }
            }
        }

        public void remove_all () {
            rows = new GenericArray<ListBoxRow> ();
            selected_index = -1;
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

        public void select_row (ListBoxRow? row) {
            if (selection_mode == SelectionMode.NONE)
                return;
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
                int rw = 0;
                int rh = 0;
                rows[i].measure (out rw, out rh);
                rows[i].allocate (ax, cy, width, rh);
                cy += rh;
            }
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            for (int i = 0; i < rows.length; i++)
                rows[i].draw (cr);
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
                    focused = true;
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
            if (key == 0xFF52) { // Up
                int nxt = (selected_index > 0) ? (selected_index - 1) : 0;
                select_row (rows[nxt]);
                return true;
            }
            if (key == 0xFF54) { // Down
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
        public int row_height = 28;
        private int selected_index = -1;
        private int hovered_index = -1;
        public double font_size = 14.0;

        public signal void selection_changed (int position);
        public signal void activate (int position);

        public ListView () {
            labels = new GenericArray<string> ();
            icon_names = new GenericArray<string> ();
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
                selection_changed (idx);
            }
        }

        public override void measure (out int min_w, out int min_h) {
            int total_h = labels.length * row_height;
            min_w = (req_w > 180) ? req_w : 180;
            min_h = (req_h > total_h) ? req_h : total_h;
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            for (int i = 0; i < labels.length; i++) {
                int ry = y + i * row_height;
                if (i == selected_index) {
                    cr.set_source_rgb (0.18, 0.34, 0.56);
                    cr.rectangle ((double) x, (double) ry, (double) width, (double) row_height);
                    cr.fill ();
                } else if (i == hovered_index) {
                    cr.set_source_rgb (0.15, 0.19, 0.25);
                    cr.rectangle ((double) x, (double) ry, (double) width, (double) row_height);
                    cr.fill ();
                }
                int tx = x + 10;
                if (i < icon_names.length && icon_names[i].length > 0) {
                    Image.draw_builtin_icon (cr, icon_names[i], x + 8, ry + 5, row_height - 10);
                    tx = x + row_height + 4;
                }
                cr.set_source_rgb (0.93, 0.95, 0.98);
                TextHelper.draw_text (cr, labels[i], tx, ry + (row_height - 16) / 2, font_size);
            }
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (!visible || !sensitive)
                return false;
            int nh = -1;
            if (contains (mx, my)) {
                int idx = (my - y) / row_height;
                if (idx >= 0 && idx < labels.length)
                    nh = idx;
            }
            if (nh != hovered_index) {
                hovered_index = nh;
                return true;
            }
            return false;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1 || !contains (mx, my))
                return false;
            int idx = (my - y) / row_height;
            if (idx >= 0 && idx < labels.length) {
                focused = true;
                bool already = (selected_index == idx);
                set_selected (idx);
                if (already)
                    activate (idx);
                return true;
            }
            return false;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive || labels.length == 0)
                return false;
            if (key == 0xFF52) {
                set_selected ((selected_index > 0) ? (selected_index - 1) : 0);
                return true;
            }
            if (key == 0xFF54) {
                set_selected ((selected_index + 1 < labels.length) ? (selected_index + 1) : (labels.length - 1));
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
