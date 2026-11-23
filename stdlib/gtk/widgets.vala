// Standard Gtk widgets: Label, Button, Entry.
using Cairo;
using GLib;

namespace Gtk {

    public class Label : Widget {
        public string label = "";
        public double font_size = 16.0;
        public float xalign = 0.0f;
        public float yalign = 0.5f;
        // Lunar White (#F0F4F8)
        public double r = 0.941;
        public double g = 0.957;
        public double b = 0.973;

        public Label (string? text = "") {
            label = (text != null) ? text : "";
        }

        public void set_text (string text) {
            if (text == label)
                return;
            label = text;
            damage_self ();
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

        public void set_markup (string str) {
            try {
                set_label (GLib.Markup.strip_tags (str));
            } catch (MarkupError e) {
                set_label (str);
            }
        }

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

        public override void measure (out int min_w, out int min_h) {
            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            min_w = (req_w > tw) ? req_w : (tw + 8);
            min_h = (req_h > th) ? req_h : (th + 8);
        }

        public override void draw (Context cr) {
            if (!visible || label.length == 0)
                return;
            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            int tx = x + 4;
            if (width > tw + 8)
                tx = x + 4 + (int) ((float) (width - tw - 8) * xalign);
            int ty = y + (int) ((float) (height - th) * yalign);
            if (ty < y) ty = y;
            cr.set_source_rgb (r, g, b);
            TextHelper.draw_text (cr, label, tx, ty, font_size);
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
                    cr.set_source_rgb (0.059, 0.078, 0.098);
                else if (hovered)
                    // Elevated Surface (#212B36)
                    cr.set_source_rgb (0.129, 0.169, 0.212);
                else
                    // Slate Atmosphere (#182028)
                    cr.set_source_rgb (0.094, 0.125, 0.157);
                cr.rectangle ((double) x, (double) y, (double) width, (double) height);
                cr.fill ();
                if (has_frame) {
                    cr.set_line_width (1.0);
                    if (hovered || pressed)
                        // Celestial Cerulean (#3897F0)
                        cr.set_source_rgb (0.220, 0.592, 0.941);
                    else
                        // Subtle Border (#324253, 0.6)
                        cr.set_source_rgba (0.196, 0.259, 0.325, 0.6);
                    cr.rectangle ((double) x, (double) y, (double) width, (double) height);
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
                cr.set_source_rgb (0.941, 0.957, 0.973);
            else
                // Dim Carbon (#526275)
                cr.set_source_rgb (0.322, 0.384, 0.459);
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
            if (hovered != prev)
                damage_self ();
            return hovered != prev;
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1)
                return false;
            if (contains (mx, my)) {
                pressed = true;
                damage_self ();
                return true;
            }
            return false;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (!pressed)
                return false;
            bool inside = contains (mx, my);
            pressed = false;
            damage_self ();
            if (inside && visible && sensitive)
                clicked ();
            return true;
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
        public signal void changed ();
        public signal void activate ();

        public Entry (string initial = "") {
            text = initial;
            cursor_pos = text.length;
        }

        ~Entry () {
            stop_blink ();
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
            blink_id = GLib.timeout_add (500, () => {
                if (!focused || !visible || !sensitive) {
                    blink_id = 0;
                    cursor_on = true;
                    return false;
                }
                cursor_on = !cursor_on;
                damage_self ();
                return true;
            });
        }

        public void set_text (string t) {
            string nt = (max_length > 0 && t.length > max_length) ? t.substring (0, max_length) : t;
            if (nt == text)
                return;
            text = nt;
            cursor_pos = text.length;
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
            if (max_length > 0 && text.length > max_length) {
                text = text.substring (0, max_length);
                damage_self ();
                changed ();
            }
        }
        public int get_max_length () { return max_length; }

        private string display_text () {
            if (visibility || text.length == 0)
                return text;
            var sb = new StringBuilder ();
            string ch = "*";
            if (invisible_char >= 32 && invisible_char < 127) {
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                ch = ascii.substring ((int) invisible_char - 32, 1);
            }
            for (int i = 0; i < text.length; i++)
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
                cr.set_source_rgb (0.129, 0.169, 0.212);
            else
                // Obsidian Orbit (#0F1419)
                cr.set_source_rgb (0.059, 0.078, 0.098);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.fill ();
            cr.set_line_width (1.0);
            if (focused)
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.220, 0.592, 0.941);
            else
                // Stratosphere Line (#26323F)
                cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.stroke ();

            int tw = 0;
            int th = 0;
            string disp = display_text ();
            if (disp.length > 0) {
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.941, 0.957, 0.973);
                measure_text_cached (disp, font_size, out tw, out th);
            } else {
                // Titanium Mist (#8B9BB0)
                cr.set_source_rgb (0.545, 0.608, 0.690);
                measure_text_cached (placeholder, font_size, out tw, out th);
            }
            int inner_w = width - 20;
            if (cursor_pos < 0) cursor_pos = 0;
            if (cursor_pos > disp.length) cursor_pos = disp.length;
            int cur_tw = tw;
            if (cursor_pos < disp.length) {
                int dummy_h = 0;
                TextHelper.measure_text (disp.substring (0, cursor_pos), font_size, out cur_tw, out dummy_h);
            }
            int scroll_x = 0;
            if (disp.length > 0 && tw > inner_w) {
                if (cur_tw > inner_w)
                    scroll_x = cur_tw - inner_w;
                if (scroll_x > tw - inner_w)
                    scroll_x = tw - inner_w;
            }
            int ty = y + (height - th) / 2;
            cr.save ();
            cr.rectangle ((double) (x + 6), (double) (y + 2), (double) (width - 12), (double) (height - 4));
            cr.clip ();
            if (disp.length > 0)
                TextHelper.draw_text (cr, disp, x + 10 - scroll_x, ty, font_size);
            else if (placeholder.length > 0)
                TextHelper.draw_text (cr, placeholder, x + 10, ty, font_size);
            if (focused && cursor_on) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.220, 0.592, 0.941);
                cr.rectangle ((double) (x + 10 + cur_tw - scroll_x), (double) (y + 6), 2.0, (double) (height - 12));
                cr.fill ();
            }
            cr.restore ();
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            bool prev = focused;
            if (!visible || !sensitive || !contains (mx, my)) {
                drop_focus ();
                stop_blink ();
                return prev;
            }
            grab_focus ();
            start_blink ();
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
                if (cursor_pos > 0) {
                    cursor_pos--;
                    damage_self ();
                }
                return true;
            }
            if (key == 0x84) { // Right
                if (cursor_pos < text.length) {
                    cursor_pos++;
                    damage_self ();
                }
                return true;
            }
            if (key == 0x85) { // Home
                if (cursor_pos != 0) {
                    cursor_pos = 0;
                    damage_self ();
                }
                return true;
            }
            if (key == 0x86) { // End
                if (cursor_pos != text.length) {
                    cursor_pos = text.length;
                    damage_self ();
                }
                return true;
            }
            if (!editable)
                return false;
            if (key == 8 || key == 127) {
                if (cursor_pos > 0 && text.length > 0) {
                    string before = text.substring (0, cursor_pos - 1);
                    string after = (cursor_pos < text.length) ? text.substring (cursor_pos) : "";
                    text = before + after;
                    cursor_pos--;
                    damage_self ();
                    changed ();
                }
                return true;
            }
            if (key == 0xFFFF) { // Delete
                if (cursor_pos < text.length) {
                    string before = text.substring (0, cursor_pos);
                    string after = (cursor_pos + 1 < text.length) ? text.substring (cursor_pos + 1) : "";
                    text = before + after;
                    damage_self ();
                    changed ();
                }
                return true;
            }
            if (key >= 32 && key < 127) {
                if (max_length > 0 && text.length >= max_length)
                    return true;
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                string ch = ascii.substring (key - 32, 1);
                string before = text.substring (0, cursor_pos);
                string after = (cursor_pos < text.length) ? text.substring (cursor_pos) : "";
                text = before + ch + after;
                cursor_pos++;
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
            group_leader = group;
            if (group != null) {
                if (group.group_members == null)
                    group.group_members = new GenericArray<weak CheckButton> ();
                group.group_members.add (this);
            }
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
                cr.set_source_rgb (0.220, 0.592, 0.941);
                cr.rectangle ((double) bx, (double) by, 18.0, 18.0);
                cr.fill ();
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.941, 0.957, 0.973);
                cr.set_line_width (2.0);
                cr.move_to ((double) (bx + 4), (double) (by + 9));
                cr.line_to ((double) (bx + 8), (double) (by + 13));
                cr.stroke ();
                cr.move_to ((double) (bx + 8), (double) (by + 13));
                cr.line_to ((double) (bx + 14), (double) (by + 5));
                cr.stroke ();
            } else {
                // Obsidian Orbit (#0F1419)
                cr.set_source_rgb (0.059, 0.078, 0.098);
                cr.rectangle ((double) bx, (double) by, 18.0, 18.0);
                cr.fill ();
                cr.set_line_width (1.0);
                if (hovered)
                    cr.set_source_rgb (0.220, 0.592, 0.941);
                else
                    cr.set_source_rgba (0.196, 0.259, 0.325, 0.6);
                cr.rectangle ((double) bx, (double) by, 18.0, 18.0);
                cr.stroke ();
            }
            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            int ty = y + (height - th) / 2;
            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.941, 0.957, 0.973);
            TextHelper.draw_text (cr, label, bx + 26, ty, font_size);
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1)
                return false;
            if (contains (mx, my)) {
                pressed = true;
                return true;
            }
            return false;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (!pressed)
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
    }

    public class ProgressBar : Widget {
        public double fraction = 0.0;
        public string text = "";
        public bool show_text = true;
        public double font_size = 13.0;
        private double pulse_step = 0.1;

        public ProgressBar () {}

        public void set_fraction (double f) {
            if (!(f >= 0.0)) f = 0.0;
            if (f > 1.0) f = 1.0;
            if (f == fraction)
                return;
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
            double nf = fraction + pulse_step;
            if (nf > 1.0) nf = 0.0;
            set_fraction (nf);
        }

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 160) ? req_w : 160;
            min_h = (req_h > 22) ? req_h : 22;
        }

        public override void draw (Context cr) {
            if (!visible || width <= 2 || height <= 2)
                return;
            // Obsidian Orbit (#0F1419)
            cr.set_source_rgb (0.059, 0.078, 0.098);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.fill ();
            int fw = (int) ((double) (width - 2) * fraction);
            if (fw > 2) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.220, 0.592, 0.941);
                cr.rectangle ((double) (x + 1), (double) (y + 1), (double) fw, (double) (height - 2));
                cr.fill ();
            }
            cr.set_line_width (1.0);
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.stroke ();
            if (show_text && text.length > 0) {
                int tw = 0;
                int th = 0;
                measure_text_cached (text, font_size, out tw, out th);
                int tx = x + (width - tw) / 2;
                int ty = y + (height - th) / 2;
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.941, 0.957, 0.973);
                TextHelper.draw_text (cr, text, tx, ty, font_size);
            }
        }
    }

    public class Separator : Widget {
        public Separator () {}

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 20) ? req_w : 20;
            min_h = (req_h > 6) ? req_h : 6;
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.149, 0.196, 0.247);
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
                state = v;
                damage_self ();
                state_set (v);
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
                cr.set_source_rgb (0.220, 0.592, 0.941);
            else if (hovered)
                // Elevated Surface (#212B36)
                cr.set_source_rgb (0.129, 0.169, 0.212);
            else
                // Stratosphere Line (#26323F)
                cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.rounded_rectangle ((double) sx, (double) sy, (double) sw, (double) sh, (double) (sh / 2));
            cr.fill ();
            int kx = active ? (sx + sw - sh + 2) : (sx + 2);
            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.941, 0.957, 0.973);
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
        }

        public void set_value (double v) {
            double nv = (v < min_val) ? min_val : ((v > max_val) ? max_val : v);
            if (nv != value) {
                value = nv;
                if (adj != null)
                    adj.set_value (nv);
                damage_self ();
                value_changed (value);
            }
        }

        public double get_value () {
            return value;
        }

        private void set_from_x (int mx) {
            int pad = 8;
            int track_w = width - pad * 2;
            if (track_w <= 0)
                return;
            double frac = (double) (mx - (x + pad)) / (double) track_w;
            if (frac < 0.0) frac = 0.0;
            if (frac > 1.0) frac = 1.0;
            set_value (min_val + frac * (max_val - min_val));
        }

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 120) ? req_w : 120;
            min_h = (req_h > 24) ? req_h : 24;
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            int pad = 8;
            int track_w = width - pad * 2;
            if (track_w <= 0)
                return;
            int ty = y + height / 2 - 2;
            double span = max_val - min_val;
            double frac = (span > 0.0) ? ((value - min_val) / span) : 0.0;
            if (frac < 0.0) frac = 0.0;
            if (frac > 1.0) frac = 1.0;
            int fill_w = (int) (frac * (double) track_w);

            // Stratosphere Line (#26323F)
            cr.set_source_rgb (0.149, 0.196, 0.247);
            cr.rounded_rectangle ((double) (x + pad), (double) ty, (double) track_w, 4.0, 2.0);
            cr.fill ();
            if (fill_w > 0) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.220, 0.592, 0.941);
                cr.rounded_rectangle ((double) (x + pad), (double) ty, (double) fill_w, 4.0, 2.0);
                cr.fill ();
            }
            int kx = x + pad + fill_w - 6;
            int ky = y + height / 2 - 6;
            if (dragging)
                cr.set_source_rgb (0.941, 0.957, 0.973);
            else
                cr.set_source_rgb (0.220, 0.592, 0.941);
            cr.rounded_rectangle ((double) kx, (double) ky, 12.0, 12.0, 6.0);
            cr.fill ();
        }

        public override bool on_pointer_motion (int mx, int my) {
            if (dragging) {
                set_from_x (mx);
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
            set_from_x (mx);
            return true;
        }

        public override bool on_pointer_release (int mx, int my, int button) {
            if (dragging) {
                dragging = false;
                damage_self ();
                return true;
            }
            return false;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            if (key == 0x83) { set_value (value - step); return true; }
            if (key == 0x84) { set_value (value + step); return true; }
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
