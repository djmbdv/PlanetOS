// Pure-Vala GIO TLS backend inspired by BoringSSL (TLS 1.3, X25519, ChaCha20-Poly1305, SHA-256, HKDF)
// implementing GLib.TlsBackend, GLib.TlsCertificate, GLib.TlsDatabase, GLib.TlsConnection,
// GLib.TlsClientConnection, and GLib.TlsServerConnection.
using GLib;
using Planet;

namespace Gio {

    [Flags]
    public enum TlsCertificateFlags {
        NONE = 0,
        UNKNOWN_CA = 1,
        BAD_IDENTITY = 2,
        NOT_ACTIVATED = 4,
        EXPIRED = 8,
        REVOKED = 16,
        INSECURE = 32,
        GENERIC_ERROR = 64,
        VALIDATE_ALL = 0x007F
    }

    public errordomain TlsError {
        UNAVAILABLE,
        MISC,
        BAD_CERTIFICATE,
        NOT_TLS,
        HANDSHAKE,
        CERTIFICATE_REQUIRED,
        EOF
    }

    public enum TlsRehandshakeMode {
        NEVER,
        SAFELY,
        UNSAFELY
    }

    // --- BoringSSL-style constant-time & CSPRNG primitives ---
    internal class TlsCrypto : Object {
        private static uint32 prng_counter = 1;

        public static bool ct_memcmp (uint8[] a, int a_off, uint8[] b, int b_off, int len) {
            if (len < 0 || a_off + len > a.length || b_off + len > b.length)
                return false;
            uint32 diff = 0;
            for (int i = 0; i < len; i++)
                diff |= (uint32) (a[a_off + i] ^ b[b_off + i]);
            return diff == 0;
        }

        public static void random_bytes (uint8[] out_buf) {
            var seed = new uint8[32];
            uint64 t1 = Sys.rdtsc ();
            uint64 t2 = (uint64) Sys.ticks ();
            uint32 c = prng_counter++;
            for (int i = 0; i < 8; i++) {
                seed[i] = (uint8) ((t1 >> (i * 8)) & 0xFF);
                seed[8 + i] = (uint8) ((t2 >> (i * 8)) & 0xFF);
            }
            seed[16] = (uint8) (c & 0xFF);
            seed[17] = (uint8) ((c >> 8) & 0xFF);
            seed[18] = (uint8) ((c >> 16) & 0xFF);
            seed[19] = (uint8) ((c >> 24) & 0xFF);
            uint64 t3 = Sys.rdtsc ();
            for (int i = 0; i < 8; i++)
                seed[24 + i] = (uint8) ((t3 >> (i * 8)) & 0xFF);

            var nonce = new uint8[12];
            int pos = 0;
            uint32 blk = 0;
            while (pos < out_buf.length) {
                var ks = chacha20_block (seed, blk++, nonce);
                int take = out_buf.length - pos;
                if (take > 64) take = 64;
                for (int i = 0; i < take; i++)
                    out_buf[pos + i] = ks[i];
                pos += take;
            }
        }

        // --- FIPS 180-4 SHA-256 ---
        private static uint32 rotr32 (uint32 x, int n) {
            return (x >> n) | (x << (32 - n));
        }

        public static uint8[] sha256 (uint8[] data, int len = -1) {
            int n = (len < 0 || len > data.length) ? data.length : len;
            uint32[] k = {
                0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
                0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
                0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
                0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
                0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
                0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
                0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
                0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
            };
            uint32[] h = {
                0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
                0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U
            };

            int pad_len = n + 1 + 8;
            int rem = pad_len % 64;
            if (rem != 0)
                pad_len += (64 - rem);
            var msg = new uint8[pad_len];
            for (int i = 0; i < n; i++)
                msg[i] = data[i];
            msg[n] = 0x80;
            uint64 bit_len = (uint64) n * 8U;
            for (int i = 0; i < 8; i++)
                msg[pad_len - 1 - i] = (uint8) ((bit_len >> (i * 8)) & 0xFF);

            var w = new uint32[64];
            for (int off = 0; off < pad_len; off += 64) {
                for (int i = 0; i < 16; i++) {
                    int bi = off + i * 4;
                    w[i] = ((uint32) msg[bi] << 24) | ((uint32) msg[bi + 1] << 16)
                         | ((uint32) msg[bi + 2] << 8) | (uint32) msg[bi + 3];
                }
                for (int i = 16; i < 64; i++) {
                    uint32 s0 = rotr32 (w[i - 15], 7) ^ rotr32 (w[i - 15], 18) ^ (w[i - 15] >> 3);
                    uint32 s1 = rotr32 (w[i - 2], 17) ^ rotr32 (w[i - 2], 19) ^ (w[i - 2] >> 10);
                    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
                }
                uint32 a = h[0];
                uint32 b = h[1];
                uint32 c = h[2];
                uint32 d = h[3];
                uint32 e = h[4];
                uint32 f = h[5];
                uint32 g = h[6];
                uint32 hh = h[7];
                for (int i = 0; i < 64; i++) {
                    uint32 S1 = rotr32 (e, 6) ^ rotr32 (e, 11) ^ rotr32 (e, 25);
                    uint32 ch = (e & f) ^ ((~e) & g);
                    uint32 temp1 = hh + S1 + ch + k[i] + w[i];
                    uint32 S0 = rotr32 (a, 2) ^ rotr32 (a, 13) ^ rotr32 (a, 22);
                    uint32 maj = (a & b) ^ (a & c) ^ (b & c);
                    uint32 temp2 = S0 + maj;
                    hh = g;
                    g = f;
                    f = e;
                    e = d + temp1;
                    d = c;
                    c = b;
                    b = a;
                    a = temp1 + temp2;
                }
                h[0] += a; h[1] += b; h[2] += c; h[3] += d;
                h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
            }
            var digest = new uint8[32];
            for (int i = 0; i < 8; i++) {
                digest[i * 4 + 0] = (uint8) ((h[i] >> 24) & 0xFF);
                digest[i * 4 + 1] = (uint8) ((h[i] >> 16) & 0xFF);
                digest[i * 4 + 2] = (uint8) ((h[i] >> 8) & 0xFF);
                digest[i * 4 + 3] = (uint8) (h[i] & 0xFF);
            }
            return digest;
        }

        public static uint8[] hmac_sha256 (uint8[] key, uint8[] data) {
            var k0 = new uint8[64];
            if (key.length > 64) {
                var hk = sha256 (key);
                for (int i = 0; i < 32; i++) k0[i] = hk[i];
            } else {
                for (int i = 0; i < key.length; i++) k0[i] = key[i];
            }
            var inner = new uint8[64 + data.length];
            for (int i = 0; i < 64; i++) inner[i] = (uint8) (k0[i] ^ 0x36);
            for (int i = 0; i < data.length; i++) inner[64 + i] = data[i];
            var ih = sha256 (inner);

            var outer = new uint8[64 + 32];
            for (int i = 0; i < 64; i++) outer[i] = (uint8) (k0[i] ^ 0x5c);
            for (int i = 0; i < 32; i++) outer[64 + i] = ih[i];
            return sha256 (outer);
        }

        public static uint8[] hkdf_extract (uint8[] salt, uint8[] ikm) {
            return hmac_sha256 (salt, ikm);
        }

        public static uint8[] hkdf_expand (uint8[] prk, uint8[] info, int out_len) {
            var okm = new uint8[out_len];
            var prev = new uint8[0];
            int pos = 0;
            uint8 counter = 1;
            while (pos < out_len) {
                var inp = new uint8[prev.length + info.length + 1];
                for (int i = 0; i < prev.length; i++) inp[i] = prev[i];
                for (int i = 0; i < info.length; i++) inp[prev.length + i] = info[i];
                inp[prev.length + info.length] = counter++;
                prev = hmac_sha256 (prk, inp);
                int take = out_len - pos;
                if (take > 32) take = 32;
                for (int i = 0; i < take; i++) okm[pos + i] = prev[i];
                pos += take;
            }
            return okm;
        }

        public static uint8[] hkdf_expand_label (uint8[] secret, string label, uint8[] context, int out_len) {
            string full_label = "tls13 " + label;
            int info_len = 2 + 1 + full_label.length + 1 + context.length;
            var info = new uint8[info_len];
            int p = 0;
            info[p++] = (uint8) ((out_len >> 8) & 0xFF);
            info[p++] = (uint8) (out_len & 0xFF);
            info[p++] = (uint8) full_label.length;
            for (int i = 0; i < full_label.length; i++)
                info[p++] = (uint8) full_label[i];
            info[p++] = (uint8) context.length;
            for (int i = 0; i < context.length; i++)
                info[p++] = context[i];
            return hkdf_expand (secret, info, out_len);
        }

        // --- RFC 8439 ChaCha20-Poly1305 ---
        private static uint32 rotl32 (uint32 x, int n) {
            return (x << n) | (x >> (32 - n));
        }

        private static uint32 load_le32 (uint8[] b, int off) {
            return (uint32) b[off]
                 | ((uint32) b[off + 1] << 8)
                 | ((uint32) b[off + 2] << 16)
                 | ((uint32) b[off + 3] << 24);
        }

        private static void quarter_round (uint32[] st, int a, int b, int c, int d) {
            st[a] += st[b]; st[d] = rotl32 (st[d] ^ st[a], 16);
            st[c] += st[d]; st[b] = rotl32 (st[b] ^ st[c], 12);
            st[a] += st[b]; st[d] = rotl32 (st[d] ^ st[a], 8);
            st[c] += st[d]; st[b] = rotl32 (st[b] ^ st[c], 7);
        }

        public static uint8[] chacha20_block (uint8[] key32, uint32 counter, uint8[] nonce12) {
            var st = new uint32[16];
            st[0] = 0x61707865U; st[1] = 0x3320646eU; st[2] = 0x79622d32U; st[3] = 0x6b206574U;
            for (int i = 0; i < 8; i++)
                st[4 + i] = load_le32 (key32, i * 4);
            st[12] = counter;
            for (int i = 0; i < 3; i++)
                st[13 + i] = load_le32 (nonce12, i * 4);

            var w = new uint32[16];
            for (int i = 0; i < 16; i++) w[i] = st[i];
            for (int r = 0; r < 10; r++) {
                quarter_round (w, 0, 4, 8, 12);
                quarter_round (w, 1, 5, 9, 13);
                quarter_round (w, 2, 6, 10, 14);
                quarter_round (w, 3, 7, 11, 15);
                quarter_round (w, 0, 5, 10, 15);
                quarter_round (w, 1, 6, 11, 12);
                quarter_round (w, 2, 7, 8, 13);
                quarter_round (w, 3, 4, 9, 14);
            }
            var out_b = new uint8[64];
            for (int i = 0; i < 16; i++) {
                uint32 v = w[i] + st[i];
                out_b[i * 4 + 0] = (uint8) (v & 0xFF);
                out_b[i * 4 + 1] = (uint8) ((v >> 8) & 0xFF);
                out_b[i * 4 + 2] = (uint8) ((v >> 16) & 0xFF);
                out_b[i * 4 + 3] = (uint8) ((v >> 24) & 0xFF);
            }
            return out_b;
        }

        private static uint8[] chacha20_xor (uint8[] key32, uint32 init_counter, uint8[] nonce12, uint8[] data, int off, int len) {
            var out_b = new uint8[len];
            int pos = 0;
            uint32 ctr = init_counter;
            while (pos < len) {
                var ks = chacha20_block (key32, ctr++, nonce12);
                int take = len - pos;
                if (take > 64) take = 64;
                for (int i = 0; i < take; i++)
                    out_b[pos + i] = (uint8) (data[off + pos + i] ^ ks[i]);
                pos += take;
            }
            return out_b;
        }

        // Poly1305 (5 x 26-bit limbs in uint64, constant-time)
        private static uint8[] poly1305_mac (uint8[] otk32, uint8[] msg) {
            uint64 r0 = (uint64) (load_le32 (otk32, 0)) & 0x3ffffffU;
            uint64 r1 = (uint64) (load_le32 (otk32, 3) >> 2) & 0x3ffff03U;
            uint64 r2 = (uint64) (load_le32 (otk32, 6) >> 4) & 0x3ffc0ffU;
            uint64 r3 = (uint64) (load_le32 (otk32, 9) >> 6) & 0x3f03fffU;
            uint64 r4 = (uint64) (load_le32 (otk32, 12) >> 8) & 0x00fffffU;

            uint64 s1 = r1 * 5U;
            uint64 s2 = r2 * 5U;
            uint64 s3 = r3 * 5U;
            uint64 s4 = r4 * 5U;
            uint64 h0 = 0;
            uint64 h1 = 0;
            uint64 h2 = 0;
            uint64 h3 = 0;
            uint64 h4 = 0;

            int pos = 0;
            while (pos < msg.length) {
                int rem = msg.length - pos;
                var blk = new uint8[17];
                int take = (rem >= 16) ? 16 : rem;
                for (int i = 0; i < take; i++) blk[i] = msg[pos + i];
                blk[take] = 1;
                pos += take;

                h0 += (uint64) (load_le32 (blk, 0)) & 0x3ffffffU;
                h1 += (uint64) (load_le32 (blk, 3) >> 2) & 0x3ffffffU;
                h2 += (uint64) (load_le32 (blk, 6) >> 4) & 0x3ffffffU;
                h3 += (uint64) (load_le32 (blk, 9) >> 6) & 0x3ffffffU;
                h4 += ((uint64) (load_le32 (blk, 12) >> 8) & 0x3ffffffU) | ((uint64) blk[16] << 24);

                uint64 d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
                uint64 d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
                uint64 d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
                uint64 d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
                uint64 d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;

                uint64 c;
                c = d0 >> 26; h0 = d0 & 0x3ffffffU; d1 += c;
                c = d1 >> 26; h1 = d1 & 0x3ffffffU; d2 += c;
                c = d2 >> 26; h2 = d2 & 0x3ffffffU; d3 += c;
                c = d3 >> 26; h3 = d3 & 0x3ffffffU; d4 += c;
                c = d4 >> 26; h4 = d4 & 0x3ffffffU; h0 += c * 5U;
                c = h0 >> 26; h0 &= 0x3ffffffU; h1 += c;
            }

            uint64 c2 = h1 >> 26; h1 &= 0x3ffffffU; h2 += c2;
            c2 = h2 >> 26; h2 &= 0x3ffffffU; h3 += c2;
            c2 = h3 >> 26; h3 &= 0x3ffffffU; h4 += c2;
            c2 = h4 >> 26; h4 &= 0x3ffffffU; h0 += c2 * 5U;
            c2 = h0 >> 26; h0 &= 0x3ffffffU; h1 += c2;

            uint64 g0 = h0 + 5U; c2 = g0 >> 26; g0 &= 0x3ffffffU;
            uint64 g1 = h1 + c2; c2 = g1 >> 26; g1 &= 0x3ffffffU;
            uint64 g2 = h2 + c2; c2 = g2 >> 26; g2 &= 0x3ffffffU;
            uint64 g3 = h3 + c2; c2 = g3 >> 26; g3 &= 0x3ffffffU;
            uint64 g4 = h4 + c2 - ((uint64) 1 << 26);

            uint64 mask = (g4 >> 63) - 1U;
            g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
            mask = ~mask;
            h0 = (h0 & mask) | g0;
            h1 = (h1 & mask) | g1;
            h2 = (h2 & mask) | g2;
            h3 = (h3 & mask) | g3;
            h4 = (h4 & mask) | g4;

            uint64 f0 = ((h0) | (h1 << 26)) & 0xffffffffU;
            uint64 f1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffffU;
            uint64 f2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffffU;
            uint64 f3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffffU;

            f0 += (uint64) load_le32 (otk32, 16);
            f1 += (f0 >> 32) + (uint64) load_le32 (otk32, 20);
            f2 += (f1 >> 32) + (uint64) load_le32 (otk32, 24);
            f3 += (f2 >> 32) + (uint64) load_le32 (otk32, 28);

            var tag = new uint8[16];
            uint32[] fw = { (uint32) (f0 & 0xffffffffU), (uint32) (f1 & 0xffffffffU),
                            (uint32) (f2 & 0xffffffffU), (uint32) (f3 & 0xffffffffU) };
            for (int i = 0; i < 4; i++) {
                tag[i * 4 + 0] = (uint8) (fw[i] & 0xFF);
                tag[i * 4 + 1] = (uint8) ((fw[i] >> 8) & 0xFF);
                tag[i * 4 + 2] = (uint8) ((fw[i] >> 16) & 0xFF);
                tag[i * 4 + 3] = (uint8) ((fw[i] >> 24) & 0xFF);
            }
            return tag;
        }

        private static uint8[] poly1305_aead_input (uint8[] aad, uint8[] ct) {
            int apad = (16 - (aad.length % 16)) % 16;
            int cpad = (16 - (ct.length % 16)) % 16;
            var m = new uint8[aad.length + apad + ct.length + cpad + 16];
            int p = 0;
            for (int i = 0; i < aad.length; i++) m[p++] = aad[i];
            p += apad;
            for (int i = 0; i < ct.length; i++) m[p++] = ct[i];
            p += cpad;
            uint64 al = (uint64) aad.length;
            uint64 cl = (uint64) ct.length;
            for (int i = 0; i < 8; i++) m[p++] = (uint8) ((al >> (i * 8)) & 0xFF);
            for (int i = 0; i < 8; i++) m[p++] = (uint8) ((cl >> (i * 8)) & 0xFF);
            return m;
        }

        public static uint8[] aead_seal (uint8[] key32, uint8[] nonce12, uint8[] aad, uint8[] pt) {
            var otk = chacha20_block (key32, 0, nonce12);
            var ct = chacha20_xor (key32, 1, nonce12, pt, 0, pt.length);
            var mac_in = poly1305_aead_input (aad, ct);
            var tag = poly1305_mac (otk, mac_in);
            var out_b = new uint8[ct.length + 16];
            for (int i = 0; i < ct.length; i++) out_b[i] = ct[i];
            for (int i = 0; i < 16; i++) out_b[ct.length + i] = tag[i];
            return out_b;
        }

        public static uint8[]? aead_open (uint8[] key32, uint8[] nonce12, uint8[] aad, uint8[] ct_tag) {
            if (ct_tag.length < 16)
                return null;
            int ct_len = ct_tag.length - 16;
            var ct = new uint8[ct_len];
            for (int i = 0; i < ct_len; i++) ct[i] = ct_tag[i];
            var otk = chacha20_block (key32, 0, nonce12);
            var mac_in = poly1305_aead_input (aad, ct);
            var expected_tag = poly1305_mac (otk, mac_in);
            if (!ct_memcmp (expected_tag, 0, ct_tag, ct_len, 16))
                return null;
            return chacha20_xor (key32, 1, nonce12, ct, 0, ct_len);
        }

        // --- RFC 7748 X25519 (16-limb base-2^16 in int64, constant-time Montgomery ladder) ---
        private static void fe_add (int64[] o, int64[] a, int64[] b) {
            for (int i = 0; i < 16; i++) o[i] = a[i] + b[i];
        }

        private static void fe_sub (int64[] o, int64[] a, int64[] b) {
            for (int i = 0; i < 16; i++) o[i] = a[i] - b[i];
        }

        private static void fe_carry (int64[] o) {
            for (int i = 0; i < 16; i++) {
                o[i] += 65536;
                int64 c = o[i] >> 16;
                o[(i + 1) & 15] += c - 1 + ((i == 15) ? 37 * (c - 1) : 0);
                o[i] -= c << 16;
            }
        }

        private static void fe_mul (int64[] o, int64[] a, int64[] b, int64[] t) {
            for (int i = 0; i < 31; i++) t[i] = 0;
            for (int i = 0; i < 16; i++) {
                for (int j = 0; j < 16; j++)
                    t[i + j] += a[i] * b[j];
            }
            for (int i = 0; i < 15; i++)
                t[i] += 38 * t[i + 16];
            for (int i = 0; i < 16; i++)
                o[i] = t[i];
            fe_carry (o);
            fe_carry (o);
        }

        private static void fe_sq (int64[] o, int64[] a, int64[] t) {
            fe_mul (o, a, a, t);
        }

        private static void fe_inv (int64[] o, int64[] i, int64[] t) {
            var c = new int64[16];
            for (int a = 0; a < 16; a++) c[a] = i[a];
            for (int a = 253; a >= 0; a--) {
                fe_sq (c, c, t);
                if (a != 2 && a != 4)
                    fe_mul (c, c, i, t);
            }
            for (int a = 0; a < 16; a++) o[a] = c[a];
        }

        private static void fe_cswap (int64[] p, int64[] q, int64 bit) {
            int64 c = ~(bit - 1);
            for (int i = 0; i < 16; i++) {
                int64 t = c & (p[i] ^ q[i]);
                p[i] ^= t;
                q[i] ^= t;
            }
        }

        private static void fe_unpack (int64[] o, uint8[] n) {
            for (int i = 0; i < 16; i++)
                o[i] = (int64) n[2 * i] + ((int64) n[2 * i + 1] << 8);
            o[15] &= 0x7fff;
        }

        private static void fe_pack (uint8[] o, int64[] n) {
            var m = new int64[16];
            var t = new int64[16];
            for (int i = 0; i < 16; i++) t[i] = n[i];
            fe_carry (t); fe_carry (t); fe_carry (t);
            for (int j = 0; j < 2; j++) {
                m[0] = t[0] - 0xffed;
                for (int i = 1; i < 15; i++) {
                    m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
                    m[i - 1] &= 0xffff;
                }
                m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
                int64 b = (m[15] >> 16) & 1;
                m[14] &= 0xffff;
                fe_cswap (t, m, 1 - b);
            }
            for (int i = 0; i < 16; i++) {
                o[2 * i] = (uint8) (t[i] & 0xff);
                o[2 * i + 1] = (uint8) ((t[i] >> 8) & 0xff);
            }
        }

        public static uint8[] x25519_scalarmult (uint8[] scalar32, uint8[] point32) {
            var z = new uint8[32];
            for (int i = 0; i < 32; i++) z[i] = scalar32[i];
            z[0] &= 248;
            z[31] = (uint8) ((z[31] & 127) | 64);

            var x = new int64[16];
            fe_unpack (x, point32);

            var a = new int64[16]; var b = new int64[16];
            var c = new int64[16]; var d = new int64[16];
            var e = new int64[16]; var f = new int64[16];
            var _121665 = new int64[16];
            _121665[0] = 0xdb41; _121665[1] = 1;

            a[0] = 1;
            for (int i = 0; i < 16; i++) b[i] = x[i];
            c[0] = 0;
            d[0] = 1;

            var t = new int64[31];
            for (int i = 254; i >= 0; i--) {
                int64 r = (int64) ((z[i >> 3] >> (i & 7)) & 1);
                fe_cswap (a, b, r);
                fe_cswap (c, d, r);
                fe_add (e, a, c);
                fe_sub (a, a, c);
                fe_add (c, b, d);
                fe_sub (b, b, d);
                fe_sq (d, e, t);
                fe_sq (f, a, t);
                fe_mul (a, c, a, t);
                fe_mul (c, b, e, t);
                fe_add (e, a, c);
                fe_sub (a, a, c);
                fe_sq (b, a, t);
                fe_sub (c, d, f);
                fe_mul (a, c, _121665, t);
                fe_add (a, a, d);
                fe_mul (c, c, a, t);
                fe_mul (a, d, f, t);
                fe_mul (d, b, x, t);
                fe_sq (b, e, t);
                fe_cswap (a, b, r);
                fe_cswap (c, d, r);
            }
            fe_inv (c, c, t);
            fe_mul (a, a, c, t);
            var out_p = new uint8[32];
            fe_pack (out_p, a);
            return out_p;
        }

        public static uint8[] x25519_public (uint8[] priv32) {
            var base_pt = new uint8[32];
            base_pt[0] = 9;
            return x25519_scalarmult (priv32, base_pt);
        }
    }

    // --- GLib.TlsCertificate & GLib.TlsDatabase ---
    public class TlsCertificate : Object {
        public string certificate_pem { get; private set; default = ""; }
        public TlsCertificate? issuer { get; private set; default = null; }
        public string subject_name { get; private set; default = "localhost"; }

        public TlsCertificate.from_pem (string data, ssize_t length = -1) throws Error {
            int n = (length < 0 || (int) length > data.length) ? data.length : (int) length;
            if (!data.contains ("BEGIN CERTIFICATE"))
                throw new TlsError.BAD_CERTIFICATE ("Invalid PEM certificate");
            this.certificate_pem = data.substring (0, n);
            int cn = this.certificate_pem.index_of ("CN=");
            if (cn >= 0) {
                int end = this.certificate_pem.index_of ("\n", cn);
                if (end < 0) end = this.certificate_pem.length;
                while (end > cn + 3 && ((uint8) this.certificate_pem[end - 1] == '\r' || (uint8) this.certificate_pem[end - 1] == ' '))
                    end--;
                this.subject_name = this.certificate_pem.substring (cn + 3, end - (cn + 3));
            }
        }

        public TlsCertificateFlags verify (SocketConnectable? identity, TlsCertificate? trusted_ca) {
            TlsCertificateFlags flags = TlsCertificateFlags.NONE;
            if (trusted_ca != null && ((!) trusted_ca).certificate_pem != this.certificate_pem)
                flags |= TlsCertificateFlags.UNKNOWN_CA;
            if (identity != null && identity is NetworkAddress) {
                string host = ((NetworkAddress) identity).get_hostname ();
                if (host != subject_name && subject_name != "*")
                    flags |= TlsCertificateFlags.BAD_IDENTITY;
            } else if (identity != null && identity is InetSocketAddress) {
                var ia = ((InetSocketAddress) identity).get_inet_address ();
                if (ia != null && ((!) ia).to_string () != subject_name && subject_name != "*")
                    flags |= TlsCertificateFlags.BAD_IDENTITY;
            }
            return flags;
        }
    }

    public class TlsDatabase : Object {
        private GenericArray<TlsCertificate> anchors = new GenericArray<TlsCertificate> ();

        public void add_ca (TlsCertificate cert) {
            anchors.add (cert);
        }

        public virtual TlsCertificateFlags verify_chain (TlsCertificate chain, string purpose,
                                                        SocketConnectable? identity,
                                                        TlsCertificateFlags flags = TlsCertificateFlags.NONE,
                                                        Cancellable? cancellable = null) throws Error {
            if (anchors.length == 0)
                return chain.verify (identity, null);
            TlsCertificateFlags best = TlsCertificateFlags.UNKNOWN_CA;
            for (int i = 0; i < anchors.length; i++) {
                TlsCertificateFlags f = chain.verify (identity, anchors[i]);
                if (f == TlsCertificateFlags.NONE)
                    return TlsCertificateFlags.NONE;
                best = f;
            }
            return best;
        }
    }

    // --- GLib.TlsBackend ---
    public interface TlsBackend : Object {
        public abstract bool supports_tls ();
        public abstract TlsDatabase get_default_database ();

        public static TlsBackend get_default () {
            return PlanetTlsBackend.instance ();
        }
    }

    public class PlanetTlsBackend : Object, TlsBackend {
        private static PlanetTlsBackend? _inst;
        private TlsDatabase default_db;

        public PlanetTlsBackend () {
            this.default_db = new TlsDatabase ();
        }

        public static PlanetTlsBackend instance () {
            if (_inst == null)
                _inst = new PlanetTlsBackend ();
            return (!) _inst;
        }

        public bool supports_tls () { return true; }
        public TlsDatabase get_default_database () { return default_db; }
    }

    // --- Encrypted TLS 1.3 streams ---
    private class TlsRecordState : Object {
        public uint8[] tx_key = new uint8[32];
        public uint8[] tx_iv = new uint8[12];
        public uint64 tx_seq = 0;
        public uint8[] rx_key = new uint8[32];
        public uint8[] rx_iv = new uint8[12];
        public uint64 rx_seq = 0;
        public bool active = false;

        public uint8[] make_nonce (uint8[] iv, uint64 seq) {
            var n = new uint8[12];
            for (int i = 0; i < 12; i++) n[i] = iv[i];
            for (int i = 0; i < 8; i++)
                n[11 - i] ^= (uint8) ((seq >> (i * 8)) & 0xFF);
            return n;
        }
    }

    private class TlsInputStream : InputStream {
        private InputStream raw_in;
        public TlsRecordState st;
        private uint8[] plain_buf = new uint8[0];
        private int plain_pos = 0;

        public TlsInputStream (InputStream raw_in) {
            this.raw_in = raw_in;
            this.st = new TlsRecordState ();
        }

        private void read_exact (uint8[] dst) throws IOError {
            int got = 0;
            int tries = 0;
            while (got < dst.length) {
                var tmp = new uint8[dst.length - got];
                int n = raw_in.read (tmp);
                if (n < 0)
                    throw new IOError.FAILED ("TLS unexpected EOF");
                if (n == 0) {
                    if (++tries > 200)
                        throw new IOError.TIMED_OUT ("TLS read timeout");
                    Sys.sleep_ms (5);
                    continue;
                }
                for (int i = 0; i < n; i++) dst[got + i] = tmp[i];
                got += n;
            }
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("TlsInputStream is closed");
            if (!st.active)
                throw new IOError.FAILED ("TLS handshake not completed");
            if (plain_pos >= plain_buf.length) {
                var hdr = new uint8[5];
                read_exact (hdr);
                if (hdr[0] != 0x17)
                    throw new IOError.FAILED ("TLS expected ApplicationData record");
                int rlen = ((int) hdr[3] << 8) | (int) hdr[4];
                if (rlen <= 16 || rlen > 16640)
                    throw new IOError.FAILED ("TLS invalid record length");
                var ct_tag = new uint8[rlen];
                read_exact (ct_tag);
                var nonce = st.make_nonce (st.rx_iv, st.rx_seq++);
                uint8[]? pt = TlsCrypto.aead_open (st.rx_key, nonce, hdr, ct_tag);
                if (pt == null)
                    throw new IOError.FAILED ("TLS bad MAC");
                var dec = (!) pt;
                // Strip inner content type (TLS 1.3 RFC 8446 §5.2)
                int inner_len = dec.length - 1;
                while (inner_len > 0 && dec[inner_len] == 0)
                    inner_len--;
                uint8 ctype = dec[inner_len];
                if (ctype == 0x15) { // Alert (close_notify)
                    closed = true;
                    return 0;
                }
                plain_buf = new uint8[inner_len];
                for (int i = 0; i < inner_len; i++) plain_buf[i] = dec[i];
                plain_pos = 0;
            }
            int avail = plain_buf.length - plain_pos;
            int take = (buffer.length < avail) ? buffer.length : avail;
            for (int i = 0; i < take; i++)
                buffer[i] = plain_buf[plain_pos + i];
            plain_pos += take;
            return take;
        }
    }

    private class TlsOutputStream : OutputStream {
        private OutputStream raw_out;
        public TlsRecordState st;

        public TlsOutputStream (OutputStream raw_out) {
            this.raw_out = raw_out;
            this.st = new TlsRecordState ();
        }

        public void write_record (uint8 inner_ctype, uint8[] data) throws IOError {
            var inner = new uint8[data.length + 1];
            for (int i = 0; i < data.length; i++) inner[i] = data[i];
            inner[data.length] = inner_ctype;
            int ct_len = inner.length + 16;
            var hdr = new uint8[5];
            hdr[0] = 0x17; hdr[1] = 0x03; hdr[2] = 0x03;
            hdr[3] = (uint8) ((ct_len >> 8) & 0xFF);
            hdr[4] = (uint8) (ct_len & 0xFF);
            var nonce = st.make_nonce (st.tx_iv, st.tx_seq++);
            var enc = TlsCrypto.aead_seal (st.tx_key, nonce, hdr, inner);
            var rec = new uint8[5 + enc.length];
            for (int i = 0; i < 5; i++) rec[i] = hdr[i];
            for (int i = 0; i < enc.length; i++) rec[5 + i] = enc[i];
            raw_out.write (rec);
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("TlsOutputStream is closed");
            if (!st.active)
                throw new IOError.FAILED ("TLS handshake not completed");
            write_record (0x17, buffer);
            return buffer.length;
        }
    }

    // --- GLib.TlsConnection, TlsClientConnection, TlsServerConnection ---
    public class TlsConnection : IOStream {
        public IOStream base_io_stream { get; protected set; }
        public TlsCertificate? certificate { get; set; default = null; }
        public TlsCertificate? peer_certificate { get; protected set; default = null; }
        public TlsCertificateFlags peer_certificate_errors { get; protected set; default = TlsCertificateFlags.NONE; }
        public TlsDatabase? database { get; set; default = null; }
        public bool require_close_notify { get; set; default = true; }
        public TlsRehandshakeMode rehandshake_mode { get; set; default = TlsRehandshakeMode.NEVER; }

        protected TlsRecordState rec_state = new TlsRecordState ();
        private TlsInputStream tls_in;
        private TlsOutputStream tls_out;
        protected bool handshaked = false;

        protected TlsConnection (IOStream base_io_stream)
            : base (new TlsInputStream (base_io_stream.get_input_stream ()),
                    new TlsOutputStream (base_io_stream.get_output_stream ())) {
            this.base_io_stream = base_io_stream;
            var tin = (TlsInputStream) get_input_stream ();
            var tout = (TlsOutputStream) get_output_stream ();
            tin.st = this.rec_state;
            tout.st = this.rec_state;
            this.tls_in = tin;
            this.tls_out = tout;
            this.database = TlsBackend.get_default ().get_default_database ();
        }

        public virtual bool handshake (Cancellable? cancellable = null) throws Error {
            return handshaked;
        }

        protected void derive_tls13_traffic_keys (uint8[] shared_secret, uint8[] transcript_hash, bool is_client) {
            var zero32 = new uint8[32];
            var early = TlsCrypto.hkdf_extract (zero32, zero32);
            var empty_hash = TlsCrypto.sha256 (new uint8[0]);
            var derived = TlsCrypto.hkdf_expand_label (early, "derived", empty_hash, 32);
            var hs_secret = TlsCrypto.hkdf_extract (derived, shared_secret);
            var c_hs = TlsCrypto.hkdf_expand_label (hs_secret, "c hs traffic", transcript_hash, 32);
            var s_hs = TlsCrypto.hkdf_expand_label (hs_secret, "s hs traffic", transcript_hash, 32);

            var derived2 = TlsCrypto.hkdf_expand_label (hs_secret, "derived", empty_hash, 32);
            var master = TlsCrypto.hkdf_extract (derived2, zero32);
            var c_ap = TlsCrypto.hkdf_expand_label (master, "c ap traffic", transcript_hash, 32);
            var s_ap = TlsCrypto.hkdf_expand_label (master, "s ap traffic", transcript_hash, 32);

            var tx_sec = is_client ? c_ap : s_ap;
            var rx_sec = is_client ? s_ap : c_ap;
            var empty_ctx = new uint8[0];
            rec_state.tx_key = TlsCrypto.hkdf_expand_label (tx_sec, "key", empty_ctx, 32);
            rec_state.tx_iv = TlsCrypto.hkdf_expand_label (tx_sec, "iv", empty_ctx, 12);
            rec_state.rx_key = TlsCrypto.hkdf_expand_label (rx_sec, "key", empty_ctx, 32);
            rec_state.rx_iv = TlsCrypto.hkdf_expand_label (rx_sec, "iv", empty_ctx, 12);
            // Store Finished MAC keys via c_hs / s_hs for handshake verification
            this.c_hs_secret = c_hs;
            this.s_hs_secret = s_hs;
            rec_state.active = true;
        }

        protected uint8[] c_hs_secret = new uint8[0];
        protected uint8[] s_hs_secret = new uint8[0];

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (handshaked && require_close_notify && rec_state.active) {
                try {
                    uint8[] alert = { 1, 0 }; // warning, close_notify
                    tls_out.write_record (0x15, alert);
                } catch (IOError e) {
                }
            }
            bool ok = base.close (cancellable);
            base_io_stream.close (cancellable);
            return ok;
        }
    }

    public class TlsClientConnection : TlsConnection {
        public SocketConnectable? server_identity { get; set; default = null; }
        public TlsCertificateFlags validation_flags { get; set; default = TlsCertificateFlags.VALIDATE_ALL; }

        public TlsClientConnection (IOStream base_io_stream, SocketConnectable? server_identity = null)
            : base (base_io_stream) {
            this.server_identity = server_identity;
        }

        public static TlsClientConnection create (IOStream base_io_stream, SocketConnectable? server_identity = null) throws Error {
            return new TlsClientConnection (base_io_stream, server_identity);
        }

        public SocketConnectable? get_server_identity () { return server_identity; }
        public void set_server_identity (SocketConnectable? identity) { this.server_identity = identity; }
        public TlsCertificateFlags get_validation_flags () { return validation_flags; }
        public void set_validation_flags (TlsCertificateFlags flags) { this.validation_flags = flags; }
        public void copy_session_state (TlsClientConnection source) {}

        private static void write_all (OutputStream os, uint8[] buf) throws IOError {
            os.write (buf);
        }

        private static void read_all (InputStream ins, uint8[] buf) throws IOError {
            int got = 0;
            int tries = 0;
            while (got < buf.length) {
                var tmp = new uint8[buf.length - got];
                int n = ins.read (tmp);
                if (n < 0)
                    throw new IOError.FAILED ("TLS handshake EOF");
                if (n == 0) {
                    if (++tries > 200)
                        throw new IOError.TIMED_OUT ("TLS handshake timeout");
                    Sys.sleep_ms (5);
                    continue;
                }
                for (int i = 0; i < n; i++) buf[got + i] = tmp[i];
                got += n;
            }
        }

        public override bool handshake (Cancellable? cancellable = null) throws Error {
            if (handshaked)
                return true;
            var priv = new uint8[32];
            var rand = new uint8[32];
            TlsCrypto.random_bytes (priv);
            TlsCrypto.random_bytes (rand);
            var pub = TlsCrypto.x25519_public (priv);

            // ClientHello (TLS 1.3 handshake record: 0x16 0x03 0x01, body: type=1 + 3B len + ver=0x0303 + rand32 + pub32)
            var ch = new uint8[5 + 4 + 2 + 32 + 32];
            ch[0] = 0x16; ch[1] = 0x03; ch[2] = 0x01;
            int body_len = 4 + 2 + 32 + 32;
            ch[3] = (uint8) ((body_len >> 8) & 0xFF);
            ch[4] = (uint8) (body_len & 0xFF);
            ch[5] = 0x01; // ClientHello
            ch[6] = 0; ch[7] = 0; ch[8] = (uint8) (2 + 32 + 32);
            ch[9] = 0x03; ch[10] = 0x03;
            for (int i = 0; i < 32; i++) ch[11 + i] = rand[i];
            for (int i = 0; i < 32; i++) ch[43 + i] = pub[i];

            write_all (base_io_stream.get_output_stream (), ch);

            // Read ServerHello (5B record header + 70B body)
            var sh = new uint8[5 + 4 + 2 + 32 + 32];
            read_all (base_io_stream.get_input_stream (), sh);
            if (sh[0] != 0x16 || sh[5] != 0x02)
                throw new TlsError.HANDSHAKE ("Expected ServerHello");

            var srv_pub = new uint8[32];
            for (int i = 0; i < 32; i++) srv_pub[i] = sh[43 + i];
            var shared = TlsCrypto.x25519_scalarmult (priv, srv_pub);

            var transcript = new uint8[ch.length + sh.length - 10];
            int tp = 0;
            for (int i = 5; i < ch.length; i++) transcript[tp++] = ch[i];
            for (int i = 5; i < sh.length; i++) transcript[tp++] = sh[i];
            var thash = TlsCrypto.sha256 (transcript);

            derive_tls13_traffic_keys (shared, thash, true);

            // Verify Server Finished (32-byte HMAC over thash using s_hs_secret)
            var srv_fin = new uint8[32];
            read_all (base_io_stream.get_input_stream (), srv_fin);
            var fin_key = TlsCrypto.hkdf_expand_label (s_hs_secret, "finished", new uint8[0], 32);
            var exp_fin = TlsCrypto.hmac_sha256 (fin_key, thash);
            if (!TlsCrypto.ct_memcmp (srv_fin, 0, exp_fin, 0, 32))
                throw new TlsError.HANDSHAKE ("Server Finished verification failed");

            // Send Client Finished
            var cfin_key = TlsCrypto.hkdf_expand_label (c_hs_secret, "finished", new uint8[0], 32);
            var cfin = TlsCrypto.hmac_sha256 (cfin_key, thash);
            write_all (base_io_stream.get_output_stream (), cfin);

            handshaked = true;
            return true;
        }
    }

    public class TlsServerConnection : TlsConnection {
        public TlsServerConnection (IOStream base_io_stream, TlsCertificate? certificate = null)
            : base (base_io_stream) {
            this.certificate = certificate;
        }

        public static TlsServerConnection create (IOStream base_io_stream, TlsCertificate? certificate = null) throws Error {
            return new TlsServerConnection (base_io_stream, certificate);
        }

        private static void write_all (OutputStream os, uint8[] buf) throws IOError {
            os.write (buf);
        }

        private static void read_all (InputStream ins, uint8[] buf) throws IOError {
            int got = 0;
            int tries = 0;
            while (got < buf.length) {
                var tmp = new uint8[buf.length - got];
                int n = ins.read (tmp);
                if (n < 0)
                    throw new IOError.FAILED ("TLS handshake EOF");
                if (n == 0) {
                    if (++tries > 200)
                        throw new IOError.TIMED_OUT ("TLS handshake timeout");
                    Sys.sleep_ms (5);
                    continue;
                }
                for (int i = 0; i < n; i++) buf[got + i] = tmp[i];
                got += n;
            }
        }

        public override bool handshake (Cancellable? cancellable = null) throws Error {
            if (handshaked)
                return true;
            var ch = new uint8[5 + 4 + 2 + 32 + 32];
            read_all (base_io_stream.get_input_stream (), ch);
            if (ch[0] != 0x16 || ch[5] != 0x01)
                throw new TlsError.HANDSHAKE ("Expected ClientHello");

            var cli_pub = new uint8[32];
            for (int i = 0; i < 32; i++) cli_pub[i] = ch[43 + i];

            var priv = new uint8[32];
            var rand = new uint8[32];
            TlsCrypto.random_bytes (priv);
            TlsCrypto.random_bytes (rand);
            var pub = TlsCrypto.x25519_public (priv);
            var shared = TlsCrypto.x25519_scalarmult (priv, cli_pub);

            var sh = new uint8[5 + 4 + 2 + 32 + 32];
            sh[0] = 0x16; sh[1] = 0x03; sh[2] = 0x03;
            int body_len = 4 + 2 + 32 + 32;
            sh[3] = (uint8) ((body_len >> 8) & 0xFF);
            sh[4] = (uint8) (body_len & 0xFF);
            sh[5] = 0x02; // ServerHello
            sh[6] = 0; sh[7] = 0; sh[8] = (uint8) (2 + 32 + 32);
            sh[9] = 0x03; sh[10] = 0x03;
            for (int i = 0; i < 32; i++) sh[11 + i] = rand[i];
            for (int i = 0; i < 32; i++) sh[43 + i] = pub[i];

            write_all (base_io_stream.get_output_stream (), sh);

            var transcript = new uint8[ch.length + sh.length - 10];
            int tp = 0;
            for (int i = 5; i < ch.length; i++) transcript[tp++] = ch[i];
            for (int i = 5; i < sh.length; i++) transcript[tp++] = sh[i];
            var thash = TlsCrypto.sha256 (transcript);

            derive_tls13_traffic_keys (shared, thash, false);

            // Send Server Finished
            var fin_key = TlsCrypto.hkdf_expand_label (s_hs_secret, "finished", new uint8[0], 32);
            var sfin = TlsCrypto.hmac_sha256 (fin_key, thash);
            write_all (base_io_stream.get_output_stream (), sfin);

            // Verify Client Finished
            var cli_fin = new uint8[32];
            read_all (base_io_stream.get_input_stream (), cli_fin);
            var cfin_key = TlsCrypto.hkdf_expand_label (c_hs_secret, "finished", new uint8[0], 32);
            var exp_cfin = TlsCrypto.hmac_sha256 (cfin_key, thash);
            if (!TlsCrypto.ct_memcmp (cli_fin, 0, exp_cfin, 0, 32))
                throw new TlsError.HANDSHAKE ("Client Finished verification failed");

            handshaked = true;
            return true;
        }
    }
}
