// Pure-Vala Pango compatibility layer for PlanetOS (zero C, zero .vapi).
//
// This is a text *layout* layer on top of the compact 5x7 bitmap font that
// Cairo paints: Pango measures, wraps, ellipsizes and aligns text, and
// PangoCairo draws the resulting lines. Metrics are exact for that font
// (6xscale advance, 7xscale height) instead of shaping real outlines.

using Cairo;
using Pango;

namespace Pango {
    public enum EllipsizeMode { NONE, END }
    public enum Alignment { LEFT, CENTER, RIGHT }
    public enum Weight { NORMAL, BOLD }
    public enum Style { NORMAL, ITALIC }

    public class FontDescription : Object {
        public string family = "sans";
        public int size = 16; // pixel size, mapped onto the bitmap font scale
        public Weight weight = Weight.NORMAL;
        public Style style = Style.NORMAL;

        public FontDescription () {}

        public FontDescription copy () {
            var d = new FontDescription ();
            d.family = family;
            d.size = size;
            d.weight = weight;
            d.style = style;
            return d;
        }

        private static bool word_is (string spec, int start, int len, string word) {
            if (len != word.length)
                return false;
            for (int k = 0; k < len; k++) {
                int c = (int) spec[start + k];
                if (c >= 'A' && c <= 'Z')
                    c = c + 32;
                if (c != (int) word[k])
                    return false;
            }
            return true;
        }

        // "Sans 16", "mono 24 italic", "sans bold"
        public static FontDescription from_string (string spec) {
            var d = new FontDescription ();
            int i = 0;
            while (i < spec.length) {
                while (i < spec.length && spec[i] == ' ')
                    i = i + 1;
                if (i >= spec.length)
                    break;
                int start = i;
                while (i < spec.length && spec[i] != ' ')
                    i = i + 1;
                int len = i - start;
                int value = 0;
                bool all_digits = (len > 0);
                for (int k = start; k < start + len; k++) {
                    int c = (int) spec[k];
                    if (c >= '0' && c <= '9')
                        value = value * 10 + (c - 48);
                    else
                        all_digits = false;
                }
                if (all_digits) {
                    d.size = (value > 0) ? value : 16;
                } else if (word_is (spec, start, len, "bold")) {
                    d.weight = Weight.BOLD;
                } else if (word_is (spec, start, len, "italic")) {
                    d.style = Style.ITALIC;
                } else if (word_is (spec, start, len, "normal")) {
                    d.weight = Weight.NORMAL;
                } else if (word_is (spec, start, len, "mono")) {
                    d.family = "mono";
                } else if (word_is (spec, start, len, "serif")) {
                    d.family = "serif";
                } else if (word_is (spec, start, len, "sans")) {
                    d.family = "sans";
                }
            }
            return d;
        }

        public string describe () {
            return @"$family $size";
        }
    }

    // Named PangoContext (the C type name) because planc resolves type names
    // per file and a Pango.Context class would clash with Cairo.Context.
    public class PangoContext : Object {
        public FontDescription font_description;

        public PangoContext () {
            font_description = new FontDescription ();
        }

        // Glyph scale used by the Cairo bitmap font for a pixel size.
        public int glyph_scale (int px) {
            int s = px / 8;
            if (s < 1) return 1;
            if (s > 4) return 4;
            return s;
        }
    }

    public class Layout : Object {
        private PangoContext ctx;
        private FontDescription desc;
        private string text = "";
        private int wrap_width = -1;
        private EllipsizeMode ellipsize = EllipsizeMode.NONE;
        private Alignment alignment = Alignment.LEFT;
        private int spacing = 2;
        private int[] starts;
        private int[] lens;
        private int[] fitting;
        private int[] trunc;
        private int nlines = 0;

        public Layout (PangoContext context) {
            ctx = context;
            desc = context.font_description.copy ();
            starts = new int[1];
            lens = new int[1];
            fitting = new int[1];
            trunc = new int[1];
        }

        public int scale () { return ctx.glyph_scale (desc.size); }
        public int char_width () { return 6 * scale (); }
        public int line_height () { return 7 * scale (); }
        public int spacing_px () { return spacing; }
        public int line_count () { return nlines; }
        public string text_body () { return text; }
        public string current_text () { return text; }
        public int current_width () { return wrap_width; }
        public int line_start_of (int i) { return (i >= 0 && i < nlines) ? starts[i] : 0; }
        public int line_length_of (int i) { return (i >= 0 && i < nlines) ? lens[i] : 0; }
        public int line_chars_of (int i) { return (i >= 0 && i < nlines) ? fitting[i] : 0; }
        public bool line_truncated (int i) { return (i >= 0 && i < nlines) ? (trunc[i] != 0) : false; }
        public Alignment alignment_mode () { return alignment; }
        public EllipsizeMode ellipsize_mode () { return ellipsize; }
        public FontDescription font () { return desc; }

        public void set_text (string t) {
            text = t;
            reflow ();
        }

        public void set_font_description (FontDescription d) {
            desc = d.copy ();
            reflow ();
        }

        public void set_width (int px) {
            wrap_width = px;
            reflow ();
        }

        public void set_ellipsize (EllipsizeMode mode) {
            ellipsize = mode;
            reflow ();
        }

        public void set_alignment (Alignment a) {
            alignment = a;
        }

        public void set_spacing (int px) {
            spacing = (px < 0) ? 0 : px;
        }

        public int pixel_width () {
            int maxw = 0;
            for (int i = 0; i < nlines; i++) {
                int chars = fitting[i];
                if (trunc[i] != 0)
                    chars = chars + 2;
                int w = chars * char_width ();
                if (w > maxw)
                    maxw = w;
            }
            return maxw;
        }

        public int pixel_height () {
            if (nlines <= 0)
                return 0;
            return nlines * line_height () + (nlines - 1) * spacing;
        }

        // x offset of a line inside the layout box, for the current alignment.
        public int alignment_offset (int chars) {
            int total = pixel_width ();
            int w = chars * char_width ();
            if (alignment == Alignment.CENTER)
                return (total - w) / 2;
            if (alignment == Alignment.RIGHT)
                return total - w;
            return 0;
        }

        private void reflow () {
            int cap = text.length + 2;
            starts = new int[cap];
            lens = new int[cap];
            fitting = new int[cap];
            trunc = new int[cap];
            nlines = 0;
            if (text.length == 0) {
                add_line (0, 0, -1);
                return;
            }

            int maxc = (wrap_width > 0) ? (wrap_width / char_width ()) : -1;
            if (maxc == 0)
                maxc = 1;

            int line_start = 0;
            int i = 0;
            while (i < text.length) {
                if (text[i] == '\n') {
                    add_line (line_start, i - line_start, maxc);
                    line_start = i + 1;
                    i = i + 1;
                    continue;
                }
                if (maxc > 0 && ellipsize == EllipsizeMode.NONE && (i - line_start + 1) > maxc) {
                    int brk = -1;
                    for (int k = i - 1; k > line_start; k--) {
                        if (text[k] == ' ') {
                            brk = k;
                            break;
                        }
                    }
                    if (brk > line_start) {
                        add_line (line_start, brk - line_start, maxc);
                        line_start = brk + 1;
                        i = line_start;
                    } else {
                        add_line (line_start, i - line_start, maxc);
                        line_start = i;
                    }
                    continue;
                }
                i = i + 1;
            }
            add_line (line_start, text.length - line_start, maxc);
        }

        private void add_line (int start, int len, int maxc) {
            if (nlines >= starts.length)
                return;
            starts[nlines] = start;
            lens[nlines] = len;
            if (maxc > 0 && len > maxc) {
                if (ellipsize == EllipsizeMode.END) {
                    fitting[nlines] = (maxc > 2) ? (maxc - 2) : 0;
                    trunc[nlines] = 1;
                } else {
                    fitting[nlines] = maxc;
                    trunc[nlines] = 0;
                }
            } else {
                fitting[nlines] = len;
                trunc[nlines] = 0;
            }
            nlines = nlines + 1;
        }
    }
}

namespace PangoCairo {
    // Draws a layout with its top-left corner at (x, y).
    public void show_layout_at (Context cr, Layout layout, int x, int y) {
        int lh = layout.line_height ();
        int sp = layout.spacing_px ();
        int n = layout.line_count ();
        for (int i = 0; i < n; i++) {
            int chars = layout.line_chars_of (i);
            int lx = x + layout.alignment_offset (chars);
            int ly = y + i * (lh + sp);
            cr.set_font_size ((double) (layout.scale () * 8));
            cr.move_to (lx, ly);
            cr.show_text_range (layout.text_body (), layout.line_start_of (i), chars);
            if (layout.line_truncated (i)) {
                cr.move_to (lx + chars * layout.char_width (), ly);
                cr.show_text ("..");
            }
        }
    }

    public void show_layout (Context cr, Layout layout) {
        show_layout_at (cr, layout, cr.current_x (), cr.current_y ());
    }
}
