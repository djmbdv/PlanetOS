// GLib host adapter for c2vala.
//
// The translator is written in the planc dialect, which is a subset of Vala, so
// the same sources build twice:
//
//   * with planc for the guest (planc/src/host_native.vala + buffer.vala, raw
//     syscalls, ELF) -- tools/c2vala/build.sh
//   * with valac for the host (this file, GLib, .exe on Windows) --
//     tools/c2vala/build_host.sh
//
// Only the host primitives are reimplemented; everything above them (preproc,
// lexer, parser, translator) is the same code. `FileError` here is
// GLib.FileError, which is why the host build does not link buffer.vala: with
// both in scope the name would be ambiguous at every `catch (FileError e)`.

namespace Planc {

    public delegate void ThreadEntry (int arg);

    public class StrBuilder : Object {

        private StringBuilder sb;

        public StrBuilder (string init = "") {
            sb = new StringBuilder ();
            if (init != "")
                sb.append (init);
        }

        public int length {
            get { return (int) sb.len; }
        }

        public void truncate (int new_len) {
            if (new_len >= 0 && new_len <= (int) sb.len)
                sb.truncate ((size_t) new_len);
        }

        public void append (string s) {
            sb.append (s);
        }

        public void append_c (char c) {
            sb.append_c (c);
        }

        public string str {
            owned get { return sb.str; }
        }
    }

    public class Host : Object {

        public static void eprint (string s) {
            stderr.printf ("%s", s);
        }

        public static void eprintln (string s) {
            stderr.printf ("%s\n", s);
            stderr.flush ();
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
            FileUtils.get_contents (path, out contents);
            return contents;
        }

        public static void write_file (string path, uint8[] data) throws FileError {
            FileUtils.set_contents (path, bytes_to_string (data, data.length));
        }

        public static void chmod_755 (string path) {
            // the host file systems this build targets have no executable bit
        }

        public static string bytes_to_string (uint8[] buf, int len) {
            var sb = new StringBuilder.sized (len);
            for (int i = 0; i < len; i++)
                sb.append_c ((char) buf[i]);
            return sb.str;
        }

        private static string hex_nibble (int d) {
            string hex = "0123456789abcdef";
            if (d < 0 || d > 15)
                return "?";
            return hex.substring (d, 1);
        }

        public static string hex_u8 (uint8 v) {
            int iv = (int) v;
            return hex_nibble ((iv >> 4) & 0xf) + hex_nibble (iv & 0xf);
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

        private static GLib.Mutex g_thr_lock;
        private static GenericArray<GLib.Thread<void*>> g_threads = new GenericArray<GLib.Thread<void*>> ();

        public static string getenv (string name) {
            string? v = Environment.get_variable (name);
            if (v == null)
                return "";
            return v;
        }

        public static int cpu_count () {
            int n = (int) GLib.get_num_processors ();
            return n > 0 ? n : 1;
        }

        public static int64 thread_spawn (ThreadEntry fn, int arg) {
            var thr = new GLib.Thread<void*> ("c2v-worker", () => {
                fn (arg);
                return null;
            });
            g_thr_lock.lock ();
            if (g_threads == null)
                g_threads = new GenericArray<GLib.Thread<void*>> ();
            int64 id = g_threads.length + 1;
            g_threads.add (thr);
            g_thr_lock.unlock ();
            return id;
        }

        public static void thread_join (int64 handle) {
            if (handle <= 0)
                return;
            g_thr_lock.lock ();
            var thr = g_threads[(int) (handle - 1)];
            g_thr_lock.unlock ();
            thr.join ();
        }

        public static void spin_lock (int[] lock_arr) {
            while (!GLib.AtomicInt.compare_and_exchange (ref lock_arr[0], 0, 1)) {
                GLib.Thread.yield ();
            }
        }

        public static void spin_unlock (int[] lock_arr) {
            GLib.AtomicInt.set (ref lock_arr[0], 0);
        }
    }
}
