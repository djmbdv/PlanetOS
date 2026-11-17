// Standard Gtk widgets: Label, Button, Entry.
using Cairo;

namespace Gtk {

    public class Label : Widget {
        public string label = "";
        public double font_size = 16.0;
        public double r = 0.92;
        public double g = 0.94;
        public double b = 0.97;

        public Label (string text = "") {
            label = text;
        }

        public void set_text (string text) {
            label = text;
        }

        public override void measure (out int min_w, out int min_h) {
            int tw = 0;
            int th = 0;
            TextHelper.measure_text (label, font_size, out tw, out th);
            min_w = (req_w > tw) ? req_w : (tw + 8);
            min_h = (req_h > th) ? req_h : (th + 8);
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            int tw = 0;
            int th = 0;
            TextHelper.measure_text (label, font_size, out tw, out th);
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
            label = text;
        }

        public override void measure (out int min_w, out int min_h) {
            int tw = 0;
            int th = 0;
            TextHelper.measure_text (label, font_size, out tw, out th);
            int bw = tw + 24;
            int bh = th + 16;
            min_w = (req_w > bw) ? req_w : bw;
            min_h = (req_h > bh) ? req_h : bh;
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            if (pressed) {
                cr.fill_gradient_v ((double) x, (double) y, (double) width, (double) height,
                                    0.14, 0.36, 0.62, 0.10, 0.28, 0.50);
            } else if (hovered) {
                cr.fill_gradient_v ((double) x, (double) y, (double) width, (double) height,
                                    0.26, 0.52, 0.82, 0.19, 0.42, 0.70);
            } else {
                cr.fill_gradient_v ((double) x, (double) y, (double) width, (double) height,
                                    0.20, 0.24, 0.31, 0.15, 0.18, 0.24);
            }
            cr.set_line_width (1.0);
            if (hovered || pressed)
                cr.set_source_rgb (0.45, 0.72, 0.98);
            else
                cr.set_source_rgb (0.34, 0.39, 0.48);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 6.0);
            cr.stroke ();

            int tw = 0;
            int th = 0;
            TextHelper.measure_text (label, font_size, out tw, out th);
            int tx = x + (width - tw) / 2;
            int ty = y + (height - th) / 2;
            cr.set_source_rgb (0.96, 0.97, 0.99);
            TextHelper.draw_text (cr, label, tx, ty, font_size);
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
            text = t;
            changed ();
        }

        public string get_text () {
            return text.substring (0, text.length);
        }

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 160) ? req_w : 160;
            min_h = (req_h > 34) ? req_h : 34;
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            cr.set_source_rgb (0.10, 0.12, 0.16);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 5.0);
            cr.fill ();
            cr.set_line_width (focused ? 2.0 : 1.0);
            if (focused)
                cr.set_source_rgb (0.35, 0.65, 0.98);
            else
                cr.set_source_rgb (0.30, 0.35, 0.43);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 5.0);
            cr.stroke ();

            int tw = 0;
            int th = 0;
            if (text.length > 0) {
                cr.set_source_rgb (0.94, 0.96, 0.98);
                TextHelper.measure_text (text, font_size, out tw, out th);
            } else {
                cr.set_source_rgb (0.50, 0.55, 0.63);
                TextHelper.measure_text (placeholder, font_size, out tw, out th);
            }
            int ty = y + (height - th) / 2;
            cr.save ();
            cr.rectangle ((double) (x + 6), (double) (y + 2), (double) (width - 12), (double) (height - 4));
            cr.clip ();
            if (text.length > 0)
                TextHelper.draw_text (cr, text, x + 10, ty, font_size);
            else
                TextHelper.draw_text (cr, placeholder, x + 10, ty, font_size);
            if (focused) {
                int cw = 0;
                int ch = 0;
                TextHelper.measure_text (text, font_size, out cw, out ch);
                cr.set_source_rgb (0.45, 0.78, 1.0);
                cr.rectangle ((double) (x + 11 + cw), (double) (y + 6), 2.0, (double) (height - 12));
                cr.fill ();
            }
            cr.restore ();
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive)
                return false;
            focused = contains (mx, my);
            return focused;
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
                    changed ();
                }
                return true;
            }
            if (key >= 32 && key < 127) {
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                text = text + ascii.substring (key - 32, 1);
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
                toggled ();
            }
        }

        public override void measure (out int min_w, out int min_h) {
            int tw = 0;
            int th = 0;
            TextHelper.measure_text (label, font_size, out tw, out th);
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
                cr.set_source_rgb (0.24, 0.54, 0.88);
                cr.rounded_rectangle ((double) bx, (double) by, 18.0, 18.0, 4.0);
                cr.fill ();
                cr.set_source_rgb (0.97, 0.98, 1.0);
                cr.set_line_width (2.0);
                cr.move_to ((double) (bx + 4), (double) (by + 9));
                cr.line_to ((double) (bx + 8), (double) (by + 13));
                cr.stroke ();
                cr.move_to ((double) (bx + 8), (double) (by + 13));
                cr.line_to ((double) (bx + 14), (double) (by + 5));
                cr.stroke ();
            } else {
                cr.set_source_rgb (0.12, 0.14, 0.19);
                cr.rounded_rectangle ((double) bx, (double) by, 18.0, 18.0, 4.0);
                cr.fill ();
                cr.set_line_width (1.0);
                if (hovered)
                    cr.set_source_rgb (0.45, 0.72, 0.98);
                else
                    cr.set_source_rgb (0.34, 0.39, 0.48);
                cr.rounded_rectangle ((double) bx, (double) by, 18.0, 18.0, 4.0);
                cr.stroke ();
            }
            int tw = 0;
            int th = 0;
            TextHelper.measure_text (label, font_size, out tw, out th);
            int ty = y + (height - th) / 2;
            cr.set_source_rgb (0.92, 0.94, 0.97);
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
            if (f < 0.0) f = 0.0;
            if (f > 1.0) f = 1.0;
            fraction = f;
        }

        public void set_text (string t) {
            text = t;
        }

        public override void measure (out int min_w, out int min_h) {
            min_w = (req_w > 160) ? req_w : 160;
            min_h = (req_h > 22) ? req_h : 22;
        }

        public override void draw (Context cr) {
            if (!visible)
                return;
            cr.set_source_rgb (0.10, 0.12, 0.16);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 6.0);
            cr.fill ();
            int fw = (int) ((double) (width - 2) * fraction);
            if (fw > 4) {
                cr.fill_gradient_v ((double) (x + 1), (double) (y + 1), (double) fw, (double) (height - 2),
                                    0.25, 0.56, 0.90, 0.18, 0.42, 0.74);
            }
            cr.set_line_width (1.0);
            cr.set_source_rgb (0.30, 0.35, 0.43);
            cr.rounded_rectangle ((double) x, (double) y, (double) width, (double) height, 6.0);
            cr.stroke ();
            if (text.length > 0) {
                int tw = 0;
                int th = 0;
                TextHelper.measure_text (text, font_size, out tw, out th);
                int tx = x + (width - tw) / 2;
                int ty = y + (height - th) / 2;
                cr.set_source_rgb (0.95, 0.97, 0.99);
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
            cr.set_source_rgb (0.26, 0.30, 0.38);
            cr.rectangle ((double) x, (double) (y + height / 2), (double) width, 1.0);
            cr.fill ();
        }
    }
}
