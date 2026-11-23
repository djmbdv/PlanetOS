// TrueType (libschrift) glyph cache and text helper for Gtk (Sans + Mono).
using Planet;
using Cairo;
using Schrift;

namespace Gtk {

    private class GlyphEntry : Object {
        public int32 key = 0; // (cp << 12) | size_px
        public SftImage? img = null;
        public int16 adv = 0;
        public int16 lsb = 0;
        public int16 y_off = 0;
    }

    private class FontSlot : Object {
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

    private FontSlot? gtk_sans_slot;
    private FontSlot? gtk_mono_slot;

    [AsmBody(@"
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __txt_arr_addr (uint8[] a);

    public class TextHelper : Object {
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
                    GLib.Memory.copy (__txt_arr_addr (buf) + got, __txt_arr_addr (chunk), (size_t) r);
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
            gtk_sans_slot = load_slot (path);
            return gtk_sans_slot != null;
        }

        public static bool load_mono_ttf (string path) {
            gtk_mono_slot = load_slot (path);
            return gtk_mono_slot != null;
        }

        private static void ensure_line_metrics (FontSlot slot, int size_px) {
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

        private static GlyphEntry? get_glyph_from (FontSlot? slot, int cp, int size_px) {
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
                // Ring-evict oldest slot and rebuild htab on wrap so new glyphs stay fast.
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

        private static int next_utf8 (string text, ref int pos) {
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

        private static void measure_slot (FontSlot? slot, string text, double size_px, out int out_w, out int out_h) {
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
                int lh = (int) (slot.cached_asc - slot.cached_desc + 1.0);
                out_h = (lh > px) ? lh : px;
                return;
            }
            int sc = (px / 8);
            if (sc < 1) sc = 1;
            if (sc > 4) sc = 4;
            out_w = text.length * 6 * sc;
            out_h = 7 * sc;
        }

        private static void draw_slot (FontSlot? slot, Context cr, string text, int x, int y, double size_px) {
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
                int cx = x;
                int pos = 0;
                while (pos < text.length && cx < c_right) {
                    int cp = next_utf8 (text, ref pos);
                    var ge = get_glyph_from (slot, cp, px);
                    if (ge != null) {
                        if (ge.img != null) {
                            int gx = cx + ge.lsb;
                            int gy = y + (int) slot.cached_asc + ge.y_off;
                            cr.blit_alpha_mask (ge.img.pixels, ge.img.width, ge.img.height, gx, gy);
                        }
                        cx += ge.adv;
                    } else {
                        cx += px / 2;
                    }
                }
                return;
            }
            cr.set_font_size (size_px);
            cr.move_to ((double) x, (double) y);
            cr.show_text (text);
        }

        public static void measure_text (string text, double size_px, out int out_w, out int out_h) {
            measure_slot (gtk_sans_slot, text, size_px, out out_w, out out_h);
        }

        public static void draw_text (Context cr, string text, int x, int y, double size_px) {
            draw_slot (gtk_sans_slot, cr, text, x, y, size_px);
        }

        public static void measure_mono (string text, double size_px, out int out_w, out int out_h) {
            FontSlot? s = (gtk_mono_slot != null) ? gtk_mono_slot : gtk_sans_slot;
            measure_slot (s, text, size_px, out out_w, out out_h);
        }

        public static void draw_mono (Context cr, string text, int x, int y, double size_px) {
            FontSlot? s = (gtk_mono_slot != null) ? gtk_mono_slot : gtk_sans_slot;
            draw_slot (s, cr, text, x, y, size_px);
        }

        // Advance width of one character in the mono font. The editor needs the
        // caret column on every repaint; measuring the prefix would walk every
        // glyph of the line again.
        public static int mono_advance (double size_px) {
            int px = (int) size_px;
            if (px < 1) px = 1;
            FontSlot? s = (gtk_mono_slot != null) ? gtk_mono_slot : gtk_sans_slot;
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
}
