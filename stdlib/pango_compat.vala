// Pure-Vala Pango compatibility layer for PlanetOS (zero C, zero .vapi).
//
// Supports both TrueType fonts via libschrift (when loaded through
// FontRegistry.load_ttf / load_mono_ttf) and automatic fallback to the
// compact 5x7 Cairo bitmap font (6*scale advance, 7*scale height).

using Planet;
using GLib;
using Cairo;
using Schrift;
using Pango;

namespace Pango {
    public enum EllipsizeMode { NONE, END }
    public enum Alignment { LEFT, CENTER, RIGHT }
    public enum Weight { NORMAL, BOLD }
    public enum Style { NORMAL, ITALIC }

    public class FontDescription : Object {
        public string family = "sans";
        public int size = 16; // pixel size
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

        public bool equals (FontDescription other) {
            return family == other.family
                && size == other.size
                && weight == other.weight
                && style == other.style;
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
            if (spec == null)
                return d;
            int i = 0;
            while (i < spec.length) {
                while (i < spec.length && (spec[i] == ' ' || spec[i] == ','))
                    i = i + 1;
                if (i >= spec.length)
                    break;
                int start = i;
                while (i < spec.length && spec[i] != ' ' && spec[i] != ',')
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
            string s = @"$family";
            if (weight == Weight.BOLD)
                s = s + " bold";
            if (style == Style.ITALIC)
                s = s + " italic";
            return @"$s $size";
        }
    }

    // --- TrueType (libschrift) glyph cache & UTF-8 decoder -----------------

    public class GlyphEntry : Object {
        public int32 key = 0; // (cp << 10) | size_px
        public SftImage? img = null;
        public int16 adv = 0;
        public int16 lsb = 0;
        public int16 y_off = 0;
    }

    public class FontSlot : Object {
        public const int CACHE_CAP = 1024;
        public const int HTAB_SIZE = 2048;
        public SftFont? font = null;
        public GenericArray<GlyphEntry>? cache = null;
        public int16[]? htab = null;
        public int cache_cursor = 0;
        public float cached_asc = 14.0f;
        public float cached_desc = -3.0f;
        public int16 cached_size = 0;

        public void ensure_htab () {
            if (htab != null)
                return;
            var t = new int16[HTAB_SIZE];
            for (int i = 0; i < HTAB_SIZE; i++)
                t[i] = -1;
            htab = t;
        }
    }

    private FontSlot? pango_sans_slot;
    private FontSlot? pango_mono_slot;

    public class FontRegistry : Object {
        private const int MAX_FONT_BYTES = 16 * 1024 * 1024;

        private static FontSlot? load_slot (string path) {
            int fd = Sys.open (path);
            if (fd < 0)
                return null;
            int sz = Sys.file_size (fd);
            if (sz < 12 || sz > MAX_FONT_BYTES) {
                Sys.close (fd);
                return null;
            }
            var buf = new uint8[sz];
            int got = 0;
            int first = Sys.read (fd, buf, sz);
            if (first > 0)
                got = first;
            if (got < sz) {
                var chunk = new uint8[4096];
                while (got < sz) {
                    int want = sz - got;
                    if (want > 4096)
                        want = 4096;
                    int r = Sys.read (fd, chunk, want);
                    if (r <= 0)
                        break;
                    for (int j = 0; j < r; j++)
                        buf[got + j] = chunk[j];
                    got += r;
                }
            }
            Sys.close (fd);
            if (got != sz)
                return null;
            var f = SftFont.load_mem (buf, sz);
            if (f == null)
                return null;
            var s = new FontSlot ();
            s.font = f;
            s.cache = new GenericArray<GlyphEntry> ();
            return s;
        }

        public static bool load_ttf (string path) {
            pango_sans_slot = load_slot (path);
            return pango_sans_slot != null;
        }

        public static bool load_mono_ttf (string path) {
            pango_mono_slot = load_slot (path);
            return pango_mono_slot != null;
        }

        public static FontSlot? slot_for_family (string family) {
            if (family == "mono")
                return (pango_mono_slot != null) ? pango_mono_slot : pango_sans_slot;
            return pango_sans_slot;
        }

        public static bool has_ttf (string family) {
            var s = slot_for_family (family);
            return s != null && s.font != null;
        }

        public static void ensure_line_metrics (FontSlot? slot, int size_px) {
            if (slot == null || slot.font == null)
                return;
            if (size_px < 1)
                size_px = 1;
            if (size_px > 512)
                size_px = 512;
            if ((int) slot.cached_size == size_px)
                return;
            var sft = new Sft ();
            sft.font = slot.font;
            sft.x_scale = (double) size_px;
            sft.y_scale = (double) size_px;
            sft.flags = SFT_DOWNWARD_Y;
            var lm = new SftLMetrics ();
            if (sft.lmetrics (lm) == 0) {
                slot.cached_asc = (float) lm.ascender;
                slot.cached_desc = (float) lm.descender;
                slot.cached_size = (int16) size_px;
            }
        }

        public static int slot_line_height (FontSlot slot, int size_px) {
            int px = (size_px < 1) ? 1 : size_px;
            ensure_line_metrics (slot, px);
            int lh = (int) (slot.cached_asc - slot.cached_desc + 1.0);
            return (lh > px) ? lh : px;
        }

        public static GlyphEntry? get_glyph_from (FontSlot? slot, int cp, int size_px) {
            if (slot == null || slot.font == null)
                return null;
            if (cp < 0 || cp > 0x10FFFF)
                cp = 0xFFFD;
            if (size_px < 1)
                size_px = 1;
            if (size_px > 512)
                size_px = 512;
            ensure_line_metrics (slot, size_px);
            if (slot.cache == null)
                slot.cache = new GenericArray<GlyphEntry> ();
            slot.ensure_htab ();
            int mask = FontSlot.HTAB_SIZE - 1;
            int32 key = (int32) ((cp << 10) | (size_px & 0x3FF));
            int h = ((key * 2654435761) >> 16) & mask;
            int probe = h;
            for (int step = 0; step < FontSlot.HTAB_SIZE; step++) {
                int idx = (int) slot.htab[probe];
                if (idx < 0)
                    break;
                if (slot.cache[idx].key == key)
                    return slot.cache[idx];
                probe = (probe + 1) & mask;
            }
            var sft = new Sft ();
            sft.font = slot.font;
            sft.x_scale = (double) size_px;
            sft.y_scale = (double) size_px;
            sft.flags = SFT_DOWNWARD_Y;
            int gid = 0;
            if (sft.lookup (cp, out gid) != 0)
                return null;
            var gm = new SftGMetrics ();
            if (sft.gmetrics (gid, gm) != 0)
                return null;
            var ge = new GlyphEntry ();
            ge.key = key;
            ge.adv = (int16) (gm.advance_width + 0.5);
            ge.lsb = (int16) gm.left_side_bearing;
            ge.y_off = (int16) gm.y_offset;
            if (gm.min_width > 0 && gm.min_height > 0) {
                var img = new SftImage (gm.min_width, gm.min_height);
                if (sft.render (gid, img) == 0)
                    ge.img = img;
            }
            if (slot.cache.length < FontSlot.CACHE_CAP) {
                int new_idx = slot.cache.length;
                slot.cache.add (ge);
                slot.htab[probe] = (int16) new_idx;
            } else {
                int evict_idx = slot.cache_cursor;
                slot.cache[evict_idx] = ge;
                slot.cache_cursor = (evict_idx + 1) % FontSlot.CACHE_CAP;
                for (int i = 0; i < FontSlot.HTAB_SIZE; i++)
                    slot.htab[i] = -1;
                for (int i = 0; i < slot.cache.length; i++) {
                    int32 k = slot.cache[i].key;
                    int p = ((k * 2654435761) >> 16) & mask;
                    while (slot.htab[p] >= 0)
                        p = (p + 1) & mask;
                    slot.htab[p] = (int16) i;
                }
            }
            return ge;
        }

        public static int next_utf8 (string text, ref int pos) {
            int n = text.length;
            uint8 b0 = (uint8) text[pos++];
            if (b0 < 0x80)
                return (int) b0;
            if ((b0 & 0xE0) == 0xC0 && pos < n) {
                uint8 b1 = (uint8) text[pos];
                if ((b1 & 0xC0) != 0x80 || b0 < 0xC2)
                    return 0xFFFD;
                pos++;
                return ((int) (b0 & 0x1F) << 6) | (int) (b1 & 0x3F);
            }
            if ((b0 & 0xF0) == 0xE0 && pos + 1 < n) {
                uint8 b1 = (uint8) text[pos];
                uint8 b2 = (uint8) text[pos + 1];
                if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80)
                    return 0xFFFD;
                int cp = ((int) (b0 & 0x0F) << 12) | ((int) (b1 & 0x3F) << 6) | (int) (b2 & 0x3F);
                if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))
                    return 0xFFFD;
                pos += 2;
                return cp;
            }
            if ((b0 & 0xF8) == 0xF0 && pos + 2 < n) {
                uint8 b1 = (uint8) text[pos];
                uint8 b2 = (uint8) text[pos + 1];
                uint8 b3 = (uint8) text[pos + 2];
                if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80)
                    return 0xFFFD;
                int cp = ((int) (b0 & 0x07) << 18) | ((int) (b1 & 0x3F) << 12) | ((int) (b2 & 0x3F) << 6) | (int) (b3 & 0x3F);
                if (cp < 0x10000 || cp > 0x10FFFF)
                    return 0xFFFD;
                pos += 3;
                return cp;
            }
            return 0xFFFD;
        }

        public static int glyph_advance (FontSlot? slot, int cp, int size_px) {
            if (cp == '\r')
                return 0;
            if (slot != null && slot.font != null) {
                var ge = get_glyph_from (slot, cp, size_px);
                return (ge != null) ? (int) ge.adv : (size_px / 2);
            }
            int sc = size_px / 8;
            if (sc < 1) sc = 1;
            if (sc > 4) sc = 4;
            return (cp < 0x80) ? (6 * sc) : 0;
        }

        public static int measure_string_px (FontSlot? slot, string text, int start, int byte_len, int size_px) {
            int end = start + byte_len;
            if (end > text.length)
                end = text.length;
            int pos = (start < 0) ? 0 : start;
            int w = 0;
            while (pos < end) {
                int cp = next_utf8 (text, ref pos);
                w += glyph_advance (slot, cp, size_px);
            }
            return w;
        }

        public static int draw_glyph (FontSlot? slot, Context cr, int cp, int size_px, int cx, int y) {
            if (slot == null)
                return size_px / 2;
            var ge = get_glyph_from (slot, cp, size_px);
            if (ge != null) {
                if (ge.img != null) {
                    int gx = cx + ge.lsb;
                    int gy = y + (int) slot.cached_asc + ge.y_off;
                    cr.blit_alpha_mask (ge.img.pixels, ge.img.width, ge.img.height, gx, gy);
                }
                return (int) ge.adv;
            }
            return size_px / 2;
        }

        public static void measure_slot (FontSlot? slot, string text, double size_px, out int out_w, out int out_h) {
            int px = (int) size_px;
            if (px < 1) px = 1;
            if (slot != null && slot.font != null) {
                int cx = 0;
                int pos = 0;
                while (pos < text.length) {
                    int cp = next_utf8 (text, ref pos);
                    var ge = get_glyph_from (slot, cp, px);
                    cx += (ge != null) ? ge.adv : (px / 2);
                }
                out_w = (text.length == 0) ? 0 : (cx + 2);
                out_h = slot_line_height (slot, px);
                return;
            }
            int sc = px / 8;
            if (sc < 1) sc = 1;
            if (sc > 4) sc = 4;
            out_w = text.length * 6 * sc;
            out_h = 7 * sc;
        }

        public static void draw_slot (FontSlot? slot, Context cr, string text, int x, int y, double size_px) {
            if (text.length == 0)
                return;
            int px = (int) size_px;
            if (px < 1) px = 1;
            int c_top = cr.clip_top ();
            int c_bot = cr.clip_bottom ();
            int c_right = cr.clip_right ();
            if (y >= c_bot || y + px + 8 <= c_top || x >= c_right)
                return;
            if (slot != null && slot.font != null) {
                ensure_line_metrics (slot, px);
                int cx = x;
                int pos = 0;
                while (pos < text.length && cx < c_right) {
                    int cp = next_utf8 (text, ref pos);
                    cx += draw_glyph (slot, cr, cp, px, cx, y);
                }
                return;
            }
            cr.set_font_size (size_px);
            cr.move_to ((double) x, (double) y);
            cr.show_text (text);
        }

        public static int mono_advance (double size_px) {
            int px = (int) size_px;
            if (px < 1) px = 1;
            FontSlot? s = slot_for_family ("mono");
            if (s != null && s.font != null) {
                var ge = get_glyph_from (s, 'M', px);
                if (ge != null)
                    return (int) ge.adv;
                return px / 2;
            }
            int sc = px / 8;
            if (sc < 1) sc = 1;
            if (sc > 4) sc = 4;
            return 6 * sc;
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

    public class ColorAttribute : Object {
        public int start_;
        public int end_;
        public int argb;

        public ColorAttribute (int start_, int end_, int argb) {
            this.start_ = start_;
            this.end_ = end_;
            this.argb = argb;
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
        private int cap = 8;
        private int[] starts;
        private int[] lens;
        private int[] fitting;
        private int[] fitting_bytes;
        private int[] line_w;
        private int[] trunc;
        private int nlines = 0;
        private int max_line_w = 0;
        private GenericArray<ColorAttribute> attrs;

        public Layout (PangoContext context) {
            ctx = context;
            desc = context.font_description.copy ();
            starts = new int[cap];
            lens = new int[cap];
            fitting = new int[cap];
            fitting_bytes = new int[cap];
            line_w = new int[cap];
            trunc = new int[cap];
            attrs = new GenericArray<ColorAttribute> ();
            add_line (0, 0, 0, 0, 0, false);
        }

        // --- attributes -------------------------------------------------

        // Colour run over [start, end); the renderer paints those glyphs with
        // the attribute colour instead of the caller's source colour.
        public void add_color_attribute (int start_, int end_, double r, double g, double b) {
            if (end_ <= 0 || end_ <= start_)
                return;
            int s = (start_ < 0) ? 0 : start_;
            int ir = (int) (r * 255.0);
            int ig = (int) (g * 255.0);
            int ib = (int) (b * 255.0);
            if (ir < 0) ir = 0;
            if (ir > 255) ir = 255;
            if (ig < 0) ig = 0;
            if (ig > 255) ig = 255;
            if (ib < 0) ib = 0;
            if (ib > 255) ib = 255;
            attrs.add (new ColorAttribute (s, end_, (ir << 16) | (ig << 8) | ib));
        }

        public void clear_attributes () {
            if (attrs.length > 0)
                attrs = new GenericArray<ColorAttribute> ();
        }

        public int attribute_count () { return attrs.length; }
        public bool has_attributes () { return attrs.length > 0; }

        // 0xRRGGBB for the glyph at byte index, or -1 when no attribute covers it.
        // Iterates backwards so later attributes override earlier ones.
        public int color_at (int index) {
            for (int i = attrs.length - 1; i >= 0; i--) {
                var a = attrs[i];
                if (index >= a.start_ && index < a.end_)
                    return a.argb;
            }
            return -1;
        }

        public int scale () { return ctx.glyph_scale (desc.size); }
        public int char_width () { return 6 * scale (); }

        public int line_height () {
            var slot = FontRegistry.slot_for_family (desc.family);
            if (slot != null && slot.font != null)
                return FontRegistry.slot_line_height (slot, desc.size);
            return 7 * scale ();
        }

        public int spacing_px () { return spacing; }
        public int line_count () { return nlines; }
        public string text_body () { return text; }
        public string current_text () { return text; }
        public int current_width () { return wrap_width; }
        public int line_start_of (int i) { return (i >= 0 && i < nlines) ? starts[i] : 0; }
        public int line_length_of (int i) { return (i >= 0 && i < nlines) ? lens[i] : 0; }
        public int line_chars_of (int i) { return (i >= 0 && i < nlines) ? fitting[i] : 0; }
        public int line_bytes_of (int i) { return (i >= 0 && i < nlines) ? fitting_bytes[i] : 0; }
        public int line_width_of (int i) { return (i >= 0 && i < nlines) ? line_w[i] : 0; }
        public bool line_truncated (int i) { return (i >= 0 && i < nlines) ? (trunc[i] != 0) : false; }
        public Alignment alignment_mode () { return alignment; }
        public EllipsizeMode ellipsize_mode () { return ellipsize; }
        public FontDescription font () { return desc; }

        public void set_text (string t) {
            string nt = (t != null) ? t : "";
            if (nt == text && nlines > 0)
                return;
            text = nt;
            reflow ();
        }

        public void set_font_description (FontDescription d) {
            if (d == null)
                return;
            if (desc.equals (d))
                return;
            desc = d.copy ();
            reflow ();
        }

        public void set_width (int px) {
            if (wrap_width == px)
                return;
            wrap_width = px;
            reflow ();
        }

        public void set_ellipsize (EllipsizeMode mode) {
            if (ellipsize == mode)
                return;
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
            return max_line_w;
        }

        public int pixel_height () {
            if (nlines <= 0)
                return 0;
            return nlines * line_height () + (nlines - 1) * spacing;
        }

        public void get_pixel_size (out int width, out int height) {
            width = pixel_width ();
            height = pixel_height ();
        }

        // x offset of a line inside the layout box, given its pixel width.
        public int alignment_offset_px (int line_px) {
            if (alignment == Alignment.CENTER)
                return (max_line_w - line_px) / 2;
            if (alignment == Alignment.RIGHT)
                return max_line_w - line_px;
            return 0;
        }

        // Compatibility helper: x offset given a bitmap character count.
        public int alignment_offset (int chars) {
            return alignment_offset_px (chars * char_width ());
        }

        private void ensure_cap () {
            if (nlines < cap)
                return;
            int ncap = cap * 2;
            var ns = new int[ncap];
            var nl = new int[ncap];
            var nf = new int[ncap];
            var nfb = new int[ncap];
            var nw = new int[ncap];
            var nt = new int[ncap];
            for (int i = 0; i < cap; i++) {
                ns[i] = starts[i];
                nl[i] = lens[i];
                nf[i] = fitting[i];
                nfb[i] = fitting_bytes[i];
                nw[i] = line_w[i];
                nt[i] = trunc[i];
            }
            starts = ns;
            lens = nl;
            fitting = nf;
            fitting_bytes = nfb;
            line_w = nw;
            trunc = nt;
            cap = ncap;
        }

        private void add_line (int start, int blen, int cp_cnt, int fit_bytes, int w_px, bool is_trunc) {
            ensure_cap ();
            starts[nlines] = start;
            lens[nlines] = blen;
            fitting[nlines] = cp_cnt;
            fitting_bytes[nlines] = fit_bytes;
            line_w[nlines] = w_px;
            trunc[nlines] = is_trunc ? 1 : 0;
            if (w_px > max_line_w)
                max_line_w = w_px;
            nlines = nlines + 1;
        }

        private void emit_paragraph (FontSlot? slot, int start, int blen, int raw_chars, int raw_px, int ellip_px) {
            if (wrap_width >= 0 && ellipsize == EllipsizeMode.END && raw_px > wrap_width) {
                int budget = wrap_width - ellip_px;
                if (budget < 0)
                    budget = 0;
                int pos = start;
                int end = start + blen;
                int acc_px = 0;
                int fit_c = 0;
                while (pos < end) {
                    int cp_start = pos;
                    int cp = FontRegistry.next_utf8 (text, ref pos);
                    int adv = FontRegistry.glyph_advance (slot, cp, desc.size);
                    if (acc_px + adv > budget) {
                        pos = cp_start;
                        break;
                    }
                    acc_px += adv;
                    fit_c++;
                }
                bool do_trunc = (ellip_px <= wrap_width);
                int total_px = do_trunc ? (acc_px + ellip_px) : acc_px;
                add_line (start, blen, fit_c, pos - start, total_px, do_trunc);
            } else {
                add_line (start, blen, raw_chars, blen, raw_px, false);
            }
        }

        private void reflow () {
            nlines = 0;
            max_line_w = 0;
            if (text.length == 0) {
                add_line (0, 0, 0, 0, 0, false);
                return;
            }

            var slot = FontRegistry.slot_for_family (desc.family);
            int ellip_px = (ellipsize == EllipsizeMode.END)
                ? FontRegistry.measure_string_px (slot, "..", 0, 2, desc.size)
                : 0;

            int line_start = 0;
            int line_px = 0;
            int cp_count = 0;
            int last_space_byte = -1;
            int last_space_end = -1;
            int last_space_px = 0;
            int last_space_chars = 0;
            int prev_cp = -1;

            int pos = 0;
            while (pos < text.length) {
                int cp_start = pos;
                int cp = FontRegistry.next_utf8 (text, ref pos);
                if (cp == '\r')
                    continue;
                if (cp == '\n') {
                    emit_paragraph (slot, line_start, cp_start - line_start, cp_count, line_px, ellip_px);
                    line_start = pos;
                    line_px = 0;
                    cp_count = 0;
                    last_space_byte = -1;
                    prev_cp = -1;
                    continue;
                }

                int adv = FontRegistry.glyph_advance (slot, cp, desc.size);

                if (wrap_width >= 0 && ellipsize == EllipsizeMode.NONE && line_px + adv > wrap_width && cp_count > 0) {
                    if (cp == ' ') {
                        add_line (line_start, cp_start - line_start, cp_count, cp_start - line_start, line_px, false);
                        while (pos < text.length && text[pos] == ' ')
                            pos++;
                        line_start = pos;
                    } else if (last_space_byte > line_start) {
                        add_line (line_start, last_space_byte - line_start, last_space_chars, last_space_byte - line_start, last_space_px, false);
                        pos = last_space_end;
                        while (pos < text.length && text[pos] == ' ')
                            pos++;
                        line_start = pos;
                    } else {
                        add_line (line_start, cp_start - line_start, cp_count, cp_start - line_start, line_px, false);
                        pos = cp_start;
                        line_start = cp_start;
                    }
                    line_px = 0;
                    cp_count = 0;
                    last_space_byte = -1;
                    prev_cp = -1;
                    continue;
                }

                if (cp == ' ' && prev_cp != ' ') {
                    last_space_byte = cp_start;
                    last_space_end = pos;
                    last_space_px = line_px;
                    last_space_chars = cp_count;
                }

                line_px += adv;
                cp_count++;
                prev_cp = cp;
            }
            emit_paragraph (slot, line_start, text.length - line_start, cp_count, line_px, ellip_px);
        }
    }
}

namespace PangoCairo {
    private void apply_color (Context cr, int col) {
        if (col >= 0) {
            cr.set_source_rgb ((double) ((col >> 16) & 0xFF) / 255.0,
                               (double) ((col >> 8) & 0xFF) / 255.0,
                               (double) (col & 0xFF) / 255.0);
        } else {
            cr.restore ();
            cr.save ();
        }
    }

    // Draws a layout with its top-left corner at (x, y).
    public void show_layout_at (Context cr, Layout layout, int x, int y) {
        cr.save ();
        int lh = layout.line_height ();
        int sp = layout.spacing_px ();
        int n = layout.line_count ();
        var desc = layout.font ();
        var slot = FontRegistry.slot_for_family (desc.family);
        bool use_ttf = (slot != null && slot.font != null);
        string body = layout.text_body ();
        bool has_attrs = layout.has_attributes ();

        if (use_ttf)
            FontRegistry.ensure_line_metrics (slot, desc.size);
        else
            cr.set_font_size ((double) (layout.scale () * 8));

        for (int i = 0; i < n; i++) {
            int lstart = layout.line_start_of (i);
            int fbytes = layout.line_bytes_of (i);
            int lw = layout.line_width_of (i);
            int lx = x + layout.alignment_offset_px (lw);
            int ly = y + i * (lh + sp);

            if (use_ttf) {
                int cx = lx;
                int pos = lstart;
                int end = lstart + fbytes;
                int last_col = -2;
                while (pos < end) {
                    int cp_byte = pos;
                    int cp = FontRegistry.next_utf8 (body, ref pos);
                    if (has_attrs) {
                        int col = layout.color_at (cp_byte);
                        if (col != last_col) {
                            apply_color (cr, col);
                            if (!use_ttf)
                                cr.set_font_size ((double) (layout.scale () * 8));
                            last_col = col;
                        }
                    }
                    cx += FontRegistry.draw_glyph (slot, cr, cp, desc.size, cx, ly);
                }
                if (layout.line_truncated (i)) {
                    if (last_col >= 0)
                        apply_color (cr, -1);
                    cx += FontRegistry.draw_glyph (slot, cr, '.', desc.size, cx, ly);
                    FontRegistry.draw_glyph (slot, cr, '.', desc.size, cx, ly);
                } else if (last_col >= 0) {
                    apply_color (cr, -1);
                }
            } else if (!has_attrs) {
                cr.move_to (lx, ly);
                cr.show_text_range (body, lstart, fbytes);
                if (layout.line_truncated (i))
                    cr.show_text ("..");
            } else {
                int cx = lx;
                int pos = lstart;
                int end = lstart + fbytes;
                int run_start = lstart;
                int run_col = (pos < end) ? layout.color_at (pos) : -1;
                int last_applied = -1;
                while (pos < end) {
                    int c = layout.color_at (pos);
                    if (c != run_col) {
                        if (run_col != last_applied) {
                            apply_color (cr, run_col);
                            cr.set_font_size ((double) (layout.scale () * 8));
                            last_applied = run_col;
                        }
                        cr.move_to (cx, ly);
                        cr.show_text_range (body, run_start, pos - run_start);
                        cx = cr.current_x ();
                        run_start = pos;
                        run_col = c;
                    }
                    pos++;
                }
                if (run_start < end) {
                    if (run_col != last_applied) {
                        apply_color (cr, run_col);
                        cr.set_font_size ((double) (layout.scale () * 8));
                        last_applied = run_col;
                    }
                    cr.move_to (cx, ly);
                    cr.show_text_range (body, run_start, end - run_start);
                    cx = cr.current_x ();
                }
                if (layout.line_truncated (i)) {
                    if (last_applied >= 0) {
                        apply_color (cr, -1);
                        cr.set_font_size ((double) (layout.scale () * 8));
                    }
                    cr.move_to (cx, ly);
                    cr.show_text ("..");
                } else if (last_applied >= 0) {
                    apply_color (cr, -1);
                    cr.set_font_size ((double) (layout.scale () * 8));
                }
            }
        }
        cr.restore ();
    }

    public void show_layout (Context cr, Layout layout) {
        show_layout_at (cr, layout, cr.current_x (), cr.current_y ());
    }
}
