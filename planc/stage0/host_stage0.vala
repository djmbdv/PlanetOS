// Stage-0 GLib host adapter (used only when building planc1 with valac).

namespace Planc {

    public class Host : Object {

        public static void eprint (string s) {
            stderr.printf ("%s", s);
        }

        public static void eprintln (string s) {
            stderr.printf ("%s\n", s);
        }

        public static void println (string s) {
            stdout.printf ("%s\n", s);
        }

        public static void panic (string msg) {
            stderr.printf ("planc: fatal: %s\n", msg);
            Process.exit (134);
        }

        public static string read_file (string path) throws FileError {
            string contents;
            try {
                GLib.FileUtils.get_contents (path, out contents);
            } catch (GLib.FileError e) {
                throw new Planc.FileError.FAILED (e.message);
            }
            return contents;
        }

        public static void write_file (string path, uint8[] data) throws FileError {
            try {
                GLib.FileUtils.set_contents (path, (string) data, (ssize_t) data.length);
            } catch (GLib.FileError e) {
                throw new Planc.FileError.FAILED (e.message);
            }
        }

        public static void chmod_755 (string path) {
            GLib.FileUtils.chmod (path, 493);
        }

        public static string bytes_to_string (uint8[] buf, int len) {
            var tmp = new uint8[len + 1];
            for (int i = 0; i < len; i++)
                tmp[i] = buf[i];
            tmp[len] = 0;
            return ((string) tmp).dup ();
        }

        public static string hex_u8 (uint8 v) {
            return "%02x".printf (v);
        }

        public static string hex_u32 (uint32 v) {
            return "%x".printf (v);
        }

        public static string getenv (string name) {
            return GLib.Environment.get_variable (name) ?? "";
        }
    }
}
