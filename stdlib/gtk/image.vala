// Image widget with built-in vector icons and pixel-buffer support for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public enum ImageType {
        EMPTY,
        ICON_NAME,
        PIXBUF
    }

    public class Image : Widget {
        public string icon_name = "";
        public int pixel_size = 20;
        private uint8[]? rgba_buf = null;
        private int pb_w = 0;
        private int pb_h = 0;

        public Image () {}

        public Image.from_icon_name (string name, int size = 20) {
            icon_name = name;
            pixel_size = (size < 8) ? 8 : size;
        }

        public void set_from_icon_name (string name, int size = 20) {
            icon_name = name;
            pixel_size = (size < 8) ? 8 : size;
            rgba_buf = null;
            pb_w = 0;
            pb_h = 0;
            damage_self ();
        }

        public string get_icon_name () {
            return icon_name;
        }

        public void set_pixel_size (int size) {
            int ns = (size < 8) ? 8 : size;
            if (ns != pixel_size) {
                pixel_size = ns;
                damage_self ();
            }
        }

        public int get_pixel_size () {
            return pixel_size;
        }

        public ImageType get_storage_type () {
            if (rgba_buf != null && pb_w > 0 && pb_h > 0)
                return ImageType.PIXBUF;
            if (icon_name.length > 0)
                return ImageType.ICON_NAME;
            return ImageType.EMPTY;
        }

        public void clear () {
            icon_name = "";
            rgba_buf = null;
            pb_w = 0;
            pb_h = 0;
            damage_self ();
        }

        public void set_from_pixbuf (int[] pixels, int pw, int ph) {
            if (pw <= 0 || ph <= 0 || pw > 4096 || ph > 4096)
                return;
            int64 count = (int64) pw * (int64) ph;
            if (count > (int64) pixels.length)
                return;
            int n = (int) count;
            var buf = new uint8[n * 4];
            for (int i = 0; i < n; i++) {
                int argb = pixels[i];
                int off = i * 4;
                buf[off + 0] = (uint8) ((argb >> 16) & 0xFF);
                buf[off + 1] = (uint8) ((argb >> 8) & 0xFF);
                buf[off + 2] = (uint8) (argb & 0xFF);
                buf[off + 3] = (uint8) ((argb >> 24) & 0xFF);
            }
            rgba_buf = buf;
            pb_w = pw;
            pb_h = ph;
            icon_name = "";
            damage_self ();
        }

        public override void measure (out int min_w, out int min_h) {
            int w = (rgba_buf != null && pb_w > 0) ? pb_w : pixel_size;
            int h = (rgba_buf != null && pb_h > 0) ? pb_h : pixel_size;
            min_w = (req_w > w) ? req_w : w;
            min_h = (req_h > h) ? req_h : h;
        }

        public static void draw_builtin_icon (Context cr, string name, int ix, int iy, int sz) {
            if (sz < 8) sz = 8;
            double x = (double) ix;
            double y = (double) iy;
            double s = (double) sz;
            if (name == "folder" || name == "inode-directory") {
                // Amber Warning (#F59E0B)
                cr.set_source_rgb (0.840, 0.540, 0.035);
                cr.rectangle (x, y + s * 0.15, s * 0.45, s * 0.2);
                cr.fill ();
                cr.set_source_rgb (0.961, 0.620, 0.043);
                cr.rectangle (x, y + s * 0.28, s, s * 0.62);
                cr.fill ();
                return;
            }
            if (name == "application-x-executable") {
                // Celestial Cerulean (#3897F0) & Lunar White (#F0F4F8)
                cr.set_source_rgb (0.220, 0.592, 0.941);
                cr.rectangle (x + s * 0.12, y + s * 0.12, s * 0.76, s * 0.76);
                cr.fill ();
                cr.set_source_rgb (0.941, 0.957, 0.973);
                cr.rectangle (x + s * 0.34, y + s * 0.34, s * 0.32, s * 0.32);
                cr.fill ();
                return;
            }
            // Default document/file icon: Titanium Mist (#8B9BB0) & Slate Atmosphere (#182028)
            cr.set_source_rgb (0.545, 0.608, 0.690);
            cr.rectangle (x + s * 0.18, y + s * 0.08, s * 0.64, s * 0.84);
            cr.fill ();
            cr.set_source_rgb (0.094, 0.125, 0.157);
            cr.rectangle (x + s * 0.28, y + s * 0.32, s * 0.44, 1.5);
            cr.fill ();
            cr.rectangle (x + s * 0.28, y + s * 0.52, s * 0.44, 1.5);
            cr.fill ();
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            if (rgba_buf != null && pb_w > 0 && pb_h > 0) {
                int ox = x + (width - pb_w) / 2;
                int oy = y + (height - pb_h) / 2;
                cr.save ();
                cr.rectangle ((double) x, (double) y, (double) width, (double) height);
                cr.clip ();
                cr.draw_rgba (rgba_buf, pb_w, pb_h, ox, oy);
                cr.restore ();
                return;
            }
            if (icon_name.length > 0) {
                int sz = (width < height) ? width : height;
                if (sz > pixel_size) sz = pixel_size;
                int ix = x + (width - sz) / 2;
                int iy = y + (height - sz) / 2;
                draw_builtin_icon (cr, icon_name, ix, iy, sz);
            }
        }
    }
}
