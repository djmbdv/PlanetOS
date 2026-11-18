// Pure-Vala GLib core helpers (StringBuilder, FileUtils, Environment, Str).
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
            if (extra <= 0 || used + extra <= buf.length)
                return;
            int ncap = (buf.length > 0) ? (buf.length * 2) : 64;
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

        public void append_len (string s, int len) {
            int n = (len < 0 || len > s.length) ? s.length : len;
            if (n <= 0)
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
                ensure (1);
                buf[used++] = (uint8) cp;
            } else if (cp <= 0x7FF) {
                ensure (2);
                buf[used++] = (uint8) (0xC0 | (cp >> 6));
                buf[used++] = (uint8) (0x80 | (cp & 0x3F));
            } else if (cp <= 0xFFFF) {
                ensure (3);
                buf[used++] = (uint8) (0xE0 | (cp >> 12));
                buf[used++] = (uint8) (0x80 | ((cp >> 6) & 0x3F));
                buf[used++] = (uint8) (0x80 | (cp & 0x3F));
            } else if (cp <= 0x10FFFF) {
                ensure (4);
                buf[used++] = (uint8) (0xF0 | (cp >> 18));
                buf[used++] = (uint8) (0x80 | ((cp >> 12) & 0x3F));
                buf[used++] = (uint8) (0x80 | ((cp >> 6) & 0x3F));
                buf[used++] = (uint8) (0x80 | (cp & 0x3F));
            }
        }

        public void assign (string s) {
            used = 0;
            append (s);
        }

        public void erase (int pos, int len) {
            if (pos < 0 || pos >= used || len == 0)
                return;
            if (len < 0 || pos + len >= used) {
                used = pos;
                return;
            }
            int tail = used - (pos + len);
            for (int i = 0; i < tail; i++)
                buf[pos + i] = buf[pos + len + i];
            used = used - len;
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
            if (path.length == 0)
                return false;
            if (path == "/" || path == ".")
                return mode != FileTest.IS_REGULAR;
            int kind = Sys.stat (path);
            if (mode == FileTest.EXISTS)
                return kind != 0;
            if (mode == FileTest.IS_REGULAR)
                return kind == 1;
            if (mode == FileTest.IS_DIR)
                return kind == 2;
            return false;
        }

        public static bool get_contents (string path, out string contents) {
            contents = "";
            if (path.length == 0)
                return false;
            int fd = Sys.open (path);
            if (fd < 0)
                return false;
            int sz = Sys.file_size (fd);
            if (sz < 0) {
                Sys.close (fd);
                return false;
            }
            if (sz == 0) {
                Sys.close (fd);
                return true;
            }
            var buf = new uint8[sz];
            int got = 0;
            int first = Sys.read (fd, buf, sz);
            if (first > 0)
                got = first;
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
            if (path.length == 0)
                return false;
            int fd = Sys.create (path);
            if (fd < 0)
                return false;
            int nw = 0;
            if (contents.length > 0)
                nw = Sys.write_str (fd, contents, contents.length);
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
            int n = s.length;
            if (n == 0)
                return "";
            int a = 0;
            int b = n;
            while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n'))
                a = a + 1;
            while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n'))
                b = b - 1;
            if (a == 0 && b == n)
                return s;
            return s.substring (a, b - a);
        }

        public static string replace (string s, string old_str, string new_str) {
            if (s.length == 0 || old_str.length == 0 || old_str == new_str)
                return s;
            int first = s.index_of (old_str, 0);
            if (first < 0)
                return s;
            var sb = new StringBuilder ();
            if (first > 0)
                sb.append (s.substring (0, first));
            sb.append (new_str);
            int pos = first + old_str.length;
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
            if (parts.length == 0)
                return "";
            if (parts.length == 1)
                return parts[0];
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

}
