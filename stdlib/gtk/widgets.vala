// Standard Gtk widgets: Label, Button, Entry.
using Cairo;

namespace Gtk {

    public class Label : Widget {
        public string label = "";
        public double font_size = 16.0;
        // Lunar White (#F0F4F8)
        public double r = 0.941;
        public double g = 0.957;
        public double b = 0.973;

        public Label (string text = "") {
            label = text;
        }

        public void set_text (string text) {
            if (text == label)
                return;
            label = text;
            damage_self ();
        }

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
            int ty = y + (height - th) / 2;
            if (ty < y) ty = y;
            cr.set_source_rgb (r, g, b);
            TextHelper.draw_text (cr, label, x + 4, ty, font_size);
        }
    }

    public class Button : Widget {
        public string label = "";
        public double font_size = 15.0;
        public signal void clicked ();

        public Button (string text = "") {
            label = text;
        }

        public void set_label (string text) {
            if (text == label)
                return;
            label = text;
            damage_self ();
        }

        public override void measure (out int min_w, out int min_h) {
            int tw = 0;
            int th = 0;
            measure_text_cached (label, font_size, out tw, out th);
            int bw = tw + 24;
            int bh = th + 16;
            min_w = (req_w > bw) ? req_w : bw;
            min_h = (req_h > bh) ? req_h : bh;
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
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
            cr.set_line_width (1.0);
            if (hovered || pressed)
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.220, 0.592, 0.941);
            else
                // Subtle Border (#324253, 0.6)
                cr.set_source_rgba (0.196, 0.259, 0.325, 0.6);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.stroke ();

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
        public signal void changed ();
        public signal void activate ();

        public Entry (string initial = "") {
            text = initial;
        }

        public void set_text (string t) {
            if (t == text)
                return;
            text = t;
            damage_self ();
            changed ();
        }

        public string get_text () {
            return text.substring (0, text.length);
        }

        public void set_placeholder_text (string p) {
            placeholder = p;
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
            if (text.length > 0) {
                // Lunar White (#F0F4F8)
                cr.set_source_rgb (0.941, 0.957, 0.973);
                TextHelper.measure_text (text, font_size, out tw, out th);
            } else {
                // Titanium Mist (#8B9BB0)
                cr.set_source_rgb (0.545, 0.608, 0.690);
                TextHelper.measure_text (placeholder, font_size, out tw, out th);
            }
            int inner_w = width - 20;
            int scroll_x = (text.length > 0 && tw > inner_w) ? (tw - inner_w) : 0;
            int ty = y + (height - th) / 2;
            cr.save ();
            cr.rectangle ((double) (x + 6), (double) (y + 2), (double) (width - 12), (double) (height - 4));
            cr.clip ();
            if (text.length > 0)
                TextHelper.draw_text (cr, text, x + 10 - scroll_x, ty, font_size);
            else if (placeholder.length > 0)
                TextHelper.draw_text (cr, placeholder, x + 10, ty, font_size);
            if (focused) {
                // Celestial Cerulean (#3897F0)
                cr.set_source_rgb (0.220, 0.592, 0.941);
                cr.rectangle ((double) (x + 11 + tw - scroll_x), (double) (y + 6), 2.0, (double) (height - 12));
                cr.fill ();
            }
            cr.restore ();
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            bool prev = focused;
            if (!visible || !sensitive || !contains (mx, my)) {
                drop_focus ();
                return prev;
            }
            grab_focus ();
            return true;
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            if (key == '\n' || key == '\r') {
                activate ();
                return true;
            }
            if (key == 8 || key == 127) {
                if (text.length > 0) {
                    text = text.substring (0, text.length - 1);
                    damage_self ();
                    changed ();
                }
                return true;
            }
            if (key >= 32 && key < 127) {
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                text = text + ascii.substring (key - 32, 1);
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
        public signal void toggled ();

        public CheckButton (string text = "", bool initial = false) {
            label = text;
            active = initial;
        }

        public bool get_active () {
            return active;
        }

        public void set_active (bool v) {
            if (active != v) {
                active = v;
                damage_self ();
                toggled ();
            }
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
                active = !active;
                damage_self ();
                toggled ();
            }
            return true;
        }
    }

    public class ProgressBar : Widget {
        public double fraction = 0.0;
        public string text = "";
        public double font_size = 13.0;

        public ProgressBar () {}

        public void set_fraction (double f) {
            if (!(f >= 0.0)) f = 0.0;
            if (f > 1.0) f = 1.0;
            if (f == fraction)
                return;
            fraction = f;
            damage_self ();
        }

        public void set_text (string t) {
            if (t == text)
                return;
            text = t;
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
            if (text.length > 0) {
                int tw = 0;
                int th = 0;
                TextHelper.measure_text (text, font_size, out tw, out th);
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

        public signal void toggled ();

        public Switch (bool initial = false) {
            active = initial;
        }

        public void set_active (bool v) {
            if (active != v) {
                active = v;
                damage_self ();
                toggled ();
            }
        }

        public bool get_active () {
            return active;
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
     * Horizontal range slider supporting drag, track click, wheel, and arrow keys.
     */
    public class Scale : Widget {
        public double min_val = 0.0;
        public double max_val = 100.0;
        public double value = 0.0;
        public double step = 5.0;
        private bool dragging = false;

        public signal void value_changed (double val);

        public Scale (double mn = 0.0, double mx = 100.0, double st = 5.0) {
            min_val = mn;
            max_val = (mx > mn) ? mx : (mn + 1.0);
            step = (st > 0.0) ? st : 1.0;
            value = min_val;
        }

        public void set_value (double v) {
            double nv = (v < min_val) ? min_val : ((v > max_val) ? max_val : v);
            if (nv != value) {
                value = nv;
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
