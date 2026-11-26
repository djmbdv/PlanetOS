// Minimal libc shim for C code translated by tools/c2vala.py.
//
// Only what the translated subset needs: the string helpers that Vala does not
// expose as free functions. Everything else (printf) maps to GLib directly.

using GLib;

public int c_strlen (string s) {
    return s.length;
}

private static StringChunk? _c2v_str_chunk = null;

public unowned string c_intern_str (string s) {
    if (_c2v_str_chunk == null)
        _c2v_str_chunk = new StringChunk (4096);
    return ((!) _c2v_str_chunk).insert_const (s);
}

public int c_strcmp (string a, string b) {
    int n = (a.length < b.length) ? a.length : b.length;
    for (int i = 0; i < n; i++) {
        if (a[i] != b[i])
            return (a[i] < b[i]) ? -1 : 1;
    }
    if (a.length == b.length)
        return 0;
    return (a.length < b.length) ? -1 : 1;
}

public int c_strncmp (string a, string b, size_t n) {
    int limit = (int) n;
    for (int i = 0; i < limit; i++) {
        bool end_a = (i >= a.length);
        bool end_b = (i >= b.length);
        if (end_a && end_b)
            return 0;
        if (end_a)
            return -1;
        if (end_b)
            return 1;
        if (a[i] != b[i])
            return (a[i] < b[i]) ? -1 : 1;
    }
    return 0;
}

public string c_chr (int c) {
    if (c == 10) return "\n";
    if (c == 9) return "\t";
    if (c == 13) return "\r";
    if (c >= 32 && c <= 126) {
        string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
        return ascii.substring (c - 32, 1);
    }
    return "?";
}

public string c_hex (uint64 v, bool upper) {
    if (v == 0)
        return "0";
    string digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    string out_s = "";
    uint64 cur = v;
    while (cur > 0) {
        int d = (int) (cur & 0xf);
        out_s = digits.substring (d, 1) + out_s;
        cur = cur >> 4;
    }
    return out_s;
}

public uint64 c_ptr_u64 (uint8[]? a) {
    if (a == null) return 0;
    return (uint64) (uintptr.from_pointer ((void*) ((!) a)) + (uintptr) 16);
}

private int __c2v_arr_addr (uint8[] a) {
    return (int) c_ptr_u64 (a);
}

public void c_memcpy (uint8[] dst, uint8[] src, size_t n) {
    c_memcpy_off (dst, 0, src, 0, n);
}

public void c_memmove (uint8[] dst, uint8[] src, size_t n) {
    c_memmove_off (dst, 0, src, 0, n);
}

// Offset forms: copying from `buf + off` must not slice the buffer, which
// would copy its whole tail before the memcpy even starts.
public void c_memcpy_off (uint8[] dst, int doff, uint8[] src, int soff, size_t n) {
    int limit = (int) n;
    if (doff < 0) { limit += doff; doff = 0; }
    if (soff < 0) { limit += soff; soff = 0; }
    if (limit <= 0) return;
    if (doff + limit > dst.length) limit = dst.length - doff;
    if (soff + limit > src.length) limit = src.length - soff;
    if (limit <= 0) return;
#if PLANC
    GLib.Memory.copy (__c2v_arr_addr (dst) + doff, __c2v_arr_addr (src) + soff, (size_t) limit);
#else
    for (int i = 0; i < limit; i++)
        dst[doff + i] = src[soff + i];
#endif
}

public void c_memmove_off (uint8[] dst, int doff, uint8[] src, int soff, size_t n) {
    int limit = (int) n;
    if (doff < 0) { limit += doff; doff = 0; }
    if (soff < 0) { limit += soff; soff = 0; }
    if (limit <= 0) return;
    if (doff + limit > dst.length) limit = dst.length - doff;
    if (soff + limit > src.length) limit = src.length - soff;
    if (limit <= 0) return;
#if PLANC
    GLib.Memory.move (__c2v_arr_addr (dst) + doff, __c2v_arr_addr (src) + soff, (size_t) limit);
#else
    // glib-2.0's Memory.move takes void*, so stage the source for the overlap.
    var tmp = new uint8[limit];
    for (int i = 0; i < limit; i++)
        tmp[i] = src[soff + i];
    for (int i = 0; i < limit; i++)
        dst[doff + i] = tmp[i];
#endif
}

public void c_memset (uint8[] dst, int c, size_t n) {
    int limit = (int) n;
    if (limit <= 0) return;
    if (limit > dst.length) limit = dst.length;
    if (limit <= 0) return;
#if PLANC
    GLib.Memory.set (__c2v_arr_addr (dst), c, (size_t) limit);
#else
    for (int i = 0; i < limit; i++)
        dst[i] = (uint8) c;
#endif
}

public int c_memcmp (uint8[] a, uint8[] b, size_t n) {
    int limit = (int) n;
    if (limit <= 0) return 0;
    if (limit > a.length) limit = a.length;
    if (limit > b.length) limit = b.length;
    if (limit <= 0) return 0;
#if PLANC
    int diff = GLib.Memory.cmp (__c2v_arr_addr (a), __c2v_arr_addr (b), (size_t) limit);
    if (diff == 0) return 0;
    return (diff < 0) ? -1 : 1;
#else
    for (int i = 0; i < limit; i++) {
        if (a[i] != b[i])
            return (a[i] < b[i]) ? -1 : 1;
    }
    return 0;
#endif
}

public uint8[] c_realloc_u8 (uint8[]? old, size_t new_len) {
    int n = (int) new_len;
    var res = new uint8[n];
    if (old != null) {
        int copy_n = (old.length < n) ? old.length : n;
        for (int i = 0; i < copy_n; i++)
            res[i] = old[i];
    }
    return res;
}

public int c_ctz32 (uint32 v) {
    if (v == 0) return 32;
    int n = 0;
    uint32 x = v;
    while ((x & 1u) == 0u) { n++; x >>= 1; }
    return n;
}

public int c_ctz64 (uint64 v) {
    if (v == 0) return 64;
    int n = 0;
    uint64 x = v;
    while ((x & 1UL) == 0UL) { n++; x >>= 1; }
    return n;
}

public int c_clz32 (uint32 v) {
    if (v == 0) return 32;
    int n = 0;
    uint32 x = v;
    while ((x & 0x80000000u) == 0u) { n++; x <<= 1; }
    return n;
}

public int c_clz64 (uint64 v) {
    if (v == 0) return 64;
    int n = 0;
    uint64 x = v;
    while ((x & ((uint64) 1 << 63)) == 0UL) { n++; x <<= 1; }
    return n;
}

public int c_popcount32 (uint32 v) {
    int n = 0;
    uint32 x = v;
    while (x != 0u) { n += (int) (x & 1u); x >>= 1; }
    return n;
}

public int c_popcount64 (uint64 v) {
    int n = 0;
    uint64 x = v;
    while (x != 0UL) { n += (int) (x & 1UL); x >>= 1; }
    return n;
}

public uint16 c_bswap16 (uint16 v) {
    return (uint16) (((v & 0xFF) << 8) | ((v >> 8) & 0xFF));
}

public uint32 c_bswap32 (uint32 v) {
    return ((v & 0x000000FFu) << 24)
         | ((v & 0x0000FF00u) << 8)
         | ((v & 0x00FF0000u) >> 8)
         | ((v >> 24) & 0x000000FFu);
}

public uint64 c_bswap64 (uint64 v) {
    return ((v & 0xFFUL) << 56)
         | ((v & 0xFF00UL) << 40)
         | ((v & 0xFF0000UL) << 24)
         | ((v & 0xFF000000UL) << 8)
         | ((v >> 8) & 0xFF000000UL)
         | ((v >> 24) & 0xFF0000UL)
         | ((v >> 40) & 0xFF00UL)
         | ((v >> 56) & 0xFFUL);
}

public void c_assert (bool cond) {
    if (!cond) {
        print ("c2vala: assertion failed\n");
    }
}

public void c_abort () {
    print ("c2vala: abort()\n");
}

public int c_isnan (double x) {
    return (x != x) ? 1 : 0;
}

public int c_isfinite (double x) {
    return ((x == x) && (x - x == 0.0)) ? 1 : 0;
}

public string c_bytes_to_str (uint8[]? b) {
    if (b == null) return "";
    string res = "";
    for (int i = 0; i < b.length; i++) {
        if (b[i] == 0) break;
        res = res + c_chr ((int) b[i]);
    }
    return res;
}

public double c_fabs (double x) {
    return (x < 0.0) ? -x : x;
}

public double c_trunc (double x) {
    return (double) ((int64) x);
}

public double c_floor (double x) {
    int64 t = (int64) x;
    if ((double) t > x)
        t--;
    return (double) t;
}

public double c_ceil (double x) {
    int64 t = (int64) x;
    if ((double) t < x)
        t++;
    return (double) t;
}

public int c_putchar (int ch) {
    print (c_chr (ch));
    return ch;
}

public int c_atoi (string s) {
    int i = 0;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
        i++;
    bool neg = false;
    if (i < s.length && (s[i] == '-' || s[i] == '+')) {
        neg = (s[i] == '-');
        i++;
    }
    int v = 0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9') {
        v = v * 10 + (int) (s[i] - '0');
        i++;
    }
    return neg ? -v : v;
}

public int c_strspn (string s, string accept) {
    int i = 0;
    while (i < s.length) {
        bool ok = false;
        for (int j = 0; j < accept.length; j++) {
            if (s[i] == accept[j]) { ok = true; break; }
        }
        if (!ok) break;
        i++;
    }
    return i;
}

public string? c_strchr (string s, int c) {
    int i = s.index_of_char (c);
    return (i >= 0) ? s.substring (i) : null;
}

public string? c_strrchr (string s, int c) {
    int i = s.last_index_of_char (c);
    return (i >= 0) ? s.substring (i) : null;
}

public string? c_strstr (string hay, string needle) {
    int i = hay.index_of (needle);
    return (i >= 0) ? hay.substring (i) : null;
}

// Assignment expressions: Vala has none, so `(n = x) == y` becomes
// `c_assign_i (x, ref n) == y`. Each helper stores the value and returns it.
public bool c_assign_b (bool v, ref bool t) { t = v; return v; }
public char c_assign_c (char v, ref char t) { t = v; return v; }
public int8 c_assign_i8 (int8 v, ref int8 t) { t = v; return v; }
public int16 c_assign_i16 (int16 v, ref int16 t) { t = v; return v; }
public int c_assign_i (int v, ref int t) { t = v; return v; }
public int64 c_assign_i64 (int64 v, ref int64 t) { t = v; return v; }
public uint8 c_assign_u8 (uint8 v, ref uint8 t) { t = v; return v; }
public uint16 c_assign_u16 (uint16 v, ref uint16 t) { t = v; return v; }
public uint32 c_assign_u32 (uint32 v, ref uint32 t) { t = v; return v; }
public uint64 c_assign_u64 (uint64 v, ref uint64 t) { t = v; return v; }
public float c_assign_f (float v, ref float t) { t = v; return v; }
public double c_assign_d (double v, ref double t) { t = v; return v; }

public int c_comma_i (int64 _ignored, int val) { return val; }
public int64 c_comma_i64 (int64 _ignored, int64 val) { return val; }
public uint32 c_comma_u32 (int64 _ignored, uint32 val) { return val; }
public uint64 c_comma_u64 (int64 _ignored, uint64 val) { return val; }
public double c_comma_d (int64 _ignored, double val) { return val; }
public bool c_comma_b (int64 _ignored, bool val) { return val; }

public string c_str_add (string s, int off) {
    if (off <= 0) return s;
    if (off >= s.length) return "";
    return s.substring (off);
}

public uint8[] c_bytes_add (uint8[] b, int off) {
    if (off <= 0) return b;
    if (off >= b.length) return new uint8[0];
    int n = b.length - off;
    uint8[] out_b = new uint8[n];
    for (int i = 0; i < n; i++)
        out_b[i] = b[off + i];
    return out_b;
}

public uint8[] c_str_to_bytes (string? s) {
    if (s == null)
        return new uint8[0];
    string sv = (!) s;
    var b = new uint8[sv.length + 1];
    for (int i = 0; i < sv.length; i++)
        b[i] = sv[i];
    b[sv.length] = 0;
    return b;
}

public uint8[] c_strcpy_buf (uint8[] dst, string src) {
    int n = src.length;
    if (n >= dst.length) n = dst.length > 0 ? dst.length - 1 : 0;
    for (int i = 0; i < n; i++)
        dst[i] = src[i];
    if (dst.length > 0) dst[n] = 0;
    return dst;
}

public uint8[] c_strncpy_buf (uint8[] dst, string src, size_t max_n) {
    int lim = (int) max_n;
    if (lim > dst.length) lim = dst.length;
    int i = 0;
    while (i < lim && i < src.length) {
        dst[i] = src[i];
        i++;
    }
    while (i < lim) {
        dst[i] = 0;
        i++;
    }
    return dst;
}

public uint8[] c_strcat_buf (uint8[] dst, string src) {
    int pos = 0;
    while (pos < dst.length && dst[pos] != 0)
        pos++;
    int n = src.length;
    if (pos + n >= dst.length)
        n = (dst.length - 1 > pos) ? (dst.length - 1 - pos) : 0;
    for (int i = 0; i < n; i++)
        dst[pos + i] = src[i];
    if (pos + n < dst.length)
        dst[pos + n] = 0;
    return dst;
}

public int c_sprintf_buf (uint8[] dst, string src) {
    c_strcpy_buf (dst, src);
    return src.length;
}

public int c_snprintf_buf (uint8[] dst, size_t max_n, string src) {
    int lim = (int) max_n;
    if (lim > 0) {
        int copy_n = src.length;
        if (copy_n >= lim) copy_n = lim - 1;
        if (copy_n > dst.length) copy_n = dst.length > 0 ? dst.length - 1 : 0;
        for (int i = 0; i < copy_n; i++)
            dst[i] = src[i];
        if (copy_n < dst.length)
            dst[copy_n] = 0;
    }
    return src.length;
}

public class C2VArena {
    public uint8[] buf;
    public int used;

    public C2VArena (int capacity) {
        int cap = capacity > 64 ? capacity : 64;
        buf = new uint8[cap];
        used = 0;
    }

    public int alloc (int bytes, int align = 8) {
        int a = align > 1 ? align : 1;
        int off = (used + a - 1) & ~(a - 1);
        int need = off + (bytes > 0 ? bytes : 1);
        if (need > buf.length) {
            int ncap = buf.length * 2;
            while (ncap < need) ncap *= 2;
            uint8[] nbuf = new uint8[ncap];
            for (int i = 0; i < used; i++)
                nbuf[i] = buf[i];
            buf = nbuf;
        }
        used = need;
        return off;
    }

    public int add_off (int base_off, int delta, int elem_size = 1) {
        return base_off + delta * elem_size;
    }

    public uint8 read_u8 (int off) {
        if (off < 0 || off >= buf.length) return 0;
        return buf[off];
    }

    public void write_u8 (int off, uint8 v) {
        if (off >= 0 && off < buf.length)
            buf[off] = v;
    }

    public uint32 read_u32 (int off) {
        if (off < 0 || off + 4 > buf.length) return 0;
        return (uint32) buf[off]
            | ((uint32) buf[off + 1] << 8)
            | ((uint32) buf[off + 2] << 16)
            | ((uint32) buf[off + 3] << 24);
    }

    public void write_u32 (int off, uint32 v) {
        if (off < 0 || off + 4 > buf.length) return;
        buf[off] = (uint8) (v & 0xff);
        buf[off + 1] = (uint8) ((v >> 8) & 0xff);
        buf[off + 2] = (uint8) ((v >> 16) & 0xff);
        buf[off + 3] = (uint8) ((v >> 24) & 0xff);
    }

    public uint64 read_u64 (int off) {
        if (off < 0 || off + 8 > buf.length) return 0;
        uint64 lo = (uint64) read_u32 (off);
        uint64 hi = (uint64) read_u32 (off + 4);
        return lo | (hi << 32);
    }

    public void write_u64 (int off, uint64 v) {
        if (off < 0 || off + 8 > buf.length) return;
        write_u32 (off, (uint32) (v & 0xffffffff));
        write_u32 (off + 4, (uint32) ((v >> 32) & 0xffffffff));
    }

    public uint8[] slice (int off) {
        return c_bytes_add (buf, off);
    }

    public C2VPtr alloc_ptr (int bytes, int align = 8) {
        int off = alloc (bytes, align);
        return new C2VPtr.from_bytes (buf, off);
    }

    public C2VPtr alloc_with_header (int hdr_bytes, int body_bytes, int align = 8) {
        int h = (hdr_bytes < 0) ? 0 : hdr_bytes;
        int b = (body_bytes < 0) ? 0 : body_bytes;
        int off = alloc (h + b, align);
        return new C2VPtr.from_bytes (buf, off + h);
    }
}

public class C2VBox<T> : Object {
    public T val;
    public int off = 0;

    public C2VBox (T v, int o = 0) {
        val = v;
        off = o;
    }
}

public class C2VPtr : Object {
    public uint8[]? data = null;
    public int offset = 0;
    public Object? obj = null;

    public C2VPtr () {}

    public C2VPtr.from_bytes (uint8[] b, int off = 0) {
        data = b;
        offset = (off < 0) ? 0 : ((off > b.length) ? b.length : off);
    }

    public C2VPtr.from_obj (Object? o) {
        obj = o;
    }

    public C2VPtr add (int delta) {
        var p = new C2VPtr ();
        p.data = data;
        int64 n = (int64) offset + (int64) delta;
        if (n < 0) n = 0;
        if (data != null && n > (int64) ((!) data).length)
            n = (int64) ((!) data).length;
        p.offset = (int) n;
        p.obj = obj;
        return p;
    }

    public uint8 get_u8_at (int rel_off) {
        if (data == null) return 0;
        int64 pos = (int64) offset + (int64) rel_off;
        if (pos < 0 || pos >= (int64) ((!) data).length) return 0;
        return ((!) data)[(int) pos];
    }

    public void set_u8_at (int rel_off, uint8 val) {
        if (data == null) return;
        int64 pos = (int64) offset + (int64) rel_off;
        if (pos < 0 || pos >= (int64) ((!) data).length) return;
        c_u_set_u8_at ((!) data, (int) pos, val);
    }

    public uint32 get_u32_at (int rel_off) {
        if (data == null) return 0;
        int64 pos = (int64) offset + (int64) rel_off;
        if (pos < 0 || pos + 4 > (int64) ((!) data).length) return 0;
        return c_u_get_u32_at ((!) data, (int) pos);
    }

    public void set_u32_at (int rel_off, uint32 val) {
        if (data == null) return;
        int64 pos = (int64) offset + (int64) rel_off;
        if (pos < 0 || pos + 4 > (int64) ((!) data).length) return;
        c_u_set_u32_at ((!) data, (int) pos, val);
    }

    public uint64 get_u64_at (int rel_off) {
        if (data == null) return 0;
        int64 pos = (int64) offset + (int64) rel_off;
        if (pos < 0 || pos + 8 > (int64) ((!) data).length) return 0;
        return c_u_get_u64_at ((!) data, (int) pos);
    }

    public void set_u64_at (int rel_off, uint64 val) {
        if (data == null) return;
        int64 pos = (int64) offset + (int64) rel_off;
        if (pos < 0 || pos + 8 > (int64) ((!) data).length) return;
        c_u_set_u64_at ((!) data, (int) pos, val);
    }

    public uint8[] as_bytes () {
        if (data == null)
            return new uint8[0];
        if (offset <= 0)
            return (!) data;
        return c_bytes_add ((!) data, offset);
    }
}

public string c_getenv (string name) {
    return "";
}

public void c_exit (int status) {
    c_abort ();
}

public int c_puts (string s) {
    print (s + "\n");
    return 0;
}

public int c_isspace (int c) {
    return ((char) c).isspace () ? 1 : 0;
}

public int c_isdigit (int c) {
    return ((char) c).isdigit () ? 1 : 0;
}

public int c_isupper (int c) {
    return ((char) c).isupper () ? 1 : 0;
}

public int c_islower (int c) {
    return ((char) c).islower () ? 1 : 0;
}

public int c_isalpha (int c) {
    return ((char) c).isalpha () ? 1 : 0;
}

public int c_isalnum (int c) {
    return ((char) c).isalnum () ? 1 : 0;
}

public int c_isxdigit (int c) {
    return ((char) c).isxdigit () ? 1 : 0;
}

public int c_tolower (int c) {
    return (int) ((char) c).tolower ();
}

public int c_toupper (int c) {
    return (int) ((char) c).toupper ();
}

#if PLANC
public FileStream? stdin;
public FileStream? stdout;
public FileStream? stderr;
#else
// stdio.h brings stdin/stdout/stderr in as macros, so the host build gives
// these globals C names of their own while keeping the Vala identifiers the
// translated code uses.
[CCode (cname = "c2v_stdin")]
public FileStream? stdin;
[CCode (cname = "c2v_stdout")]
public FileStream? stdout;
[CCode (cname = "c2v_stderr")]
public FileStream? stderr;
#endif

#if !PLANC
// valac's glib-2.0 binds FileStream as [Compact] with fclose as its free
// function and exposes no close (), so call fclose by its C name on the host.
[CCode (cname = "fclose", cheader_filename = "stdio.h")]
private extern int c2v_file_close (FileStream s);
#endif

public void c_init_stdio () {
    if (stdin == null)
        stdin = FileStream.fdopen (0, "r");
    if (stdout == null)
        stdout = FileStream.fdopen (1, "w");
    if (stderr == null)
        stderr = FileStream.fdopen (2, "w");
}

public int c_fclose (ref FileStream? s) {
    if (s == null)
        return -1;
#if PLANC
    int r = s.close_now ();
#else
    int r = c2v_file_close ((!) s);
#endif
    s = null;
    return r;
}

public int c_fclose_val (FileStream? s) {
    if (s == null)
        return -1;
#if PLANC
    return s.close_now ();
#else
    return c2v_file_close ((!) s);
#endif
}

public size_t c_fread (uint8[] buf, size_t size, size_t nmemb, FileStream? s) {
    if (s == null || size == 0 || nmemb == 0 || buf.length == 0)
        return 0;
    size_t max_items = (size_t) buf.length / size;
    size_t count = (nmemb > max_items) ? max_items : nmemb;
    if (count == 0)
        return 0;
    int total = (int) (size * count);
    var tmp = new uint8[total];
    size_t got_bytes = s.read (tmp, 1);
    for (int i = 0; i < (int) got_bytes; i++)
        buf[i] = tmp[i];
    return got_bytes / size;
}

public size_t c_fwrite (uint8[] buf, size_t size, size_t nmemb, FileStream? s) {
    if (s == null || size == 0 || nmemb == 0 || buf.length == 0)
        return 0;
    size_t max_items = (size_t) buf.length / size;
    size_t count = (nmemb > max_items) ? max_items : nmemb;
    if (count == 0)
        return 0;
    int total = (int) (size * count);
    var tmp = new uint8[total];
    for (int i = 0; i < total; i++)
        tmp[i] = buf[i];
    size_t put_bytes = s.write (tmp, 1);
    return put_bytes / size;
}

public string? c_fgets (uint8[] buf, int size, FileStream? s) {
    if (s == null || size <= 0 || buf.length == 0)
        return null;
    if (size == 1) {
        buf[0] = 0;
        return "";
    }
    int max_chars = (size - 1 < buf.length - 1) ? (size - 1) : (buf.length - 1);
    int i = 0;
    while (i < max_chars) {
        int c = s.getc ();
        if (c < 0)
            break;
        buf[i] = (uint8) c;
        i++;
        if (c == '\n')
            break;
    }
    if (i == 0)
        return null;
    buf[i] = 0;
    return (string) buf;
}

public uint64 c_u_get_u64 (uint8[] data, int nbytes) {
    if (nbytes <= 0)
        return 0;
    uint64 v = 0;
    int lim = (nbytes < data.length) ? nbytes : data.length;
    for (int i = 0; i < lim; i++)
        v |= ((uint64) data[i]) << (i * 8);
    return v;
}

public void c_u_set_u64 (uint8[] data, int nbytes, uint64 val) {
    if (nbytes <= 0)
        return;
    int lim = (nbytes < data.length) ? nbytes : data.length;
    for (int i = 0; i < lim; i++)
        data[i] = (uint8) ((val >> (i * 8)) & 0xff);
}

public uint16 c_u_get_u16 (uint8[] data) {
    if (data.length < 2)
        return (uint16) c_u_get_u64 (data, 2);
    return (uint16) (((uint32) data[0]) | (((uint32) data[1]) << 8));
}

public void c_u_set_u16 (uint8[] data, uint16 val) {
    if (data.length < 2) {
        c_u_set_u64 (data, 2, (uint64) val);
        return;
    }
    data[0] = (uint8) (val & 0xff);
    data[1] = (uint8) ((val >> 8) & 0xff);
}

public uint32 c_u_get_u32 (uint8[] data) {
    if (data.length < 4)
        return (uint32) c_u_get_u64 (data, 4);
    return ((uint32) data[0])
        | (((uint32) data[1]) << 8)
        | (((uint32) data[2]) << 16)
        | (((uint32) data[3]) << 24);
}

public void c_u_set_u32 (uint8[] data, uint32 val) {
    if (data.length < 4) {
        c_u_set_u64 (data, 4, (uint64) val);
        return;
    }
    data[0] = (uint8) (val & 0xff);
    data[1] = (uint8) ((val >> 8) & 0xff);
    data[2] = (uint8) ((val >> 16) & 0xff);
    data[3] = (uint8) ((val >> 24) & 0xff);
}

public uint64 c_u_get_u64_le (uint8[] data) {
    if (data.length < 8)
        return c_u_get_u64 (data, 8);
    return ((uint64) data[0])
        | (((uint64) data[1]) << 8)
        | (((uint64) data[2]) << 16)
        | (((uint64) data[3]) << 24)
        | (((uint64) data[4]) << 32)
        | (((uint64) data[5]) << 40)
        | (((uint64) data[6]) << 48)
        | (((uint64) data[7]) << 56);
}

public void c_u_set_u64_le (uint8[] data, uint64 val) {
    if (data.length < 8) {
        c_u_set_u64 (data, 8, val);
        return;
    }
    data[0] = (uint8) (val & 0xff);
    data[1] = (uint8) ((val >> 8) & 0xff);
    data[2] = (uint8) ((val >> 16) & 0xff);
    data[3] = (uint8) ((val >> 24) & 0xff);
    data[4] = (uint8) ((val >> 32) & 0xff);
    data[5] = (uint8) ((val >> 40) & 0xff);
    data[6] = (uint8) ((val >> 48) & 0xff);
    data[7] = (uint8) ((val >> 56) & 0xff);
}

public void c_u_copy (uint8[] dst, uint8[] src) {
    int lim = (dst.length < src.length) ? dst.length : src.length;
    for (int i = 0; i < lim; i++)
        dst[i] = src[i];
}

public uint8 c_u_get_u8_at (uint8[] data, int off) {
    if (off < 0 || off >= data.length)
        return 0;
    return data[off];
}

public void c_u_set_u8_at (uint8[] data, int off, uint8 val) {
    if (off >= 0 && off < data.length)
        data[off] = val;
}

public uint16 c_u_get_u16_at (uint8[] data, int off) {
    if (off < 0 || off + 2 > data.length)
        return 0;
    return (uint16) (((uint32) data[off]) | (((uint32) data[off + 1]) << 8));
}

public void c_u_set_u16_at (uint8[] data, int off, uint16 val) {
    if (off < 0 || off + 2 > data.length)
        return;
    data[off] = (uint8) (val & 0xff);
    data[off + 1] = (uint8) ((val >> 8) & 0xff);
}

public uint32 c_u_get_u32_at (uint8[] data, int off) {
    if (off < 0 || off + 4 > data.length)
        return 0;
    return ((uint32) data[off])
        | (((uint32) data[off + 1]) << 8)
        | (((uint32) data[off + 2]) << 16)
        | (((uint32) data[off + 3]) << 24);
}

public void c_u_set_u32_at (uint8[] data, int off, uint32 val) {
    if (off < 0 || off + 4 > data.length)
        return;
    data[off] = (uint8) (val & 0xff);
    data[off + 1] = (uint8) ((val >> 8) & 0xff);
    data[off + 2] = (uint8) ((val >> 16) & 0xff);
    data[off + 3] = (uint8) ((val >> 24) & 0xff);
}

public uint64 c_u_get_u64_at (uint8[] data, int off) {
    if (off < 0 || off + 8 > data.length)
        return 0;
    return ((uint64) data[off])
        | (((uint64) data[off + 1]) << 8)
        | (((uint64) data[off + 2]) << 16)
        | (((uint64) data[off + 3]) << 24)
        | (((uint64) data[off + 4]) << 32)
        | (((uint64) data[off + 5]) << 40)
        | (((uint64) data[off + 6]) << 48)
        | (((uint64) data[off + 7]) << 56);
}

public void c_u_set_u64_at (uint8[] data, int off, uint64 val) {
    if (off < 0 || off + 8 > data.length)
        return;
    data[off] = (uint8) (val & 0xff);
    data[off + 1] = (uint8) ((val >> 8) & 0xff);
    data[off + 2] = (uint8) ((val >> 16) & 0xff);
    data[off + 3] = (uint8) ((val >> 24) & 0xff);
    data[off + 4] = (uint8) ((val >> 32) & 0xff);
    data[off + 5] = (uint8) ((val >> 40) & 0xff);
    data[off + 6] = (uint8) ((val >> 48) & 0xff);
    data[off + 7] = (uint8) ((val >> 56) & 0xff);
}

public uint32 c_f32_to_u32 (float f) {
    double d = (double) f;
    if (d != d)
        return (uint32) 0x7FC00000;
    uint32 sign = 0;
    if (d < 0.0 || (d == 0.0 && (1.0 / d) < 0.0)) {
        sign = (uint32) 0x80000000;
        if (d < 0.0)
            d = -d;
    }
    if (d == 0.0)
        return sign;
    if (d > 3.4028235e38)
        return sign | (uint32) 0x7F800000;
    int exp = 127;
    while (d >= 2.0 && exp < 255) {
        d *= 0.5;
        exp++;
    }
    while (d < 1.0 && exp > 0) {
        d *= 2.0;
        exp--;
    }
    if (exp == 0) {
        uint32 sub = (uint32) (d * 4194304.0 + 0.5);
        return sign | (sub & (uint32) 0x7FFFFF);
    }
    uint32 mant = (uint32) ((d - 1.0) * 8388608.0 + 0.5);
    if (mant >= (uint32) 8388608) {
        mant = 0;
        exp++;
    }
    return sign | (((uint32) exp) << 23) | (mant & (uint32) 0x7FFFFF);
}

public float c_u32_to_f32 (uint32 bits) {
    uint32 exp_bits = (bits >> 23) & (uint32) 0xFF;
    uint32 mant = bits & (uint32) 0x7FFFFF;
    bool neg = (bits & (uint32) 0x80000000) != 0;
    if (exp_bits == 255) {
        if (mant != 0)
            return (float) (0.0 / 0.0);
        return neg ? (float) (-1.0 / 0.0) : (float) (1.0 / 0.0);
    }
    if (exp_bits == 0 && mant == 0)
        return neg ? (float) (-0.0) : 0.0f;
    double val;
    int e;
    if (exp_bits == 0) {
        val = ((double) mant) / 8388608.0;
        e = -126;
    } else {
        val = 1.0 + ((double) mant) / 8388608.0;
        e = (int) exp_bits - 127;
    }
    while (e > 0) { val *= 2.0; e--; }
    while (e < 0) { val *= 0.5; e++; }
    return neg ? (float) (-val) : (float) val;
}

public uint64 c_f64_to_u64 (double d) {
    if (d != d)
        return (uint64) 0x7FF8000000000000;
    uint64 sign = 0;
    if (d < 0.0 || (d == 0.0 && (1.0 / d) < 0.0)) {
        sign = ((uint64) 1) << 63;
        if (d < 0.0)
            d = -d;
    }
    if (d == 0.0)
        return sign;
    if (d > 1.7976931348623157e308)
        return sign | ((uint64) 0x7FF << 52);
    int exp = 1023;
    while (d >= 2.0 && exp < 2047) {
        d *= 0.5;
        exp++;
    }
    while (d < 1.0 && exp > 0) {
        d *= 2.0;
        exp--;
    }
    if (exp == 0) {
        uint64 sub = (uint64) (d * 2251799813685248.0 + 0.5);
        return sign | (sub & (((uint64) 1 << 52) - 1));
    }
    uint64 mant = (uint64) ((d - 1.0) * 4503599627370496.0 + 0.5);
    if (mant >= ((uint64) 1 << 52)) {
        mant = 0;
        exp++;
    }
    return sign | (((uint64) exp) << 52) | (mant & (((uint64) 1 << 52) - 1));
}

public double c_u64_to_f64 (uint64 bits) {
    uint64 exp_bits = (bits >> 52) & (uint64) 0x7FF;
    uint64 mant = bits & (((uint64) 1 << 52) - 1);
    bool neg = (bits & (((uint64) 1) << 63)) != 0;
    if (exp_bits == 2047) {
        if (mant != 0)
            return 0.0 / 0.0;
        return neg ? (-1.0 / 0.0) : (1.0 / 0.0);
    }
    if (exp_bits == 0 && mant == 0)
        return neg ? -0.0 : 0.0;
    double val;
    int e;
    if (exp_bits == 0) {
        val = ((double) mant) / 4503599627370496.0;
        e = -1022;
    } else {
        val = 1.0 + ((double) mant) / 4503599627370496.0;
        e = (int) exp_bits - 1023;
    }
    while (e > 0) { val *= 2.0; e--; }
    while (e < 0) { val *= 0.5; e++; }
    return neg ? -val : val;
}

public int64 c_time_now () {
    return get_real_time () / 1000000;
}

public int64 c_time (int64[] tloc) {
    int64 t = get_real_time () / 1000000;
    if (tloc.length > 0)
        tloc[0] = t;
    return t;
}

#if PLANC
// The thread shims are written against the PlanetOS GLib.Thread/Mutex/Cond
// (stdlib/glib/thread.vala). valac's glib-2.0 spells those types differently
// (generic Thread<T>, Cond.wait takes Mutex), so the host build omits them.
public int c_pthread_create (out Thread? tid, PthreadFunc fn, uint8[] arg) {
    tid = new Thread.with_arg (null, fn, arg);
    return 0;
}

public int c_pthread_join_null (Thread? tid) {
    if (tid != null)
        ((!) tid).join ();
    return 0;
}

public int c_pthread_mutex_lock (RecMutex? m) {
    if (m != null)
        ((!) m).@lock ();
    return 0;
}

public int c_pthread_mutex_trylock (RecMutex? m) {
    if (m == null)
        return 0;
    return ((!) m).trylock () ? 0 : 16;
}

public int c_pthread_mutex_unlock (RecMutex? m) {
    if (m != null)
        ((!) m).unlock ();
    return 0;
}

public int c_pthread_cond_wait (Cond? c, RecMutex? m) {
    if (c != null && m != null)
        ((!) c).wait ((!) m);
    return 0;
}

public int c_pthread_cond_timedwait (Cond? c, RecMutex? m, int64[] abstime) {
    if (c != null && m != null) {
        int64 end_us = (abstime.length > 0) ? abstime[0] * 1000000 : 0;
        return ((!) c).wait_until ((!) m, end_us) ? 0 : 110;
    }
    return 0;
}

public int c_pthread_cond_signal (Cond? c) {
    if (c != null)
        ((!) c).signal ();
    return 0;
}

public int c_pthread_cond_broadcast (Cond? c) {
    if (c != null)
        ((!) c).broadcast ();
    return 0;
}
#endif

#if !PLANC
// Host counterparts of the c2vala_rt_posix.vala shims, which only the PlanetOS
// build compiles (they wrap int 0x80 and a private FileStream).
public int c_remove (string path) {
    return FileUtils.remove (path);
}

public int c_rename (string oldpath, string newpath) {
    return FileUtils.rename (oldpath, newpath);
}
#endif

// POSIX -> GLib compatibility helpers
public int c_usleep (uint32 usec) {
    int64 target = get_real_time () + (int64) usec;
    while (get_real_time () < target) {}
    return 0;
}

public int c_sleep (uint sec) {
    int64 target = get_real_time () + (int64) sec * 1000000;
    while (get_real_time () < target) {}
    return 0;
}

public int c_clock_gettime (int clk_id, int64[] ts) {
    int64 us = get_real_time ();
    if (ts.length >= 2) {
        ts[0] = us / 1000000;
        ts[1] = (us % 1000000) * 1000;
    }
    return 0;
}

public int c_gettimeofday (int64[] tv) {
    int64 us = get_real_time ();
    if (tv.length >= 2) {
        tv[0] = us / 1000000;
        tv[1] = us % 1000000;
    }
    return 0;
}

public bool c_s_islnk (int m) {
    return (m & 0170000) == 0120000;
}

public bool c_s_isdir (int m) {
    return (m & 0170000) == 0040000;
}

public bool c_s_isreg (int m) {
    return (m & 0170000) == 0100000;
}

public int c_getpid () {
    return 1;
}
