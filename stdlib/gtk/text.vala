// TrueType (libschrift) glyph cache and text helper for Gtk (Sans + Mono).
using Planet;
using Cairo;
using Schrift;

namespace Gtk {

    private class GlyphEntry : Object {
        public int key = 0; // (cp << 12) | size_px
        public SftImage? img = null;
        public int adv = 0;
        public int lsb = 0;
        public int y_off = 0;
    }

    private class FontSlot : Object {
        public SftFont? font = null;
        public GenericArray<GlyphEntry>? cache = null;
        public double cached_asc = 14.0;
        public double cached_desc = -3.0;
        public int cached_size = 0;
    }

    private FontSlot? gtk_sans_slot;
    private FontSlot? gtk_mono_slot;

    public class TextHelper : Object {
        private static FontSlot? load_slot (string path) {
            int fd = Sys.open (path);
            if (fd < 0)
                return null;
            int sz = Sys.file_size (fd);
            if (sz < 12) {
                Sys.close (fd);
                return null;
            }
            var buf = new uint8[sz];
            int got = 0;
            while (got < sz) {
                var chunk = new uint8[4096];
                int want = sz - got;
                if (want > 4096)
                    want = 4096;
                int r = Sys.read (fd, chunk, want);
                if (r <= 0)
                    break;
                for (int i = 0; i < r; i++)
                    buf[got + i] = chunk[i];
                got += r;
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

        private static GlyphEntry? get_glyph_from (FontSlot? slot, int cp, int size_px) {
            if (slot == null || slot.font == null)
                return null;
            if (slot.cache == null)
                slot.cache = new GenericArray<GlyphEntry> ();
            int key = (cp << 12) | (size_px & 0xFFF);
            for (int i = 0; i < slot.cache.length; i++) {
                if (slot.cache[i].key == key)
                    return slot.cache[i];
            }
            var sft = new Sft ();
            sft.font = slot.font;
            sft.x_scale = (double) size_px;
            sft.y_scale = (double) size_px;
            sft.flags = SFT_DOWNWARD_Y;
            if (slot.cached_size != size_px) {
                var lm = new SftLMetrics ();
                if (sft.lmetrics (lm) == 0) {
                    slot.cached_asc = lm.ascender;
                    slot.cached_desc = lm.descender;
                    slot.cached_size = size_px;
                }
            }
            int gid = 0;
            if (sft.lookup (cp, out gid) != 0)
                return null;
            var gm = new SftGMetrics ();
            if (sft.gmetrics (gid, gm) != 0)
                return null;
            var ge = new GlyphEntry ();
            ge.key = key;
            ge.adv = (int) (gm.advance_width + 0.5);
            ge.lsb = (int) gm.left_side_bearing;
            ge.y_off = gm.y_offset;
            if (gm.min_width > 0 && gm.min_height > 0) {
                var img = new SftImage (gm.min_width, gm.min_height);
                if (sft.render (gid, img) == 0)
                    ge.img = img;
            }
            if (slot.cache.length < 512)
                slot.cache.add (ge);
            return ge;
        }

        private static void measure_slot (FontSlot? slot, string text, double size_px, out int out_w, out int out_h) {
            int px = (int) size_px;
            if (slot != null && slot.font != null) {
                int cx = 0;
                for (int i = 0; i < text.length; i++) {
                    var ge = get_glyph_from (slot, (int) text[i], px);
                    cx += (ge != null) ? ge.adv : (px / 2);
                }
                out_w = cx + 2;
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
            int px = (int) size_px;
            if (slot != null && slot.font != null) {
                int cx = x;
                for (int i = 0; i < text.length; i++) {
                    var ge = get_glyph_from (slot, (int) text[i], px);
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
    }
}
