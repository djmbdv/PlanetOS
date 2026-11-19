// Pure-Vala Gdk.RGBA color type and Cairo source helper for PlanetOS.

namespace Gdk {
    using Cairo;

    /**
     * RGBA color with channel values in [0.0, 1.0].
     */
    public class RGBA : Object {
        public double red = 1.0;
        public double green = 1.0;
        public double blue = 1.0;
        public double alpha = 1.0;

        private static double clamp01 (double v) {
            if (v < 0.0) return 0.0;
            if (v > 1.0) return 1.0;
            return v;
        }

        private static int hex_val (uint8 c) {
            if (c >= '0' && c <= '9') return (int) (c - '0');
            if (c >= 'a' && c <= 'f') return 10 + (int) (c - 'a');
            if (c >= 'A' && c <= 'F') return 10 + (int) (c - 'A');
            return -1;
        }

        private static int hex_byte (uint8 hi, uint8 lo) {
            int h = hex_val (hi);
            int l = hex_val (lo);
            if (h < 0 || l < 0)
                return -1;
            return h * 16 + l;
        }

        public RGBA () {
        }

        public RGBA.from_rgba (double r, double g, double b, double a = 1.0) {
            red = clamp01 (r);
            green = clamp01 (g);
            blue = clamp01 (b);
            alpha = clamp01 (a);
        }

        /**
         * Parses #RGB, #RRGGBB, or #RRGGBBAA hex color specifications.
         * Leaves existing channels untouched if parsing fails.
         */
        public bool parse (string spec) {
            if (spec.length < 4 || spec[0] != '#')
                return false;

            if (spec.length == 4) {
                int r = hex_val ((uint8) spec[1]);
                int g = hex_val ((uint8) spec[2]);
                int b = hex_val ((uint8) spec[3]);
                if (r < 0 || g < 0 || b < 0)
                    return false;
                red = (double) (r * 17) / 255.0;
                green = (double) (g * 17) / 255.0;
                blue = (double) (b * 17) / 255.0;
                alpha = 1.0;
                return true;
            }

            if (spec.length == 7 || spec.length == 9) {
                int r = hex_byte ((uint8) spec[1], (uint8) spec[2]);
                int g = hex_byte ((uint8) spec[3], (uint8) spec[4]);
                int b = hex_byte ((uint8) spec[5], (uint8) spec[6]);
                if (r < 0 || g < 0 || b < 0)
                    return false;
                int a = 255;
                if (spec.length == 9) {
                    a = hex_byte ((uint8) spec[7], (uint8) spec[8]);
                    if (a < 0)
                        return false;
                }
                red = (double) r / 255.0;
                green = (double) g / 255.0;
                blue = (double) b / 255.0;
                alpha = (double) a / 255.0;
                return true;
            }

            return false;
        }

        public RGBA copy () {
            return new RGBA.from_rgba (red, green, blue, alpha);
        }

        public bool equal (RGBA? other) {
            if (other == null)
                return false;
            return red == other.red && green == other.green &&
                   blue == other.blue && alpha == other.alpha;
        }

        public uint32 to_argb32 () {
            uint32 a = (uint32) (clamp01 (alpha) * 255.0 + 0.5);
            uint32 r = (uint32) (clamp01 (red) * 255.0 + 0.5);
            uint32 g = (uint32) (clamp01 (green) * 255.0 + 0.5);
            uint32 b = (uint32) (clamp01 (blue) * 255.0 + 0.5);
            return (a << 24) | (r << 16) | (g << 8) | b;
        }

        public void from_argb32 (uint32 px) {
            alpha = (double) ((px >> 24) & 0xFF) / 255.0;
            red = (double) ((px >> 16) & 0xFF) / 255.0;
            green = (double) ((px >> 8) & 0xFF) / 255.0;
            blue = (double) (px & 0xFF) / 255.0;
        }
    }

    public void cairo_set_source_rgba (Context? cr, RGBA? c) {
        if (cr == null || c == null)
            return;
        cr.set_source_rgba (c.red, c.green, c.blue, c.alpha);
    }
}
