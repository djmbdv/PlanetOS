// Minimal libc shim for C code translated by tools/c2vala.py.
//
// Only what the translated subset needs: the string helpers that Vala does not
// expose as free functions. Everything else (printf) maps to GLib directly.

public int c_strlen (string s) {
    return s.length;
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
        if (i >= a.length || i >= b.length)
            break;
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

public void c_memcpy (uint8[] dst, uint8[] src, size_t n) {
    int limit = (int) n;
    for (int i = 0; i < limit; i++)
        dst[i] = src[i];
}

public void c_memmove (uint8[] dst, uint8[] src, size_t n) {
    int limit = (int) n;
    var tmp = new uint8[limit];
    for (int i = 0; i < limit; i++)
        tmp[i] = src[i];
    for (int i = 0; i < limit; i++)
        dst[i] = tmp[i];
}

public void c_memset (uint8[] dst, int c, size_t n) {
    int limit = (int) n;
    uint8 b = (uint8) c;
    for (int i = 0; i < limit; i++)
        dst[i] = b;
}

public int c_memcmp (uint8[] a, uint8[] b, size_t n) {
    int limit = (int) n;
    for (int i = 0; i < limit; i++) {
        if (a[i] != b[i])
            return (a[i] < b[i]) ? -1 : 1;
    }
    return 0;
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

public uint8[] c_str_to_bytes (string s) {
    var b = new uint8[s.length];
    for (int i = 0; i < s.length; i++)
        b[i] = s[i];
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
    return (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f') ? 1 : 0;
}

public int c_isdigit (int c) {
    return (c >= '0' && c <= '9') ? 1 : 0;
}

public int c_isupper (int c) {
    return (c >= 'A' && c <= 'Z') ? 1 : 0;
}

public int c_islower (int c) {
    return (c >= 'a' && c <= 'z') ? 1 : 0;
}

public int c_isalpha (int c) {
    return (c_isupper (c) != 0 || c_islower (c) != 0) ? 1 : 0;
}

public int c_isalnum (int c) {
    return (c_isalpha (c) != 0 || c_isdigit (c) != 0) ? 1 : 0;
}

public int c_isxdigit (int c) {
    return (c_isdigit (c) != 0 || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) ? 1 : 0;
}

public int c_tolower (int c) {
    return c_isupper (c) != 0 ? (c + 32) : c;
}

public int c_toupper (int c) {
    return c_islower (c) != 0 ? (c - 32) : c;
}

[AsmBody(@"
    lea 16(%rsi), %rsi
    xor %eax, %eax
    syscall
    ret
")]
private static extern int64 c_sys_read (int fd, uint8[] buf, int count);

[AsmBody(@"
    lea 16(%rsi), %rsi
    mov $1, %rax
    syscall
    ret
")]
private static extern int64 c_sys_write (int fd, uint8[] buf, int count);

[AsmBody(@"
    lea 16(%rsi), %rsi
    mov %rcx, %r10
    mov $257, %rax
    syscall
    ret
")]
private static extern int c_sys_openat (int dirfd, string path, int flags, int mode);

[AsmBody(@"
    mov $3, %rax
    syscall
    ret
")]
private static extern int c_sys_close (int fd);

[AsmBody(@"
    mov $8, %rax
    syscall
    ret
")]
private static extern int64 c_sys_lseek (int fd, int64 offset, int whence);

[AsmBody(@"
    lea 16(%rsi), %rsi
    mov $263, %rax
    syscall
    ret
")]
private static extern int c_sys_unlinkat (int dirfd, string path, int flags);

[AsmBody(@"
    lea 16(%rsi), %rsi
    lea 16(%rcx), %r10
    mov $264, %rax
    syscall
    ret
")]
private static extern int c_sys_renameat (int olddirfd, string oldpath, int newdirfd, string newpath);

public enum FileSeek {
    SET = 0,
    CUR = 1,
    END = 2
}

public class FileStream : Object {
    private int fd;
    private bool owned_fd;
    private bool eof_flag = false;
    private int err_flag = 0;
    private int pushback = -1;
    private uint8[]? rbuf = null;
    private int rpos = 0;
    private int rlen = 0;

    private FileStream (int fd, bool owned_fd = true) {
        this.fd = fd;
        this.owned_fd = owned_fd;
    }

    ~FileStream () {
        if (owned_fd && fd >= 0) {
            c_sys_close (fd);
            fd = -1;
        }
    }

    public static FileStream? open (string path, string mode) {
        if (mode.length == 0)
            return null;
        bool plus = false;
        for (int i = 0; i < mode.length; i++) {
            if (mode[i] == '+')
                plus = true;
        }
        int flags = 0;
        uint8 m0 = mode[0];
        if (m0 == 'r') {
            flags = plus ? 2 : 0; // O_RDWR : O_RDONLY
        } else if (m0 == 'w') {
            flags = (plus ? 2 : 1) | 64 | 512; // O_CREAT | O_TRUNC
        } else if (m0 == 'a') {
            flags = (plus ? 2 : 1) | 64 | 1024; // O_CREAT | O_APPEND
        } else {
            return null;
        }
        flags = flags | 524288; // O_CLOEXEC
        int fd = c_sys_openat (-100, path, flags, 420); // 0644
        if (fd < 0)
            return null;
        return new FileStream (fd, true);
    }

    public static FileStream? fdopen (int fildes, string mode) {
        if (fildes < 0)
            return null;
        return new FileStream (fildes, false);
    }

    public int close_now () {
        if (fd < 0)
            return -1;
        rpos = 0;
        rlen = 0;
        int r = owned_fd ? c_sys_close (fd) : 0;
        fd = -1;
        return r < 0 ? -1 : 0;
    }

    public int fileno () {
        return fd;
    }

    public bool eof () {
        return eof_flag;
    }

    public int error () {
        return err_flag;
    }

    public void clearerr () {
        eof_flag = false;
        err_flag = 0;
    }

    public int flush () {
        return 0;
    }

    public void rewind () {
        seek (0, FileSeek.SET);
        clearerr ();
    }

    public int seek (long offset, FileSeek whence) {
        if (fd < 0)
            return -1;
        long adj = offset;
        if (whence == FileSeek.CUR && rpos < rlen)
            adj = adj - (long) (rlen - rpos);
        pushback = -1;
        rpos = 0;
        rlen = 0;
        int64 r = c_sys_lseek (fd, (int64) adj, (int) whence);
        if (r < 0) {
            err_flag = 1;
            return -1;
        }
        eof_flag = false;
        return 0;
    }

    public long tell () {
        if (fd < 0)
            return -1;
        int64 r = c_sys_lseek (fd, 0, 1);
        if (r < 0)
            return -1;
        int64 buffered = (int64) (rlen - rpos);
        if (buffered > 0 && r >= buffered)
            r = r - buffered;
        if (pushback >= 0 && r > 0)
            r = r - 1;
        return (long) r;
    }

    private int64 read_retry (uint8[] dst, int count) {
        while (true) {
            int64 n = c_sys_read (fd, dst, count);
            if (n == -4) // EINTR
                continue;
            return n;
        }
    }

    private int refill_rbuf () {
        if (rbuf == null)
            rbuf = new uint8[4096];
        rpos = 0;
        rlen = 0;
        var b = (!) rbuf;
        int64 n = read_retry (b, b.length);
        if (n < 0) {
            err_flag = 1;
            return -1;
        }
        if (n == 0) {
            eof_flag = true;
            return 0;
        }
        rlen = (int) n;
        return rlen;
    }

    public size_t read (uint8[] buf, size_t size = 1) {
        if (fd < 0 || size == 0 || buf.length == 0)
            return 0;
        int want = buf.length;
        int got = 0;
        if (pushback >= 0 && want > 0) {
            buf[0] = (uint8) pushback;
            pushback = -1;
            got = 1;
        }
        if (got < want && rpos < rlen && rbuf != null) {
            var b = (!) rbuf;
            int avail = rlen - rpos;
            int take = (want - got < avail) ? (want - got) : avail;
            for (int i = 0; i < take; i++)
                buf[got + i] = b[rpos + i];
            rpos = rpos + take;
            got = got + take;
        }
        if (got < want) {
            var tmp = new uint8[want - got];
            int64 n = read_retry (tmp, want - got);
            if (n < 0) {
                err_flag = 1;
            } else if (n == 0) {
                eof_flag = true;
            } else {
                for (int i = 0; i < (int) n; i++)
                    buf[got + i] = tmp[i];
                got = got + (int) n;
            }
        }
        return (size_t) ((size > 1) ? (got / (int) size) : got);
    }

    private int write_all_fd (uint8[] data, int len) {
        int off = 0;
        while (off < len) {
            int rem = len - off;
            uint8[] slice;
            if (off == 0) {
                slice = data;
            } else {
                slice = new uint8[rem];
                for (int i = 0; i < rem; i++)
                    slice[i] = data[off + i];
            }
            int64 n = c_sys_write (fd, slice, rem);
            if (n == -4) // EINTR
                continue;
            if (n <= 0) {
                err_flag = 1;
                return off > 0 ? off : -1;
            }
            off = off + (int) n;
        }
        return off;
    }

    public size_t write (uint8[] buf, size_t size = 1) {
        if (fd < 0 || size == 0 || buf.length == 0)
            return 0;
        int w = write_all_fd (buf, buf.length);
        if (w <= 0)
            return 0;
        return (size_t) ((size > 1) ? (w / (int) size) : w);
    }

    public int getc () {
        if (pushback >= 0) {
            int c = pushback;
            pushback = -1;
            return c;
        }
        if (rpos >= rlen) {
            if (refill_rbuf () <= 0)
                return -1;
        }
        var b = (!) rbuf;
        int ch = (int) b[rpos];
        rpos = rpos + 1;
        return ch;
    }

    public int ungetc (int c) {
        if (c < 0)
            return -1;
        pushback = c & 0xff;
        eof_flag = false;
        return pushback;
    }

    public int putc (char c) {
        var b = new uint8[1];
        b[0] = (uint8) c;
        if (write_all_fd (b, 1) != 1)
            return -1;
        return (int) ((uint8) c);
    }

    public int puts (string s) {
        if (s.length == 0)
            return 0;
        return write_all_fd (s.data, s.length);
    }
}

public FileStream? stdin;
public FileStream? stdout;
public FileStream? stderr;

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
    int r = s.close_now ();
    s = null;
    return r;
}

public int c_fclose_val (FileStream? s) {
    if (s == null)
        return -1;
    return s.close_now ();
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

public int c_remove (string path) {
    return c_sys_unlinkat (-100, path, 0) < 0 ? -1 : 0;
}

public int c_rename (string oldpath, string newpath) {
    return c_sys_renameat (-100, oldpath, -100, newpath) < 0 ? -1 : 0;
}
