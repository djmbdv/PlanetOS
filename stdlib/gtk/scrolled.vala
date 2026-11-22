// ScrolledWindow, Paned, and Notebook containers for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public class ScrolledWindow : Widget {
        public Widget? child = null;
        public int scroll_x = 0;
        public int scroll_y = 0;
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
            child = w;
            scroll_x = 0;
            scroll_y = 0;
            sb_dragging = false;
        }

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
        private void apply_metrics (int cw, int ch) {
            natural_w = cw;
            natural_h = ch;
            content_w = (cw > width) ? cw : width;
            content_h = (ch > height) ? ch : height;
            int view_w = (content_h > height && width > SB_W + 4) ? (width - SB_W) : width;
            if (cw <= view_w)
                content_w = view_w;
            int max_x = (content_w > width) ? (content_w - width) : 0;
            int max_y = (content_h > height) ? (content_h - height) : 0;
            if (scroll_x > max_x) scroll_x = max_x;
            if (scroll_y > max_y) scroll_y = max_y;
            position_child ();
        }

        private void relayout_child () {
            if (child == null)
                return;
            int cw = 0;
            int ch = 0;
            child.measure (out cw, out ch);
            apply_metrics (cw, ch);
        }

        private void sync_content () {
            if (child == null)
                return;
            int cw = 0;
            int ch = 0;
            child.measure (out cw, out ch);
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
            min_w = (req_w > 0) ? req_w : 120;
            min_h = (req_h > 0) ? req_h : 100;
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
            sync_content ();
            cr.save ();
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.clip ();
            if (child != null)
                child.draw (cr);
            if (content_h > height && height > 8) {
                int bar_y = 0;
                int bar_h = 0;
                int track = 0;
                int max_y = 0;
                vbar_metrics (out bar_y, out bar_h, out track, out max_y);
                int sb_x = x + width - SB_W;
                // Obsidian Orbit (#0F1419) track
                cr.set_source_rgba (0.059, 0.078, 0.098, 0.45);
                cr.rectangle ((double) sb_x, (double) y, (double) SB_W, (double) height);
                cr.fill ();
                if (sb_dragging)
                    // Celestial Cerulean (#3897F0)
                    cr.set_source_rgba (0.220, 0.592, 0.941, 0.85);
                else if (sb_hovered)
                    // Titanium Mist (#8B9BB0)
                    cr.set_source_rgba (0.545, 0.608, 0.690, 0.78);
                else
                    // Dim Carbon (#526275)
                    cr.set_source_rgba (0.322, 0.384, 0.459, 0.60);
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
            sb_hovered = (content_h > height && hovered && mx >= x + width - SB_W - 2);
            bool ch = false;
            // Only the scrollbar strip draws a hover state; the content behind it
            // does not change when the pointer merely enters.
            if (sb_hovered != prev_sb) {
                damage_box (x + width - SB_W - 2, y, SB_W + 2, height);
                ch = true;
            }
            if (child != null && hovered && !sb_hovered && child.on_pointer_motion (mx, my))
                ch = true;
            return ch;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || !contains (mx, my))
                return false;
            grab_focus ();
            sync_content ();
            if (button == 4) {
                scroll_by (0, -36);
                return true;
            }
            if (button == 5) {
                scroll_by (0, 36);
                return true;
            }
            if (button == 1 && content_h > height && mx >= x + width - SB_W - 2) {
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
            if (child != null)
                return child.on_pointer_press (mx, my, button);
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
            if (child != null && child.handle_key (key))
                return true;
            if (!focused)
                return false;
            return on_key_press (key);
        }

        public override bool on_key_press (int key) {
            sync_content ();
            if (child != null && child.on_key_press (key)) {
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

        public void set_start_child (Widget? w) {
            start_child = w;
        }

        public void set_end_child (Widget? w) {
            end_child = w;
        }

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
                min_w = w1 + w2 + 6;
                min_h = (h1 > h2) ? h1 : h2;
            } else {
                min_w = (w1 > w2) ? w1 : w2;
                min_h = h1 + h2 + 6;
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
                position = p;
                if (start_child != null)
                    start_child.allocate (ax, ay, p, height);
                if (end_child != null)
                    end_child.allocate (ax + p + div, ay, (width > p + div) ? (width - p - div) : 0, height);
            } else {
                int p = position;
                int max_p = (height > 40 + div) ? (height - 40 - div) : 40;
                if (p < 40) p = 40;
                if (p > max_p) p = max_p;
                position = p;
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
                start_child.draw (cr);
            if (end_child != null)
                end_child.draw (cr);
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.149, 0.196, 0.247);
            if (orientation == Orientation.HORIZONTAL)
                cr.rectangle ((double) (x + position), (double) y, 4.0, (double) height);
            else
                cr.rectangle ((double) x, (double) (y + position), (double) width, 4.0);
            cr.fill ();
        }

        public override void gather_damage () {
            if (start_child != null) {
                start_child.gather_damage ();
                int n = start_child.damage_rect_count ();
                for (int j = 0; j < n; j++) {
                    int x = 0;
                    int y = 0;
                    int w = 0;
                    int h = 0;
                    if (start_child.damage_rect_at (j, out x, out y, out w, out h))
                        damage_box (x, y, w, h);
                }
                start_child.clear_damage ();
            }
            if (end_child != null) {
                end_child.gather_damage ();
                int n = end_child.damage_rect_count ();
                for (int j = 0; j < n; j++) {
                    int x = 0;
                    int y = 0;
                    int w = 0;
                    int h = 0;
                    if (end_child.damage_rect_at (j, out x, out y, out w, out h))
                        damage_box (x, y, w, h);
                }
                end_child.clear_damage ();
            }
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

        public signal void switch_page (Widget page, int page_num);

        public Notebook () {
            pages = new GenericArray<Widget> ();
            labels = new GenericArray<string> ();
        }

        public int append_page (Widget child, string tab_label = "") {
            pages.add (child);
            labels.add (tab_label);
            int idx = pages.length - 1;
            if (width > 0 && height > tab_h)
                child.allocate (x, y + tab_h, width, height - tab_h);
            return idx;
        }

        public void remove_page (int page_num) {
            if (page_num < 0 || page_num >= pages.length)
                return;
            pages.remove_index (page_num);
            labels.remove_index (page_num);
            if (current_page >= pages.length && pages.length > 0)
                current_page = pages.length - 1;
            if (pages.length == 0)
                current_page = 0;
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
            min_w = (req_w > max_w) ? req_w : max_w;
            min_h = (req_h > (max_h + tab_h)) ? req_h : (max_h + tab_h);
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            x = ax;
            y = ay;
            width = (aw < 0) ? 0 : aw;
            height = (ah < 0) ? 0 : ah;
            int ch = (height > tab_h) ? (height - tab_h) : 0;
            for (int i = 0; i < pages.length; i++)
                pages[i].allocate (ax, ay + tab_h, width, ch);
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            // Obsidian Orbit (#0F1419) tab strip
            cr.set_source_rgb (0.059, 0.078, 0.098);
            cr.rectangle ((double) x, (double) y, (double) width, (double) tab_h);
            cr.fill ();
            int tx = x + 4;
            for (int i = 0; i < pages.length; i++) {
                if (i == current_page)
                    // Slate Atmosphere (#182028)
                    cr.set_source_rgb (0.094, 0.125, 0.157);
                else
                    // Obsidian Orbit (#0F1419)
                    cr.set_source_rgb (0.059, 0.078, 0.098);
                cr.rectangle ((double) tx, (double) (y + 3), (double) (tab_w - 4), (double) (tab_h - 3));
                cr.fill ();
                if (i == current_page) {
                    // Celestial Cerulean (#3897F0)
                    cr.set_source_rgb (0.220, 0.592, 0.941);
                    cr.rectangle ((double) tx, (double) (y + 3), (double) (tab_w - 4), 2.0);
                    cr.fill ();
                }
                if (i == current_page)
                    // Lunar White (#F0F4F8)
                    cr.set_source_rgb (0.941, 0.957, 0.973);
                else
                    // Titanium Mist (#8B9BB0)
                    cr.set_source_rgb (0.545, 0.608, 0.690);
                TextHelper.draw_text (cr, labels[i], tx + 10, y + 7, 13.0);
                tx += tab_w;
            }
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.rectangle ((double) x, (double) (y + tab_h - 1), (double) width, 1.0);
            cr.fill ();
            if (current_page >= 0 && current_page < pages.length)
                pages[current_page].draw (cr);
        }

        public override void gather_damage () {
            if (current_page < 0 || current_page >= pages.length)
                return;
            pages[current_page].gather_damage ();
            int n = pages[current_page].damage_rect_count ();
            for (int j = 0; j < n; j++) {
                int x = 0;
                int y = 0;
                int w = 0;
                int h = 0;
                if (pages[current_page].damage_rect_at (j, out x, out y, out w, out h))
                    damage_box (x, y, w, h);
            }
            pages[current_page].clear_damage ();
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_pointer_motion (mx, my);
            return false;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive)
                return false;
            if (button == 1 && my >= y && my < y + tab_h) {
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
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_pointer_release (mx, my, button);
            return false;
        }

        public override bool on_key_press (int key) {
            if (current_page >= 0 && current_page < pages.length)
                return pages[current_page].on_key_press (key);
            return false;
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive || current_page < 0 || current_page >= pages.length)
                return false;
            if (pages[current_page].handle_key (key))
                return true;
            return on_key_press (key);
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
