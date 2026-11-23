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
    }
}
