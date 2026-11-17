// PlanetOS userland host adapter (compiled with --target=planetos using int 0x80 syscalls).

using Planet;

namespace Planc {

    public class Host : Object {

        public static void eprint (string s) {
            print (s);
        }

        public static void eprintln (string s) {
            print (s + "\n");
        }

        public static void println (string s) {
            print (s + "\n");
        }

        public static void panic (string msg) {
            print ("planc: fatal: " + msg + "\n");
            exit (134);
        }

        public static string read_file (string path) throws FileError {
            int fd = Sys.open (path);
            if (fd < 0)
                throw new FileError.FAILED (@"cannot open '$path'");
            int sz = Sys.file_size (fd);
            if (sz < 0) {
                Sys.close (fd);
                throw new FileError.FAILED (@"cannot stat '$path'");
            }
            var buf = new uint8[sz];
            int got = 0;
            while (got < sz) {
                var chunk = new uint8[sz - got];
                int r = Sys.read (fd, chunk, sz - got);
                if (r <= 0)
                    break;
                for (int i = 0; i < r; i++)
                    buf[got + i] = chunk[i];
                got = got + r;
            }
            Sys.close (fd);
            return bytes_to_string (buf, got);
        }

        public static void write_file (string path, uint8[] data) throws FileError {
            int fd = Sys.create (path);
            if (fd < 0)
                throw new FileError.FAILED (@"cannot create '$path'");
            int nw = Sys.write (fd, data, data.length);
            Sys.close (fd);
            if (nw != data.length)
                throw new FileError.FAILED (@"short write to '$path'");
        }

        public static void chmod_755 (string path) {
        }

        public static string bytes_to_string (uint8[] buf, int len) {
            return __planc_host_bytes_to_str (buf, len);
        }

        private static string hex_nibble (int d) {
            string hex = "0123456789abcdef";
            return hex.substring (d, 1);
        }

        public static string hex_u8 (uint8 v) {
            int iv = (int) v;
            int hi = (iv >> 4) & 0xf;
            int lo = iv & 0xf;
            return hex_nibble (hi) + hex_nibble (lo);
        }

        public static string hex_u32 (uint32 v) {
            int iv = (int) v;
            if (iv == 0)
                return "0";
            string out_str = "";
            for (int shift = 28; shift >= 0; shift -= 4) {
                int nib = (iv >> shift) & 0xf;
                if (nib != 0 || out_str.length > 0)
                    out_str = out_str + hex_nibble (nib);
            }
            return out_str;
        }

        public static string getenv (string name) {
            return Sys.getenv (name);
        }
    }
}
