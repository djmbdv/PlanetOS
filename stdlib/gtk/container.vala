// Layout container (Box) for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public class Box : Widget {
        public Orientation orientation = Orientation.VERTICAL;
        public int spacing = 8;
        public bool homogeneous = false;
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

        public void set_orientation (Orientation orient) {
            if (orientation != orient) {
                orientation = orient;
                damage_self ();
            }
        }

        public Orientation get_orientation () { return orientation; }

        public void set_spacing (int sp) {
            int ns = (sp < 0) ? 0 : sp;
            if (ns != spacing) {
                spacing = ns;
                damage_self ();
            }
        }

        public int get_spacing () { return spacing; }

        public void set_homogeneous (bool h) {
            if (homogeneous != h) {
                homogeneous = h;
                damage_self ();
            }
        }

        public bool get_homogeneous () { return homogeneous; }

        public void pack_start (Widget child, bool expand = false, bool fill = true, int padding = 0) {
            children.add (child);
            expands.add (expand);
            fills.add (fill);
            paddings.add ((padding < 0) ? 0 : padding);
            child.set_parent (this);
            queue_resize ();
        }

        public void append (Widget child) {
            pack_start (child, false, true, 0);
        }

        public void prepend (Widget child) {
            var nc = new GenericArray<Widget> ();
            var ne = new GenericArray<bool> ();
            var nf = new GenericArray<bool> ();
            var np = new GenericArray<int> ();
            nc.add (child);
            ne.add (false);
            nf.add (true);
            np.add (0);
            for (int i = 0; i < children.length; i++) {
                nc.add (children[i]);
                ne.add (expands[i]);
                nf.add (fills[i]);
                np.add (paddings[i]);
            }
            children = nc;
            expands = ne;
            fills = nf;
            paddings = np;
            child.set_parent (this);
            queue_resize ();
        }

        public void insert_child_after (Widget child, Widget? sibling) {
            if (sibling == null) {
                prepend (child);
                return;
            }
            int idx = -1;
            for (int i = 0; i < children.length; i++) {
                if (children[i] == sibling) {
                    idx = i;
                    break;
                }
            }
            if (idx < 0 || idx == children.length - 1) {
                append (child);
                return;
            }
            var nc = new GenericArray<Widget> ();
            var ne = new GenericArray<bool> ();
            var nf = new GenericArray<bool> ();
            var np = new GenericArray<int> ();
            for (int i = 0; i < children.length; i++) {
                nc.add (children[i]);
                ne.add (expands[i]);
                nf.add (fills[i]);
                np.add (paddings[i]);
                if (i == idx) {
                    nc.add (child);
                    ne.add (false);
                    nf.add (true);
                    np.add (0);
                }
            }
            children = nc;
            expands = ne;
            fills = nf;
            paddings = np;
            child.set_parent (this);
            queue_resize ();
        }

        public void add (Widget child) {
            append (child);
        }

        public bool remove (Widget child) {
            for (int i = 0; i < children.length; i++) {
                if (children[i] == child) {
                    children[i].unparent ();
                    children.remove_index (i);
                    expands.remove_index (i);
                    fills.remove_index (i);
                    paddings.remove_index (i);
                    queue_resize ();
                    return true;
                }
            }
            return false;
        }

        private bool child_expands (int i) {
            if (expands[i])
                return true;
            var c = children[i];
            return (orientation == Orientation.VERTICAL) ? c.vexpand : c.hexpand;
        }

        public override SizeRequestMode get_request_mode () {
            for (int i = 0; i < children.length; i++) {
                if (children[i].visible && children[i].get_request_mode () == SizeRequestMode.HEIGHT_FOR_WIDTH)
                    return SizeRequestMode.HEIGHT_FOR_WIDTH;
            }
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure_for (Orientation measure_orient, int for_size,
                                          out int minimum, out int natural,
                                          out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (measure_orient == Orientation.VERTICAL && orientation == Orientation.VERTICAL && for_size >= 0) {
                int total_h = 0;
                int max_main = 0;
                int vis_count = 0;
                for (int i = 0; i < children.length; i++) {
                    var c = children[i];
                    if (!c.visible)
                        continue;
                    int avail_w = for_size - c.margin_start - c.margin_end;
                    if (avail_w < 0) avail_w = 0;
                    int ch_min = 0;
                    int ch_nat = 0;
                    c.measure_height_for_width (avail_w, out ch_min, out ch_nat);
                    int mh = ch_min + c.margin_top + c.margin_bottom + paddings[i] * 2;
                    if (mh > max_main) max_main = mh;
                    total_h += mh;
                    vis_count++;
                }
                if (homogeneous && vis_count > 0)
                    total_h = max_main * vis_count;
                if (vis_count > 1)
                    total_h += (vis_count - 1) * spacing;
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
            int total_w = 0;
            int total_h = 0;
            int max_main = 0;
            int vis_count = 0;
            for (int i = 0; i < children.length; i++) {
                var c = children[i];
                if (!c.visible)
                    continue;
                int cw = 0;
                int ch = 0;
                c.measure (out cw, out ch);
                cw += c.margin_start + c.margin_end;
                ch += c.margin_top + c.margin_bottom;
                int pad = paddings[i] * 2;
                if (orientation == Orientation.VERTICAL) {
                    if (cw > total_w) total_w = cw;
                    int mh = ch + pad;
                    if (mh > max_main) max_main = mh;
                    total_h += mh;
                } else {
                    int mw = cw + pad;
                    if (mw > max_main) max_main = mw;
                    total_w += mw;
                    if (ch > total_h) total_h = ch;
                }
                vis_count++;
            }
            if (homogeneous && vis_count > 0) {
                if (orientation == Orientation.VERTICAL)
                    total_h = max_main * vis_count;
                else
                    total_w = max_main * vis_count;
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

            int n = children.length;
            if (n == 0)
                return;

            // Single-pass measure cache: measure each visible child once.
            int[] cws = new int[n];
            int[] chs = new int[n];
            int vis_count = 0;
            int exp_count = 0;
            int total_main = 0;
            for (int i = 0; i < n; i++) {
                var c = children[i];
                if (!c.visible)
                    continue;
                int cw = 0;
                int ch = 0;
                if (orientation == Orientation.VERTICAL && width > 0) {
                    int cw_nat = 0;
                    int ch_nat = 0;
                    int max_w = width - c.margin_start - c.margin_end;
                    if (max_w < 0) max_w = 0;
                    c.measure_width_for_height (-1, out cw, out cw_nat);
                    c.measure_height_for_width (max_w, out ch, out ch_nat);
                } else {
                    c.measure (out cw, out ch);
                }
                cws[i] = cw;
                chs[i] = ch;
                int pad = paddings[i] * 2;
                if (orientation == Orientation.VERTICAL)
                    total_main += ch + c.margin_top + c.margin_bottom + pad;
                else
                    total_main += cw + c.margin_start + c.margin_end + pad;
                if (child_expands (i))
                    exp_count++;
                vis_count++;
            }
            if (vis_count > 1)
                total_main += (vis_count - 1) * spacing;

            int extra = 0;
            int extra_rem = 0;
            int homo_slot = 0;
            int homo_rem = 0;
            if (homogeneous && vis_count > 0) {
                int avail_main = (orientation == Orientation.VERTICAL) ? height : width;
                avail_main -= (vis_count - 1) * spacing;
                if (avail_main < 0) avail_main = 0;
                homo_slot = avail_main / vis_count;
                homo_rem = avail_main % vis_count;
            } else if (exp_count > 0) {
                int avail = (orientation == Orientation.VERTICAL) ? (height - total_main) : (width - total_main);
                if (avail > 0) {
                    extra = avail / exp_count;
                    extra_rem = avail % exp_count;
                }
            }

            int cx = ax;
            int cy = ay;
            for (int i = 0; i < n; i++) {
                var c = children[i];
                if (!c.visible)
                    continue;
                int cw = cws[i];
                int ch = chs[i];
                int pad = paddings[i];
                int bonus = 0;
                if (homogeneous) {
                    if (homo_rem > 0) {
                        bonus = 1;
                        homo_rem--;
                    }
                } else if (child_expands (i)) {
                    bonus = extra;
                    if (extra_rem > 0) {
                        bonus++;
                        extra_rem--;
                    }
                }
                if (orientation == Orientation.VERTICAL) {
                    int slot_h = homogeneous ? (homo_slot + bonus) : (ch + c.margin_top + c.margin_bottom + bonus);
                    int alloc_h = slot_h - c.margin_top - c.margin_bottom;
                    if (alloc_h < 0) alloc_h = 0;
                    int max_w = width - c.margin_start - c.margin_end;
                    if (max_w < 0) max_w = 0;
                    int alloc_w = (fills[i] && c.halign == Align.FILL) ? max_w : ((cw < max_w) ? cw : max_w);
                    int ox = cx + c.margin_start;
                    if (c.halign == Align.CENTER && max_w > alloc_w)
                        ox += (max_w - alloc_w) / 2;
                    else if (c.halign == Align.END && max_w > alloc_w)
                        ox += (max_w - alloc_w);
                    c.allocate (ox, cy + pad + c.margin_top, alloc_w, alloc_h);
                    cy += slot_h + pad * 2 + spacing;
                } else {
                    int slot_w = homogeneous ? (homo_slot + bonus) : (cw + c.margin_start + c.margin_end + bonus);
                    int alloc_w = slot_w - c.margin_start - c.margin_end;
                    if (alloc_w < 0) alloc_w = 0;
                    int max_h = height - c.margin_top - c.margin_bottom;
                    if (max_h < 0) max_h = 0;
                    int alloc_h = (fills[i] && c.valign == Align.FILL) ? max_h : ((ch < max_h) ? ch : max_h);
                    int oy = cy + c.margin_top;
                    if (c.valign == Align.CENTER && max_h > alloc_h)
                        oy += (max_h - alloc_h) / 2;
                    else if (c.valign == Align.END && max_h > alloc_h)
                        oy += (max_h - alloc_h);
                    c.allocate (cx + pad + c.margin_start, oy, alloc_w, alloc_h);
                    cx += slot_w + pad * 2 + spacing;
                }
            }
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            for (int i = 0; i < children.length; i++) {
                children[i].render (cr);
            }
        }

        public override void gather_damage () {
            for (int i = 0; i < children.length; i++)
                hoist_child_damage (children[i]);
        }

        public override void collect_focusables (GenericArray<Widget> out_list) {
            if (!visible || !sensitive)
                return;
            for (int i = 0; i < children.length; i++)
                children[i].collect_focusables (out_list);
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive)
                return false;
            for (int i = 0; i < children.length; i++) {
                if (children[i].handle_key (key))
                    return true;
            }
            return false;
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
            if (!visible || !sensitive)
                return false;
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
        public float label_xalign = 0.0f;

        public Frame (string? title = null) {
            label = title;
        }

        public void set_child (Widget? w) {
            if (child != null)
                child.unparent ();
            child = w;
            if (child != null)
                child.set_parent (this);
        }

        public Widget? get_child () {
            return child;
        }

        public void set_label (string? title) {
            label = title;
            damage_self ();
        }

        public string? get_label () {
            return label;
        }

        public void set_label_align (float xalign) {
            float xa = (xalign < 0.0f) ? 0.0f : ((xalign > 1.0f) ? 1.0f : xalign);
            if (xa != label_xalign) {
                label_xalign = xa;
                damage_self ();
            }
        }

        public float get_label_align () {
            return label_xalign;
        }

        private int header_height () {
            return (label != null && label.length > 0) ? 22 : 4;
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
                int avail_w = for_size - (pad + 1) * 2 - child.margin_start - child.margin_end;
                if (avail_w < 0) avail_w = 0;
                int ch_min = 0;
                int ch_nat = 0;
                child.measure_height_for_width (avail_w, out ch_min, out ch_nat);
                int hh = header_height ();
                int total = ch_min + child.margin_top + child.margin_bottom + hh + pad + 1;
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
            if (child != null && child.visible) {
                int hh = header_height ();
                int cw = width - (pad + 1) * 2 - child.margin_start - child.margin_end;
                int ch = height - hh - pad - 1 - child.margin_top - child.margin_bottom;
                if (cw < 0) cw = 0;
                if (ch < 0) ch = 0;
                child.allocate (x + pad + 1 + child.margin_start, y + hh + child.margin_top, cw, ch);
            }
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            // Slate Atmosphere (#182028) card fill & Stratosphere Line (#26323F) border
            cr.set_source_rgb (0.130, 0.130, 0.135);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 6.0);
            cr.fill ();
            cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.set_line_width (1.0);
            cr.rounded_rectangle ((double) x + 0.5, (double) y + 0.5, (double) (width - 1), (double) (height - 1), 6.0);
            cr.stroke ();
            if (label != null && label.length > 0) {
                int tw = 0;
                int th = 0;
                measure_text_cached (label, 13.0, out tw, out th);
                int avail = width - pad * 2 - tw;
                int lx = x + pad + ((avail > 0) ? (int) ((double) avail * label_xalign) : 0);
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.920, 0.920, 0.925);
                TextHelper.draw_text (cr, label, lx, y + 4, 13.0);
            }
            if (child != null)
                child.render (cr);
        }

        public override void gather_damage () {
            hoist_child_damage (child);
        }

        public override void collect_focusables (GenericArray<Widget> out_list) {
            if (visible && sensitive && child != null)
                child.collect_focusables (out_list);
        }

        public override bool handle_key (int key) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.handle_key (key);
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
            if (!visible || !sensitive || child == null)
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

    /**
     * Horizontal titlebar container with start/end packing and optional close button.
     */
    public class HeaderBar : Box {
        public string title = "";
        public string subtitle = "";
        public bool show_title_buttons = true;
        public string decoration_layout = ":close";
        private Label title_lbl;
        private Widget? title_widget = null;
        private Button? close_btn = null;

        public HeaderBar () : base (Orientation.HORIZONTAL, 8) {
            title_lbl = new Label ("");
            title_lbl.font_size = 15.0;
            title_widget = title_lbl;
            pack_start (title_lbl, true, true, 8);
            set_show_title_buttons (true);
        }

        public void pack_end (Widget child) {
            if (close_btn != null) {
                remove ((!) close_btn);
                pack_start (child, false, false, 4);
                pack_start ((!) close_btn, false, false, 6);
            } else {
                pack_start (child, false, false, 4);
            }
        }

        public void set_title_widget (Widget? w) {
            if (title_widget != null)
                remove ((!) title_widget);
            title_widget = (w != null) ? w : title_lbl;
            prepend ((!) title_widget);
            queue_resize ();
        }

        public Widget? get_title_widget () { return title_widget; }

        public void set_decoration_layout (string? layout) {
            decoration_layout = (layout != null) ? (!) layout : ":close";
            set_show_title_buttons (decoration_layout.contains ("close"));
        }

        public string get_decoration_layout () { return decoration_layout; }

        public void set_title (string? t) {
            title = (t != null) ? (!) t : "";
            title_lbl.set_text (title);
            damage_self ();
        }

        public string get_title () { return title; }

        public void set_subtitle (string? s) {
            subtitle = (s != null) ? (!) s : "";
            damage_self ();
        }

        public string get_subtitle () { return subtitle; }

        public void set_show_title_buttons (bool show) {
            show_title_buttons = show;
            if (show && close_btn == null) {
                var btn = new Button ("X");
                btn.set_size_request (28, 26);
                btn.clicked.connect ((sender) => {
                    var p = get_parent ();
                    if (p != null && p is GtkWindow)
                        ((GtkWindow) p).close ();
                });
                close_btn = btn;
                pack_start (btn, false, false, 6);
            } else if (!show && close_btn != null) {
                remove ((!) close_btn);
                close_btn = null;
            }
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            cr.fill_gradient_v ((double) x, (double) y, (double) width, (double) height,
                                0.175, 0.175, 0.182, 0.130, 0.130, 0.135);
            cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rectangle ((double) x, (double) (y + height - 1), (double) width, 1.0);
            cr.fill ();
            base.draw (cr);
            if (subtitle.length > 0 && title_lbl.width > 0) {
                int tw = 0;
                int th = 0;
                measure_text_cached (title, title_lbl.font_size, out tw, out th);
                int sx = title_lbl.x + tw + 12;
                int max_x = title_lbl.x + title_lbl.width - 4;
                if (sx < max_x) {
                    cr.save ();
                    cr.rectangle ((double) sx, (double) y, (double) (max_x - sx), (double) height);
                    cr.clip ();
                    // Titanium Mist (#8B9BB0)
                    cr.set_source_rgb (0.600, 0.600, 0.615);
                    TextHelper.draw_text (cr, subtitle, sx, y + (height - 12) / 2, 12.0);
                    cr.restore ();
                }
            }
        }
    }
}
