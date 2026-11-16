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
