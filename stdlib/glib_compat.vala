// Pure-Vala GLib & Gee compatibility layer for PlanetOS (zero C, zero .vapi).

using Planet;

namespace GLib {

    public void printerr (string s) {
        print (s);
    }

    public enum FileTest {
        EXISTS,
        IS_REGULAR,
        IS_DIR
    }

    public class StringBuilder : Object {
        private uint8[] buf;
        private int used = 0;

        public string str {
            get {
                return __planc_host_bytes_to_str (buf, used);
            }
        }

        public int len {
            get { return used; }
        }

        public StringBuilder (string init = "") {
            int cap = (init.length > 64) ? (init.length * 2) : 64;
            buf = new uint8[cap];
            used = 0;
            if (init.length > 0)
                append (init);
        }

        private void ensure (int extra) {
            if (used + extra <= buf.length)
                return;
            int ncap = buf.length * 2;
            while (ncap < used + extra)
                ncap = ncap * 2;
            var nbuf = new uint8[ncap];
            for (int i = 0; i < used; i++)
                nbuf[i] = buf[i];
            buf = nbuf;
        }

        public void append (string s) {
            int n = s.length;
            if (n == 0)
                return;
            ensure (n);
            for (int i = 0; i < n; i++)
                buf[used + i] = s[i];
            used = used + n;
        }

        public void append_c (char c) {
            ensure (1);
            buf[used] = (uint8) c;
            used = used + 1;
        }

        public void append_unichar (unichar cp) {
            if (cp <= 0x7F) {
                append_c ((char) (uint8) cp);
            } else if (cp <= 0x7FF) {
                append_c ((char) (uint8) (0xC0 | (cp >> 6)));
                append_c ((char) (uint8) (0x80 | (cp & 0x3F)));
            } else if (cp <= 0xFFFF) {
                append_c ((char) (uint8) (0xE0 | (cp >> 12)));
                append_c ((char) (uint8) (0x80 | ((cp >> 6) & 0x3F)));
                append_c ((char) (uint8) (0x80 | (cp & 0x3F)));
            } else if (cp <= 0x10FFFF) {
                append_c ((char) (uint8) (0xF0 | (cp >> 18)));
                append_c ((char) (uint8) (0x80 | ((cp >> 12) & 0x3F)));
                append_c ((char) (uint8) (0x80 | ((cp >> 6) & 0x3F)));
                append_c ((char) (uint8) (0x80 | (cp & 0x3F)));
            }
        }

        public int byte_at (int index) {
            if (index < 0 || index >= used)
                return -1;
            return (int) buf[index];
        }

        public void remove_last (int count) {
            if (count <= 0)
                return;
            if (count > used)
                count = used;
            used = used - count;
        }

        public void truncate (int new_len = 0) {
            if (new_len < 0)
                new_len = 0;
            if (new_len < used)
                used = new_len;
        }
    }

    public class FileUtils : Object {
        public static bool test (string path, FileTest mode) {
            if (mode == FileTest.IS_DIR)
                return false;
            int fd = Sys.open (path);
            if (fd < 0)
                return false;
            Sys.close (fd);
            return true;
        }

        public static bool get_contents (string path, out string contents) {
            contents = "";
            int fd = Sys.open (path);
            if (fd < 0)
                return false;
            int sz = Sys.file_size (fd);
            if (sz < 0) {
                Sys.close (fd);
                return false;
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
            contents = __planc_host_bytes_to_str (buf, got);
            return true;
        }

        public static bool set_contents (string path, string contents) {
            int fd = Sys.create (path);
            if (fd < 0)
                return false;
            int nw = Sys.write_str (fd, contents, contents.length);
            Sys.close (fd);
            return nw == contents.length;
        }
    }

    private string __env_prgname = "planetos";

    public class Environment : Object {
        public static string get_prgname () {
            return __env_prgname;
        }
        public static void set_prgname (string name) {
            __env_prgname = name;
        }
    }

    public class Str : Object {
        public static string strip (string s) {
            int a = 0;
            int b = s.length;
            while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n'))
                a = a + 1;
            while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n'))
                b = b - 1;
            return s.substring (a, b - a);
        }

        public static string replace (string s, string old_str, string new_str) {
            if (old_str.length == 0)
                return s;
            var sb = new StringBuilder ();
            int pos = 0;
            while (pos < s.length) {
                int idx = s.index_of (old_str, pos);
                if (idx < 0) {
                    sb.append (s.substring (pos));
                    break;
                }
                if (idx > pos)
                    sb.append (s.substring (pos, idx - pos));
                sb.append (new_str);
                pos = idx + old_str.length;
            }
            return sb.str;
        }

        public static string joinv (string sep, GenericArray<string> parts) {
            var sb = new StringBuilder ();
            for (int i = 0; i < parts.length; i++) {
                if (i > 0)
                    sb.append (sep);
                sb.append (parts[i]);
            }
            return sb.str;
        }
    }

    // --- main loop ---------------------------------------------------------
    // One MainContext with idle and timeout sources, driven by SYS_TICKS
    // (100 Hz) and SYS_YIELD. Single-threaded: sources run in the loop thread.

    public delegate bool SourceFunc ();

    private class Source : Object {
        public uint32 id;
        public int kind;      // 0 = idle, 1 = timeout
        public uint32 interval; // ms
        public int due;       // ms
        public bool removed;
        public SourceFunc func;

        public Source (uint32 id, int kind, uint32 interval, int due, SourceFunc func) {
            this.id = id;
            this.kind = kind;
            this.interval = interval;
            this.due = due;
            this.func = func;
        }
    }

    private MainContext? default_main_context;

    public class MainContext : Object {
        private GenericArray<Source> sources;
        private uint32 next_id = 0;

        public MainContext () {
            sources = new GenericArray<Source> ();
        }

        public static MainContext default_ () {
            var ctx = default_main_context;
            if (ctx == null) {
                var created = new MainContext ();
                default_main_context = created;
                return created;
            } else {
                return ctx;
            }
        }

        public bool has_sources () {
            for (int i = 0; i < sources.length; i++) {
                if (!sources[i].removed)
                    return true;
            }
            return false;
        }

        public bool pending () {
            int now = Sys.ticks () * 10;
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed)
                    continue;
                if (s.kind == 0 || now >= s.due)
                    return true;
            }
            return false;
        }

        // Runs one ready source: idle sources first, then due timeouts.
        // Returns false when nothing was ready; may_block yields the CPU once.
        public bool iteration (bool may_block) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed || s.kind != 0)
                    continue;
                if (!s.func ())
                    s.removed = true;
                return true;
            }
            int now = Sys.ticks () * 10;
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed || s.kind != 1 || now < s.due)
                    continue;
                s.due = now + (int) s.interval;
                if (!s.func ())
                    s.removed = true;
                return true;
            }
            if (may_block)
                Sys.yield_cpu ();
            return false;
        }

        public uint32 add_idle (SourceFunc func) {
            next_id = next_id + 1;
            sources.add (new Source (next_id, 0, 0, 0, func));
            return next_id;
        }

        public uint32 add_timeout (uint32 interval_ms, SourceFunc func) {
            next_id = next_id + 1;
            uint32 interval = (interval_ms == 0) ? 1 : interval_ms;
            sources.add (new Source (next_id, 1, interval, Sys.ticks () * 10 + (int) interval, func));
            return next_id;
        }

        public bool remove (uint32 id) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.id == id && !s.removed) {
                    s.removed = true;
                    return true;
                }
            }
            return false;
        }

        public bool exists (uint32 id) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.id == id && !s.removed)
                    return true;
            }
            return false;
        }
    }

    public uint32 idle_add (SourceFunc func) {
        return MainContext.default_ ().add_idle (func);
    }

    public uint32 timeout_add (uint32 interval_ms, SourceFunc func) {
        return MainContext.default_ ().add_timeout (interval_ms, func);
    }

    public bool source_remove (uint32 id) {
        return MainContext.default_ ().remove (id);
    }

    public bool source_exists (uint32 id) {
        return MainContext.default_ ().exists (id);
    }

    public class MainLoop : Object {
        private MainContext context;
        private bool running = false;

        public MainLoop (MainContext? ctx = null) {
            context = (ctx != null) ? ctx : MainContext.default_ ();
        }

        public MainContext get_context () {
            return context;
        }

        public bool is_running () {
            return running;
        }

        public void quit () {
            running = false;
        }

        // Runs until quit() is called. If every source removes itself the loop
        // also stops instead of blocking forever.
        public void run () {
            if (running)
                return;
            running = true;
            while (running) {
                bool did = context.iteration (false);
                if (!did) {
                    if (!context.has_sources ())
                        break;
                    Sys.yield_cpu ();
                }
            }
            running = false;
        }
    }
}

namespace Gee {
    public class ArrayList<T> : Object {
        private GenericArray<T> inner;

        public int size {
            get { return inner.length; }
        }

        public ArrayList () {
            inner = new GenericArray<T> ();
        }

        public void add (T item) {
            inner.add (item);
        }

        public T get (int index) {
            return inner[index];
        }

        public void set (int index, T item) {
            inner[index] = item;
        }

        public void clear () {
            inner = new GenericArray<T> ();
        }
    }
}
