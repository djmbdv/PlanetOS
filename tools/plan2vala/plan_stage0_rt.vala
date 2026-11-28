// Stage 0 Vala runtime shim for code translated by plan2vala.
// Provides PlanetOS stdlib extensions (array slicing, ByteSlice, PlanMem)
// on top of standard GLib so `valac` can compile `.plan` code on the host.

public int[] _plan_slice_int (int[] arr, int start, int end) {
    if (start < 0) start = 0;
    if (end > arr.length) end = arr.length;
    if (end <= start) return new int[0];
    int n = end - start;
    int[] res = new int[n];
    for (int i = 0; i < n; i++) res[i] = arr[start + i];
    return res;
}

public uint8[] _plan_slice_uint8 (uint8[] arr, int start, int end) {
    if (start < 0) start = 0;
    if (end > arr.length) end = arr.length;
    if (end <= start) return new uint8[0];
    int n = end - start;
    uint8[] res = new uint8[n];
    for (int i = 0; i < n; i++) res[i] = arr[start + i];
    return res;
}

public uint32[] _plan_slice_uint32 (uint32[] arr, int start, int end) {
    if (start < 0) start = 0;
    if (end > arr.length) end = arr.length;
    if (end <= start) return new uint32[0];
    int n = end - start;
    uint32[] res = new uint32[n];
    for (int i = 0; i < n; i++) res[i] = arr[start + i];
    return res;
}

public int64[] _plan_slice_int64 (int64[] arr, int start, int end) {
    if (start < 0) start = 0;
    if (end > arr.length) end = arr.length;
    if (end <= start) return new int64[0];
    int n = end - start;
    int64[] res = new int64[n];
    for (int i = 0; i < n; i++) res[i] = arr[start + i];
    return res;
}

public char[] _plan_slice_char (char[] arr, int start, int end) {
    if (start < 0) start = 0;
    if (end > arr.length) end = arr.length;
    if (end <= start) return new char[0];
    int n = end - start;
    char[] res = new char[n];
    for (int i = 0; i < n; i++) res[i] = arr[start + i];
    return res;
}

public string[] _plan_slice_string (string[] arr, int start, int end) {
    if (start < 0) start = 0;
    if (end > arr.length) end = arr.length;
    if (end <= start) return new string[0];
    int n = end - start;
    string[] res = new string[n];
    for (int i = 0; i < n; i++) res[i] = arr[start + i];
    return res;
}

public T[] _plan_arr_slice<T> (T[] arr, int start, int end) {
    if (start < 0) start = 0;
    if (end > arr.length) end = arr.length;
    if (end <= start) return new T[0];
    int n = end - start;
    T[] res = new T[n];
    for (int i = 0; i < n; i++)
        res[i] = arr[start + i];
    return res;
}

public string _plan_bytes_to_str (uint8[] buf, int len) {
    if (len <= 0 || buf.length == 0)
        return "";
    int n = (len > buf.length) ? buf.length : len;
    var sb = new GLib.StringBuilder ();
    for (int i = 0; i < n; i++)
        sb.append_c ((char) buf[i]);
    return sb.str;
}

public class PlanMem : GLib.Object {
    private static size_t clamp_span (int arr_len, size_t off, size_t n) {
        if (off >= (size_t) arr_len || n == 0)
            return 0;
        size_t avail = (size_t) arr_len - off;
        return (n > avail) ? avail : n;
    }

    public static void set_bytes (uint8[]? dst, size_t off, uint8 val, size_t n) {
        if (dst == null) return;
        size_t count = clamp_span (((!) dst).length, off, n);
        for (size_t i = 0; i < count; i++)
            ((!) dst)[(int) (off + i)] = val;
    }

    public static void copy_bytes (uint8[]? dst, size_t dst_off, uint8[]? src, size_t src_off, size_t n) {
        if (dst == null || src == null || n == 0) return;
        size_t da = clamp_span (((!) dst).length, dst_off, n);
        size_t sa = clamp_span (((!) src).length, src_off, n);
        size_t count = (da < sa) ? da : sa;
        for (size_t i = 0; i < count; i++)
            ((!) dst)[(int) (dst_off + i)] = ((!) src)[(int) (src_off + i)];
    }

    public static void move_bytes (uint8[]? dst, size_t dst_off, uint8[]? src, size_t src_off, size_t n) {
        if (dst == null || src == null || n == 0) return;
        size_t da = clamp_span (((!) dst).length, dst_off, n);
        size_t sa = clamp_span (((!) src).length, src_off, n);
        size_t count = (da < sa) ? da : sa;
        var tmp = new uint8[(int) count];
        for (size_t i = 0; i < count; i++)
            tmp[(int) i] = ((!) src)[(int) (src_off + i)];
        for (size_t i = 0; i < count; i++)
            ((!) dst)[(int) (dst_off + i)] = tmp[(int) i];
    }

    public static int cmp_bytes (uint8[]? a, size_t a_off, uint8[]? b, size_t b_off, size_t n) {
        if (n == 0) return 0;
        size_t aa = (a == null) ? 0 : clamp_span (((!) a).length, a_off, n);
        size_t ba = (b == null) ? 0 : clamp_span (((!) b).length, b_off, n);
        size_t count = (aa < ba) ? aa : ba;
        for (size_t i = 0; i < count; i++) {
            uint8 ca = ((!) a)[(int) (a_off + i)];
            uint8 cb = ((!) b)[(int) (b_off + i)];
            if (ca != cb) return (ca < cb) ? -1 : 1;
        }
        if (aa == ba) return 0;
        return (aa < ba) ? -1 : 1;
    }

    public static size_t c_strlen (uint8[]? buf, size_t off = 0) {
        if (buf == null || off >= (size_t) ((!) buf).length) return 0;
        size_t i = off;
        while (i < (size_t) ((!) buf).length && ((!) buf)[(int) i] != 0) i++;
        return i - off;
    }

    public static int c_strcmp (uint8[]? a, size_t a_off, uint8[]? b, size_t b_off) {
        size_t la = c_strlen (a, a_off);
        size_t lb = c_strlen (b, b_off);
        size_t min_l = (la < lb) ? la : lb;
        for (size_t i = 0; i < min_l; i++) {
            uint8 ca = ((!) a)[(int) (a_off + i)];
            uint8 cb = ((!) b)[(int) (b_off + i)];
            if (ca != cb) return (ca < cb) ? -1 : 1;
        }
        if (la == lb) return 0;
        return (la < lb) ? -1 : 1;
    }

    public static int c_strncmp (uint8[]? a, size_t a_off, uint8[]? b, size_t b_off, size_t n) {
        if (n == 0) return 0;
        size_t la = c_strlen (a, a_off);
        size_t lb = c_strlen (b, b_off);
        if (la > n) la = n;
        if (lb > n) lb = n;
        size_t min_l = (la < lb) ? la : lb;
        for (size_t i = 0; i < min_l; i++) {
            uint8 ca = ((!) a)[(int) (a_off + i)];
            uint8 cb = ((!) b)[(int) (b_off + i)];
            if (ca != cb) return (ca < cb) ? -1 : 1;
        }
        if (la == lb) return 0;
        return (la < lb) ? -1 : 1;
    }

    public static string c_str_to_string (uint8[]? buf, size_t off = 0) {
        if (buf == null) return "";
        size_t n = c_strlen (buf, off);
        if (n == 0) return "";
        var sb = new GLib.StringBuilder ();
        for (size_t i = 0; i < n; i++)
            sb.append_c ((char) ((!) buf)[(int) (off + i)]);
        return sb.str;
    }
}

public class PlanBytes : GLib.Object {
    public static GLib.Bytes from_string (string? s) {
        if (s == null || ((!) s).length == 0)
            return new GLib.Bytes (null);
        return new GLib.Bytes (((!) s).data);
    }
}

namespace GLib {
    public class ByteSlice : Object {
        public uint8[] buf;
        public size_t off;
        public size_t len;

        public ByteSlice (uint8[]? data, size_t offset = 0, size_t length = 0) {
            if (data == null || offset >= (size_t) ((!) data).length) {
                buf = new uint8[0];
                off = 0;
                len = 0;
                return;
            }
            buf = (!) data;
            off = offset;
            size_t avail = (size_t) ((!) data).length - offset;
            len = (length == 0 || length > avail) ? avail : length;
        }

        public ByteSlice.exact (uint8[]? data, size_t offset, size_t length) {
            if (data == null || length == 0 || offset >= (size_t) ((!) data).length) {
                buf = new uint8[0];
                off = 0;
                len = 0;
                return;
            }
            buf = (!) data;
            off = offset;
            size_t avail = (size_t) ((!) data).length - offset;
            len = (length > avail) ? avail : length;
        }

        public static ByteSlice from_string (string? s) {
            if (s == null || ((!) s).length == 0)
                return new ByteSlice (null);
            unowned uint8[] raw = ((!) s).data;
            var copy = new uint8[raw.length];
            PlanMem.copy_bytes (copy, 0, raw, 0, (size_t) raw.length);
            return new ByteSlice.exact (copy, 0, (size_t) raw.length);
        }

        public ByteSlice slice (size_t start, size_t end) {
            if (start >= len || end <= start)
                return new ByteSlice (null);
            size_t clamped_end = (end > len) ? len : end;
            return new ByteSlice.exact (buf, off + start, clamped_end - start);
        }

        public new uint8 get (size_t index) {
            if (index >= len) return 0;
            return buf[(int) (off + index)];
        }

        public new void set (size_t index, uint8 value) {
            if (index < len) buf[(int) (off + index)] = value;
        }

        public uint8[] to_uint8_array () {
            var out_arr = new uint8[(int) len];
            if (len > 0) PlanMem.copy_bytes (out_arr, 0, buf, off, len);
            return out_arr;
        }

        public char[] to_char_array () {
            var out_arr = new char[(int) len];
            for (size_t i = 0; i < len; i++)
                out_arr[(int) i] = (char) buf[(int) (off + i)];
            return out_arr;
        }

        public string to_string () {
            if (len == 0) return "";
            var sb = new StringBuilder ();
            for (size_t i = 0; i < len; i++)
                sb.append_c ((char) buf[(int) (off + i)]);
            return sb.str;
        }

        public string to_c_string () {
            size_t n = PlanMem.c_strlen (buf, off);
            if (n > len) n = len;
            return PlanMem.c_str_to_string (buf, off).substring (0, (long) n);
        }

        public int index_of (uint8 b) {
            for (size_t i = 0; i < len; i++) {
                if (buf[(int) (off + i)] == b) return (int) i;
            }
            return -1;
        }

        public bool eq_ascii (string s) {
            if ((size_t) s.length != len) return false;
            return to_string () == s;
        }

        public size_t copy_to (uint8[] dst, size_t dst_off = 0) {
            if (dst_off >= (size_t) dst.length || len == 0) return 0;
            size_t avail = (size_t) dst.length - dst_off;
            size_t n = (len > avail) ? avail : len;
            PlanMem.copy_bytes (dst, dst_off, buf, off, n);
            return n;
        }
    }

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

        public T get_item (int index) { return buf[off + index]; }
        public void set_item (int index, T value) { buf[off + index] = value; }
        public View<T> slice (int start, int end) {
            if (start < 0) start = 0;
            if (end > length) end = length;
            if (end <= start) return new View<T> (buf, off, 0);
            return new View<T> (buf, off + start, end - start);
        }
    }
}

namespace Simd {
    public struct u32x4 {
        public uint32 x;
        public uint32 y;
        public uint32 z;
        public uint32 w;
        public u32x4 (uint32 vx = 0, uint32 vy = 0, uint32 vz = 0, uint32 vw = 0) { x = vx; y = vy; z = vz; w = vw; }
        public static u32x4 splat (uint32 v) { return u32x4 () { x = v, y = v, z = v, w = v }; }
        public u32x4 add (u32x4 o) { return u32x4 () { x = x + o.x, y = y + o.y, z = z + o.z, w = w + o.w }; }
        public u32x4 sub (u32x4 o) { return u32x4 () { x = x - o.x, y = y - o.y, z = z - o.z, w = w - o.w }; }
        public u32x4 mul (u32x4 o) { return u32x4 () { x = x * o.x, y = y * o.y, z = z * o.z, w = w * o.w }; }
        public u32x4 bit_and (u32x4 o) { return u32x4 () { x = x & o.x, y = y & o.y, z = z & o.z, w = w & o.w }; }
        public u32x4 bit_or (u32x4 o) { return u32x4 () { x = x | o.x, y = y | o.y, z = z | o.z, w = w | o.w }; }
        public u32x4 bit_xor (u32x4 o) { return u32x4 () { x = x ^ o.x, y = y ^ o.y, z = z ^ o.z, w = w ^ o.w }; }
    }
    public struct i32x4 {
        public int32 x;
        public int32 y;
        public int32 z;
        public int32 w;
        public i32x4 (int32 vx = 0, int32 vy = 0, int32 vz = 0, int32 vw = 0) { x = vx; y = vy; z = vz; w = vw; }
        public static i32x4 splat (int32 v) { return i32x4 () { x = v, y = v, z = v, w = v }; }
        public i32x4 add (i32x4 o) { return i32x4 () { x = x + o.x, y = y + o.y, z = z + o.z, w = w + o.w }; }
        public i32x4 sub (i32x4 o) { return i32x4 () { x = x - o.x, y = y - o.y, z = z - o.z, w = w - o.w }; }
        public i32x4 mul (i32x4 o) { return i32x4 () { x = x * o.x, y = y * o.y, z = z * o.z, w = w * o.w }; }
    }
    public struct f32x4 {
        public float x;
        public float y;
        public float z;
        public float w;
        public f32x4 (float vx = 0.0f, float vy = 0.0f, float vz = 0.0f, float vw = 0.0f) { x = vx; y = vy; z = vz; w = vw; }
        public static f32x4 splat (float v) { return f32x4 () { x = v, y = v, z = v, w = v }; }
        public f32x4 add (f32x4 o) { return f32x4 () { x = x + o.x, y = y + o.y, z = z + o.z, w = w + o.w }; }
        public f32x4 sub (f32x4 o) { return f32x4 () { x = x - o.x, y = y - o.y, z = z - o.z, w = w - o.w }; }
        public f32x4 mul (f32x4 o) { return f32x4 () { x = x * o.x, y = y * o.y, z = z * o.z, w = w * o.w }; }
        public float dot (f32x4 o) { return x * o.x + y * o.y + z * o.z + w * o.w; }
    }
}
