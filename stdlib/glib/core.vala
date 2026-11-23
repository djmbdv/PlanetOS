// Pure-Vala GLib core helpers (StringBuilder, FileUtils, Environment, Str).
using Planet;

namespace GLib {

    // GLib-style log levels; the kernel ring (Klog, category CAT_USER) keeps
    // what userland emits so a failure can be inspected after the fact.
    public enum LogLevelFlags {
        ERROR = 4,
        CRITICAL = 8,
        WARNING = 16,
        MESSAGE = 32,
        INFO = 64,
        DEBUG = 128
    }

    private const int KLOG_CAT_USER = 7;

    private static int klog_level_of (LogLevelFlags level) {
        if (level == LogLevelFlags.ERROR || level == LogLevelFlags.CRITICAL)
            return 0;
        if (level == LogLevelFlags.WARNING)
            return 1;
        if (level == LogLevelFlags.DEBUG)
            return 3;
        return 2;
    }

    // Mirrors the Linux/GLib default: only warnings and worse reach the console.
    public bool log_would_print (LogLevelFlags level) {
        return level == LogLevelFlags.ERROR || level == LogLevelFlags.CRITICAL
            || level == LogLevelFlags.WARNING;
    }

    public void log_message (string? domain, LogLevelFlags level, string msg) {
        string line = (domain != null && domain.length > 0) ? @"$(domain): $(msg)" : msg;
        Sys.klog_write (KLOG_CAT_USER, klog_level_of (level), line);
        if (log_would_print (level))
            printerr (line + "\n");
    }

    // GLib.g_log_set_level (): forwards the filter to the kernel ring.
    public void log_set_level (int level) {
        Sys.klog_set_level (level);
    }

    public void log_info (string? domain, string msg) {
        log_message (domain, LogLevelFlags.INFO, msg);
    }

    public void log_warning (string? domain, string msg) {
        log_message (domain, LogLevelFlags.WARNING, msg);
    }

    public void log_critical (string? domain, string msg) {
        log_message (domain, LogLevelFlags.CRITICAL, msg);
    }

    public void log_error (string? domain, string msg) {
        log_message (domain, LogLevelFlags.ERROR, msg);
    }

    public void log_debug (string? domain, string msg) {
        log_message (domain, LogLevelFlags.DEBUG, msg);
    }

    // stderr goes to both the console and the kernel ring (GLib.g_printerr).
    public void printerr (string s) {
        print (s);
        int n = s.length;
        while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r'))
            n--;
        if (n > 0)
            Sys.klog_write (KLOG_CAT_USER, 0, s.substring (0, n));
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
            if (used > 0)
                Memory.copy (Sys.byte_arr_addr (nbuf), Sys.byte_arr_addr (buf), (size_t) used);
            buf = nbuf;
        }

        public void append (string s) {
            int n = s.length;
            if (n == 0)
                return;
            ensure (n);
            Memory.copy (Sys.byte_arr_addr (buf) + used, Sys.str_addr (s), (size_t) n);
            used = used + n;
        }

        public void append_len (string s, int len) {
            int n = (len < 0 || len > s.length) ? s.length : len;
            if (n <= 0)
                return;
            ensure (n);
            Memory.copy (Sys.byte_arr_addr (buf) + used, Sys.str_addr (s), (size_t) n);
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

        // Returns the current value and starts a new empty buffer. Unlike
        // reading `str` in a loop, this makes the ownership transfer explicit.
        public string steal () {
            string value = str;
            used = 0;
            return value;
        }

        public string free_to_string () {
            return steal ();
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

    /**
     * Arena/interning storage for groups of strings (GLib.StringChunk).
     */
    public class StringChunk : Object {
        private string[] items;
        private int count = 0;
        private int[] buckets;
        private int bcap = 0;
        private size_t chunk_size;

        public StringChunk (size_t size = 4096) {
            chunk_size = (size == 0) ? 4096 : size;
            items = new string[16];
            bcap = 32;
            buckets = new int[32];
        }

        private static uint32 hash_str (string s) {
            uint32 h = 2166136261U;
            for (int i = 0; i < s.length; i++) {
                h = (h ^ (uint32) s[i]) * 16777619U;
            }
            return h;
        }

        private void rehash (int new_cap) {
            int[] nb = new int[new_cap];
            int mask = new_cap - 1;
            for (int i = 0; i < count; i++) {
                int slot = (int) (hash_str (items[i]) & (uint32) mask);
                while (nb[slot] != 0)
                    slot = (slot + 1) & mask;
                nb[slot] = i + 1;
            }
            buckets = nb;
            bcap = new_cap;
        }

        private unowned string store_new (string s) {
            if (count >= items.length) {
                var ni = new string[items.length * 2];
                for (int i = 0; i < count; i++)
                    ni[i] = items[i];
                items = ni;
            }
            int idx = count;
            items[count++] = s;
            if (count * 10 >= bcap * 7)
                rehash (bcap * 2);
            int mask = bcap - 1;
            int slot = (int) (hash_str (s) & (uint32) mask);
            while (buckets[slot] != 0)
                slot = (slot + 1) & mask;
            buckets[slot] = idx + 1;
            return items[idx];
        }

        public unowned string insert (string str) {
            return insert_len (str, (ssize_t) str.length);
        }

        public unowned string insert_len (string str, ssize_t len) {
            int n = (len < 0 || len > (ssize_t) str.length) ? str.length : (int) len;
            if (n <= 0)
                return store_new ("");
            var copy = new uint8[n];
            Memory.copy (Sys.byte_arr_addr (copy), (int) (uintptr.from_pointer ((void*) str) + (uintptr) 16), (size_t) n);
            return store_new ((string) copy);
        }

        public unowned string insert_const (string str) {
            int mask = bcap - 1;
            int slot = (int) (hash_str (str) & (uint32) mask);
            while (buckets[slot] != 0) {
                int idx = buckets[slot] - 1;
                if (items[idx] == str)
                    return items[idx];
                slot = (slot + 1) & mask;
            }
            return insert (str);
        }

        public void clear () {
            items = new string[16];
            count = 0;
            bcap = 32;
            buckets = new int[32];
        }

        public void free () {
            clear ();
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

        public static bool query_exists (string path) {
            return Sys.stat (path) != 0;
        }

        public static bool is_dir (string path) {
            return Sys.stat (path) == 2;
        }

        public static int64 query_size (string path) {
            int sz = 0;
            if (Sys.stat_ex (path, out sz) == 0)
                return -1;
            return (int64) sz;
        }

        public static int remove (string filename) {
            int r = Sys.unlink (filename);
            return (r < 0) ? -Sys.errno_code () : r;
        }

        public static int rename (string oldfilename, string newfilename) {
            int r = Sys.rename (oldfilename, newfilename);
            return (r < 0) ? -Sys.errno_code () : r;
        }

        public static int mkdir (string filename, int mode = 493) {
            int r = Sys.mkdir (filename);
            return (r < 0) ? -Sys.errno_code () : r;
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

        public static int strv_length (string[] strv) {
            return strv.length;
        }

        // Strings are reference-counted in this runtime, so freeing a vector is
        // a no-op for the elements; the array itself is collected. The method
        // exists so ported GLib code keeps its explicit ownership shape.
        public static void strfreev (string[]? strv) {
        }

        public static GenericArray<string> strsplit_set (string s, string delimiters) {
            var res = new GenericArray<string> ();
            var token = new StringBuilder ();
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                bool split = false;
                for (int j = 0; j < delimiters.length; j++) {
                    if (delimiters[j] == c) {
                        split = true;
                        break;
                    }
                }
                if (split) {
                    if (token.len > 0)
                        res.add (token.steal ());
                } else {
                    token.append_c (c);
                }
            }
            if (token.len > 0)
                res.add (token.steal ());
            return res;
        }

        private const string HEX = "0123456789abcdef";

        public static string strescape (string s, string exceptions) {
            var sb = new StringBuilder ();
            for (int i = 0; i < s.length; i++) {
                uint8 c = s[i];
                bool keep = (c >= 'a' && c <= 'z')
                         || (c >= 'A' && c <= 'Z')
                         || (c >= '0' && c <= '9');
                for (int j = 0; j < exceptions.length; j++) {
                    if ((uint8) exceptions[j] == c) {
                        keep = true;
                        break;
                    }
                }
                if (keep) {
                    sb.append_c ((char) c);
                } else {
                    sb.append_c ('\\');
                    sb.append_c ('x');
                    sb.append_c (HEX[c >> 4]);
                    sb.append_c (HEX[c & 0x0F]);
                }
            }
            return sb.steal ();
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
                if (used > 0)
                    Memory.copy (Sys.byte_arr_addr (res), Sys.byte_arr_addr (buf), (size_t) used);
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

        public ByteArray.take (owned uint8[]? data) {
            if (data == null) {
                buf = new uint8[64];
                used = 0;
                return;
            }
            buf = data;
            used = data.length;
        }

        private void ensure (int extra) {
            if (extra <= 0 || used + extra < 0 || used + extra <= buf.length)
                return;
            int ncap = (buf.length > 0) ? (buf.length * 2) : 64;
            while (ncap > 0 && ncap < used + extra)
                ncap = ncap * 2;
            if (ncap <= 0)
                ncap = used + extra;
            var nbuf = new uint8[ncap];
            if (used > 0)
                Memory.copy (Sys.byte_arr_addr (nbuf), Sys.byte_arr_addr (buf), (size_t) used);
            buf = nbuf;
        }

        public void append (uint8[] bytes) {
            if (bytes.length == 0)
                return;
            ensure (bytes.length);
            Memory.copy (Sys.byte_arr_addr (buf) + used, Sys.byte_arr_addr (bytes), (size_t) bytes.length);
            used = used + bytes.length;
        }

        public void append_byte (uint8 b) {
            ensure (1);
            buf[used] = b;
            used = used + 1;
        }

        public uint8 get_byte (int index) {
            if (index < 0 || index >= used)
                return 0;
            return buf[index];
        }

        public int copy_to (int offset, uint8[] dst, int dst_offset, int count) {
            if (offset < 0 || offset >= used || dst_offset < 0 || dst_offset >= dst.length || count <= 0)
                return 0;
            int avail = used - offset;
            int dst_avail = dst.length - dst_offset;
            int n = (count < avail) ? count : avail;
            if (dst_avail < n)
                n = dst_avail;
            if (n > 0)
                Memory.copy (Sys.byte_arr_addr (dst) + dst_offset, Sys.byte_arr_addr (buf) + offset, (size_t) n);
            return n;
        }

        public void write_at (int pos, uint8[] bytes) {
            if (pos < 0 || bytes.length == 0 || pos > 2147483647 - bytes.length)
                return;
            int end_pos = pos + bytes.length;
            if (end_pos > buf.length)
                ensure (end_pos - used);
            if (pos > used)
                Memory.set (Sys.byte_arr_addr (buf) + used, 0, (size_t) (pos - used));
            Memory.copy (Sys.byte_arr_addr (buf) + pos, Sys.byte_arr_addr (bytes), (size_t) bytes.length);
            if (end_pos > used)
                used = end_pos;
        }

        public string to_string () {
            if (used == 0)
                return "";
            return __planc_host_bytes_to_str (buf, used);
        }

        public void prepend (uint8[] bytes) {
            if (bytes.length == 0)
                return;
            ensure (bytes.length);
            int ba = Sys.byte_arr_addr (buf);
            if (used > 0)
                Memory.move (ba + bytes.length, ba, (size_t) used);
            Memory.copy (ba, Sys.byte_arr_addr (bytes), (size_t) bytes.length);
            used = used + bytes.length;
        }

        public void remove_index (int index) {
            if (index < 0 || index >= used)
                return;
            int rem = used - 1 - index;
            if (rem > 0) {
                int ba = Sys.byte_arr_addr (buf);
                Memory.move (ba + index, ba + index + 1, (size_t) rem);
            }
            used = used - 1;
        }

        public void remove_range (int index, int length) {
            if (index < 0 || index >= used || length <= 0)
                return;
            int n = (index + length > used) ? (used - index) : length;
            int rem = used - n - index;
            if (rem > 0) {
                int ba = Sys.byte_arr_addr (buf);
                Memory.move (ba + index, ba + index + n, (size_t) rem);
            }
            used = used - n;
        }

        public void set_size (int length) {
            if (length < 0)
                length = 0;
            if (length > buf.length)
                ensure (length - used);
            if (length > used)
                Memory.set (Sys.byte_arr_addr (buf) + used, 0, (size_t) (length - used));
            used = length;
        }

        public void remove_index_fast (int index) {
            if (index < 0 || index >= used)
                return;
            if (index < used - 1)
                buf[index] = buf[used - 1];
            used = used - 1;
        }

        public uint8[] steal () {
            uint8[] res;
            if (used == buf.length) {
                res = buf;
            } else {
                res = data;
            }
            buf = new uint8[64];
            used = 0;
            return res;
        }
    }

    public class DirUtils : Object {
        public static int create (string pathname, int mode) {
            if (pathname.length == 0)
                return -1;
            return Sys.mkdir (pathname);
        }

        public static int create_with_parents (string pathname, int mode) {
            if (pathname.length == 0)
                return -1;
            if (FileUtils.test (pathname, FileTest.IS_DIR))
                return 0;
            int n = pathname.length;
            for (int i = 1; i < n; i++) {
                if (pathname[i] == '/') {
                    string sub = pathname.substring (0, i);
                    if (!FileUtils.test (sub, FileTest.IS_DIR)) {
                        if (Sys.mkdir (sub) != 0 && !FileUtils.test (sub, FileTest.IS_DIR))
                            return -1;
                    }
                }
            }
            return Sys.mkdir (pathname);
        }

        public static int remove (string filename) {
            if (filename.length == 0)
                return -1;
            return Sys.unlink (filename);
        }
    }

    public class Dir : Object {
        private string _path;
        private uint8[] _buf;
        private int _len = 0;
        private int _pos = 0;
        private bool _loaded = false;

        public Dir (string path) {
            _path = path;
        }

        public static Dir? open (string path, uint flags = 0) {
            if (path.length == 0 || !FileUtils.test (path, FileTest.IS_DIR))
                return null;
            return new Dir (path);
        }

        // SYS_READDIR returns the names NUL- or newline-separated; read them
        // once and hand them out through read_name ().
        private void load () {
            if (_loaded)
                return;
            _loaded = true;
            _buf = new uint8[3584];
            _len = Sys.readdir_path (_path, _buf, 3584);
            if (_len < 0)
                _len = 0;
        }

        public string? read_name () {
            load ();
            while (_pos < _len) {
                int start = _pos;
                while (_pos < _len && _buf[_pos] != 0 && _buf[_pos] != '\n')
                    _pos++;
                int end = _pos;
                if (_pos < _len)
                    _pos++;
                if (end > start) {
                    var sb = new StringBuilder ();
                    for (int i = start; i < end; i++)
                        sb.append_c ((char) _buf[i]);
                    return sb.str;
                }
            }
            return null;
        }

        public void rewind () {
            _pos = 0;
        }

        public void close () {
            _pos = _len;
        }
    }

    public class Rand : Object {
        private uint64 _state;

        public Rand () {
            uint64 t = (uint64) Sys.ticks ();
            _state = (t != 0) ? (t * 0x9E3779B97F4A7C15UL) : 0x853C49E6748FEA9BUL;
        }

        public Rand.with_seed (uint32 seed) {
            set_seed (seed);
        }

        public void set_seed (uint32 seed) {
            uint64 s = (uint64) seed;
            _state = (s != 0) ? s : 0x853C49E6748FEA9BUL;
        }

        public uint32 next_int () {
            uint64 x = _state;
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            _state = x;
            uint64 r = x * 0x2545F4914F6CDD1DUL;
            return (uint32) (r >> 32);
        }

        public int32 int_range (int32 begin, int32 end) {
            if (end <= begin)
                return begin;
            uint32 span = (uint32) (end - begin);
            return begin + (int32) (next_int () % span);
        }

        public double next_double () {
            uint32 v = next_int ();
            return ((double) v) / 4294967296.0;
        }

        public double double_range (double begin, double end) {
            if (end <= begin)
                return begin;
            return begin + next_double () * (end - begin);
        }

        public bool boolean () {
            return (next_int () & 1U) != 0;
        }
    }

    /**
     * Builds a null-terminated, freshly owned string vector (GLib.StrvBuilder).
     * `end()` transfers the vector and leaves the builder empty.
     */
    public class StrvBuilder : Object {
        private GenericArray<string> items = new GenericArray<string> ();

        public void add (string value) {
            items.add (value);
        }

        public void addv (string[] values) {
            for (int i = 0; i < values.length; i++)
                items.add (values[i]);
        }

        public int length () {
            return items.length;
        }

        public string[] end () {
            var res = new string[items.length];
            for (int i = 0; i < items.length; i++)
                res[i] = items[i];
            items = new GenericArray<string> ();
            return res;
        }

        public string[] steal () {
            return end ();
        }

        public void unref () {
            items = new GenericArray<string> ();
        }
    }

    /**
     * Incremental path builder (GLib.PathBuf). Joins with '/', avoids duplicate
     * separators and supports removing the last element or changing the suffix.
     */
    public class PathBuf : Object {
        private StringBuilder path = new StringBuilder ();

        public PathBuf () {}

        public PathBuf.from_path (string value) {
            path.assign (value);
        }

        public void init_from_path (string value) {
            path.assign (value);
        }

        public void clear () {
            path.assign ("");
        }

        public int size () {
            return path.len;
        }

        public void push (string element) {
            if (element.length == 0)
                return;
            if (element[0] == '/') {
                path.assign (element);
                return;
            }
            string current = path.str;
            if (current == ".") {
                path.assign (element);
                return;
            }
            if (current == "/") {
                path.assign ("/" + element);
                return;
            }
            if (current.length > 0 && current[current.length - 1] != '/')
                path.append_c ('/');
            path.append (element);
        }

        public void pop () {
            string p = path.str;
            int n = p.length;
            if (n == 0)
                return;
            int end = n;
            while (end > 0 && p[end - 1] == '/')
                end--;
            while (end > 0 && p[end - 1] != '/')
                end--;
            if (end > 0)
                end--;
            if (end <= 0) {
                if (n > 0 && p[0] == '/')
                    path.assign ("/");
                else
                    path.assign ("");
                return;
            }
            path.assign (p.substring (0, end));
        }

        public void set_extension (string? extension) {
            string p = path.str;
            int slash = -1;
            for (int i = 0; i < p.length; i++) {
                if (p[i] == '/')
                    slash = i;
            }
            int dot = -1;
            for (int i = slash + 1; i < p.length; i++) {
                if (p[i] == '.')
                    dot = i;
            }
            if (dot >= 0)
                p = p.substring (0, dot);
            if (extension != null && extension.length > 0)
                p = p + "." + extension;
            path.assign (p);
        }

        public string to_path () {
            return path.str;
        }

        public string to_string () {
            return path.str;
        }
    }

    public enum ByteOrder {
        LITTLE_ENDIAN,
        BIG_ENDIAN,
        PDP_ENDIAN
    }

    public static uint16 swap16 (uint16 v) {
        return (uint16) ((v >> 8) | (v << 8));
    }

    public static uint32 swap32 (uint32 v) {
        return ((v & 0x000000FFU) << 24)
             | ((v & 0x0000FF00U) << 8)
             | ((v & 0x00FF0000U) >> 8)
             | ((v & 0xFF000000U) >> 24);
    }

    public static uint64 swap64 (uint64 v) {
        return ((uint64) swap32 ((uint32) (v & 0xFFFFFFFFUL)) << 32)
             | (uint64) swap32 ((uint32) (v >> 32));
    }

    // PlanetOS and the supported hosts are little-endian. These wrappers keep
    // protocol code independent of the host byte order.
    public static uint16 from_le16 (uint16 v) { return v; }
    public static uint32 from_le32 (uint32 v) { return v; }
    public static uint64 from_le64 (uint64 v) { return v; }
    public static uint16 to_le16 (uint16 v) { return v; }
    public static uint32 to_le32 (uint32 v) { return v; }
    public static uint64 to_le64 (uint64 v) { return v; }
    public static uint16 from_be16 (uint16 v) { return swap16 (v); }
    public static uint32 from_be32 (uint32 v) { return swap32 (v); }
    public static uint64 from_be64 (uint64 v) { return swap64 (v); }
    public static uint16 to_be16 (uint16 v) { return swap16 (v); }
    public static uint32 to_be32 (uint32 v) { return swap32 (v); }
    public static uint64 to_be64 (uint64 v) { return swap64 (v); }

    /**
     * Allocator with an explicit power-of-two alignment (GLib.Aligned).
     * `Memory.malloc` returns a 16-byte aligned pointer; SIMD and DMA users can
     * request 32/64 bytes here.
     */
    public class Aligned : Object {
        public static int alloc (size_t n_bytes, size_t alignment) {
            if (n_bytes == 0)
                return 0;
            size_t align = (alignment < 16) ? 16 : alignment;
            if ((align & (align - 1)) != 0)
                return 0;
            uint64 total = (uint64) n_bytes + (uint64) align + 16;
            if (total > 0x7FFFFFFFUL)
                return 0;
            int raw = Memory.malloc ((size_t) total);
            if (raw == 0)
                return 0;
            int mask = (int) align - 1;
            int aligned = (raw + 16 + mask) & ~mask;
            Memory.poke64 (aligned - 8, raw);
            return aligned;
        }

        public static int alloc0 (size_t n_bytes, size_t alignment) {
            int p = alloc (n_bytes, alignment);
            if (p != 0)
                Memory.set (p, 0, n_bytes);
            return p;
        }

        public static void free (int mem) {
            if (mem <= 0x100000)
                return;
            int raw = Memory.peek64 (mem - 8);
            if (raw == 0)
                return;
            Memory.free (raw);
        }
    }

    public enum FormatSizeFlags {
        DEFAULT = 0,
        LONG_FORMAT = 1,
        IEC_UNITS = 2,
        BITS = 4
    }

    public string format_size (uint64 size, FormatSizeFlags flags = FormatSizeFlags.DEFAULT) {
        uint64 value = size;
        if ((flags & FormatSizeFlags.BITS) != 0)
            value = value * 8;
        uint64 radix = ((flags & FormatSizeFlags.IEC_UNITS) != 0) ? 1024 : 1000;
        string[] units = ((flags & FormatSizeFlags.IEC_UNITS) != 0)
            ? new string[] { "B", "KiB", "MiB", "GiB", "TiB" }
            : new string[] { "B", "kB", "MB", "GB", "TB" };
        int unit = 0;
        uint64 limit = radix;
        while (unit + 1 < units.length && value >= limit) {
            unit++;
            limit = limit * radix;
        }
        if (unit == 0)
            return @"$value $(units[unit])";
        double scaled = (double) value / (double) (limit / radix);
        return @"$scaled $(units[unit])";
    }

    // --- main loop ---------------------------------------------------------
    // One MainContext with idle and timeout sources, driven by SYS_TICKS
    // (100 Hz) and SYS_YIELD. Single-threaded: sources run in the loop thread.

}
