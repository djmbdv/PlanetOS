// TrueType (libschrift) glyph cache and text helper for Gtk (Sans + Mono),
// backed by Pango.FontRegistry.
using Cairo;
using Pango;

namespace Gtk {

    public class TextHelper : Object {
        public static bool load_ttf (string path) {
            return FontRegistry.load_ttf (path);
        }

        public static bool load_mono_ttf (string path) {
            return FontRegistry.load_mono_ttf (path);
        }

        public static void measure_text (string text, double size_px, out int out_w, out int out_h) {
            FontRegistry.measure_slot (FontRegistry.slot_for_family ("sans"), text, size_px, out out_w, out out_h);
        }

        public static void draw_text (Context cr, string text, int x, int y, double size_px) {
            FontRegistry.draw_slot (FontRegistry.slot_for_family ("sans"), cr, text, x, y, size_px);
        }

        public static void measure_mono (string text, double size_px, out int out_w, out int out_h) {
            FontRegistry.measure_slot (FontRegistry.slot_for_family ("mono"), text, size_px, out out_w, out out_h);
        }

        public static void draw_mono (Context cr, string text, int x, int y, double size_px) {
            FontRegistry.draw_slot (FontRegistry.slot_for_family ("mono"), cr, text, x, y, size_px);
        }

        // Advance width of one character in the mono font. The editor needs the
        // caret column on every repaint; measuring the prefix would walk every
        // glyph of the line again.
        public static int mono_advance (double size_px) {
            return FontRegistry.mono_advance (size_px);
        }
    }
}
