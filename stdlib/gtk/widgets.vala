// Standard Gtk widgets: Label, Button, Entry.
using Cairo;
using GLib;
using Pango;
using PangoCairo;

namespace Gtk {

    public enum Justification {
        LEFT,
        RIGHT,
        CENTER,
        FILL
    }

    private PangoContext? gtk_pango_ctx = null;

    private PangoContext get_pango_ctx () {
        if (gtk_pango_ctx == null)
            gtk_pango_ctx = new PangoContext ();
        return (!) gtk_pango_ctx;
    }

    public class Label : Widget {
        public string label = "";
        public double font_size = 16.0;
        public float xalign = 0.0f;
        public float yalign = 0.5f;
        public bool wrap = false;
        public EllipsizeMode ellipsize = EllipsizeMode.NONE;
        public int max_width_chars = -1;
        public Justification justify = Justification.LEFT;
        // Lunar White (#F0F4F8)
        public double r = 0.941;
        public double g = 0.957;
        public double b = 0.973;
        private Layout? lay = null;
        private double lay_font_size = -1.0;

        public Label (string? text = "") {
            label = (text != null) ? text : "";
        }

        private Layout ensure_layout () {
            if (lay == null) {
                var nl = new Layout (get_pango_ctx ());
                nl.set_text (label);
                lay = nl;
            }
            var l = (!) lay;
            if (lay_font_size != font_size) {
                var fd = new FontDescription ();
                fd.size = (int) font_size;
                if (fd.size < 1) fd.size = 1;
                l.set_font_description (fd);
                lay_font_size = font_size;
            }
            return l;
        }

        private void sync_layout_width () {
            var l = ensure_layout ();
            int max_px = -1;
            if ((wrap || ellipsize != EllipsizeMode.NONE) && width > 8)
                max_px = width - 8;
            if (max_width_chars > 0) {
                int cw_px = max_width_chars * l.char_width ();
                if (max_px < 0 || cw_px < max_px)
                    max_px = cw_px;
            }
            l.set_width (max_px);
            l.set_ellipsize (ellipsize);
            if (justify == Justification.CENTER)
                l.set_alignment (Pango.Alignment.CENTER);
            else if (justify == Justification.RIGHT)
                l.set_alignment (Pango.Alignment.RIGHT);
            else
                l.set_alignment (Pango.Alignment.LEFT);
        }

        public void set_text (string text) {
            if (text == label)
                return;
            label = text;
            if (lay != null)
                lay.set_text (label);
            queue_resize ();
        }

        public string get_text () {
            return label;
        }

        public void set_label (string text) {
            set_text (text);
        }

        public string get_label () {
            return label;
        }

        private static int hex_val (uint8 c) {
            if (c >= '0' && c <= '9') return (int) (c - '0');
            if (c >= 'a' && c <= 'f') return 10 + (int) (c - 'a');
            if (c >= 'A' && c <= 'F') return 10 + (int) (c - 'A');
            return -1;
        }

        private static bool parse_hex_color (string s, int pos, out double r, out double g, out double b) {
            r = 0.0; g = 0.0; b = 0.0;
            if (pos + 7 > s.length || s[pos] != '#')
                return false;
            int r0 = hex_val ((uint8) s[pos + 1]);
            int r1 = hex_val ((uint8) s[pos + 2]);
            int g0 = hex_val ((uint8) s[pos + 3]);
            int g1 = hex_val ((uint8) s[pos + 4]);
            int b0 = hex_val ((uint8) s[pos + 5]);
            int b1 = hex_val ((uint8) s[pos + 6]);
            if (r0 < 0 || r1 < 0 || g0 < 0 || g1 < 0 || b0 < 0 || b1 < 0)
                return false;
            r = (double) ((r0 << 4) | r1) / 255.0;
            g = (double) ((g0 << 4) | g1) / 255.0;
            b = (double) ((b0 << 4) | b1) / 255.0;
            return true;
        }

        public void set_markup (string str) {
            var l = ensure_layout ();
            l.clear_attributes ();
            var plain = new StringBuilder ();
            double cur_r = 0.0;
            double cur_g = 0.0;
            double cur_b = 0.0;
            bool in_span = false;
            int span_start = 0;
            int i = 0;
            while (i < str.length) {
                if (str[i] == '<') {
                    int close = -1;
                    for (int k = i + 1; k < str.length; k++) {
                        if (str[k] == '>') { close = k; break; }
                    }
                    if (close > i) {
                        string tag = str.substring (i + 1, close - i - 1);
                        if (tag.has_prefix ("span ") && !in_span) {
                            int hp = -1;
                            for (int k = 0; k < tag.length; k++) {
                                if (tag[k] == '#') { hp = k; break; }
                            }
                            if (hp >= 0 && parse_hex_color (tag, hp, out cur_r, out cur_g, out cur_b)) {
                                in_span = true;
                                span_start = plain.str.length;
                            }
                        } else if (tag == "/span" && in_span) {
                            l.add_color_attribute (span_start, plain.str.length, cur_r, cur_g, cur_b);
                            in_span = false;
                        }
                        i = close + 1;
                        continue;
                    }
                }
                plain.append_c (str[i]);
                i++;
            }
            if (in_span)
                l.add_color_attribute (span_start, plain.str.length, cur_r, cur_g, cur_b);
            label = plain.str;
            l.set_text (label);
            queue_resize ();
        }

        public void set_wrap (bool w) {
            if (wrap != w) {
                wrap = w;
                queue_resize ();
            }
        }
        public bool get_wrap () { return wrap; }

        public void set_ellipsize (EllipsizeMode mode) {
            if (ellipsize != mode) {
                ellipsize = mode;
                queue_resize ();
            }
        }
        public EllipsizeMode get_ellipsize () { return ellipsize; }

        public void set_max_width_chars (int n) {
            if (max_width_chars != n) {
                max_width_chars = n;
                queue_resize ();
            }
        }
        public int get_max_width_chars () { return max_width_chars; }

        public void set_justify (Justification j) {
            if (justify != j) {
                justify = j;
                damage_self ();
            }
        }
        public Justification get_justify () { return justify; }

        public void set_xalign (float xa) {
            xalign = (xa < 0.0f) ? 0.0f : ((xa > 1.0f) ? 1.0f : xa);
            damage_self ();
        }
        public float get_xalign () { return xalign; }

        public void set_yalign (float ya) {
            yalign = (ya < 0.0f) ? 0.0f : ((ya > 1.0f) ? 1.0f : ya);
            damage_self ();
        }
        public float get_yalign () { return yalign; }

        public override SizeRequestMode get_request_mode () {
            return wrap ? SizeRequestMode.HEIGHT_FOR_WIDTH : SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure_for (Orientation orientation, int for_size,
                                          out int minimum, out int natural,
                                          out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            var l = ensure_layout ();
            if (orientation == Orientation.HORIZONTAL) {
                l.set_ellipsize (EllipsizeMode.NONE);
                if (max_width_chars > 0)
                    l.set_width (max_width_chars * l.char_width ());
                else
                    l.set_width (-1);
                int tw = 0;
                int th = 0;
                l.get_pixel_size (out tw, out th);
                natural = (req_w > (tw + 8)) ? req_w : (tw + 8);
                if (wrap || ellipsize != EllipsizeMode.NONE) {
                    int min_cap = (req_w > 16) ? req_w : 16;
                    minimum = (natural < min_cap) ? natural : min_cap;
                } else {
                    minimum = natural;
                }
                return;
            }
            if (for_size >= 0 && wrap) {
                int avail_w = (for_size > 8) ? (for_size - 8) : 1;
                if (max_width_chars > 0) {
                    int cw_px = max_width_chars * l.char_width ();
                    if (cw_px < avail_w)
                        avail_w = cw_px;
                }
                l.set_ellipsize (EllipsizeMode.NONE);
                l.set_width (avail_w);
            } else {
                l.set_ellipsize (ellipsize);
                l.set_width ((max_width_chars > 0) ? (max_width_chars * l.char_width ()) : -1);
            }
            int tw = 0;
            int th = 0;
            l.get_pixel_size (out tw, out th);
            minimum = (req_h > (th + 8)) ? req_h : (th + 8);
            natural = minimum;
        }

        public override void measure (out int min_w, out int min_h) {
            int nat_w = 0;
            int nat_h = 0;
            int mb = 0;
            int nb = 0;
            measure_for (Orientation.HORIZONTAL, -1, out min_w, out nat_w, out mb, out nb);
            if (!wrap)
                min_w = nat_w;
            measure_for (Orientation.VERTICAL, -1, out min_h, out nat_h, out mb, out nb);
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            base.allocate (ax, ay, aw, ah);
            sync_layout_width ();
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0 || label.length == 0)
                return;
            sync_layout_width ();
            var l = ensure_layout ();
            int tw = 0;
            int th = 0;
            l.get_pixel_size (out tw, out th);
            int tx = x + 4;
            if (width > tw + 8)
                tx = x + 4 + (int) ((float) (width - tw - 8) * xalign);
            int ty = y + (int) ((float) (height - th) * yalign);
            if (ty < y) ty = y;
            cr.save ();
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.clip ();
            cr.set_source_rgb (r, g, b);
            show_layout_at (cr, l, tx, ty);
            cr.restore ();
        }
    }

    public class Button : Widget {
        public string label = "";
        public string icon_name = "";
        public Widget? child = null;
        public bool has_frame = true;
        public double font_size = 15.0;
        public signal void clicked ();

        public Button (string text = "") {
            label = text;
        }

        public Button.from_icon_name (string icon) {
            icon_name = icon;
        }

        public void set_label (string text) {
            if (text == label)
                return;
            label = text;
            damage_self ();
        }

        public string get_label () {
            return label;
        }

        public void set_markup (string str) {
            try {
                set_label (GLib.Markup.strip_tags (str));
            } catch (MarkupError e) {
                set_label (str);
            }
        }

        public void set_icon_name (string icon) {
            if (icon == icon_name)
                return;
            icon_name = icon;
            damage_self ();
        }

        public void set_has_frame (bool frame) {
            if (has_frame != frame) {
                has_frame = frame;
                damage_self ();
            }
        }
        public bool get_has_frame () { return has_frame; }

        public void set_child (Widget? w) {
            if (child != null)
                child.unparent ();
            child = w;
            if (child != null)
                child.set_parent (this);
            damage_self ();
        }

        public Widget? get_child () {
            return child;
        }

        public override void measure (out int min_w, out int min_h) {
            if (child != null && child.visible) {
                int cw = 0;
                int ch = 0;
                child.measure (out cw, out ch);
                int bw = cw + 16;
                int bh = ch + 12;
                min_w = (req_w > bw) ? req_w : bw;
                min_h = (req_h > bh) ? req_h : bh;
                return;
            }
            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            int bw = tw + 24;
            int bh = th + 16;
            if (icon_name.length > 0 && label.length == 0) {
                bw = 32;
                bh = 32;
            }
            min_w = (req_w > bw) ? req_w : bw;
            min_h = (req_h > bh) ? req_h : bh;
        }

        public override void allocate (int ax, int ay, int aw, int ah) {
            base.allocate (ax, ay, aw, ah);
            if (child != null)
                child.allocate (x + 8, y + 6, (width > 16) ? (width - 16) : 0, (height > 12) ? (height - 12) : 0);
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            if (has_frame || hovered || pressed) {
                if (pressed)
                    // Obsidian Orbit (#0F1419)
                    cr.set_source_rgb (0.090, 0.090, 0.094);
                else if (hovered)
                    // Elevated Surface (#212B36)
                    cr.set_source_rgb (0.175, 0.175, 0.182);
                else
                    // Slate Atmosphere (#182028)
                    cr.set_source_rgb (0.130, 0.130, 0.135);
                cr.rectangle ((double) x, (double) y, (double) width, (double) height);
                cr.fill ();
                if (has_frame) {
                    cr.set_line_width (1.0);
                    if (hovered || pressed)
                        // Celestial Cerulean (#3897F0)
                        cr.set_source_rgb (0.450, 0.455, 0.470);
                    else
                        // Subtle Border (#324253, 0.6)
                        cr.set_source_rgba (0.280, 0.280, 0.290, 0.6);
                    cr.rectangle ((double) x + 0.5, (double) y + 0.5, (double) (width - 1), (double) (height - 1));
                    cr.stroke ();
                }
            }

            if (child != null) {
                child.render (cr);
                return;
            }

            if (icon_name.length > 0 && label.length == 0) {
                int sz = (width < height) ? (width - 8) : (height - 8);
                if (sz > 20) sz = 20;
                if (sz < 8) sz = 8;
                Image.draw_builtin_icon (cr, icon_name, x + (width - sz) / 2, y + (height - sz) / 2, sz);
                return;
            }

            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            int tx = x + (width - tw) / 2;
            int ty = y + (height - th) / 2;
            if (sensitive)
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.920, 0.920, 0.925);
            else
                // Dim Carbon (#526275)
                cr.set_source_rgb (0.360, 0.360, 0.370);
            TextHelper.draw_text (cr, label, tx, ty, font_size);
        }

        public override void gather_damage () {
            hoist_child_damage (child);
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (!visible || !sensitive) {
                bool changed = hovered || pressed;
                hovered = false;
                pressed = false;
                if (changed)
                    damage_self ();
                return changed;
            }
            bool prev = hovered;
            hovered = contains (mx, my);
            bool ch = (hovered != prev);
            if (ch)
                damage_self ();
            if (child != null && child.on_pointer_motion (mx, my))
                ch = true;
            return ch;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1)
                return false;
            if (contains (mx, my)) {
                grab_focus ();
                pressed = true;
                damage_self ();
                return true;
            }
            return false;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (!pressed || button != 1)
                return false;
            bool inside = contains (mx, my);
            pressed = false;
            damage_self ();
            if (inside && visible && sensitive)
                clicked ();
            return true;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            if (key == ' ' || key == '\n' || key == '\r') {
                clicked ();
                return true;
            }
            return false;
        }

        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive || child == null)
                return false;
            return child.on_scroll (mx, my, dx, dy);
        }
    }

    public class Entry : Widget {
        public string text = "";
        public string placeholder = "";
        public double font_size = 15.0;
        public bool visibility = true;
        public bool editable = true;
        public int max_length = 0;
        public char invisible_char = '*';
        public int cursor_pos = 0;
        private bool cursor_on = true;
        private uint32 blink_id = 0;
        private int scroll_x = 0;
        private int sel_start = -1;
        private int sel_end = -1;
        private Layout? lay = null;
        private double lay_font_size = -1.0;
        public signal void changed ();
        public signal void activate ();

        public Entry (string initial = "") {
            text = initial;
            cursor_pos = text.length;
        }

        ~Entry () {
            stop_blink ();
        }

        private static int utf8_prev (string s, int pos) {
            int p = pos - 1;
            while (p > 0 && (((uint8) s[p]) & 0xC0) == 0x80)
                p--;
            return (p < 0) ? 0 : p;
        }

        private static int utf8_next (string s, int pos) {
            int p = pos + 1;
            while (p < s.length && (((uint8) s[p]) & 0xC0) == 0x80)
                p++;
            return (p > s.length) ? s.length : p;
        }

        private static int utf8_count (string s) {
            int c = 0;
            for (int i = 0; i < s.length; i++) {
                if ((((uint8) s[i]) & 0xC0) != 0x80)
                    c++;
            }
            return c;
        }

        private static string utf8_truncate (string s, int max_cp) {
            int c = 0;
            int i = 0;
            while (i < s.length) {
                if ((((uint8) s[i]) & 0xC0) != 0x80) {
                    if (c >= max_cp)
                        return s.substring (0, i);
                    c++;
                }
                i++;
            }
            return s;
        }

        private void stop_blink () {
            if (blink_id != 0) {
                GLib.source_remove (blink_id);
                blink_id = 0;
            }
            cursor_on = true;
        }

        private void start_blink () {
            stop_blink ();
            cursor_on = true;
            weak Entry? self_weak = this;
            blink_id = GLib.timeout_add (500, () => {
                if (self_weak == null || !self_weak.focused || !self_weak.visible || !self_weak.sensitive) {
                    if (self_weak != null) {
                        self_weak.blink_id = 0;
                        self_weak.cursor_on = true;
                    }
                    return false;
                }
                self_weak.cursor_on = !self_weak.cursor_on;
                self_weak.damage_self ();
                return true;
            });
        }

        public void set_text (string t) {
            string nt = (max_length > 0 && utf8_count (t) > max_length) ? utf8_truncate (t, max_length) : t;
            if (nt == text)
                return;
            text = nt;
            cursor_pos = text.length;
            scroll_x = 0;
            damage_self ();
            changed ();
        }

        public string get_text () {
            return text.substring (0, text.length);
        }

        public void set_placeholder_text (string? p) {
            placeholder = (p != null) ? p : "";
            damage_self ();
        }

        public string get_placeholder_text () {
            return placeholder;
        }

        public void set_visibility (bool vis) {
            if (visibility != vis) {
                visibility = vis;
                damage_self ();
            }
        }
        public bool get_visibility () { return visibility; }

        public void set_invisible_char (char ch) {
            if (invisible_char != ch) {
                invisible_char = ch;
                if (!visibility)
                    damage_self ();
            }
        }
        public char get_invisible_char () { return invisible_char; }

        public void set_editable (bool ed) { editable = ed; }
        public bool get_editable () { return editable; }

        public void set_max_length (int max_len) {
            max_length = (max_len < 0) ? 0 : max_len;
            if (max_length > 0 && utf8_count (text) > max_length) {
                text = utf8_truncate (text, max_length);
                if (cursor_pos > text.length)
                    cursor_pos = text.length;
                clear_selection ();
                damage_self ();
                changed ();
            }
        }
        public int get_max_length () { return max_length; }

        private Layout ensure_layout (string content) {
            if (lay == null)
                lay = new Layout (get_pango_ctx ());
            var l = (!) lay;
            if (lay_font_size != font_size) {
                var fd = new FontDescription ();
                fd.size = (int) font_size;
                if (fd.size < 1) fd.size = 1;
                l.set_font_description (fd);
                lay_font_size = font_size;
            }
            l.set_text (content);
            return l;
        }

        private int byte_offset_at_x (string disp, int rel_x) {
            if (rel_x <= 0 || disp.length == 0)
                return 0;
            var slot = FontRegistry.slot_for_family ("sans");
            int px_sz = (int) font_size;
            if (px_sz < 1) px_sz = 1;
            int pos = 0;
            int acc = 0;
            while (pos < disp.length) {
                int prev = pos;
                int cp = FontRegistry.next_utf8 (disp, ref pos);
                int adv = FontRegistry.glyph_advance (slot, cp, px_sz);
                if (rel_x < acc + adv / 2)
                    return prev;
                acc += adv;
            }
            return disp.length;
        }

        public void select_region (int start, int end) {
            int s = (start < 0) ? 0 : ((start > text.length) ? text.length : start);
            int e = (end < 0) ? text.length : ((end > text.length) ? text.length : end);
            if (s > e) {
                int t = s; s = e; e = t;
            }
            sel_start = s;
            sel_end = e;
            cursor_pos = e;
            damage_self ();
        }

        public bool get_selection_bounds (out int start, out int end) {
            if (sel_start >= 0 && sel_end > sel_start) {
                start = sel_start;
                end = sel_end;
                return true;
            }
            start = cursor_pos;
            end = cursor_pos;
            return false;
        }

        private void clear_selection () {
            sel_start = -1;
            sel_end = -1;
        }

        private string display_text () {
            if (visibility || text.length == 0)
                return text;
            var sb = new StringBuilder ();
            string ch = "*";
            if (invisible_char >= 32 && invisible_char < 127) {
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                ch = ascii.substring ((int) invisible_char - 32, 1);
            }
            int cp_cnt = utf8_count (text);
            for (int i = 0; i < cp_cnt; i++)
                sb.append (ch);
            return sb.str;
        }

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 160) ? req_w : 160;
            min_h = (req_h > 34) ? req_h : 34;
        }

        public override void draw (Context cr) {
            if (!visible || width <= 12 || height <= 4)
                return;
            if (focused)
                // Elevated Surface (#212B36)
                cr.set_source_rgb (0.175, 0.175, 0.182);
            else
                // Obsidian Orbit (#0F1419)
                cr.set_source_rgb (0.090, 0.090, 0.094);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.fill ();
            cr.set_line_width (1.0);
            if (focused)
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.450, 0.455, 0.470);
            else
                // Stratosphere Line (#26323F)
                cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.stroke ();

            int tw = 0;
            int th = 0;
            string disp = display_text ();
            string shown = (disp.length > 0) ? disp : placeholder;
            var l = ensure_layout (shown);
            l.get_pixel_size (out tw, out th);

            int inner_w = width - 20;
            if (inner_w < 1) inner_w = 1;
            if (cursor_pos < 0) cursor_pos = 0;
            if (cursor_pos > disp.length) cursor_pos = disp.length;
            var slot = FontRegistry.slot_for_family ("sans");
            int px_sz = (int) font_size;
            if (px_sz < 1) px_sz = 1;
            int cur_tw = (disp.length > 0) ? FontRegistry.measure_string_px (slot, disp, 0, cursor_pos, px_sz) : 0;

            if (disp.length > 0 && tw > inner_w) {
                if (cur_tw < scroll_x)
                    scroll_x = cur_tw;
                else if (cur_tw > scroll_x + inner_w)
                    scroll_x = cur_tw - inner_w;
                if (scroll_x > tw - inner_w)
                    scroll_x = tw - inner_w;
                if (scroll_x < 0)
                    scroll_x = 0;
            } else {
                scroll_x = 0;
            }
            int ty = y + (height - th) / 2;
            cr.save ();
            cr.rectangle ((double) (x + 6), (double) (y + 2), (double) (width - 12), (double) (height - 4));
            cr.clip ();
            if (disp.length > 0 && sel_start >= 0 && sel_end > sel_start && sel_end <= text.length) {
                int ds = visibility ? sel_start : utf8_count (text.substring (0, sel_start));
                int de = visibility ? sel_end : utf8_count (text.substring (0, sel_end));
                if (de <= disp.length && de > ds) {
                    int sx0 = FontRegistry.measure_string_px (slot, disp, 0, ds, px_sz);
                    int sx1 = FontRegistry.measure_string_px (slot, disp, 0, de, px_sz);
                    cr.set_source_rgba (0.450, 0.455, 0.470, 0.35);
                    cr.rectangle ((double) (x + 10 + sx0 - scroll_x), (double) (y + 5), (double) (sx1 - sx0), (double) (height - 10));
                    cr.fill ();
                }
            }
            if (disp.length > 0) {
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.920, 0.920, 0.925);
                show_layout_at (cr, l, x + 10 - scroll_x, ty);
            } else if (placeholder.length > 0) {
                // Titanium Mist (#8B9BB0)
                cr.set_source_rgb (0.600, 0.600, 0.615);
                show_layout_at (cr, l, x + 10, ty);
            }
            if (focused && cursor_on) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.450, 0.455, 0.470);
                cr.rectangle ((double) (x + 10 + cur_tw - scroll_x), (double) (y + 6), 2.0, (double) (height - 12));
                cr.fill ();
            }
            cr.restore ();
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || !contains (mx, my)) {
                drop_focus ();
                stop_blink ();
                clear_selection ();
                return false;
            }
            grab_focus ();
            start_blink ();
            if (button == 1) {
                string disp = display_text ();
                cursor_pos = byte_offset_at_x (disp, mx - (x + 10) + scroll_x);
                clear_selection ();
                damage_self ();
            }
            return true;
        }

        private bool delete_selection () {
            if (sel_start < 0 || sel_end <= sel_start || sel_end > text.length)
                return false;
            string before = text.substring (0, sel_start);
            string after = (sel_end < text.length) ? text.substring (sel_end) : "";
            text = before + after;
            cursor_pos = sel_start;
            clear_selection ();
            return true;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            cursor_on = true;
            if (key == '\n' || key == '\r') {
                activate ();
                return true;
            }
            if (key == 0x83) { // Left
                clear_selection ();
                if (cursor_pos > 0) {
                    cursor_pos = utf8_prev (text, cursor_pos);
                    damage_self ();
                }
                return true;
            }
            if (key == 0x84) { // Right
                clear_selection ();
                if (cursor_pos < text.length) {
                    cursor_pos = utf8_next (text, cursor_pos);
                    damage_self ();
                }
                return true;
            }
            if (key == 0x85) { // Home
                clear_selection ();
                if (cursor_pos != 0) {
                    cursor_pos = 0;
                    damage_self ();
                }
                return true;
            }
            if (key == 0x86) { // End
                clear_selection ();
                if (cursor_pos != text.length) {
                    cursor_pos = text.length;
                    damage_self ();
                }
                return true;
            }
            if (!editable)
                return false;
            if (key == 8 || key == 127) {
                if (delete_selection ()) {
                    damage_self ();
                    changed ();
                } else if (cursor_pos > 0 && text.length > 0) {
                    int prev_p = utf8_prev (text, cursor_pos);
                    string before = text.substring (0, prev_p);
                    string after = (cursor_pos < text.length) ? text.substring (cursor_pos) : "";
                    text = before + after;
                    cursor_pos = prev_p;
                    damage_self ();
                    changed ();
                }
                return true;
            }
            if (key == 0xFFFF) { // Delete
                if (delete_selection ()) {
                    damage_self ();
                    changed ();
                } else if (cursor_pos < text.length) {
                    int next_p = utf8_next (text, cursor_pos);
                    string before = text.substring (0, cursor_pos);
                    string after = (next_p < text.length) ? text.substring (next_p) : "";
                    text = before + after;
                    damage_self ();
                    changed ();
                }
                return true;
            }
            if (key >= 32 && key < 127) {
                bool had_sel = delete_selection ();
                if (max_length > 0 && utf8_count (text) >= max_length) {
                    if (had_sel) { damage_self (); changed (); }
                    return true;
                }
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                string ch = ascii.substring (key - 32, 1);
                string before = text.substring (0, cursor_pos);
                string after = (cursor_pos < text.length) ? text.substring (cursor_pos) : "";
                text = before + ch + after;
                cursor_pos += ch.length;
                damage_self ();
                changed ();
                return true;
            }
            return false;
        }
    }

    public class CheckButton : Widget {
        public string label = "";
        public bool active = false;
        public double font_size = 15.0;
        private weak CheckButton? group_leader = null;
        private GenericArray<weak CheckButton>? group_members = null;
        public signal void toggled ();

        public CheckButton (string text = "", bool initial = false) {
            label = text;
            active = initial;
        }

        ~CheckButton () {
            detach_group ();
        }

        private void detach_group () {
            if (group_leader != null && group_leader.group_members != null) {
                for (int i = 0; i < group_leader.group_members.length; i++) {
                    if (group_leader.group_members[i] == this) {
                        group_leader.group_members.remove_index (i);
                        break;
                    }
                }
            }
            group_leader = null;
        }

        public void set_label (string? text) {
            string nt = (text != null) ? text : "";
            if (nt != label) {
                label = nt;
                damage_self ();
            }
        }

        public string get_label () {
            return label;
        }

        public void set_markup (string str) {
            try {
                set_label (GLib.Markup.strip_tags (str));
            } catch (MarkupError e) {
                set_label (str);
            }
        }

        public void set_group (CheckButton? group) {
            detach_group ();
            if (group == null || group == this)
                return;
            var root = (group.group_leader != null) ? group.group_leader : group;
            if (root == this)
                return;
            group_leader = root;
            if (root.group_members == null)
                root.group_members = new GenericArray<weak CheckButton> ();
            root.group_members.add (this);
        }

        public CheckButton? get_group () {
            return group_leader;
        }

        public bool get_active () {
            return active;
        }

        public void set_active (bool v) {
            if (active == v)
                return;
            if (v && (group_leader != null || group_members != null)) {
                var leader = (group_leader != null) ? group_leader : this;
                if (leader != this && leader.active)
                    leader.set_active (false);
                if (leader.group_members != null) {
                    for (int i = 0; i < leader.group_members.length; i++) {
                        var m = leader.group_members[i];
                        if (m != null && m != this && m.active)
                            m.set_active (false);
                    }
                }
            }
            active = v;
            damage_self ();
            toggled ();
        }

        // The check box border changes colour on hover, so this widget does need
        // to repaint itself when the pointer enters or leaves.
        public override bool on_pointer_motion (int mx, int my) {
            bool prev = hovered;
            hovered = visible && sensitive && contains (mx, my);
            if (hovered != prev)
                damage_self ();
            return hovered != prev;
        }

        public override void measure (out int min_w, out int min_h) {
            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            int w = 28 + tw;
            int h = (th > 20) ? (th + 6) : 26;
            min_w = (req_w > w) ? req_w : w;
            min_h = (req_h > h) ? req_h : h;
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            int bx = x + 2;
            int by = y + (height - 18) / 2;
            if (active) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.450, 0.455, 0.470);
                cr.rectangle ((double) bx, (double) by, 18.0, 18.0);
                cr.fill ();
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.920, 0.920, 0.925);
                cr.set_line_width (2.0);
                cr.move_to ((double) (bx + 4), (double) (by + 9));
                cr.line_to ((double) (bx + 8), (double) (by + 13));
                cr.stroke ();
                cr.move_to ((double) (bx + 8), (double) (by + 13));
                cr.line_to ((double) (bx + 14), (double) (by + 5));
                cr.stroke ();
            } else {
                // Obsidian Orbit (#0F1419)
                cr.set_source_rgb (0.090, 0.090, 0.094);
                cr.rectangle ((double) bx, (double) by, 18.0, 18.0);
                cr.fill ();
                cr.set_line_width (1.0);
                if (hovered)
                    cr.set_source_rgb (0.450, 0.455, 0.470);
                else
                    cr.set_source_rgba (0.280, 0.280, 0.290, 0.6);
                cr.rectangle ((double) bx, (double) by, 18.0, 18.0);
                cr.stroke ();
            }
            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            int ty = y + (height - th) / 2;
            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.920, 0.920, 0.925);
            TextHelper.draw_text (cr, label, bx + 26, ty, font_size);
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1)
                return false;
            if (contains (mx, my)) {
                grab_focus ();
                pressed = true;
                return true;
            }
            return false;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (!pressed || button != 1)
                return false;
            bool inside = contains (mx, my);
            pressed = false;
            if (inside && visible && sensitive) {
                if (group_leader != null || group_members != null)
                    set_active (true);
                else
                    set_active (!active);
            }
            return true;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            if (key == ' ' || key == '\n' || key == '\r') {
                if (group_leader != null || group_members != null)
                    set_active (true);
                else
                    set_active (!active);
                return true;
            }
            return false;
        }
    }

    public class ProgressBar : Widget {
        public double fraction = 0.0;
        public string text = "";
        public bool show_text = true;
        public double font_size = 13.0;
        private double pulse_step = 0.1;
        private bool pulse_mode = false;
        private double pulse_pos = 0.0;
        private int pulse_dir = 1;

        public ProgressBar () {}

        public void set_pulse_step (double frac) {
            pulse_step = (frac > 0.0 && frac <= 1.0) ? frac : 0.1;
        }
        public double get_pulse_step () { return pulse_step; }

        public void set_fraction (double f) {
            if (!(f >= 0.0)) f = 0.0;
            if (f > 1.0) f = 1.0;
            if (f == fraction && !pulse_mode)
                return;
            pulse_mode = false;
            fraction = f;
            damage_self ();
        }

        public double get_fraction () { return fraction; }

        public void set_text (string? t) {
            string nt = (t != null) ? t : "";
            if (nt == text)
                return;
            text = nt;
            damage_self ();
        }

        public string get_text () { return text; }

        public void set_show_text (bool st) {
            if (show_text != st) {
                show_text = st;
                damage_self ();
            }
        }
        public bool get_show_text () { return show_text; }

        public void pulse () {
            pulse_mode = true;
            pulse_pos += (double) pulse_dir * pulse_step;
            if (pulse_pos >= 0.75) {
                pulse_pos = 0.75;
                pulse_dir = -1;
            } else if (pulse_pos <= 0.0) {
                pulse_pos = 0.0;
                pulse_dir = 1;
            }
            damage_self ();
        }

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 160) ? req_w : 160;
            min_h = (req_h > 22) ? req_h : 22;
        }

        public override void draw (Context cr) {
            if (!visible || width <= 2 || height <= 2)
                return;
            // Obsidian Orbit (#0F1419)
            cr.set_source_rgb (0.090, 0.090, 0.094);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.fill ();
            if (pulse_mode) {
                int pw = (width - 2) / 4;
                if (pw < 8) pw = 8;
                int px = x + 1 + (int) ((double) (width - 2 - pw) * (pulse_pos / 0.75));
                cr.set_source_rgb (0.450, 0.455, 0.470);
                cr.rectangle ((double) px, (double) (y + 1), (double) pw, (double) (height - 2));
                cr.fill ();
            } else {
                int fw = (int) ((double) (width - 2) * fraction);
                if (fw > 2) {
                    // Celestial Cerulean (#3897F0)
                    cr.set_source_rgb (0.450, 0.455, 0.470);
                    cr.rectangle ((double) (x + 1), (double) (y + 1), (double) fw, (double) (height - 2));
                    cr.fill ();
                }
            }
            cr.set_line_width (1.0);
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.stroke ();
            if (show_text && text.length > 0) {
                int tw = 0;
                int th = 0;
                measure_text_cached (text, font_size, out tw, out th);
                int tx = x + (width - tw) / 2;
                int ty = y + (height - th) / 2;
                cr.save ();
                cr.rectangle ((double) (x + 2), (double) (y + 1), (double) (width - 4), (double) (height - 2));
                cr.clip ();
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.920, 0.920, 0.925);
                TextHelper.draw_text (cr, text, tx, ty, font_size);
                cr.restore ();
            }
        }
    }

    public class Separator : Widget {
        public Orientation orientation = Orientation.HORIZONTAL;

        public Separator (Orientation orient = Orientation.HORIZONTAL) {
            orientation = orient;
        }

        public void set_orientation (Orientation orient) {
            if (orientation != orient) {
                orientation = orient;
                queue_resize ();
            }
        }
        public Orientation get_orientation () { return orientation; }

        public override void measure (out int min_w, out int min_h) {
            if (orientation == Orientation.VERTICAL) {
                min_w = (req_w > 6) ? req_w : 6;
                min_h = (req_h > 20) ? req_h : 20;
            } else {
                min_w = (req_w > 20) ? req_w : 20;
                min_h = (req_h > 6) ? req_h : 6;
            }
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            if (orientation == Orientation.VERTICAL)
                cr.rectangle ((double) (x + width / 2), (double) y, 1.0, (double) height);
            else
                cr.rectangle ((double) x, (double) (y + height / 2), (double) width, 1.0);
            cr.fill ();
        }
    }

    /**
     * Pill-shaped on/off toggle switch.
     */
    public class Switch : Widget {
        public bool active = false;
        public bool state = false;

        public signal void toggled ();
        public signal bool state_set (bool new_state);

        public Switch (bool initial = false) {
            active = initial;
            state = initial;
        }

        public void set_active (bool v) {
            if (active != v) {
                active = v;
                if (!state_set (v))
                    state = v;
                damage_self ();
                toggled ();
            }
        }

        public bool get_active () {
            return active;
        }

        public void set_state (bool s) {
            if (state != s) {
                state = s;
                damage_self ();
            }
        }

        public bool get_state () {
            return state;
        }

        // The pill draws a hover colour, so it repaints itself on enter/leave.
        public override bool on_pointer_motion (int mx, int my) {
            bool prev = hovered;
            hovered = visible && sensitive && contains (mx, my);
            if (hovered != prev)
                damage_self ();
            return hovered != prev;
        }

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 46) ? req_w : 46;
            min_h = (req_h > 24) ? req_h : 24;
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            int sw = 44;
            int sh = 22;
            int sx = x + (width - sw) / 2;
            int sy = y + (height - sh) / 2;
            if (active)
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.450, 0.455, 0.470);
            else if (hovered)
                // Elevated Surface (#212B36)
                cr.set_source_rgb (0.175, 0.175, 0.182);
            else
                // Stratosphere Line (#26323F)
                cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rounded_rectangle ((double) sx, (double) sy, (double) sw, (double) sh, (double) (sh / 2));
            cr.fill ();
            int kx = active ? (sx + sw - sh + 2) : (sx + 2);
            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.920, 0.920, 0.925);
            cr.rounded_rectangle ((double) kx, (double) (sy + 2), (double) (sh - 4), (double) (sh - 4), (double) ((sh - 4) / 2));
            cr.fill ();
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1 || !contains (mx, my))
                return false;
            grab_focus ();
            set_active (!active);
            return true;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            if (key == ' ' || key == '\n' || key == '\r') {
                set_active (!active);
                return true;
            }
            return false;
        }
    }

    /**
     * GTK4 Adjustment model representing a bounded value with step/page increments.
     */
    public class Adjustment : Object {
        public double value = 0.0;
        public double lower = 0.0;
        public double upper = 100.0;
        public double step_increment = 1.0;
        public double page_increment = 10.0;
        public double page_size = 0.0;

        public signal void value_changed ();
        public signal void changed ();

        public Adjustment (double val = 0.0, double low = 0.0, double up = 100.0,
                           double step_inc = 1.0, double page_inc = 10.0, double page_sz = 0.0) {
            configure (val, low, up, step_inc, page_inc, page_sz);
        }

        public void configure (double val, double low, double up,
                               double step_inc, double page_inc, double page_sz) {
            lower = low;
            upper = (up >= low) ? up : low;
            step_increment = (step_inc > 0.0) ? step_inc : 1.0;
            page_increment = (page_inc > 0.0) ? page_inc : 10.0;
            page_size = (page_sz >= 0.0) ? page_sz : 0.0;
            double max_v = upper - page_size;
            if (max_v < lower) max_v = lower;
            double nv = (val < lower) ? lower : ((val > max_v) ? max_v : val);
            bool vc = (nv != value);
            value = nv;
            changed ();
            if (vc) value_changed ();
        }

        public void set_value (double v) {
            double max_v = upper - page_size;
            if (max_v < lower) max_v = lower;
            double nv = (v < lower) ? lower : ((v > max_v) ? max_v : v);
            if (nv != value) {
                value = nv;
                value_changed ();
            }
        }

        public double get_value () { return value; }
    }

    /**
     * Horizontal range slider supporting drag, track click, wheel, and arrow keys.
     */
    public class Scale : Widget {
        public double min_val = 0.0;
        public double max_val = 100.0;
        public double value = 0.0;
        public double step = 5.0;
        public Orientation orientation = Orientation.HORIZONTAL;
        public bool draw_value = false;
        private Adjustment? adj = null;
        private bool dragging = false;

        public signal void value_changed (double val);

        public Scale (double mn = 0.0, double mx = 100.0, double st = 5.0) {
            min_val = mn;
            max_val = (mx > mn) ? mx : (mn + 1.0);
            step = (st > 0.0) ? st : 1.0;
            value = min_val;
        }

        public Scale.with_range (Orientation orient, double min, double max, double st) {
            orientation = orient;
            min_val = min;
            max_val = (max > min) ? max : (min + 1.0);
            step = (st > 0.0) ? st : 1.0;
            value = min_val;
        }

        public void set_range (double min, double max) {
            min_val = min;
            max_val = (max > min) ? max : (min + 1.0);
            set_value (value);
        }

        public void set_draw_value (bool dv) {
            if (draw_value != dv) {
                draw_value = dv;
                damage_self ();
            }
        }
        public bool get_draw_value () { return draw_value; }

        public Adjustment get_adjustment () {
            if (adj != null)
                return adj;
            var na = new Adjustment (value, min_val, max_val, step, step * 2.0, 0.0);
            adj = na;
            return na;
        }

        public void set_adjustment (Adjustment a) {
            adj = a;
            min_val = a.lower;
            max_val = a.upper;
            step = a.step_increment;
            set_value (a.value);
            weak Scale? self_weak = this;
            a.value_changed.connect ((sender) => {
                if (self_weak != null && self_weak.adj == a)
                    self_weak.set_value (a.value);
            });
        }

        public void set_value (double v) {
            double nv = (v < min_val) ? min_val : ((v > max_val) ? max_val : v);
            if (nv != value) {
                value = nv;
                if (adj != null && adj.value != nv)
                    adj.set_value (nv);
                damage_self ();
                value_changed (value);
            }
        }

        public double get_value () {
            return value;
        }

        private void set_from_pos (int mx, int my) {
            int pad = 8;
            if (orientation == Orientation.VERTICAL) {
                int track_h = height - pad * 2;
                if (track_h <= 0)
                    return;
                double frac = (double) (my - (y + pad)) / (double) track_h;
                if (frac < 0.0) frac = 0.0;
                if (frac > 1.0) frac = 1.0;
                set_value (min_val + frac * (max_val - min_val));
            } else {
                int track_w = width - pad * 2;
                if (track_w <= 0)
                    return;
                double frac = (double) (mx - (x + pad)) / (double) track_w;
                if (frac < 0.0) frac = 0.0;
                if (frac > 1.0) frac = 1.0;
                set_value (min_val + frac * (max_val - min_val));
            }
        }

        public override void measure (out int min_w, out int min_h) {
            if (orientation == Orientation.VERTICAL) {
                min_w = (req_w > 24) ? req_w : 24;
                min_h = (req_h > 120) ? req_h : 120;
            } else {
                min_w = (req_w > 120) ? req_w : 120;
                min_h = (req_h > 24) ? req_h : 24;
            }
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            int pad = 8;
            double span = max_val - min_val;
            double frac = (span > 0.0) ? ((value - min_val) / span) : 0.0;
            if (frac < 0.0) frac = 0.0;
            if (frac > 1.0) frac = 1.0;

            if (orientation == Orientation.VERTICAL) {
                int track_h = height - pad * 2;
                if (track_h <= 0)
                    return;
                int tx = x + width / 2 - 2;
                int fill_h = (int) (frac * (double) track_h);
                cr.set_source_rgb (0.210, 0.210, 0.218);
                cr.rounded_rectangle ((double) tx, (double) (y + pad), 4.0, (double) track_h, 2.0);
                cr.fill ();
                if (fill_h > 0) {
                    cr.set_source_rgb (0.450, 0.455, 0.470);
                    cr.rounded_rectangle ((double) tx, (double) (y + pad), 4.0, (double) fill_h, 2.0);
                    cr.fill ();
                }
                int kx = x + width / 2 - 6;
                int ky = y + pad + fill_h - 6;
                if (dragging)
                    cr.set_source_rgb (0.920, 0.920, 0.925);
                else
                    cr.set_source_rgb (0.450, 0.455, 0.470);
                cr.rounded_rectangle ((double) kx, (double) ky, 12.0, 12.0, 6.0);
                cr.fill ();
                return;
            }

            int track_w = width - pad * 2;
            if (track_w <= 0)
                return;
            int ty = y + height / 2 - 2;
            int fill_w = (int) (frac * (double) track_w);

            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.210, 0.210, 0.218);
            cr.rounded_rectangle ((double) (x + pad), (double) ty, (double) track_w, 4.0, 2.0);
            cr.fill ();
            if (fill_w > 0) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.450, 0.455, 0.470);
                cr.rounded_rectangle ((double) (x + pad), (double) ty, (double) fill_w, 4.0, 2.0);
                cr.fill ();
            }
            int kx = x + pad + fill_w - 6;
            int ky = y + height / 2 - 6;
            if (dragging)
                cr.set_source_rgb (0.920, 0.920, 0.925);
            else
                cr.set_source_rgb (0.450, 0.455, 0.470);
            cr.rounded_rectangle ((double) kx, (double) ky, 12.0, 12.0, 6.0);
            cr.fill ();
            if (draw_value) {
                int iv = (int) (value + ((value >= 0.0) ? 0.5 : -0.5));
                string vs = @"$iv";
                int vw = 0;
                int vh = 0;
                measure_text_cached (vs, 11.0, out vw, out vh);
                cr.set_source_rgb (0.920, 0.920, 0.925);
                TextHelper.draw_text (cr, vs, x + width - vw - 4, y + 2, 11.0);
            }
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (dragging) {
                set_from_pos (mx, my);
                return true;
            }
            return base.on_pointer_motion (mx, my);
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1 || !contains (mx, my))
                return false;
            grab_focus ();
            dragging = true;
            damage_self ();
            set_from_pos (mx, my);
            return true;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (dragging && button == 1) {
                dragging = false;
                damage_self ();
                return true;
            }
            return false;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            if (key == 0x83 || key == 0x81 || key == 0xFF52) { set_value (value - step); return true; }
            if (key == 0x84 || key == 0x82 || key == 0xFF54) { set_value (value + step); return true; }
            if (key == 0x85) { set_value (min_val); return true; }
            if (key == 0x86) { set_value (max_val); return true; }
            return false;
        }

        public override bool on_scroll (int mx, int my, int dx, int dy) {
            if (!visible || !sensitive || !contains (mx, my))
                return false;
            if (dy != 0) {
                set_value (value - (double) dy * step);
                return true;
            }
            return false;
        }
    }
}
