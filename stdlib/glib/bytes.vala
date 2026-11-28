// Pure-Vala GLib.Bytes immutable zero-copy byte slice for PlanetOS.
using Planet;

namespace GLib {

    /**
     * Immutable reference-counted byte array with zero-copy sub-slicing (GLib.Bytes).
     */
    public class Bytes : Object {
        private uint8[] buf;
        private size_t off = 0;
        private size_t len = 0;

        public Bytes (uint8[]? data) {
            if (data == null || data.length == 0) {
                buf = new uint8[0];
                off = 0;
                len = 0;
                return;
            }
            var copy = new uint8[data.length];
            Memory.copy (Sys.byte_arr_addr (copy), Sys.byte_arr_addr (data), (size_t) data.length);
            buf = copy;
            off = 0;
            len = (size_t) data.length;
        }

        public Bytes.take (uint8[] data) {
            buf = data;
            off = 0;
            len = (size_t) data.length;
        }

        public static Bytes from_byte_array (owned ByteArray array) {
            return new Bytes.take (array.steal ());
        }

        private Bytes.slice_raw (uint8[] backing, size_t slice_off, size_t slice_len) {
            buf = backing;
            off = slice_off;
            len = slice_len;
        }

        public Bytes new_from_bytes (size_t offset, size_t length) {
            if (offset >= len || length == 0)
                return new Bytes (null);
            size_t avail = len - offset;
            size_t n = (length > avail) ? avail : length;
            return new Bytes.slice_raw (buf, off + offset, n);
        }

        public size_t get_size () {
            return len;
        }

        public uint8 get_byte (size_t index) {
            if (index >= len)
                return 0;
            return buf[(int) (off + index)];
        }

        public uint8[] get_data () {
            if (off == 0 && len == (size_t) buf.length)
                return buf;
            return to_array ();
        }

        public uint8[] to_array () {
            var out_arr = new uint8[(int) len];
            if (len > 0)
                Memory.copy (Sys.byte_arr_addr (out_arr), Sys.byte_arr_addr (buf) + (int) off, len);
            return out_arr;
        }

        public int compare (Bytes other) {
            size_t min_len = (len < other.len) ? len : other.len;
            if (min_len > 0) {
                int c = Memory.cmp (Sys.byte_arr_addr (buf) + (int) off,
                                    Sys.byte_arr_addr (other.buf) + (int) other.off,
                                    min_len);
                if (c != 0)
                    return (c < 0) ? -1 : 1;
            }
            if (len == other.len) return 0;
            return (len < other.len) ? -1 : 1;
        }

        public bool equal (Bytes other) {
            if (len != other.len)
                return false;
            return compare (other) == 0;
        }

        public uint hash () {
            uint h = 2166136261u;
            for (size_t i = 0; i < len; i++) {
                h = h ^ (uint) buf[(int) (off + i)];
                h = h * 16777619u;
            }
            return h;
        }

        public static Bytes from_string (string? s) {
            if (s == null || ((!) s).length == 0)
                return new Bytes (null);
            return new Bytes (((!) s).data);
        }

        public char[] to_char_array () {
            var out_arr = new char[(int) len];
            for (size_t i = 0; i < len; i++)
                out_arr[(int) i] = (char) buf[(int) (off + i)];
            return out_arr;
        }

        public string to_string () {
            if (len == 0)
                return "";
            if (off == 0)
                return __planc_host_bytes_to_str (buf, (int) len);
            return __planc_host_bytes_to_str (to_array (), (int) len);
        }

        public string to_c_string () {
            size_t n = Memory.c_strlen (buf, off);
            if (n > len)
                n = len;
            if (n == 0)
                return "";
            if (off == 0)
                return __planc_host_bytes_to_str (buf, (int) n);
            var tmp = new uint8[(int) n];
            Memory.copy_bytes (tmp, 0, buf, off, n);
            return __planc_host_bytes_to_str (tmp, (int) n);
        }
    }

    /**
     * Zero-copy view over a uint8[] slice with conversions to uint8[], char[], and string.
     */
    public class ByteSlice : Object {
        public uint8[] buf;
        public size_t off;
        public size_t len;

        public ByteSlice (uint8[]? data, size_t offset = 0, size_t length = 0) {
            if (data == null || offset >= (size_t) data.length) {
                buf = new uint8[0];
                off = 0;
                len = 0;
                return;
            }
            buf = data;
            off = offset;
            size_t avail = (size_t) data.length - offset;
            len = (length == 0 || length > avail) ? avail : length;
        }

        public ByteSlice.exact (uint8[]? data, size_t offset, size_t length) {
            if (data == null || length == 0 || offset >= (size_t) data.length) {
                buf = new uint8[0];
                off = 0;
                len = 0;
                return;
            }
            buf = data;
            off = offset;
            size_t avail = (size_t) data.length - offset;
            len = (length > avail) ? avail : length;
        }

        public static ByteSlice from_string (string? s) {
            if (s == null || ((!) s).length == 0)
                return new ByteSlice (null);
            unowned uint8[] raw = ((!) s).data;
            var copy = new uint8[raw.length];
            Memory.copy_bytes (copy, 0, raw, 0, (size_t) raw.length);
            return new ByteSlice.exact (copy, 0, (size_t) raw.length);
        }

        public ByteSlice slice (size_t start, size_t end) {
            if (start >= len || end <= start)
                return new ByteSlice (null);
            size_t clamped_end = (end > len) ? len : end;
            return new ByteSlice.exact (buf, off + start, clamped_end - start);
        }

        public uint8 get (size_t index) {
            if (index >= len)
                return 0;
            return buf[(int) (off + index)];
        }

        public void set (size_t index, uint8 value) {
            if (index < len)
                buf[(int) (off + index)] = value;
        }

        public uint8[] to_uint8_array () {
            var out_arr = new uint8[(int) len];
            if (len > 0)
                Memory.copy_bytes (out_arr, 0, buf, off, len);
            return out_arr;
        }

        public char[] to_char_array () {
            var out_arr = new char[(int) len];
            for (size_t i = 0; i < len; i++)
                out_arr[(int) i] = (char) buf[(int) (off + i)];
            return out_arr;
        }

        public string to_string () {
            if (len == 0)
                return "";
            if (off == 0)
                return __planc_host_bytes_to_str (buf, (int) len);
            return __planc_host_bytes_to_str (to_uint8_array (), (int) len);
        }

        public string to_c_string () {
            size_t n = Memory.c_strlen (buf, off);
            if (n > len)
                n = len;
            if (n == 0)
                return "";
            if (off == 0)
                return __planc_host_bytes_to_str (buf, (int) n);
            var tmp = new uint8[(int) n];
            Memory.copy_bytes (tmp, 0, buf, off, n);
            return __planc_host_bytes_to_str (tmp, (int) n);
        }

        public int index_of (uint8 b) {
            for (size_t i = 0; i < len; i++) {
                if (buf[(int) (off + i)] == b)
                    return (int) i;
            }
            return -1;
        }

        public bool eq_ascii (string s) {
            if ((size_t) s.length != len)
                return false;
            if (len == 0)
                return true;
            return Memory.cmp (Sys.byte_arr_addr (buf) + (int) off, Sys.str_addr (s), len) == 0;
        }

        public size_t copy_to (uint8[] dst, size_t dst_off = 0) {
            if (dst_off >= (size_t) dst.length || len == 0)
                return 0;
            size_t avail = (size_t) dst.length - dst_off;
            size_t n = (len > avail) ? avail : len;
            Memory.copy_bytes (dst, dst_off, buf, off, n);
            return n;
        }
    }

    /**
     * Generic zero-copy array view (view<T>).
     */
    public class View<T> : Object {
        public T[] buf;
        public int off;
        public int length;

        public View (T[] data, int offset = 0, int len = -1) {
            buf = data;
            if (offset < 0) offset = 0;
            if (offset > data.length) offset = data.length;
            off = offset;
            int avail = data.length - offset;
            length = (len < 0 || len > avail) ? avail : len;
        }

        public T get_item (int index) {
            return buf[off + index];
        }

        public void set_item (int index, T value) {
            buf[off + index] = value;
        }

        public View<T> slice (int start, int end) {
            if (start < 0) start = 0;
            if (end > length) end = length;
            if (end <= start)
                return new View<T> (buf, off, 0);
            return new View<T> (buf, off + start, end - start);
        }
    }
}
