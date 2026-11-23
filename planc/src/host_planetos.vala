// PlanetOS userland host adapter (compiled with --target=planetos using int 0x80 syscalls).

using Planet;

namespace Planc {

    public delegate void ThreadEntry (int arg);

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

        // Sys.read rejects a single transfer over Sys.MAX_IO (64 KiB), and the
        // old one-shot read turned that -1 into an empty source for any file
        // bigger than that, so read in chunks and fail loudly on a short read.
        private static uint8[] read_all (string path) throws FileError {
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
                int want = sz - got;
                if (want > Sys.MAX_IO)
                    want = Sys.MAX_IO;
                var chunk = new uint8[want];
                int r = Sys.read (fd, chunk, want);
                if (r <= 0)
                    break;
                for (int i = 0; i < r; i++)
                    buf[got + i] = chunk[i];
                got = got + r;
            }
            Sys.close (fd);
            if (got != sz)
                throw new FileError.FAILED (@"short read on '$path' ($got of $sz bytes)");
            return buf;
        }

        public static uint8[] read_bytes (string path) throws FileError {
            return read_all (path);
        }

        public static string read_file (string path) throws FileError {
            var buf = read_all (path);
            return bytes_to_string (buf, buf.length);
        }

        public static void write_file (string path, uint8[] data) throws FileError {
            int fd = Sys.create (path);
            if (fd < 0)
                throw new FileError.FAILED (@"cannot create '$path'");
            // Sys.write rejects a single transfer over Sys.MAX_IO (64 KiB).
            int done = 0;
            while (done < data.length) {
                int want = data.length - done;
                if (want > Sys.MAX_IO)
                    want = Sys.MAX_IO;
                var chunk = new uint8[want];
                for (int i = 0; i < want; i++)
                    chunk[i] = data[done + i];
                int nw = Sys.write (fd, chunk, want);
                if (nw <= 0) {
                    Sys.close (fd);
                    throw new FileError.FAILED (@"short write to '$path'");
                }
                done = done + nw;
            }
            Sys.close (fd);
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

        public static int cpu_count () {
            return 1;
        }

        public static int64 thread_spawn (ThreadEntry fn, int arg) {
            fn (arg);
            return 0;
        }

        public static void thread_join (int64 handle) {
        }

        public static void spin_lock (int[] lock_arr) {
        }

        public static void spin_unlock (int[] lock_arr) {
        }
    }
}
