// Stage-0 GLib host adapter (used only when building planc1 with valac).

namespace Planc {

    public delegate void ThreadEntry (int arg);

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

        public static uint8[] read_bytes (string path) throws FileError {
            uint8[] data;
            try {
                GLib.FileUtils.get_data (path, out data);
            } catch (GLib.FileError e) {
                throw new Planc.FileError.FAILED (e.message);
            }
            return data;
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

        private static GLib.Mutex g_thr_lock;
        private static GenericArray<GLib.Thread<void*>> g_threads = new GenericArray<GLib.Thread<void*>> ();

        public static string getenv (string name) {
            return GLib.Environment.get_variable (name) ?? "";
        }

        public static int cpu_count () {
            int n = (int) GLib.get_num_processors ();
            return n > 0 ? n : 1;
        }

        public static int64 thread_spawn (ThreadEntry fn, int arg) {
            var thr = new GLib.Thread<void*> ("planc-worker", () => {
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
