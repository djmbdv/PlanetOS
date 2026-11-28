// Pure-Vala GLib.Checksum (CRC32, SHA-256) and GLib.Base64 for PlanetOS.
using Planet;

namespace GLib {

    [AsmBody(@"
        # __crc32c_hw(crc in rdi, buf in rsi, n in rdx) -> eax (SSE4.2 crc32q + crc32b)
        mov %edi, %eax
        cmp $8, %rdx
        jb _c32_tail
    _c32_q:
        .byte 0xf2, 0x48, 0x0f, 0x38, 0xf1, 0x06
        add $8, %rsi
        sub $8, %rdx
        cmp $8, %rdx
        jae _c32_q
    _c32_tail:
        test %rdx, %rdx
        jz _c32_done
    _c32_b:
        .byte 0xf2, 0x0f, 0x38, 0xf0, 0x06
        inc %rsi
        dec %rdx
        jnz _c32_b
    _c32_done:
        ret
    ")]
    private extern uint32 __crc32c_hw (uint32 crc, int buf_addr, size_t n);

    public enum ChecksumType {
        CRC32,
        CRC32C,
        SHA256
    }

    /**
     * Incremental cryptographic/error-checking hash (GLib.Checksum).
     */
    public class Checksum : Object {
        private ChecksumType kind;
        private uint32 crc = 0xFFFFFFFFu;
        private uint32[] sha_h = new uint32[8];
        private uint8[] sha_blk = new uint8[64];
        private uint32[] sha_w = new uint32[64];
        private int sha_len = 0;
        private uint64 sha_bits = 0;
        private bool closed = false;
        private string cached_hex = "";

        private static uint32[]? crc_tab;
        private static uint32[]? sha_k;
        private static uint8[]? once_crc;
        private static uint8[]? once_sha;

        private static uint32[] ensure_crc_tab () {
            var oc = once_crc;
            uint8[] cell;
            if (oc == null) {
                cell = new uint8[8];
                once_crc = cell;
            } else {
                cell = oc;
            }
            if (Once.init_enter (Sys.byte_arr_addr (cell))) {
                var t = new uint32[256];
                for (uint32 i = 0; i < 256; i++) {
                    uint32 c = i;
                    for (int b = 0; b < 8; b++)
                        c = ((c & 1u) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
                    t[i] = c;
                }
                crc_tab = t;
                Once.init_leave (Sys.byte_arr_addr (cell), 2);
            }
            var cur = crc_tab;
            return (cur != null) ? cur : new uint32[256];
        }

        private static uint32[] ensure_sha_k () {
            var os = once_sha;
            uint8[] cell;
            if (os == null) {
                cell = new uint8[8];
                once_sha = cell;
            } else {
                cell = os;
            }
            if (Once.init_enter (Sys.byte_arr_addr (cell))) {
                uint32[] k = {
                    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
                    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
                    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
                    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
                    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
                    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
                    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
                    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
                    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
                    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
                    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
                    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
                    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
                    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
                    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
                    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
                };
                sha_k = k;
                Once.init_leave (Sys.byte_arr_addr (cell), 2);
            }
            var cur = sha_k;
            return (cur != null) ? cur : new uint32[64];
        }

        public Checksum (ChecksumType checksum_type) {
            kind = checksum_type;
            reset ();
        }

        public void reset () {
            closed = false;
            cached_hex = "";
            crc = 0xFFFFFFFFu;
            sha_len = 0;
            sha_bits = 0;
            Memory.set (Sys.byte_arr_addr (sha_blk), 0, 64);
            sha_h[0] = 0x6a09e667u; sha_h[1] = 0xbb67ae85u;
            sha_h[2] = 0x3c6ef372u; sha_h[3] = 0xa54ff53au;
            sha_h[4] = 0x510e527fu; sha_h[5] = 0x9b05688cu;
            sha_h[6] = 0x1f83d9abu; sha_h[7] = 0x5be0cd19u;
        }

#if PLANC
        [NoAlloc]
        [AlwaysInline]
        [Wrap]
#endif
        private static uint32 rotr32 (uint32 v, int n) {
            return (v >> n) | (v << (32 - n));
        }

#if PLANC
        [Wrap]
#endif
        private void sha_compress () {
            var k = ensure_sha_k ();
            var w = sha_w;
            for (int i = 0; i < 16; i++) {
                int j = i * 4;
                w[i] = ((uint32) sha_blk[j] << 24) | ((uint32) sha_blk[j + 1] << 16)
                     | ((uint32) sha_blk[j + 2] << 8) | (uint32) sha_blk[j + 3];
            }
            for (int i = 16; i < 64; i++) {
                uint32 s0 = rotr32 (w[i - 15], 7) ^ rotr32 (w[i - 15], 18) ^ (w[i - 15] >> 3);
                uint32 s1 = rotr32 (w[i - 2], 17) ^ rotr32 (w[i - 2], 19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16] + s0 + w[i - 7] + s1;
            }
            uint32 a = sha_h[0]; uint32 b = sha_h[1]; uint32 c = sha_h[2]; uint32 d = sha_h[3];
            uint32 e = sha_h[4]; uint32 f = sha_h[5]; uint32 g = sha_h[6]; uint32 h = sha_h[7];
            for (int i = 0; i < 64; i++) {
                uint32 S1 = rotr32 (e, 6) ^ rotr32 (e, 11) ^ rotr32 (e, 25);
                uint32 ch = (e & f) ^ ((~e) & g);
                uint32 t1 = h + S1 + ch + k[i] + w[i];
                uint32 S0 = rotr32 (a, 2) ^ rotr32 (a, 13) ^ rotr32 (a, 22);
                uint32 maj = (a & b) ^ (a & c) ^ (b & c);
                uint32 t2 = S0 + maj;
                h = g; g = f; f = e; e = d + t1;
                d = c; c = b; b = a; a = t1 + t2;
            }
            sha_h[0] += a; sha_h[1] += b; sha_h[2] += c; sha_h[3] += d;
            sha_h[4] += e; sha_h[5] += f; sha_h[6] += g; sha_h[7] += h;
        }

        public void update (uint8[] data, ssize_t length = -1) {
            if (closed)
                return;
            int n = (length < 0 || (int) length > data.length) ? data.length : (int) length;
            if (n <= 0)
                return;
            if (kind == ChecksumType.CRC32C) {
                crc = __crc32c_hw (crc, Sys.byte_arr_addr (data), (size_t) n);
                return;
            }
            if (kind == ChecksumType.CRC32) {
                var tab = ensure_crc_tab ();
                uint32 c = crc;
                for (int i = 0; i < n; i++)
                    c = tab[(c ^ data[i]) & 0xFFu] ^ (c >> 8);
                crc = c;
                return;
            }
            for (int i = 0; i < n; i++) {
                sha_blk[sha_len++] = data[i];
                sha_bits += 8UL;
                if (sha_len == 64) {
                    sha_compress ();
                    sha_len = 0;
                }
            }
        }

        private void finalize_hash () {
            if (closed)
                return;
            closed = true;
            if (kind == ChecksumType.CRC32 || kind == ChecksumType.CRC32C) {
                crc = crc ^ 0xFFFFFFFFu;
                return;
            }
            sha_blk[sha_len++] = 0x80;
            if (sha_len > 56) {
                while (sha_len < 64)
                    sha_blk[sha_len++] = 0;
                sha_compress ();
                sha_len = 0;
            }
            while (sha_len < 56)
                sha_blk[sha_len++] = 0;
            for (int i = 0; i < 8; i++)
                sha_blk[56 + i] = (uint8) ((sha_bits >> (56 - i * 8)) & 0xFFUL);
            sha_compress ();
        }

        // Raw digest bytes (GLib.Checksum.get_digest). The digest is finalized
        // on the first call, like get_string().
        public uint8[] get_digest (out size_t length) {
            finalize_hash ();
            if (kind == ChecksumType.CRC32 || kind == ChecksumType.CRC32C) {
                var crc_buf = new uint8[4];
                crc_buf[0] = (uint8) ((crc >> 24) & 0xFFu);
                crc_buf[1] = (uint8) ((crc >> 16) & 0xFFu);
                crc_buf[2] = (uint8) ((crc >> 8) & 0xFFu);
                crc_buf[3] = (uint8) (crc & 0xFFu);
                length = 4;
                return crc_buf;
            }
            var out_buf = new uint8[32];
            for (int i = 0; i < 8; i++) {
                uint32 w = sha_h[i];
                out_buf[i * 4 + 0] = (uint8) ((w >> 24) & 0xFFu);
                out_buf[i * 4 + 1] = (uint8) ((w >> 16) & 0xFFu);
                out_buf[i * 4 + 2] = (uint8) ((w >> 8) & 0xFFu);
                out_buf[i * 4 + 3] = (uint8) (w & 0xFFu);
            }
            length = 32;
            return out_buf;
        }

        public string get_string () {
            if (cached_hex.length > 0)
                return cached_hex;
            finalize_hash ();
            string hex = "0123456789abcdef";
            if (kind == ChecksumType.CRC32 || kind == ChecksumType.CRC32C) {
                var buf = new uint8[8];
                for (int i = 0; i < 8; i++)
                    buf[i] = (uint8) hex[(int) ((crc >> (28 - i * 4)) & 0xFu)];
                cached_hex = __planc_host_bytes_to_str (buf, 8);
                return cached_hex;
            }
            var out_buf = new uint8[64];
            for (int i = 0; i < 8; i++) {
                uint32 w = sha_h[i];
                for (int j = 0; j < 8; j++)
                    out_buf[i * 8 + j] = (uint8) hex[(int) ((w >> (28 - j * 4)) & 0xFu)];
            }
            cached_hex = __planc_host_bytes_to_str (out_buf, 64);
            return cached_hex;
        }

        public static string compute_for_string (ChecksumType t, string str) {
            var cs = new Checksum (t);
            var b = new uint8[str.length];
            for (int i = 0; i < str.length; i++)
                b[i] = (uint8) str[i];
            cs.update (b, str.length);
            return cs.get_string ();
        }
    }

    /**
     * Keyed-hash message authentication (GLib.Hmac, RFC 2104). Only the
     * checksum types this runtime implements are accepted; SHA-256 is the
     * intended one.
     */
    public class Hmac : Object {
        private const int BLOCK = 64;

        private ChecksumType kind;
        private uint8[] opad_key = new uint8[0];
        private uint8[] ipad_key = new uint8[0];
        private Checksum inner;
        private bool finished = false;

        public Hmac (ChecksumType digest_type, uint8[] key) {
            kind = digest_type;
            var k = new uint8[BLOCK];
            if (key.length > BLOCK) {
                var hk = new Checksum (digest_type);
                hk.update (key, key.length);
                size_t hl = 0;
                var dig = hk.get_digest (out hl);
                for (int i = 0; i < (int) hl && i < BLOCK; i++)
                    k[i] = dig[i];
            } else {
                for (int i = 0; i < key.length; i++)
                    k[i] = key[i];
            }
            ipad_key = new uint8[BLOCK];
            opad_key = new uint8[BLOCK];
            for (int i = 0; i < BLOCK; i++) {
                ipad_key[i] = (uint8) (k[i] ^ 0x36);
                opad_key[i] = (uint8) (k[i] ^ 0x5C);
            }
            reset ();
        }

        private void reset () {
            inner = new Checksum (kind);
            inner.update (ipad_key, BLOCK);
            finished = false;
        }

        public void update (uint8[] data, ssize_t length = -1) {
            if (finished)
                return;
            inner.update (data, length);
        }

        public uint8[] get_digest_bytes (out size_t length) {
            finished = true;
            size_t inner_len = 0;
            var inner_digest = inner.get_digest (out inner_len);
            var outer = new Checksum (kind);
            outer.update (opad_key, BLOCK);
            outer.update (inner_digest, (ssize_t) inner_len);
            return outer.get_digest (out length);
        }

        public void get_digest (uint8[] buffer, ref size_t digest_len) {
            size_t n = 0;
            var d = get_digest_bytes (out n);
            int want = (int) digest_len;
            int copy_n = (want < (int) n) ? want : (int) n;
            for (int i = 0; i < copy_n; i++)
                buffer[i] = d[i];
            digest_len = n;
        }

        public string get_string () {
            size_t n = 0;
            var d = get_digest_bytes (out n);
            string hex = "0123456789abcdef";
            var out_buf = new uint8[(int) n * 2];
            for (int i = 0; i < (int) n; i++) {
                out_buf[i * 2] = (uint8) hex[(int) ((d[i] >> 4) & 0xF)];
                out_buf[i * 2 + 1] = (uint8) hex[(int) (d[i] & 0xF)];
            }
            return __planc_host_bytes_to_str (out_buf, (int) n * 2);
        }

        public static string compute_for_data (ChecksumType checksum_type, uint8[] key, uint8[] data) {
            var h = new Hmac (checksum_type, key);
            h.update (data, data.length);
            return h.get_string ();
        }

        public static string compute_for_string (ChecksumType checksum_type, uint8[] key, string str, ssize_t length = -1) {
            int n = (length < 0 || (int) length > str.length) ? str.length : (int) length;
            var data_buf = new uint8[n];
            for (int i = 0; i < n; i++)
                data_buf[i] = (uint8) str[i];
            return compute_for_data (checksum_type, key, data_buf);
        }
    }

    /**
     * RFC 4648 Base64 encoding and decoding (GLib.Base64).
     */
    public class Base64 : Object {
        private const string B64_TAB = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

        public static string encode (uint8[] data) {
            int n = data.length;
            if (n == 0)
                return "";
            int out_len = ((n + 2) / 3) * 4;
            var out_buf = new uint8[out_len];
            int oi = 0;
            for (int i = 0; i < n; i += 3) {
                int b0 = (int) data[i];
                int b1 = (i + 1 < n) ? (int) data[i + 1] : 0;
                int b2 = (i + 2 < n) ? (int) data[i + 2] : 0;
                uint32 triple = ((uint32) b0 << 16) | ((uint32) b1 << 8) | (uint32) b2;
                out_buf[oi++] = (uint8) B64_TAB[(int) ((triple >> 18) & 0x3Fu)];
                out_buf[oi++] = (uint8) B64_TAB[(int) ((triple >> 12) & 0x3Fu)];
                out_buf[oi++] = (i + 1 < n) ? (uint8) B64_TAB[(int) ((triple >> 6) & 0x3Fu)] : (uint8) '=';
                out_buf[oi++] = (i + 2 < n) ? (uint8) B64_TAB[(int) (triple & 0x3Fu)] : (uint8) '=';
            }
            return __planc_host_bytes_to_str (out_buf, out_len);
        }

        private static int b64_val (uint8 c) {
            if (c >= 'A' && c <= 'Z') return (int) (c - 'A');
            if (c >= 'a' && c <= 'z') return 26 + (int) (c - 'a');
            if (c >= '0' && c <= '9') return 52 + (int) (c - '0');
            if (c == '+') return 62;
            if (c == '/') return 63;
            return -1;
        }

        public static uint8[] decode (string text) {
            int n = text.length;
            if (n == 0)
                return new uint8[0];
            var tmp = new uint8[(n / 4) * 3 + 3];
            int out_len = 0;
            uint32 acc = 0;
            int bits = 0;
            for (int i = 0; i < n; i++) {
                uint8 c = (uint8) text[i];
                if (c == '=' || c == ' ' || c == '\n' || c == '\r' || c == '\t')
                    continue;
                int v = b64_val (c);
                if (v < 0)
                    continue;
                acc = (acc << 6) | (uint32) v;
                bits += 6;
                if (bits >= 8) {
                    bits -= 8;
                    tmp[out_len++] = (uint8) ((acc >> bits) & 0xFFu);
                }
            }
            var res = new uint8[out_len];
            if (out_len > 0)
                Memory.copy (Sys.byte_arr_addr (res), Sys.byte_arr_addr (tmp), (size_t) out_len);
            return res;
        }
    }
}
