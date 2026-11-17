// TrueType (libschrift) glyph cache and text helper for Gtk.
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

    private SftFont? gtk_ttf_font;
    private GenericArray<GlyphEntry>? gtk_glyph_cache;
    private double gtk_cached_asc = 14.0;
    private double gtk_cached_desc = -3.0;
    private int gtk_cached_size = 0;

    public class TextHelper : Object {
        public static bool load_ttf (string path) {
            int fd = Sys.open (path);
            if (fd < 0)
                return false;
            int sz = Sys.file_size (fd);
            if (sz < 12) {
                Sys.close (fd);
                return false;
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
                return false;
            gtk_ttf_font = SftFont.load_mem (buf, sz);
            gtk_glyph_cache = new GenericArray<GlyphEntry> ();
            gtk_cached_size = 0;
            return gtk_ttf_font != null;
        }

        private static GlyphEntry? get_glyph (int cp, int size_px) {
            if (gtk_ttf_font == null)
                return null;
            if (gtk_glyph_cache == null)
                gtk_glyph_cache = new GenericArray<GlyphEntry> ();
            int key = (cp << 12) | (size_px & 0xFFF);
            for (int i = 0; i < gtk_glyph_cache.length; i++) {
                if (gtk_glyph_cache[i].key == key)
                    return gtk_glyph_cache[i];
            }
            var sft = new Sft ();
            sft.font = gtk_ttf_font;
            sft.x_scale = (double) size_px;
            sft.y_scale = (double) size_px;
            sft.flags = SFT_DOWNWARD_Y;
            if (gtk_cached_size != size_px) {
                var lm = new SftLMetrics ();
                if (sft.lmetrics (lm) == 0) {
                    gtk_cached_asc = lm.ascender;
                    gtk_cached_desc = lm.descender;
                    gtk_cached_size = size_px;
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
            if (gtk_glyph_cache.length < 512)
                gtk_glyph_cache.add (ge);
            return ge;
        }

        public static void measure_text (string text, double size_px, out int out_w, out int out_h) {
            int px = (int) size_px;
            if (gtk_ttf_font != null) {
                int cx = 0;
                for (int i = 0; i < text.length; i++) {
                    var ge = get_glyph ((int) text[i], px);
                    cx += (ge != null) ? ge.adv : (px / 2);
                }
                out_w = cx + 2;
                int lh = (int) (gtk_cached_asc - gtk_cached_desc + 1.0);
                out_h = (lh > px) ? lh : px;
                return;
            }
            int sc = (px / 8);
            if (sc < 1) sc = 1;
            if (sc > 4) sc = 4;
            out_w = text.length * 6 * sc;
            out_h = 7 * sc;
        }

        public static void draw_text (Context cr, string text, int x, int y, double size_px) {
            int px = (int) size_px;
            if (gtk_ttf_font != null) {
                int cx = x;
                for (int i = 0; i < text.length; i++) {
                    var ge = get_glyph ((int) text[i], px);
                    if (ge != null) {
                        if (ge.img != null) {
                            int gx = cx + ge.lsb;
                            int gy = y + (int) gtk_cached_asc + ge.y_off;
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
    }
}
