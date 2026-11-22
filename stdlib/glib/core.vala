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
                if (used == 0)
                    return "";
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

        public StringBuilder.sized (int size) {
            int cap = (size > 64) ? size : 64;
            buf = new uint8[cap];
            used = 0;
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

        public void prepend (string val) {
            insert (0, val);
        }

        public void prepend_c (char c) {
            ensure (1);
            for (int i = used; i > 0; i--)
                buf[i] = buf[i - 1];
            buf[0] = (uint8) c;
            used = used + 1;
        }

        public void insert (int pos, string val) {
            int n = val.length;
            if (n == 0)
                return;
            if (pos < 0 || pos >= used) {
                append (val);
                return;
            }
            ensure (n);
            for (int i = used - 1; i >= pos; i--)
                buf[i + n] = buf[i];
            for (int i = 0; i < n; i++)
                buf[pos + i] = val[i];
            used = used + n;
        }

        public void overwrite (int pos, string val) {
            if (pos < 0)
                pos = 0;
            int n = val.length;
            if (pos + n > used) {
                ensure ((pos + n) - used);
                for (int i = used; i < pos; i++)
                    buf[i] = (uint8) ' ';
                used = pos + n;
            }
            for (int i = 0; i < n; i++)
                buf[pos + i] = val[i];
        }

        public void ascii_down () {
            for (int i = 0; i < used; i++) {
                if (buf[i] >= 'A' && buf[i] <= 'Z')
                    buf[i] = buf[i] + 32;
            }
        }

        public void ascii_up () {
            for (int i = 0; i < used; i++) {
                if (buf[i] >= 'a' && buf[i] <= 'z')
                    buf[i] = buf[i] - 32;
            }
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
            if (sz < 0 || sz > 4194304) {
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
            if (got < sz) {
                var chunk = new uint8[4096];
                while (got < sz) {
                    int want = sz - got;
                    if (want > 4096)
                        want = 4096;
                    int r = Sys.read (fd, chunk, want);
                    if (r <= 0)
                        break;
                    for (int i = 0; i < r; i++)
                        buf[got + i] = chunk[i];
                    got = got + r;
                }
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
            int off = 0;
            int total = contents.length;
            while (off < total) {
                int chunk = total - off;
                if (chunk > 32768)
                    chunk = 32768;
                string part = (off == 0 && chunk == total) ? contents : contents.substring (off, chunk);
                int nw = Sys.write_str (fd, part, chunk);
                if (nw <= 0)
                    break;
                off = off + nw;
            }
            Sys.close (fd);
            return off == total;
        }

        public static int remove (string filename) {
            return Sys.unlink (filename);
        }

        public static int rename (string oldfilename, string newfilename) {
            return Sys.rename (oldfilename, newfilename);
        }

        public static int mkdir (string filename, int mode = 493) {
            return Sys.mkdir (filename);
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
        public static string? get_variable (string variable) {
            string v = Sys.getenv (variable);
            if (v.length == 0)
                return null;
            return v;
        }
        public static bool set_variable (string variable, string value, bool overwrite) {
            if (!overwrite && Sys.getenv (variable).length > 0)
                return true;
            return Sys.setenv (variable, value) == 0;
        }
        public static void unset_variable (string variable) {
            Sys.unsetenv (variable);
        }
        public static string get_home_dir () {
            return "/";
        }
        public static string get_tmp_dir () {
            return "/tmp";
        }
        public static string get_user_name () {
            return "planet";
        }
        public static string get_host_name () {
            return "planetos";
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

        public static GenericArray<string> split (string s, string sep) {
            var res = new GenericArray<string> ();
            if (sep.length == 0) {
                res.add (s);
                return res;
            }
            int pos = 0;
            while (pos <= s.length) {
                int idx = s.index_of (sep, pos);
                if (idx < 0) {
                    res.add (s.substring (pos));
                    break;
                }
                res.add (s.substring (pos, idx - pos));
                pos = idx + sep.length;
            }
            return res;
        }

        public static string chug (string s) {
            int n = s.length;
            int a = 0;
            while (a < n && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n'))
                a++;
            return (a == 0) ? s : s.substring (a);
        }

        public static string chomp (string s) {
            int b = s.length;
            while (b > 0 && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n'))
                b--;
            return (b == s.length) ? s : s.substring (0, b);
        }

        public static string reverse (string s) {
            int n = s.length;
            if (n <= 1)
                return s;
            var buf = new uint8[n];
            for (int i = 0; i < n; i++)
                buf[i] = s[n - 1 - i];
            return __planc_host_bytes_to_str (buf, n);
        }

        public static string ascii_down (string s) {
            int n = s.length;
            if (n == 0)
                return s;
            var buf = new uint8[n];
            for (int i = 0; i < n; i++) {
                uint8 c = s[i];
                buf[i] = (c >= 'A' && c <= 'Z') ? (c + 32) : c;
            }
            return __planc_host_bytes_to_str (buf, n);
        }

        public static string ascii_up (string s) {
            int n = s.length;
            if (n == 0)
                return s;
            var buf = new uint8[n];
            for (int i = 0; i < n; i++) {
                uint8 c = s[i];
                buf[i] = (c >= 'a' && c <= 'z') ? (c - 32) : c;
            }
            return __planc_host_bytes_to_str (buf, n);
        }

        public static bool has_prefix (string str, string prefix) {
            return str.has_prefix (prefix);
        }

        public static bool has_suffix (string str, string suffix) {
            return str.has_suffix (suffix);
        }
    }

    public class PathUtils : Object {
        public const char DIR_SEPARATOR = '/';
        public const string DIR_SEPARATOR_S = "/";
        public const string SEARCHPATH_SEPARATOR_S = ":";

        public static bool is_absolute (string file_name) {
            return file_name.length > 0 && file_name[0] == '/';
        }

        public static string skip_root (string file_name) {
            if (!is_absolute (file_name))
                return file_name;
            int i = 0;
            while (i < file_name.length && file_name[i] == '/')
                i++;
            return file_name.substring (i);
        }

        public static string get_basename (string file_name) {
            if (file_name.length == 0)
                return ".";
            if (file_name == "/")
                return "/";
            int len = file_name.length;
            while (len > 1 && file_name[len - 1] == '/')
                len--;
            int slash = file_name.substring (0, len).last_index_of_char ('/');
            if (slash < 0)
                return file_name.substring (0, len);
            if (slash == len - 1)
                return "/";
            return file_name.substring (slash + 1, len - slash - 1);
        }

        public static string get_dirname (string file_name) {
            if (file_name.length == 0)
                return ".";
            int len = file_name.length;
            while (len > 1 && file_name[len - 1] == '/')
                len--;
            int slash = file_name.substring (0, len).last_index_of_char ('/');
            if (slash < 0)
                return ".";
            if (slash == 0)
                return "/";
            return file_name.substring (0, slash);
        }

        public static string build_filename (string first_element, string? second = null, string? third = null, string? fourth = null) {
            var parts = new GenericArray<string> ();
            parts.add (first_element);
            if (second != null) parts.add ((!) second);
            if (third != null) parts.add ((!) third);
            if (fourth != null) parts.add ((!) fourth);
            var sb = new StringBuilder ();
            for (int i = 0; i < parts.length; i++) {
                string p = parts[i];
                if (p.length == 0)
                    continue;
                if (sb.len == 0) {
                    sb.append (p);
                } else {
                    int cur_len = sb.len;
                    bool has_sep = (cur_len > 0 && sb.byte_at (cur_len - 1) == '/');
                    if (has_sep && p[0] == '/')
                        sb.append (p.substring (1));
                    else if (!has_sep && p[0] != '/') {
                        sb.append_c ('/');
                        sb.append (p);
                    } else {
                        sb.append (p);
                    }
                }
            }
            return sb.str;
        }
    }

    public class Timer : Object {
        private int start_ticks = 0;
        private int stop_ticks = 0;
        private bool active = false;

        public Timer () {
            start ();
        }

        public void start () {
            start_ticks = Sys.ticks ();
            stop_ticks = start_ticks;
            active = true;
        }

        public void stop () {
            if (active) {
                stop_ticks = Sys.ticks ();
                active = false;
            }
        }

        public void @continue () {
            if (!active) {
                int now = Sys.ticks ();
                int prev = stop_ticks - start_ticks;
                start_ticks = now - prev;
                active = true;
            }
        }

        public void reset () {
            start_ticks = Sys.ticks ();
            stop_ticks = start_ticks;
        }

        public double elapsed () {
            int end_t = active ? Sys.ticks () : stop_ticks;
            uint32 diff = (uint32) end_t - (uint32) start_ticks;
            return ((double) diff) / 100.0;
        }
    }

    public class ByteArray : Object {
        private uint8[] buf;
        private int used = 0;

        public int len {
            get { return used; }
        }

        public uint8[] data {
            get {
                var res = new uint8[used];
                for (int i = 0; i < used; i++)
                    res[i] = buf[i];
                return res;
            }
        }

        public ByteArray () {
            buf = new uint8[64];
        }

        public ByteArray.sized (int reserved_size) {
            int cap = (reserved_size > 64) ? reserved_size : 64;
            buf = new uint8[cap];
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

        public void append (uint8[] bytes) {
            if (bytes.length == 0)
                return;
            ensure (bytes.length);
            for (int i = 0; i < bytes.length; i++)
                buf[used + i] = bytes[i];
            used = used + bytes.length;
        }

        public void prepend (uint8[] bytes) {
            if (bytes.length == 0)
                return;
            ensure (bytes.length);
            for (int i = used - 1; i >= 0; i--)
                buf[i + bytes.length] = buf[i];
            for (int i = 0; i < bytes.length; i++)
                buf[i] = bytes[i];
            used = used + bytes.length;
        }

        public void remove_index (int index) {
            if (index < 0 || index >= used)
                return;
            for (int i = index; i < used - 1; i++)
                buf[i] = buf[i + 1];
            used = used - 1;
        }

        public void remove_range (int index, int length) {
            if (index < 0 || index >= used || length <= 0)
                return;
            int n = (index + length > used) ? (used - index) : length;
            for (int i = index; i < used - n; i++)
                buf[i] = buf[i + n];
            used = used - n;
        }

        public void set_size (int length) {
            if (length < 0)
                length = 0;
            if (length > buf.length)
                ensure (length - used);
            for (int i = used; i < length; i++)
                buf[i] = 0;
            used = length;
        }

        public uint8[] steal () {
            var res = data;
            used = 0;
            return res;
        }
    }

    // --- main loop ---------------------------------------------------------
    // One MainContext with idle and timeout sources, driven by SYS_TICKS
    // (100 Hz) and SYS_YIELD. Single-threaded: sources run in the loop thread.

}
