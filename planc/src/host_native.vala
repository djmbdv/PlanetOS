// Native Linux x86_64 host adapter (used when compiling planc2 and planc3 with planc).

namespace Planc {

    public delegate void ThreadEntry (int arg);

    public class Host : Object {

        public static void eprint (string s) {
            __planc_host_eprint (s);
        }

        public static void eprintln (string s) {
            __planc_host_eprint (s + "\n");
        }

        public static void println (string s) {
            print (s + "\n");
        }

        public static void panic (string msg) {
            __planc_host_eprint ("planc: fatal: " + msg + "\n");
            exit (134);
        }

        public static string read_file (string path) throws FileError {
            return __planc_host_read_file (path);
        }

        public static uint8[] read_bytes (string path) throws FileError {
            string s = __planc_host_read_file (path);
            int n = s.length;
            var out_buf = new uint8[n];
            for (int i = 0; i < n; i++)
                out_buf[i] = (uint8) s[i];
            return out_buf;
        }

        public static void write_file (string path, uint8[] data) throws FileError {
            __planc_host_write_file (path, data);
        }

        public static void chmod_755 (string path) {
            __planc_host_chmod (path, 493);
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
            return "";
        }

        public static int cpu_count () {
            return __planc_host_cpu_count ();
        }

        public static int64 thread_spawn (ThreadEntry fn, int arg) {
            return __planc_host_thread_spawn (fn, arg);
        }

        public static void thread_join (int64 handle) {
            __planc_host_thread_join (handle);
        }

        public static void spin_lock (int[] lock_arr) {
            __planc_host_spin_lock (lock_arr);
        }

        public static void spin_unlock (int[] lock_arr) {
            __planc_host_spin_unlock (lock_arr);
        }
    }
}
