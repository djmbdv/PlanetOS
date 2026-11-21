// Pure-Vala Gdk.Display window factory for PlanetOS.

using Planet;

namespace Gdk {
    /**
     * Display connection opening either a compositor surface or the kernel framebuffer.
     */
    public class Display : Object {
        private const int MIN_WIN_DIM = 64;
        private const int MAX_WIN_DIM = 8192;

        private static int parse_pos_int (string s, int fallback) {
            if (s.length == 0)
                return fallback;
            int v = 0;
            for (int i = 0; i < s.length; i++) {
                uint8 c = (uint8) s[i];
                if (c < '0' || c > '9')
                    return fallback;
                v = v * 10 + (int) (c - '0');
                if (v > MAX_WIN_DIM)
                    return fallback;
            }
            return (v >= MIN_WIN_DIM) ? v : fallback;
        }

        // Addresses are far above MAX_WIN_DIM, so they need their own parser.
        private static int parse_addr (string s) {
            if (s.length == 0)
                return 0;
            int v = 0;
            for (int i = 0; i < s.length; i++) {
                uint8 c = (uint8) s[i];
                if (c < '0' || c > '9')
                    return 0;
                v = v * 10 + (int) (c - '0');
                if (v <= 0)
                    return 0;
            }
            return v;
        }

        // Attaches a compositor block the caller already owns. Used by the
        // compositor self-test, which has to drive both sides of the protocol.
        public static Window? attach_shared (int w, int h, int shm_base, string ev_path = "") {
            var win = new Window.compositor_shared (w, h, shm_base, ev_path);
            if (!win.is_valid ()) {
                win.close ();
                return null;
            }
            return win;
        }

        public static Window? open_window (int w = 800, int h = 600) {
            if (w <= 0 || h <= 0 || w > MAX_WIN_DIM || h > MAX_WIN_DIM)
                return null;
            string shm = Sys.getenv ("PLANET_WIN_SHM");
            if (shm.length > 0) {
                int shm_base = parse_addr (shm);
                int cw = parse_pos_int (Sys.getenv ("PLANET_WIN_W"), w);
                int ch = parse_pos_int (Sys.getenv ("PLANET_WIN_H"), h);
                string ev_path = Sys.getenv ("PLANET_WIN_EV");
                if (shm_base > 0) {
                    var swin = new Window.compositor_shared (cw, ch, shm_base, ev_path);
                    if (swin.is_valid ())
                        return swin;
                    swin.close ();
                }
            }
            string comp_path = Sys.getenv ("PLANET_WIN_FILE");
            if (comp_path.length > 0) {
                int cw = parse_pos_int (Sys.getenv ("PLANET_WIN_W"), w);
                int ch = parse_pos_int (Sys.getenv ("PLANET_WIN_H"), h);
                string ev_path = Sys.getenv ("PLANET_WIN_EV");
                var cwin = new Window.compositor_surface (cw, ch, comp_path, ev_path);
                if (!cwin.is_valid ()) {
                    cwin.close ();
                    return null;
                }
                return cwin;
            }
            int fb = Sys.sys (21, w, h, 0);
            if (fb == 0)
                return null;
            var win = new Window (w, h);
            if (!win.is_valid ()) {
                win.close ();
                return null;
            }
            return win;
        }
    }
}
