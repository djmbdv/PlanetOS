// ScrolledWindow, Paned, and Notebook containers for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public class ScrolledWindow : Widget {
        public Widget? child = null;
        public int scroll_x = 0;
        public int scroll_y = 0;
        public PolicyType hscrollbar_policy = PolicyType.AUTOMATIC;
        public PolicyType vscrollbar_policy = PolicyType.AUTOMATIC;
        public int min_content_width = 0;
        public int min_content_height = 0;
        private int content_w = 0;
        private int content_h = 0;
        private int natural_w = 0;
        private int natural_h = 0;
        private bool sb_dragging = false;
        private bool sb_hovered = false;
        private int sb_drag_off = 0;
        private const int SB_W = 10;

        public ScrolledWindow () {
            req_w = 160;
            req_h = 120;
        }

        public void set_child (Widget? w) {
            if (child != null)
                child.unparent ();
            child = w;
            if (child != null)
                child.set_parent (this);
            scroll_x = 0;
            scroll_y = 0;
            sb_dragging = false;
        }

        public Widget? get_child () {
            return child;
        }

        public void set_policy (PolicyType hpolicy, PolicyType vpolicy) {
            hscrollbar_policy = hpolicy;
            vscrollbar_policy = vpolicy;
            damage_self ();
        }

        public void get_policy (out PolicyType hpolicy, out PolicyType vpolicy) {
            hpolicy = hscrollbar_policy;
            vpolicy = vscrollbar_policy;
        }

        public void set_min_content_width (int w) {
            min_content_width = (w < 0) ? 0 : w;
        }
        public int get_min_content_width () { return min_content_width; }

        public void set_min_content_height (int h) {
            min_content_height = (h < 0) ? 0 : h;
        }
        public int get_min_content_height () { return min_content_height; }

        public void add (Widget w) {
            set_child (w);
        }

        public void scroll_to (int sx, int sy) {
            int max_x = (content_w > width) ? (content_w - width) : 0;
            int max_y = (content_h > height) ? (content_h - height) : 0;
            int nx = (sx < 0) ? 0 : ((sx > max_x) ? max_x : sx);
            int ny = (sy < 0) ? 0 : ((sy > max_y) ? max_y : sy);
            if (nx == scroll_x && ny == scroll_y)
                return;
            scroll_x = nx;
            scroll_y = ny;
            position_child ();
            // The content moved: the viewport is stale until it is repainted.
            damage_self ();
        }

        public void scroll_by (int dx, int dy) {
            scroll_to (scroll_x + dx, scroll_y + dy);
        }

        public void ensure_visible (int vy, int vh) {
            if (vy < scroll_y) {
                scroll_to (scroll_x, vy);
            } else if (vy + vh > scroll_y + height) {
                scroll_to (scroll_x, vy + vh - height);
            }
        }

        private void position_child () {
            if (child != null)
                child.allocate (x - scroll_x, y - scroll_y, content_w, content_h);
        }

        // Sizes come from one measure pass; everything else is bookkeeping, so a
        // repaint only re-measures and never repositions an unchanged subtree.
        private bool show_vbar () {
            if (vscrollbar_policy == PolicyType.NEVER || vscrollbar_policy == PolicyType.EXTERNAL)
                return false;
            if (vscrollbar_policy == PolicyType.ALWAYS)
                return height > 8;
            return content_h > height && height > 8;
        }

        private void apply_metrics (int cw, int ch) {
            natural_w = cw;
            natural_h = ch;
            content_w = (cw > width) ? cw : width;
            content_h = (ch > height) ? ch : height;
            int view_w = (show_vbar () && width > SB_W + 4) ? (width - SB_W) : width;
            if (cw <= view_w)
                content_w = view_w;
            int max_x = (content_w > width) ? (content_w - width) : 0;
            int max_y = (content_h > height) ? (content_h - height) : 0;
            if (scroll_x > max_x) scroll_x = max_x;
            if (scroll_y > max_y) scroll_y = max_y;
            position_child ();
        }

        private void measure_child_dims (out int cw, out int ch) {
            cw = 0;
            ch = 0;
            if (child == null)
                return;
            if (child.get_request_mode () == SizeRequestMode.HEIGHT_FOR_WIDTH && width > 0) {
                int view_w = (vscrollbar_policy != PolicyType.NEVER && width > SB_W + 4) ? (width - SB_W) : width;
                int cw_nat = 0;
                int ch_nat = 0;
                child.measure_width_for_height (-1, out cw, out cw_nat);
                child.measure_height_for_width (view_w, out ch, out ch_nat);
                if (cw < view_w)
                    cw = view_w;
            } else {
                child.measure (out cw, out ch);
            }
        }

        private void relayout_child () {
            if (child == null)
                return;
            int cw = 0;
            int ch = 0;
            measure_child_dims (out cw, out ch);
            apply_metrics (cw, ch);
        }

        private void sync_content () {
            if (child == null)
                return;
            int cw = 0;
            int ch = 0;
            measure_child_dims (out cw, out ch);
            if (cw == natural_w && ch == natural_h)
                return;
            apply_metrics (cw, ch);
        }

        private void vbar_metrics (out int bar_y, out int bar_h, out int track, out int max_y) {
            max_y = (content_h > height) ? (content_h - height) : 0;
            if (max_y <= 0 || height <= 8) {
                bar_y = y;
                bar_h = height;
                track = 0;
                return;
            }
            bar_h = (height * height) / content_h;
            if (bar_h < 22) bar_h = 22;
            if (bar_h > height) bar_h = height;
            track = height - bar_h;
            bar_y = y + ((track > 0) ? ((scroll_y * track) / max_y) : 0);
        }

        public override void measure (out int min_w, out int min_h) {
            int mw = (req_w > min_content_width) ? req_w : min_content_width;
            int mh = (req_h > min_content_height) ? req_h : min_content_height;
            min_w = (mw > 0) ? mw : 120;
            min_h = (mh > 0) ? mh : 100;
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
            relayout_child ();
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            cr.save ();
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.clip ();
            if (child != null)
                child.render (cr);
            if (show_vbar ()) {
                int bar_y = 0;
                int bar_h = 0;
                int track = 0;
                int max_y = 0;
                vbar_metrics (out bar_y, out bar_h, out track, out max_y);
                int sb_x = x + width - SB_W;
                // Obsidian Orbit (#0F1419) track
                cr.set_source_rgba (0.090, 0.090, 0.094, 0.45);
                cr.rectangle ((double) sb_x, (double) y, (double) SB_W, (double) height);
                cr.fill ();
                if (sb_dragging)
                    // Celestial Cerulean (#3897F0)
                    cr.set_source_rgba (0.450, 0.455, 0.470, 0.85);
                else if (sb_hovered)
                    // Titanium Mist (#8B9BB0)
                    cr.set_source_rgba (0.600, 0.600, 0.615, 0.78);
                else
                    // Dim Carbon (#526275)
                    cr.set_source_rgba (0.360, 0.360, 0.370, 0.60);
                cr.rounded_rectangle ((double) (sb_x + 2), (double) (bar_y + 1), (double) (SB_W - 4), (double) (bar_h - 2), 3.0);
                cr.fill ();
            }
            cr.restore ();
        }

        // A child may damage rows that are scrolled out: clamp its rectangles to
        // the viewport before hoisting them.
        public override void gather_damage () {
            if (child == null)
                return;
            child.gather_damage ();
            int n = child.damage_rect_count ();
            for (int j = 0; j < n; j++) {
                int cx = 0;
                int cy = 0;
                int cw = 0;
                int ch = 0;
                if (!child.damage_rect_at (j, out cx, out cy, out cw, out ch))
                    continue;
                int x0 = (cx > x) ? cx : x;
                int y0 = (cy > y) ? cy : y;
                int x1 = (cx + cw < x + width) ? (cx + cw) : (x + width);
                int y1 = (cy + ch < y + height) ? (cy + ch) : (y + height);
                if (x1 > x0 && y1 > y0)
                    damage_box (x0, y0, x1 - x0, y1 - y0);
            }
            child.clear_damage ();
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (!visible || !sensitive)
                return false;
            sync_content ();
            if (sb_dragging && content_h > height) {
                int bar_y = 0;
                int bar_h = 0;
                int track = 0;
                int max_y = 0;
                vbar_metrics (out bar_y, out bar_h, out track, out max_y);
                if (track > 0) {
                    int ny = (my - sb_drag_off) - y;
                    if (ny < 0) ny = 0;
                    if (ny > track) ny = track;
                    scroll_to (scroll_x, (ny * max_y) / track);
                }
                return true;
            }
            hovered = contains (mx, my);
            bool prev_sb = sb_hovered;
            sb_hovered = (show_vbar () && content_h > height && hovered && mx >= x + width - SB_W - 2);
            bool ch = false;
            if (sb_hovered != prev_sb) {
                damage_box (x + width - SB_W - 2, y, SB_W + 2, height);
                ch = true;
            }
            if (child != null) {
                int cmx = (hovered && !sb_hovered) ? mx : -1;
                int cmy = (hovered && !sb_hovered) ? my : -1;
                if (child.on_pointer_motion (cmx, cmy))
                    ch = true;
            }
            return ch;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || !contains (mx, my))
                return false;
            sync_content ();
            if (button == 4) {
                scroll_by (0, -36);
                return true;
            }
            if (button == 5) {
                scroll_by (0, 36);
                return true;
            }
            if (button == 1 && show_vbar () && content_h > height && mx >= x + width - SB_W - 2) {
                grab_focus ();
                int bar_y = 0;
                int bar_h = 0;
                int track = 0;
                int max_y = 0;
                vbar_metrics (out bar_y, out bar_h, out track, out max_y);
                if (my >= bar_y && my < bar_y + bar_h) {
                    sb_dragging = true;
                    sb_drag_off = my - bar_y;
                    damage_self ();
                } else if (my < bar_y) {
                    scroll_by (0, -(height - 24));
                } else {
                    scroll_by (0, height - 24);
                }
                return true;
            }
            if (child != null && child.on_pointer_press (mx, my, button))
                return true;
            grab_focus ();
            return false;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            bool ch = false;
            if (sb_dragging) {
                sb_dragging = false;
                damage_self ();
                ch = true;
            }
            if (child != null && child.on_pointer_release (mx, my, button))
                ch = true;
            return ch;
        }

        // Keys go to the focused widget inside the viewport first. Scrolling the
        // viewport with the keyboard is a fallback for when this widget owns
        // focus, otherwise it would swallow the arrows meant for the editor.
        public override bool handle_key (int key) {
            if (!visible || !sensitive)
                return false;
            if (child != null && child.handle_key (key)) {
                if (child is ListView) {
                    var lv = (ListView) child;
                    int sel = lv.get_selected ();
                    if (sel >= 0)
                        ensure_visible (sel * lv.row_height, lv.row_height);
                }
                return true;
            }
            if (!focused)
                return false;
            return on_key_press (key);
        }

        public override bool on_key_press (int key) {
            sync_content ();
            if (!focused)
                return false;
            if (key == 0x81 || key == 0xFF52) { scroll_by (0, -28); return true; } // Up
            if (key == 0x82 || key == 0xFF54) { scroll_by (0, 28); return true; }  // Down
            if (key == 0x83) { scroll_by (-28, 0); return true; }                  // Left
            if (key == 0x84) { scroll_by (28, 0); return true; }                   // Right
            if (key == 0x85) { scroll_to (scroll_x, 0); return true; }             // Home
            if (key == 0x86) { scroll_to (scroll_x, content_h); return true; }     // End
            if (key == 0x87 || key == 0xFF55) { scroll_by (0, -(height - 20)); return true; } // PageUp
            if (key == 0x88 || key == 0xFF56) { scroll_by (0, height - 20); return true; }    // PageDown
            return false;
        }

        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive || !contains (mx, my))
                return false;
            sync_content ();
            if (child != null && child.on_scroll (mx, my, dx, dy))
                return true;
            if (dx != 0 || dy != 0) {
                scroll_by (dx * 28, dy * 36);
                return true;
            }
            return false;
        }
    }

    public class Paned : Widget {
        public Orientation orientation = Orientation.HORIZONTAL;
        public Widget? start_child = null;
        public Widget? end_child = null;
        public int position = 180;
        private bool dragging = false;

        public Paned (Orientation orient = Orientation.HORIZONTAL) {
            orientation = orient;
        }

        public void set_orientation (Orientation orient) {
            if (orientation != orient) {
                orientation = orient;
                damage_self ();
            }
        }
        public Orientation get_orientation () { return orientation; }

        public void set_start_child (Widget? w) {
            if (start_child != null)
                start_child.unparent ();
            start_child = w;
            if (start_child != null)
                start_child.set_parent (this);
        }
        public Widget? get_start_child () { return start_child; }

        public void set_end_child (Widget? w) {
            if (end_child != null)
                end_child.unparent ();
            end_child = w;
            if (end_child != null)
                end_child.set_parent (this);
        }
        public Widget? get_end_child () { return end_child; }

        public void set_position (int pos) {
            int np = (pos < 40) ? 40 : pos;
            if (np == position)
                return;
            position = np;
            damage_self ();
        }

        public int get_position () {
            return position;
        }

        public override void measure (out int min_w, out int min_h) {
            int w1 = 0; int h1 = 0;
            int w2 = 0; int h2 = 0;
            if (start_child != null && start_child.visible)
                start_child.measure (out w1, out h1);
            if (end_child != null && end_child.visible)
                end_child.measure (out w2, out h2);
            if (orientation == Orientation.HORIZONTAL) {
                min_w = w1 + w2 + 4;
                min_h = (h1 > h2) ? h1 : h2;
            } else {
                min_w = (w1 > w2) ? w1 : w2;
                min_h = h1 + h2 + 4;
            }
            if (req_w > min_w) min_w = req_w;
            if (req_h > min_h) min_h = req_h;
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
            int div = 4;
            if (orientation == Orientation.HORIZONTAL) {
                int p = position;
                int max_p = (width > 40 + div) ? (width - 40 - div) : 40;
                if (p < 40) p = 40;
                if (p > max_p) p = max_p;
                if (start_child != null)
                    start_child.allocate (ax, ay, p, height);
                if (end_child != null)
                    end_child.allocate (ax + p + div, ay, (width > p + div) ? (width - p - div) : 0, height);
            } else {
                int p = position;
                int max_p = (height > 40 + div) ? (height - 40 - div) : 40;
                if (p < 40) p = 40;
                if (p > max_p) p = max_p;
                if (start_child != null)
                    start_child.allocate (ax, ay, width, p);
                if (end_child != null)
                    end_child.allocate (ax, ay + p + div, width, (height > p + div) ? (height - p - div) : 0);
            }
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            if (start_child != null)
                start_child.render (cr);
            if (end_child != null)
                end_child.render (cr);
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            if (orientation == Orientation.HORIZONTAL)
                cr.rectangle ((double) (x + position), (double) y, 4.0, (double) height);
            else
                cr.rectangle ((double) x, (double) (y + position), (double) width, 4.0);
            cr.fill ();
        }

        public override void gather_damage () {
            hoist_child_damage (start_child);
            hoist_child_damage (end_child);
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (dragging) {
                int np = (orientation == Orientation.HORIZONTAL) ? (mx - x) : (my - y);
                set_position (np);
                allocate (x, y, width, height);
                damage_self ();
                return true;
            }
            bool ch = false;
            if (start_child != null && start_child.on_pointer_motion (mx, my))
                ch = true;
            if (end_child != null && end_child.on_pointer_motion (mx, my))
                ch = true;
            return ch;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive)
                return false;
            if (button == 1) {
                bool on_div = (orientation == Orientation.HORIZONTAL)
                    ? (mx >= x + position - 2 && mx <= x + position + 6 && my >= y && my < y + height)
                    : (my >= y + position - 2 && my <= y + position + 6 && mx >= x && mx < x + width);
                if (on_div) {
                    dragging = true;
                    return true;
                }
            }
            if (start_child != null && start_child.on_pointer_press (mx, my, button))
                return true;
            if (end_child != null && end_child.on_pointer_press (mx, my, button))
                return true;
            return false;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            bool ch = false;
            if (dragging) {
                dragging = false;
                ch = true;
            }
            if (start_child != null && start_child.on_pointer_release (mx, my, button))
                ch = true;
            if (end_child != null && end_child.on_pointer_release (mx, my, button))
                ch = true;
            return ch;
        }

        public override bool on_key_press (int key) {
            if (start_child != null && start_child.on_key_press (key))
                return true;
            if (end_child != null && end_child.on_key_press (key))
                return true;
            return false;
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive)
                return false;
            if (start_child != null && start_child.handle_key (key))
                return true;
            if (end_child != null && end_child.handle_key (key))
                return true;
            return on_key_press (key);
        }

        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive)
                return false;
            if (start_child != null && start_child.on_scroll (mx, my, dx, dy))
                return true;
            if (end_child != null && end_child.on_scroll (mx, my, dx, dy))
                return true;
            return false;
        }
    }

    public class Notebook : Widget {
        private GenericArray<Widget> pages;
        private GenericArray<string> labels;
        private int current_page = 0;
        private int tab_h = 30;
        private int tab_w = 120;
        public bool show_tabs = true;
        public bool scrollable = false;

        public signal void switch_page (Widget page, int page_num);

        public Notebook () {
            pages = new GenericArray<Widget> ();
            labels = new GenericArray<string> ();
        }

        public void set_show_tabs (bool show) {
            if (show_tabs != show) {
                show_tabs = show;
                queue_resize ();
            }
        }
        public bool get_show_tabs () { return show_tabs; }

        public void set_scrollable (bool sc) { scrollable = sc; }
        public bool get_scrollable () { return scrollable; }

        public int page_num (Widget child) {
            for (int i = 0; i < pages.length; i++) {
                if (pages[i] == child)
                    return i;
            }
            return -1;
        }

        public void set_tab_label (Widget child, string label) {
            set_tab_label_text (child, label);
        }

        public int append_page (Widget child, string tab_label = "") {
            pages.add (child);
            labels.add (tab_label);
            child.set_parent (this);
            int idx = pages.length - 1;
            if (width > 0 && height > tab_h)
                child.allocate (x, y + tab_h, width, height - tab_h);
            queue_resize ();
            return idx;
        }

        public int prepend_page (Widget child, string tab_label = "") {
            return insert_page (child, tab_label, 0);
        }

        public int insert_page (Widget child, string tab_label, int position) {
            int pos = position;
            if (pos < 0 || pos >= pages.length)
                return append_page (child, tab_label);
            var np = new GenericArray<Widget> ();
            var nl = new GenericArray<string> ();
            for (int i = 0; i < pages.length; i++) {
                if (i == pos) {
                    np.add (child);
                    nl.add (tab_label);
                }
                np.add (pages[i]);
                nl.add (labels[i]);
            }
            pages = np;
            labels = nl;
            child.set_parent (this);
            if (current_page >= pos)
                current_page++;
            if (width > 0 && height > tab_h)
                child.allocate (x, y + tab_h, width, height - tab_h);
            damage_self ();
            return pos;
        }

        public void remove_page (int page_num) {
            if (page_num < 0 || page_num >= pages.length)
                return;
            pages[page_num].unparent ();
            pages.remove_index (page_num);
            labels.remove_index (page_num);
            if (pages.length == 0) {
                current_page = 0;
            } else if (page_num < current_page) {
                current_page--;
            } else if (current_page >= pages.length) {
                current_page = pages.length - 1;
            }
            if (pages.length > 0 && width > 0 && height > tab_h)
                pages[current_page].allocate (x, y + tab_h, width, height - tab_h);
            damage_self ();
        }

        public string? get_tab_label_text (Widget child) {
            for (int i = 0; i < pages.length; i++) {
                if (pages[i] == child)
                    return labels[i];
            }
            return null;
        }

        public void set_tab_label_text (Widget child, string tab_text) {
            for (int i = 0; i < pages.length; i++) {
                if (pages[i] == child) {
                    labels[i] = tab_text;
                    damage_box (x, y, width, tab_h);
                    return;
                }
            }
        }

        public void next_page () {
            if (current_page + 1 < pages.length)
                set_current_page (current_page + 1);
        }

        public void prev_page () {
            if (current_page > 0)
                set_current_page (current_page - 1);
        }

        public int get_n_pages () {
            return pages.length;
        }

        public int get_current_page () {
            return current_page;
        }

        public void set_current_page (int page_num) {
            if (page_num < 0 || page_num >= pages.length || page_num == current_page)
                return;
            current_page = page_num;
            if (width > 0 && height > tab_h)
                pages[current_page].allocate (x, y + tab_h, width, height - tab_h);
            damage_self ();
            switch_page (pages[current_page], current_page);
        }

        public Widget? get_nth_page (int page_num) {
            if (page_num < 0 || page_num >= pages.length)
                return null;
            return pages[page_num];
        }

        public override void measure (out int min_w, out int min_h) {
            int max_w = 160;
            int max_h = 100;
            for (int i = 0; i < pages.length; i++) {
                int cw = 0;
                int ch = 0;
                pages[i].measure (out cw, out ch);
                if (cw > max_w) max_w = cw;
                if (ch > max_h) max_h = ch;
            }
            int th = show_tabs ? tab_h : 0;
            min_w = (req_w > max_w) ? req_w : max_w;
            min_h = (req_h > (max_h + th)) ? req_h : (max_h + th);
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
            int th = show_tabs ? tab_h : 0;
            int ch = (height > th) ? (height - th) : 0;
            for (int i = 0; i < pages.length; i++)
                pages[i].allocate (ax, ay + th, width, ch);
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            if (!show_tabs) {
                if (current_page >= 0 && current_page < pages.length)
                    pages[current_page].render (cr);
                return;
            }
            // Obsidian Orbit (#0F1419) tab strip
            cr.set_source_rgb (0.090, 0.090, 0.094);
            cr.rectangle ((double) x, (double) y, (double) width, (double) tab_h);
            cr.fill ();
            cr.save ();
            cr.rectangle ((double) x, (double) y, (double) width, (double) tab_h);
            cr.clip ();
            int tx = x + 4;
            for (int i = 0; i < pages.length; i++) {
                if (tx >= x + width)
                    break;
                if (i == current_page)
                    // Slate Atmosphere (#182028)
                    cr.set_source_rgb (0.130, 0.130, 0.135);
                else
                    // Obsidian Orbit (#0F1419)
                    cr.set_source_rgb (0.090, 0.090, 0.094);
                cr.rectangle ((double) tx, (double) (y + 3), (double) (tab_w - 4), (double) (tab_h - 3));
                cr.fill ();
                if (i == current_page) {
                    // Celestial Cerulean (#3897F0)
                    cr.set_source_rgb (0.450, 0.455, 0.470);
                    cr.rectangle ((double) tx, (double) (y + 3), (double) (tab_w - 4), 2.0);
                    cr.fill ();
                }
                if (i == current_page)
                    // Lunar White (#F0F4F8)
                    cr.set_source_rgb (0.920, 0.920, 0.925);
                else
                    // Titanium Mist (#8B9BB0)
                    cr.set_source_rgb (0.600, 0.600, 0.615);
                TextHelper.draw_text (cr, labels[i], tx + 10, y + 7, 13.0);
                tx += tab_w;
            }
            cr.restore ();
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rectangle ((double) x, (double) (y + tab_h - 1), (double) width, 1.0);
            cr.fill ();
            if (current_page >= 0 && current_page < pages.length)
                pages[current_page].render (cr);
        }

        public override void gather_damage () {
            if (current_page < 0 || current_page >= pages.length)
                return;
            hoist_child_damage (pages[current_page]);
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (!visible || !sensitive)
                return false;
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_pointer_motion (mx, my);
            return false;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive)
                return false;
            if (show_tabs && button == 1 && my >= y && my < y + tab_h && mx >= x + 4 && mx < x + width) {
                int idx = (mx - (x + 4)) / tab_w;
                if (idx >= 0 && idx < pages.length) {
                    set_current_page (idx);
                    return true;
                }
            }
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_pointer_press (mx, my, button);
            return false;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (!visible || !sensitive)
                return false;
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_pointer_release (mx, my, button);
            return false;
        }

        public override bool on_key_press (int key) {
            if (!visible || !sensitive)
                return false;
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_key_press (key);
            return false;
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive || current_page < 0 || current_page >= pages.length)
                return false;
            return pages[current_page].handle_key (key);
        }
        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive)
                return false;
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_scroll (mx, my, dx, dy);
            return false;
        }
    }
}
