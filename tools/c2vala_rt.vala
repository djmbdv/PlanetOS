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
