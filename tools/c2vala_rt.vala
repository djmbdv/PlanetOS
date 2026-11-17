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
