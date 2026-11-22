// Image widget with built-in vector icons and pixel-buffer support for PlanetOS Gtk.
using Cairo;

namespace Gtk {

    public class Image : Widget {
        public string icon_name = "";
        public int pixel_size = 20;
        private int[]? pixbuf = null;
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
            pixbuf = null;
        }

        public void set_pixel_size (int size) {
            pixel_size = (size < 8) ? 8 : size;
        }

        public void set_from_pixbuf (int[] pixels, int pw, int ph) {
            pixbuf = pixels;
            pb_w = pw;
            pb_h = ph;
        }

        public override void measure (out int min_w, out int min_h) {
            int w = (pixbuf != null && pb_w > 0) ? pb_w : pixel_size;
            int h = (pixbuf != null && pb_h > 0) ? pb_h : pixel_size;
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
            if (pixbuf != null && pb_w > 0 && pb_h > 0) {
                int ox = x + (width - pb_w) / 2;
                int oy = y + (height - pb_h) / 2;
                for (int py = 0; py < pb_h; py++) {
                    for (int px = 0; px < pb_w; px++) {
                        int argb = pixbuf[py * pb_w + px];
                        int a = (argb >> 24) & 0xFF;
                        if (a == 0)
                            continue;
                        double r = (double) ((argb >> 16) & 0xFF) / 255.0;
                        double g = (double) ((argb >> 8) & 0xFF) / 255.0;
                        double b = (double) (argb & 0xFF) / 255.0;
                        cr.set_source_rgba (r, g, b, (double) a / 255.0);
                        cr.rectangle ((double) (ox + px), (double) (oy + py), 1.0, 1.0);
                        cr.fill ();
                    }
                }
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
