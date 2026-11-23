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
                c.measure (out cw, out ch);
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
            int homo_slot = 0;
            if (homogeneous && vis_count > 0) {
                int avail_main = (orientation == Orientation.VERTICAL) ? height : width;
                avail_main -= (vis_count - 1) * spacing;
                if (avail_main < 0) avail_main = 0;
                homo_slot = avail_main / vis_count;
            } else if (exp_count > 0) {
                int avail = (orientation == Orientation.VERTICAL) ? (height - total_main) : (width - total_main);
                if (avail > 0)
                    extra = avail / exp_count;
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
                int bonus = child_expands (i) ? extra : 0;
                if (orientation == Orientation.VERTICAL) {
                    int slot_h = homogeneous ? homo_slot : (ch + c.margin_top + c.margin_bottom + bonus);
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
                    int slot_w = homogeneous ? homo_slot : (cw + c.margin_start + c.margin_end + bonus);
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
            // Slate Atmosphere (#182028) card fill & Stratosphere Line (#26323F) border
            cr.set_source_rgb (0.094, 0.125, 0.157);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 6.0);
            cr.fill ();
            cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.set_line_width (1.0);
            cr.rounded_rectangle ((double) x + 0.5, (double) y + 0.5, (double) (width - 1), (double) (height - 1), 6.0);
            cr.stroke ();
            if (label != null && label.length > 0) {
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.941, 0.957, 0.973);
                TextHelper.draw_text (cr, label, x + pad, y + 4, 13.0);
            }
            if (child != null)
                child.render (cr);
        }

        public override void gather_damage () {
            hoist_child_damage (child);
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

    /**
     * Horizontal titlebar container with start/end packing and optional close button.
     */
    public class HeaderBar : Box {
        public string title = "";
        public string subtitle = "";
        public bool show_title_buttons = true;
        private Label title_lbl;
        private Button? close_btn = null;

        public HeaderBar () : base (Orientation.HORIZONTAL, 8) {
            title_lbl = new Label ("");
            title_lbl.font_size = 15.0;
            pack_start (title_lbl, true, true, 8);
            set_show_title_buttons (true);
        }

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
                                0.129, 0.169, 0.212, 0.094, 0.125, 0.157);
            cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.rectangle ((double) x, (double) (y + height - 1), (double) width, 1.0);
            cr.fill ();
            base.draw (cr);
        }
    }
}
