// Pure-Vala GIO TLS backend inspired by BoringSSL (TLS 1.3, X25519, ChaCha20-Poly1305, SHA-256, HKDF)
// implementing GLib.TlsBackend, GLib.TlsCertificate, GLib.TlsDatabase, GLib.TlsConnection,
// GLib.TlsClientConnection, and GLib.TlsServerConnection.
using GLib;
using Planet;

namespace Gio {

    [AsmBody(@"
        # __cpuid_crypto_caps() -> bit0=AVX2, bit1=BMI2, bit2=AES-NI, bit3=PCLMULQDQ
        .byte 0x53, 0x45, 0x31, 0xc0, 0xb8, 0x01, 0x00, 0x00, 0x00, 0x0f, 0xa2, 0xf7, 0xc1, 0x00, 0x00, 0x00
        .byte 0x02, 0x74, 0x04, 0x41, 0x83, 0xc8, 0x04, 0xf7, 0xc1, 0x02, 0x00, 0x00, 0x00, 0x74, 0x04, 0x41
        .byte 0x83, 0xc8, 0x08, 0xb8, 0x07, 0x00, 0x00, 0x00, 0x31, 0xc9, 0x0f, 0xa2, 0xf7, 0xc3, 0x20, 0x00
        .byte 0x00, 0x00, 0x74, 0x04, 0x41, 0x83, 0xc8, 0x01, 0xf7, 0xc3, 0x00, 0x01, 0x00, 0x00, 0x74, 0x04
        .byte 0x41, 0x83, 0xc8, 0x02, 0x44, 0x89, 0xc0, 0x5b, 0xc3
    ")]
    private extern int __cpuid_crypto_caps ();

    [AsmBody(@"
        # __chacha20_avx2_8x(out_addr, in_addr, key_addr, nonce_addr, ctr, n8) - 8 blocks (512B)/iter
        .byte 0x4d, 0x85, 0xc9, 0x0f, 0x84, 0xf8, 0x06, 0x00, 0x00, 0x53, 0x55, 0x48, 0x89, 0xe5, 0x48, 0x81
        .byte 0xec, 0xc0, 0x02, 0x00, 0x00, 0x48, 0x83, 0xe4, 0xe0, 0xc7, 0x04, 0x24, 0x65, 0x78, 0x70, 0x61
        .byte 0xc7, 0x44, 0x24, 0x04, 0x6e, 0x64, 0x20, 0x33, 0xc7, 0x44, 0x24, 0x08, 0x32, 0x2d, 0x62, 0x79
        .byte 0xc7, 0x44, 0x24, 0x0c, 0x74, 0x65, 0x20, 0x6b, 0xc5, 0xfe, 0x6f, 0x02, 0xc5, 0xfe, 0x7f, 0x44
        .byte 0x24, 0x10, 0x44, 0x89, 0x44, 0x24, 0x30, 0x8b, 0x01, 0x89, 0x44, 0x24, 0x34, 0x8b, 0x41, 0x04
        .byte 0x89, 0x44, 0x24, 0x38, 0x8b, 0x41, 0x08, 0x89, 0x44, 0x24, 0x3c, 0xc7, 0x44, 0x24, 0x40, 0x00
        .byte 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x44, 0x01, 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x48, 0x02
        .byte 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x4c, 0x03, 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x50, 0x04
        .byte 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x54, 0x05, 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x58, 0x06
        .byte 0x00, 0x00, 0x00, 0xc7, 0x44, 0x24, 0x5c, 0x07, 0x00, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x04
        .byte 0x24, 0xc4, 0xe2, 0x7d, 0x58, 0x4c, 0x24, 0x04, 0xc4, 0xe2, 0x7d, 0x58, 0x54, 0x24, 0x08, 0xc4
        .byte 0xe2, 0x7d, 0x58, 0x5c, 0x24, 0x0c, 0xc4, 0xe2, 0x7d, 0x58, 0x64, 0x24, 0x10, 0xc4, 0xe2, 0x7d
        .byte 0x58, 0x6c, 0x24, 0x14, 0xc4, 0xe2, 0x7d, 0x58, 0x74, 0x24, 0x18, 0xc4, 0xe2, 0x7d, 0x58, 0x7c
        .byte 0x24, 0x1c, 0xc4, 0x62, 0x7d, 0x58, 0x44, 0x24, 0x20, 0xc4, 0x62, 0x7d, 0x58, 0x4c, 0x24, 0x24
        .byte 0xc4, 0x62, 0x7d, 0x58, 0x54, 0x24, 0x28, 0xc4, 0x62, 0x7d, 0x58, 0x5c, 0x24, 0x2c, 0xc4, 0x62
        .byte 0x7d, 0x58, 0x64, 0x24, 0x30, 0xc5, 0x1d, 0xfe, 0x64, 0x24, 0x40, 0xc4, 0x62, 0x7d, 0x58, 0x6c
        .byte 0x24, 0x34, 0xc4, 0x62, 0x7d, 0x58, 0x74, 0x24, 0x38, 0xc4, 0x62, 0x7d, 0x58, 0x7c, 0x24, 0x3c
        .byte 0xb8, 0x0a, 0x00, 0x00, 0x00, 0xc5, 0x7e, 0x7f, 0xbc, 0x24, 0xa0, 0x00, 0x00, 0x00, 0xc5, 0xfd
        .byte 0xfe, 0xc4, 0xc5, 0x1d, 0xef, 0xe0, 0xc4, 0xc1, 0x05, 0x72, 0xf4, 0x10, 0xc4, 0xc1, 0x1d, 0x72
        .byte 0xd4, 0x10, 0xc4, 0x41, 0x1d, 0xeb, 0xe7, 0xc4, 0x41, 0x3d, 0xfe, 0xc4, 0xc4, 0xc1, 0x5d, 0xef
        .byte 0xe0, 0xc5, 0x85, 0x72, 0xf4, 0x0c, 0xc5, 0xdd, 0x72, 0xd4, 0x14, 0xc4, 0xc1, 0x5d, 0xeb, 0xe7
        .byte 0xc5, 0xfd, 0xfe, 0xc4, 0xc5, 0x1d, 0xef, 0xe0, 0xc4, 0xc1, 0x05, 0x72, 0xf4, 0x08, 0xc4, 0xc1
        .byte 0x1d, 0x72, 0xd4, 0x18, 0xc4, 0x41, 0x1d, 0xeb, 0xe7, 0xc4, 0x41, 0x3d, 0xfe, 0xc4, 0xc4, 0xc1
        .byte 0x5d, 0xef, 0xe0, 0xc5, 0x85, 0x72, 0xf4, 0x07, 0xc5, 0xdd, 0x72, 0xd4, 0x19, 0xc4, 0xc1, 0x5d
        .byte 0xeb, 0xe7, 0xc5, 0xf5, 0xfe, 0xcd, 0xc5, 0x15, 0xef, 0xe9, 0xc4, 0xc1, 0x05, 0x72, 0xf5, 0x10
        .byte 0xc4, 0xc1, 0x15, 0x72, 0xd5, 0x10, 0xc4, 0x41, 0x15, 0xeb, 0xef, 0xc4, 0x41, 0x35, 0xfe, 0xcd
        .byte 0xc4, 0xc1, 0x55, 0xef, 0xe9, 0xc5, 0x85, 0x72, 0xf5, 0x0c, 0xc5, 0xd5, 0x72, 0xd5, 0x14, 0xc4
        .byte 0xc1, 0x55, 0xeb, 0xef, 0xc5, 0xf5, 0xfe, 0xcd, 0xc5, 0x15, 0xef, 0xe9, 0xc4, 0xc1, 0x05, 0x72
        .byte 0xf5, 0x08, 0xc4, 0xc1, 0x15, 0x72, 0xd5, 0x18, 0xc4, 0x41, 0x15, 0xeb, 0xef, 0xc4, 0x41, 0x35
        .byte 0xfe, 0xcd, 0xc4, 0xc1, 0x55, 0xef, 0xe9, 0xc5, 0x85, 0x72, 0xf5, 0x07, 0xc5, 0xd5, 0x72, 0xd5
        .byte 0x19, 0xc4, 0xc1, 0x55, 0xeb, 0xef, 0xc5, 0xed, 0xfe, 0xd6, 0xc5, 0x0d, 0xef, 0xf2, 0xc4, 0xc1
        .byte 0x05, 0x72, 0xf6, 0x10, 0xc4, 0xc1, 0x0d, 0x72, 0xd6, 0x10, 0xc4, 0x41, 0x0d, 0xeb, 0xf7, 0xc4
        .byte 0x41, 0x2d, 0xfe, 0xd6, 0xc4, 0xc1, 0x4d, 0xef, 0xf2, 0xc5, 0x85, 0x72, 0xf6, 0x0c, 0xc5, 0xcd
        .byte 0x72, 0xd6, 0x14, 0xc4, 0xc1, 0x4d, 0xeb, 0xf7, 0xc5, 0xed, 0xfe, 0xd6, 0xc5, 0x0d, 0xef, 0xf2
        .byte 0xc4, 0xc1, 0x05, 0x72, 0xf6, 0x08, 0xc4, 0xc1, 0x0d, 0x72, 0xd6, 0x18, 0xc4, 0x41, 0x0d, 0xeb
        .byte 0xf7, 0xc4, 0x41, 0x2d, 0xfe, 0xd6, 0xc4, 0xc1, 0x4d, 0xef, 0xf2, 0xc5, 0x85, 0x72, 0xf6, 0x07
        .byte 0xc5, 0xcd, 0x72, 0xd6, 0x19, 0xc4, 0xc1, 0x4d, 0xeb, 0xf7, 0xc5, 0x7e, 0x6f, 0xbc, 0x24, 0xa0
        .byte 0x00, 0x00, 0x00, 0xc5, 0xfe, 0x7f, 0x84, 0x24, 0xa0, 0x00, 0x00, 0x00, 0xc5, 0xe5, 0xfe, 0xdf
        .byte 0xc5, 0x05, 0xef, 0xfb, 0xc4, 0xc1, 0x7d, 0x72, 0xf7, 0x10, 0xc4, 0xc1, 0x05, 0x72, 0xd7, 0x10
        .byte 0xc5, 0x05, 0xeb, 0xf8, 0xc4, 0x41, 0x25, 0xfe, 0xdf, 0xc4, 0xc1, 0x45, 0xef, 0xfb, 0xc5, 0xfd
        .byte 0x72, 0xf7, 0x0c, 0xc5, 0xc5, 0x72, 0xd7, 0x14, 0xc5, 0xc5, 0xeb, 0xf8, 0xc5, 0xe5, 0xfe, 0xdf
        .byte 0xc5, 0x05, 0xef, 0xfb, 0xc4, 0xc1, 0x7d, 0x72, 0xf7, 0x08, 0xc4, 0xc1, 0x05, 0x72, 0xd7, 0x18
        .byte 0xc5, 0x05, 0xeb, 0xf8, 0xc4, 0x41, 0x25, 0xfe, 0xdf, 0xc4, 0xc1, 0x45, 0xef, 0xfb, 0xc5, 0xfd
        .byte 0x72, 0xf7, 0x07, 0xc5, 0xc5, 0x72, 0xd7, 0x19, 0xc5, 0xc5, 0xeb, 0xf8, 0xc5, 0xfe, 0x6f, 0x84
        .byte 0x24, 0xa0, 0x00, 0x00, 0x00, 0xc5, 0xfe, 0x7f, 0x8c, 0x24, 0xa0, 0x00, 0x00, 0x00, 0xc5, 0xfd
        .byte 0xfe, 0xc5, 0xc5, 0x05, 0xef, 0xf8, 0xc4, 0xc1, 0x75, 0x72, 0xf7, 0x10, 0xc4, 0xc1, 0x05, 0x72
        .byte 0xd7, 0x10, 0xc5, 0x05, 0xeb, 0xf9, 0xc4, 0x41, 0x2d, 0xfe, 0xd7, 0xc4, 0xc1, 0x55, 0xef, 0xea
        .byte 0xc5, 0xf5, 0x72, 0xf5, 0x0c, 0xc5, 0xd5, 0x72, 0xd5, 0x14, 0xc5, 0xd5, 0xeb, 0xe9, 0xc5, 0xfd
        .byte 0xfe, 0xc5, 0xc5, 0x05, 0xef, 0xf8, 0xc4, 0xc1, 0x75, 0x72, 0xf7, 0x08, 0xc4, 0xc1, 0x05, 0x72
        .byte 0xd7, 0x18, 0xc5, 0x05, 0xeb, 0xf9, 0xc4, 0x41, 0x2d, 0xfe, 0xd7, 0xc4, 0xc1, 0x55, 0xef, 0xea
        .byte 0xc5, 0xf5, 0x72, 0xf5, 0x07, 0xc5, 0xd5, 0x72, 0xd5, 0x19, 0xc5, 0xd5, 0xeb, 0xe9, 0xc5, 0xfe
        .byte 0x6f, 0x8c, 0x24, 0xa0, 0x00, 0x00, 0x00, 0xc5, 0xfe, 0x7f, 0x84, 0x24, 0xa0, 0x00, 0x00, 0x00
        .byte 0xc5, 0xf5, 0xfe, 0xce, 0xc5, 0x1d, 0xef, 0xe1, 0xc4, 0xc1, 0x7d, 0x72, 0xf4, 0x10, 0xc4, 0xc1
        .byte 0x1d, 0x72, 0xd4, 0x10, 0xc5, 0x1d, 0xeb, 0xe0, 0xc4, 0x41, 0x25, 0xfe, 0xdc, 0xc4, 0xc1, 0x4d
        .byte 0xef, 0xf3, 0xc5, 0xfd, 0x72, 0xf6, 0x0c, 0xc5, 0xcd, 0x72, 0xd6, 0x14, 0xc5, 0xcd, 0xeb, 0xf0
        .byte 0xc5, 0xf5, 0xfe, 0xce, 0xc5, 0x1d, 0xef, 0xe1, 0xc4, 0xc1, 0x7d, 0x72, 0xf4, 0x08, 0xc4, 0xc1
        .byte 0x1d, 0x72, 0xd4, 0x18, 0xc5, 0x1d, 0xeb, 0xe0, 0xc4, 0x41, 0x25, 0xfe, 0xdc, 0xc4, 0xc1, 0x4d
        .byte 0xef, 0xf3, 0xc5, 0xfd, 0x72, 0xf6, 0x07, 0xc5, 0xcd, 0x72, 0xd6, 0x19, 0xc5, 0xcd, 0xeb, 0xf0
        .byte 0xc5, 0xed, 0xfe, 0xd7, 0xc5, 0x15, 0xef, 0xea, 0xc4, 0xc1, 0x7d, 0x72, 0xf5, 0x10, 0xc4, 0xc1
        .byte 0x15, 0x72, 0xd5, 0x10, 0xc5, 0x15, 0xeb, 0xe8, 0xc4, 0x41, 0x3d, 0xfe, 0xc5, 0xc4, 0xc1, 0x45
        .byte 0xef, 0xf8, 0xc5, 0xfd, 0x72, 0xf7, 0x0c, 0xc5, 0xc5, 0x72, 0xd7, 0x14, 0xc5, 0xc5, 0xeb, 0xf8
        .byte 0xc5, 0xed, 0xfe, 0xd7, 0xc5, 0x15, 0xef, 0xea, 0xc4, 0xc1, 0x7d, 0x72, 0xf5, 0x08, 0xc4, 0xc1
        .byte 0x15, 0x72, 0xd5, 0x18, 0xc5, 0x15, 0xeb, 0xe8, 0xc4, 0x41, 0x3d, 0xfe, 0xc5, 0xc4, 0xc1, 0x45
        .byte 0xef, 0xf8, 0xc5, 0xfd, 0x72, 0xf7, 0x07, 0xc5, 0xc5, 0x72, 0xd7, 0x19, 0xc5, 0xc5, 0xeb, 0xf8
        .byte 0xc5, 0xe5, 0xfe, 0xdc, 0xc5, 0x0d, 0xef, 0xf3, 0xc4, 0xc1, 0x7d, 0x72, 0xf6, 0x10, 0xc4, 0xc1
        .byte 0x0d, 0x72, 0xd6, 0x10, 0xc5, 0x0d, 0xeb, 0xf0, 0xc4, 0x41, 0x35, 0xfe, 0xce, 0xc4, 0xc1, 0x5d
        .byte 0xef, 0xe1, 0xc5, 0xfd, 0x72, 0xf4, 0x0c, 0xc5, 0xdd, 0x72, 0xd4, 0x14, 0xc5, 0xdd, 0xeb, 0xe0
        .byte 0xc5, 0xe5, 0xfe, 0xdc, 0xc5, 0x0d, 0xef, 0xf3, 0xc4, 0xc1, 0x7d, 0x72, 0xf6, 0x08, 0xc4, 0xc1
        .byte 0x0d, 0x72, 0xd6, 0x18, 0xc5, 0x0d, 0xeb, 0xf0, 0xc4, 0x41, 0x35, 0xfe, 0xce, 0xc4, 0xc1, 0x5d
        .byte 0xef, 0xe1, 0xc5, 0xfd, 0x72, 0xf4, 0x07, 0xc5, 0xdd, 0x72, 0xd4, 0x19, 0xc5, 0xdd, 0xeb, 0xe0
        .byte 0xc5, 0xfe, 0x6f, 0x84, 0x24, 0xa0, 0x00, 0x00, 0x00, 0xff, 0xc8, 0x0f, 0x85, 0xa4, 0xfc, 0xff
        .byte 0xff, 0xc5, 0x7e, 0x7f, 0xbc, 0x24, 0x80, 0x02, 0x00, 0x00, 0xc4, 0x62, 0x7d, 0x58, 0x3c, 0x24
        .byte 0xc4, 0xc1, 0x7d, 0xfe, 0xc7, 0xc5, 0xfe, 0x7f, 0x84, 0x24, 0xa0, 0x00, 0x00, 0x00, 0xc4, 0xe2
        .byte 0x7d, 0x58, 0x44, 0x24, 0x04, 0xc5, 0xf5, 0xfe, 0xc8, 0xc5, 0xfe, 0x7f, 0x8c, 0x24, 0xc0, 0x00
        .byte 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x08, 0xc5, 0xed, 0xfe, 0xd0, 0xc5, 0xfe, 0x7f
        .byte 0x94, 0x24, 0xe0, 0x00, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x0c, 0xc5, 0xe5, 0xfe
        .byte 0xd8, 0xc5, 0xfe, 0x7f, 0x9c, 0x24, 0x00, 0x01, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24
        .byte 0x10, 0xc5, 0xdd, 0xfe, 0xe0, 0xc5, 0xfe, 0x7f, 0xa4, 0x24, 0x20, 0x01, 0x00, 0x00, 0xc4, 0xe2
        .byte 0x7d, 0x58, 0x44, 0x24, 0x14, 0xc5, 0xd5, 0xfe, 0xe8, 0xc5, 0xfe, 0x7f, 0xac, 0x24, 0x40, 0x01
        .byte 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x18, 0xc5, 0xcd, 0xfe, 0xf0, 0xc5, 0xfe, 0x7f
        .byte 0xb4, 0x24, 0x60, 0x01, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x1c, 0xc5, 0xc5, 0xfe
        .byte 0xf8, 0xc5, 0xfe, 0x7f, 0xbc, 0x24, 0x80, 0x01, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24
        .byte 0x20, 0xc5, 0x3d, 0xfe, 0xc0, 0xc5, 0x7e, 0x7f, 0x84, 0x24, 0xa0, 0x01, 0x00, 0x00, 0xc4, 0xe2
        .byte 0x7d, 0x58, 0x44, 0x24, 0x24, 0xc5, 0x35, 0xfe, 0xc8, 0xc5, 0x7e, 0x7f, 0x8c, 0x24, 0xc0, 0x01
        .byte 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x28, 0xc5, 0x2d, 0xfe, 0xd0, 0xc5, 0x7e, 0x7f
        .byte 0x94, 0x24, 0xe0, 0x01, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x2c, 0xc5, 0x25, 0xfe
        .byte 0xd8, 0xc5, 0x7e, 0x7f, 0x9c, 0x24, 0x00, 0x02, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24
        .byte 0x30, 0xc5, 0xfd, 0xfe, 0x44, 0x24, 0x40, 0xc5, 0x1d, 0xfe, 0xe0, 0xc5, 0x7e, 0x7f, 0xa4, 0x24
        .byte 0x20, 0x02, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x34, 0xc5, 0x15, 0xfe, 0xe8, 0xc5
        .byte 0x7e, 0x7f, 0xac, 0x24, 0x40, 0x02, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x38, 0xc5
        .byte 0x0d, 0xfe, 0xf0, 0xc5, 0x7e, 0x7f, 0xb4, 0x24, 0x60, 0x02, 0x00, 0x00, 0xc5, 0x7e, 0x6f, 0xbc
        .byte 0x24, 0x80, 0x02, 0x00, 0x00, 0xc4, 0xe2, 0x7d, 0x58, 0x44, 0x24, 0x3c, 0xc5, 0x05, 0xfe, 0xf8
        .byte 0xc5, 0x7e, 0x7f, 0xbc, 0x24, 0x80, 0x02, 0x00, 0x00, 0x48, 0x31, 0xc9, 0x48, 0x89, 0xc8, 0x48
        .byte 0xc1, 0xe0, 0x07, 0xc5, 0xfe, 0x6f, 0x84, 0x04, 0xa0, 0x00, 0x00, 0x00, 0xc5, 0xfe, 0x6f, 0x8c
        .byte 0x04, 0xc0, 0x00, 0x00, 0x00, 0xc5, 0xfe, 0x6f, 0x94, 0x04, 0xe0, 0x00, 0x00, 0x00, 0xc5, 0xfe
        .byte 0x6f, 0x9c, 0x04, 0x00, 0x01, 0x00, 0x00, 0xc5, 0xfd, 0x62, 0xe1, 0xc5, 0xfd, 0x6a, 0xe9, 0xc5
        .byte 0xed, 0x62, 0xf3, 0xc5, 0xed, 0x6a, 0xfb, 0xc5, 0x5d, 0x6c, 0xc6, 0xc5, 0x5d, 0x6d, 0xce, 0xc5
        .byte 0x55, 0x6c, 0xd7, 0xc5, 0x55, 0x6d, 0xdf, 0x48, 0x89, 0xca, 0x48, 0xc1, 0xe2, 0x04, 0xc4, 0x63
        .byte 0x7d, 0x39, 0xc0, 0x00, 0xc5, 0xf9, 0xef, 0x04, 0x16, 0xc5, 0xfa, 0x7f, 0x04, 0x17, 0xc4, 0x63
        .byte 0x7d, 0x39, 0xc8, 0x00, 0xc5, 0xf9, 0xef, 0x44, 0x16, 0x40, 0xc5, 0xfa, 0x7f, 0x44, 0x17, 0x40
        .byte 0xc4, 0x63, 0x7d, 0x39, 0xd0, 0x00, 0xc5, 0xf9, 0xef, 0x84, 0x16, 0x80, 0x00, 0x00, 0x00, 0xc5
        .byte 0xfa, 0x7f, 0x84, 0x17, 0x80, 0x00, 0x00, 0x00, 0xc4, 0x63, 0x7d, 0x39, 0xd8, 0x00, 0xc5, 0xf9
        .byte 0xef, 0x84, 0x16, 0xc0, 0x00, 0x00, 0x00, 0xc5, 0xfa, 0x7f, 0x84, 0x17, 0xc0, 0x00, 0x00, 0x00
        .byte 0xc4, 0x63, 0x7d, 0x39, 0xc0, 0x01, 0xc5, 0xf9, 0xef, 0x84, 0x16, 0x00, 0x01, 0x00, 0x00, 0xc5
        .byte 0xfa, 0x7f, 0x84, 0x17, 0x00, 0x01, 0x00, 0x00, 0xc4, 0x63, 0x7d, 0x39, 0xc8, 0x01, 0xc5, 0xf9
        .byte 0xef, 0x84, 0x16, 0x40, 0x01, 0x00, 0x00, 0xc5, 0xfa, 0x7f, 0x84, 0x17, 0x40, 0x01, 0x00, 0x00
        .byte 0xc4, 0x63, 0x7d, 0x39, 0xd0, 0x01, 0xc5, 0xf9, 0xef, 0x84, 0x16, 0x80, 0x01, 0x00, 0x00, 0xc5
        .byte 0xfa, 0x7f, 0x84, 0x17, 0x80, 0x01, 0x00, 0x00, 0xc4, 0x63, 0x7d, 0x39, 0xd8, 0x01, 0xc5, 0xf9
        .byte 0xef, 0x84, 0x16, 0xc0, 0x01, 0x00, 0x00, 0xc5, 0xfa, 0x7f, 0x84, 0x17, 0xc0, 0x01, 0x00, 0x00
        .byte 0x48, 0xff, 0xc1, 0x48, 0x83, 0xf9, 0x04, 0x0f, 0x82, 0xef, 0xfe, 0xff, 0xff, 0x83, 0x44, 0x24
        .byte 0x30, 0x08, 0x48, 0x81, 0xc6, 0x00, 0x02, 0x00, 0x00, 0x48, 0x81, 0xc7, 0x00, 0x02, 0x00, 0x00
        .byte 0x49, 0xff, 0xc9, 0x0f, 0x85, 0xa2, 0xf9, 0xff, 0xff, 0xc5, 0xf8, 0x77, 0x48, 0x89, 0xec, 0x5d
        .byte 0x5b, 0xc3
    ")]
    private extern void __chacha20_avx2_8x (int out_addr, int in_addr, int key_addr, int nonce_addr, uint32 ctr, int n8);

    [AsmBody(@"
        # __poly1305_bmi2_blocks(state_u64_addr, msg_addr, nblocks16) - radix-2^64 with BMI2 mulx
        .byte 0x48, 0x85, 0xd2, 0x0f, 0x84, 0xcc, 0x00, 0x00, 0x00, 0x53, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41
        .byte 0x56, 0x41, 0x57, 0x4c, 0x8b, 0x07, 0x4c, 0x8b, 0x4f, 0x08, 0x4c, 0x8b, 0x57, 0x10, 0x4c, 0x8b
        .byte 0x5f, 0x18, 0x4c, 0x8b, 0x67, 0x20, 0x48, 0x89, 0xd1, 0x4c, 0x03, 0x06, 0x4c, 0x13, 0x4e, 0x08
        .byte 0x49, 0x83, 0xd2, 0x01, 0x4c, 0x89, 0xda, 0xc4, 0xc2, 0xfb, 0xf6, 0xd8, 0xc4, 0x42, 0x93, 0xf6
        .byte 0xf1, 0x4c, 0x01, 0xeb, 0x49, 0x83, 0xd6, 0x00, 0x4c, 0x89, 0xe2, 0xc4, 0x42, 0x93, 0xf6, 0xf8
        .byte 0x4c, 0x01, 0xeb, 0x4d, 0x11, 0xfe, 0x40, 0x0f, 0x92, 0xc5, 0x40, 0x0f, 0xb6, 0xed, 0xc4, 0x42
        .byte 0x93, 0xf6, 0xf9, 0x4d, 0x01, 0xee, 0x4c, 0x11, 0xfd, 0x4c, 0x89, 0xd2, 0xc4, 0x42, 0x93, 0xf6
        .byte 0xfb, 0x4d, 0x01, 0xee, 0x4c, 0x11, 0xfd, 0xc4, 0x42, 0x93, 0xf6, 0xfc, 0x4c, 0x01, 0xed, 0x4d
        .byte 0x89, 0xf2, 0x49, 0x83, 0xe2, 0x03, 0x4d, 0x89, 0xf5, 0x49, 0x83, 0xe5, 0xfc, 0x49, 0x89, 0xef
        .byte 0x49, 0x0f, 0xac, 0xee, 0x02, 0x49, 0xc1, 0xef, 0x02, 0x49, 0x89, 0xc0, 0x49, 0x89, 0xd9, 0x4d
        .byte 0x01, 0xf0, 0x4d, 0x11, 0xf9, 0x49, 0x83, 0xd2, 0x00, 0x4d, 0x01, 0xe8, 0x49, 0x11, 0xe9, 0x49
        .byte 0x83, 0xd2, 0x00, 0x48, 0x83, 0xc6, 0x10, 0x48, 0xff, 0xc9, 0x0f, 0x85, 0x69, 0xff, 0xff, 0xff
        .byte 0x4c, 0x89, 0x07, 0x4c, 0x89, 0x4f, 0x08, 0x4c, 0x89, 0x57, 0x10, 0x41, 0x5f, 0x41, 0x5e, 0x41
        .byte 0x5d, 0x41, 0x5c, 0x5d, 0x5b, 0xc3
    ")]
    private extern void __poly1305_bmi2_blocks (int state_addr, int msg_addr, int nblocks16);

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
        private static int prng_spin = 0;
        private static uint8[]? prng_key;
        private static uint32 prng_counter = 1;

        public static void zero_bytes (uint8[] buf) {
            if (buf.length > 0)
                Memory.set (Sys.byte_arr_addr (buf), 0, (size_t) buf.length);
        }

        public static bool ct_memcmp (uint8[] a, int a_off, uint8[] b, int b_off, int len) {
            if (len < 0 || a_off + len > a.length || b_off + len > b.length)
                return false;
            uint32 diff = 0;
            for (int i = 0; i < len; i++)
                diff |= (uint32) (a[a_off + i] ^ b[b_off + i]);
            return diff == 0;
        }

        public static void random_bytes (uint8[] out_buf) {
            while (!AtomicInt.compare_and_exchange (ref prng_spin, 0, 1))
                Sys.sleep_ms (0);
            if (prng_key == null)
                prng_key = new uint8[32];
            var key = (!) prng_key;
            uint64 t1 = Sys.rdtsc ();
            uint64 t2 = (uint64) Sys.ticks ();
            uint32 c = prng_counter++;
            for (int i = 0; i < 8; i++) {
                key[i] ^= (uint8) ((t1 >> (i * 8)) & 0xFF);
                key[8 + i] ^= (uint8) ((t2 >> (i * 8)) & 0xFF);
            }
            key[16] ^= (uint8) (c & 0xFF);
            key[17] ^= (uint8) ((c >> 8) & 0xFF);
            key[18] ^= (uint8) ((c >> 16) & 0xFF);
            key[19] ^= (uint8) ((c >> 24) & 0xFF);
            uint64 t3 = Sys.rdtsc ();
            for (int i = 0; i < 8; i++)
                key[24 + i] ^= (uint8) ((t3 >> (i * 8)) & 0xFF);

            var nonce = new uint8[12];
            // Fast-key-erasure: first block ratchets prng_key, subsequent blocks fill out_buf
            var ratchet = chacha20_block (key, 0, nonce);
            Memory.copy (Sys.byte_arr_addr (key), Sys.byte_arr_addr (ratchet), 32);
            zero_bytes (ratchet);

            int pos = 0;
            uint32 blk = 1;
            while (pos < out_buf.length) {
                var ks = chacha20_block (key, blk++, nonce);
                int take = out_buf.length - pos;
                if (take > 64) take = 64;
                Memory.copy (Sys.byte_arr_addr (out_buf) + pos, Sys.byte_arr_addr (ks), (size_t) take);
                zero_bytes (ks);
                pos += take;
            }
            AtomicInt.set (ref prng_spin, 0);
        }

        // --- SHA-256 & HMAC-SHA256 via GLib.Checksum / GLib.Hmac ---
        public static uint8[] sha256 (uint8[] data, int len = -1) {
            int n = (len < 0 || len > data.length) ? data.length : len;
            var cs = new Checksum (ChecksumType.SHA256);
            if (n > 0)
                cs.update (data, n);
            size_t dlen = 0;
            return cs.get_digest (out dlen);
        }

        public static uint8[] hmac_sha256 (uint8[] key, uint8[] data) {
            var h = new Hmac (ChecksumType.SHA256, key);
            if (data.length > 0)
                h.update (data, data.length);
            size_t dlen = 0;
            return h.get_digest_bytes (out dlen);
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

        private static int _cpu_caps = 0;

        public static int cpu_caps () {
            int c = AtomicInt.get (ref _cpu_caps);
            if ((c & 0x100) == 0) {
                c = 0x100 | __cpuid_crypto_caps ();
                AtomicInt.set (ref _cpu_caps, c);
            }
            return c & 0xFF;
        }

        private static uint8[] chacha20_xor (uint8[] key32, uint32 init_counter, uint8[] nonce12, uint8[] data, int off, int len) {
            var out_b = new uint8[len];
            int pos = 0;
            uint32 ctr = init_counter;
            if (len >= 512 && (cpu_caps () & 1) != 0) {
                int n8 = len / 512;
                __chacha20_avx2_8x (Sys.byte_arr_addr (out_b),
                                    Sys.byte_arr_addr (data) + off,
                                    Sys.byte_arr_addr (key32),
                                    Sys.byte_arr_addr (nonce12),
                                    ctr, n8);
                pos = n8 * 512;
                ctr += (uint32) (n8 * 8);
            }
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

        // Poly1305 (BMI2 mulx radix-2^64 fast path for 16B blocks + constant-time 5x26-bit tail/reduce)
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
            if (msg.length >= 64 && (cpu_caps () & 2) != 0) {
                int n16 = msg.length / 16;
                var st64 = new uint8[40];
                uint64 r_lo = ((uint64) load_le32 (otk32, 0) | ((uint64) load_le32 (otk32, 4) << 32)) & 0x0ffffffc0fffffffUL;
                uint64 r_hi = ((uint64) load_le32 (otk32, 8) | ((uint64) load_le32 (otk32, 12) << 32)) & 0x0ffffffc0ffffffcUL;
                for (int i = 0; i < 8; i++) {
                    st64[24 + i] = (uint8) ((r_lo >> (i * 8)) & 0xFF);
                    st64[32 + i] = (uint8) ((r_hi >> (i * 8)) & 0xFF);
                }
                __poly1305_bmi2_blocks (Sys.byte_arr_addr (st64), Sys.byte_arr_addr (msg), n16);
                uint64 a0 = (uint64) load_le32 (st64, 0) | ((uint64) load_le32 (st64, 4) << 32);
                uint64 a1 = (uint64) load_le32 (st64, 8) | ((uint64) load_le32 (st64, 12) << 32);
                uint64 a2 = (uint64) load_le32 (st64, 16) | ((uint64) load_le32 (st64, 20) << 32);
                h0 = a0 & 0x3ffffffU;
                h1 = (a0 >> 26) & 0x3ffffffU;
                h2 = ((a0 >> 52) | (a1 << 12)) & 0x3ffffffU;
                h3 = (a1 >> 14) & 0x3ffffffU;
                h4 = ((a1 >> 40) | (a2 << 24)) & 0xffffffffU;
                pos = n16 * 16;
            }
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
        public Bytes certificate { get; private set; }
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
            // Decode Base64 PEM body into GLib.Bytes when present
            int hdr_end = this.certificate_pem.index_of ("-----BEGIN CERTIFICATE-----");
            int ftr_start = this.certificate_pem.index_of ("-----END CERTIFICATE-----");
            if (hdr_end >= 0 && ftr_start > hdr_end + 27) {
                string body = Str.strip (this.certificate_pem.substring (hdr_end + 27, ftr_start - (hdr_end + 27)));
                if (cn < 0 && body.length > 0) {
                    var der = Base64.decode (body);
                    this.certificate = new Bytes (der);
                } else {
                    var raw = new uint8[body.length];
                    for (int i = 0; i < body.length; i++) raw[i] = (uint8) body[i];
                    this.certificate = new Bytes (raw);
                }
            } else {
                this.certificate = new Bytes (new uint8[0]);
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
        private static int once_state = 0;
        private static PlanetTlsBackend? _inst;
        private TlsDatabase default_db;

        public PlanetTlsBackend () {
            this.default_db = new TlsDatabase ();
        }

        public static PlanetTlsBackend instance () {
            while (AtomicInt.get (ref once_state) != 2) {
                if (AtomicInt.compare_and_exchange (ref once_state, 0, 1)) {
                    _inst = new PlanetTlsBackend ();
                    AtomicInt.set (ref once_state, 2);
                    break;
                }
                Sys.yield_cpu ();
            }
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
            Memory.copy (Sys.byte_arr_addr (n), Sys.byte_arr_addr (iv), 12);
            uint64 be_seq = GLib.to_be64 (seq);
            for (int i = 0; i < 8; i++)
                n[4 + i] ^= (uint8) ((be_seq >> (i * 8)) & 0xFF);
            return n;
        }
    }

    private class TlsInputStream : InputStream {
        private InputStream raw_in;
        public TlsRecordState st;
        private uint8[] plain_buf = new uint8[0];
        private int plain_pos = 0;
        private bool peer_eof = false;

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

        public uint8[]? read_decrypted_record (out uint8 inner_ctype) throws IOError {
            inner_ctype = 0;
            while (true) {
                var hdr = new uint8[5];
                read_exact (hdr);
                int rlen = ((int) hdr[3] << 8) | (int) hdr[4];
                if (hdr[0] == 0x14) { // ChangeCipherSpec (RFC 8446 §5 middlebox compat)
                    if (rlen > 0 && rlen <= 256)
                        read_exact (new uint8[rlen]);
                    continue;
                }
                if (hdr[0] == 0x15) { // Plaintext alert from peer
                    if (rlen > 0 && rlen <= 256)
                        read_exact (new uint8[rlen]);
                    peer_eof = true;
                    inner_ctype = 0x15;
                    return null;
                }
                if (hdr[0] != 0x17)
                    throw new IOError.FAILED (@"TLS expected ApplicationData record (got $(hdr[0]) $(hdr[1]) $(hdr[2]) len=$rlen)");
                if (rlen <= 16 || rlen > 16640)
                    throw new IOError.FAILED ("TLS invalid record length");
                var ct_tag = new uint8[rlen];
                read_exact (ct_tag);
                if (st.rx_seq == uint64.MAX)
                    throw new IOError.FAILED ("TLS sequence number overflow");
                var nonce = st.make_nonce (st.rx_iv, st.rx_seq++);
                uint8[]? pt = TlsCrypto.aead_open (st.rx_key, nonce, hdr, ct_tag);
                if (pt == null)
                    throw new IOError.FAILED ("TLS bad MAC");
                var dec = (!) pt;
                // Strip inner content type (TLS 1.3 RFC 8446 §5.2)
                int inner_len = dec.length - 1;
                while (inner_len > 0 && dec[inner_len] == 0)
                    inner_len--;
                inner_ctype = dec[inner_len];
                if (inner_ctype == 0x15) { // Alert (close_notify)
                    peer_eof = true;
                    return null;
                }
                var payload = new uint8[inner_len];
                if (inner_len > 0)
                    Memory.copy (Sys.byte_arr_addr (payload), Sys.byte_arr_addr (dec), (size_t) inner_len);
                return payload;
            }
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("TlsInputStream is closed");
            if (!st.active)
                throw new IOError.FAILED ("TLS handshake not completed");
            while (plain_pos >= plain_buf.length) {
                if (peer_eof)
                    return -1;
                uint8 ctype = 0;
                uint8[]? payload = read_decrypted_record (out ctype);
                if (payload == null || ctype == 0x15)
                    return -1;
                if (ctype == 0x16) // Post-handshake message (e.g. NewSessionTicket)
                    continue;
                plain_buf = (!) payload;
                plain_pos = 0;
            }
            int avail = plain_buf.length - plain_pos;
            int take = (buffer.length < avail) ? buffer.length : avail;
            if (take > 0)
                Memory.copy (Sys.byte_arr_addr (buffer), Sys.byte_arr_addr (plain_buf) + plain_pos, (size_t) take);
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
            if (st.tx_seq == uint64.MAX)
                throw new IOError.FAILED ("TLS sequence number overflow");
            var inner = new uint8[data.length + 1];
            if (data.length > 0)
                Memory.copy (Sys.byte_arr_addr (inner), Sys.byte_arr_addr (data), (size_t) data.length);
            inner[data.length] = inner_ctype;
            uint16 be_len = GLib.to_be16 ((uint16) (inner.length + 16));
            var hdr = new uint8[5];
            hdr[0] = 0x17; hdr[1] = 0x03; hdr[2] = 0x03;
            hdr[3] = (uint8) (be_len & 0xFF);
            hdr[4] = (uint8) ((be_len >> 8) & 0xFF);
            var nonce = st.make_nonce (st.tx_iv, st.tx_seq++);
            var enc = TlsCrypto.aead_seal (st.tx_key, nonce, hdr, inner);
            var rec = new uint8[5 + enc.length];
            Memory.copy (Sys.byte_arr_addr (rec), Sys.byte_arr_addr (hdr), 5);
            Memory.copy (Sys.byte_arr_addr (rec) + 5, Sys.byte_arr_addr (enc), (size_t) enc.length);
            raw_out.write (rec);
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("TlsOutputStream is closed");
            if (!st.active)
                throw new IOError.FAILED ("TLS handshake not completed");
            int off = 0;
            while (off < buffer.length) {
                int chunk_len = buffer.length - off;
                if (chunk_len > 16384)
                    chunk_len = 16384;
                var chunk = new uint8[chunk_len];
                Memory.copy (Sys.byte_arr_addr (chunk), Sys.byte_arr_addr (buffer) + off, (size_t) chunk_len);
                write_record (0x17, chunk);
                off += chunk_len;
            }
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
        protected TlsInputStream tls_in;
        protected TlsOutputStream tls_out;
        protected bool handshaked = false;
        protected uint8[] hs_secret = new uint8[0];
        protected uint8[] c_hs_secret = new uint8[0];
        protected uint8[] s_hs_secret = new uint8[0];
        protected uint8[] c_ap_secret = new uint8[0];
        protected uint8[] s_ap_secret = new uint8[0];

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

        protected void derive_tls13_hs_keys (uint8[] shared_secret, uint8[] thash_sh, bool is_client) {
            var zero32 = new uint8[32];
            var early = TlsCrypto.hkdf_extract (zero32, zero32);
            var empty_hash = TlsCrypto.sha256 (new uint8[0]);
            var derived = TlsCrypto.hkdf_expand_label (early, "derived", empty_hash, 32);
            hs_secret = TlsCrypto.hkdf_extract (derived, shared_secret);
            c_hs_secret = TlsCrypto.hkdf_expand_label (hs_secret, "c hs traffic", thash_sh, 32);
            s_hs_secret = TlsCrypto.hkdf_expand_label (hs_secret, "s hs traffic", thash_sh, 32);

            var tx_sec = is_client ? c_hs_secret : s_hs_secret;
            var rx_sec = is_client ? s_hs_secret : c_hs_secret;
            var empty_ctx = new uint8[0];
            rec_state.tx_key = TlsCrypto.hkdf_expand_label (tx_sec, "key", empty_ctx, 32);
            rec_state.tx_iv = TlsCrypto.hkdf_expand_label (tx_sec, "iv", empty_ctx, 12);
            rec_state.tx_seq = 0;
            rec_state.rx_key = TlsCrypto.hkdf_expand_label (rx_sec, "key", empty_ctx, 32);
            rec_state.rx_iv = TlsCrypto.hkdf_expand_label (rx_sec, "iv", empty_ctx, 12);
            rec_state.rx_seq = 0;
            rec_state.active = true;
        }

        protected void derive_tls13_app_secrets (uint8[] thash_sfin) {
            var zero32 = new uint8[32];
            var empty_hash = TlsCrypto.sha256 (new uint8[0]);
            var derived2 = TlsCrypto.hkdf_expand_label (hs_secret, "derived", empty_hash, 32);
            var master = TlsCrypto.hkdf_extract (derived2, zero32);
            c_ap_secret = TlsCrypto.hkdf_expand_label (master, "c ap traffic", thash_sfin, 32);
            s_ap_secret = TlsCrypto.hkdf_expand_label (master, "s ap traffic", thash_sfin, 32);
        }

        protected void set_tx_secret (uint8[] sec) {
            var empty_ctx = new uint8[0];
            rec_state.tx_key = TlsCrypto.hkdf_expand_label (sec, "key", empty_ctx, 32);
            rec_state.tx_iv = TlsCrypto.hkdf_expand_label (sec, "iv", empty_ctx, 12);
            rec_state.tx_seq = 0;
        }

        protected void set_rx_secret (uint8[] sec) {
            var empty_ctx = new uint8[0];
            rec_state.rx_key = TlsCrypto.hkdf_expand_label (sec, "key", empty_ctx, 32);
            rec_state.rx_iv = TlsCrypto.hkdf_expand_label (sec, "iv", empty_ctx, 12);
            rec_state.rx_seq = 0;
        }

        protected static void ba_be16 (ByteArray ba, int v) {
            ba.append_byte ((uint8) ((v >> 8) & 0xFF));
            ba.append_byte ((uint8) (v & 0xFF));
        }

        protected static void ba_be24 (ByteArray ba, int v) {
            ba.append_byte ((uint8) ((v >> 16) & 0xFF));
            ba.append_byte ((uint8) ((v >> 8) & 0xFF));
            ba.append_byte ((uint8) (v & 0xFF));
        }

        protected static uint8[] ba_to_u8 (ByteArray ba) {
            return ba.data;
        }

        protected static void ba_append_u8 (ByteArray ba, uint8[] src, int off = 0, int len = -1) {
            int n = (len < 0) ? (src.length - off) : len;
            if (off == 0 && n == src.length) {
                ba.append (src);
                return;
            }
            for (int i = 0; i < n; i++)
                ba.append_byte (src[off + i]);
        }

        protected static uint8[] read_plain_record (InputStream ins, out uint8 rtype) throws IOError {
            rtype = 0;
            while (true) {
                var hdr = new uint8[5];
                read_all (ins, hdr);
                int rlen = ((int) hdr[3] << 8) | (int) hdr[4];
                if (rlen <= 0 || rlen > 16640)
                    throw new IOError.FAILED ("TLS invalid plaintext record length");
                var body = new uint8[rlen];
                read_all (ins, body);
                if (hdr[0] == 0x14) // ChangeCipherSpec
                    continue;
                rtype = hdr[0];
                return body;
            }
        }

        protected static uint8[]? parse_x25519_key_share (uint8[] exts, int off, int len, bool is_server_hello) {
            int end = off + len;
            if (end > exts.length)
                return null;
            int p = off;
            while (p + 4 <= end) {
                int etype = ((int) exts[p] << 8) | (int) exts[p + 1];
                int elen = ((int) exts[p + 2] << 8) | (int) exts[p + 3];
                p += 4;
                if (p + elen > end)
                    break;
                if (etype == 0x0033) { // key_share
                    if (is_server_hello) {
                        if (elen >= 4) {
                            int grp = ((int) exts[p] << 8) | (int) exts[p + 1];
                            int klen = ((int) exts[p + 2] << 8) | (int) exts[p + 3];
                            if (grp == 0x001d && klen == 32 && p + 4 + 32 <= end) {
                                var k = new uint8[32];
                                Memory.copy (Sys.byte_arr_addr (k), Sys.byte_arr_addr (exts) + p + 4, 32);
                                return k;
                            }
                        }
                    } else if (elen >= 2) {
                        int list_len = ((int) exts[p] << 8) | (int) exts[p + 1];
                        int kp = p + 2;
                        int kend = p + 2 + list_len;
                        if (kend > p + elen) kend = p + elen;
                        while (kp + 4 <= kend) {
                            int grp = ((int) exts[kp] << 8) | (int) exts[kp + 1];
                            int klen = ((int) exts[kp + 2] << 8) | (int) exts[kp + 3];
                            kp += 4;
                            if (grp == 0x001d && klen == 32 && kp + 32 <= kend) {
                                var k = new uint8[32];
                                Memory.copy (Sys.byte_arr_addr (k), Sys.byte_arr_addr (exts) + kp, 32);
                                return k;
                            }
                            kp += klen;
                        }
                    }
                }
                p += elen;
            }
            return null;
        }

        protected static void write_all (OutputStream os, uint8[] buf) throws IOError {
            os.write (buf);
        }

        protected static void read_all (InputStream ins, uint8[] buf) throws IOError {
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

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (handshaked && require_close_notify && rec_state.active) {
                try {
                    uint8[] alert = { 1, 0 }; // warning, close_notify
                    tls_out.write_record (0x15, alert);
                } catch (IOError e) {
                }
            }
            rec_state.active = false;
            TlsCrypto.zero_bytes (rec_state.tx_key);
            TlsCrypto.zero_bytes (rec_state.tx_iv);
            TlsCrypto.zero_bytes (rec_state.rx_key);
            TlsCrypto.zero_bytes (rec_state.rx_iv);
            TlsCrypto.zero_bytes (hs_secret);
            TlsCrypto.zero_bytes (c_hs_secret);
            TlsCrypto.zero_bytes (s_hs_secret);
            TlsCrypto.zero_bytes (c_ap_secret);
            TlsCrypto.zero_bytes (s_ap_secret);
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

        private static bool is_ipv4_literal (string s) {
            return InetAddress.new_from_string (s) != null;
        }

        public override bool handshake (Cancellable? cancellable = null) throws Error {
            if (handshaked)
                return true;
            var priv = new uint8[32];
            var rand = new uint8[32];
            var sess_id = new uint8[32];
            TlsCrypto.random_bytes (priv);
            TlsCrypto.random_bytes (rand);
            TlsCrypto.random_bytes (sess_id);
            var pub = TlsCrypto.x25519_public (priv);

            // Build RFC 8446 Extensions
            var exts = new ByteArray.sized (128);
            if (server_identity != null && server_identity is NetworkAddress) {
                string sni = ((NetworkAddress) server_identity).get_hostname ();
                if (sni.length > 0 && !is_ipv4_literal (sni)) {
                    ba_be16 (exts, 0x0000); // server_name
                    ba_be16 (exts, 2 + 1 + 2 + sni.length);
                    ba_be16 (exts, 1 + 2 + sni.length);
                    exts.append_byte (0x00); // host_name
                    ba_be16 (exts, sni.length);
                    for (int i = 0; i < sni.length; i++) exts.append_byte ((uint8) sni[i]);
                }
            }
            // supported_versions (TLS 1.3 = 0x0304)
            ba_be16 (exts, 0x002b); ba_be16 (exts, 3);
            exts.append_byte (2); ba_be16 (exts, 0x0304);
            // supported_groups (x25519 = 0x001d)
            ba_be16 (exts, 0x000a); ba_be16 (exts, 4);
            ba_be16 (exts, 2); ba_be16 (exts, 0x001d);
            // signature_algorithms
            ba_be16 (exts, 0x000d); ba_be16 (exts, 10);
            ba_be16 (exts, 8);
            ba_be16 (exts, 0x0403); ba_be16 (exts, 0x0804); ba_be16 (exts, 0x0401); ba_be16 (exts, 0x0807);
            // key_share (x25519)
            ba_be16 (exts, 0x0033); ba_be16 (exts, 2 + 4 + 32);
            ba_be16 (exts, 4 + 32);
            ba_be16 (exts, 0x001d); ba_be16 (exts, 32);
            ba_append_u8 (exts, pub);

            // ClientHello handshake message
            var ch_body = new ByteArray.sized (128);
            ba_be16 (ch_body, 0x0303); // legacy_version
            ba_append_u8 (ch_body, rand);
            ch_body.append_byte (32);
            ba_append_u8 (ch_body, sess_id);
            ba_be16 (ch_body, 2);
            ba_be16 (ch_body, 0x1303); // TLS_CHACHA20_POLY1305_SHA256
            ch_body.append_byte (1); ch_body.append_byte (0); // null compression
            ba_be16 (ch_body, exts.len);
            ba_append_u8 (ch_body, ba_to_u8 (exts));

            var ch_hs = new ByteArray.sized (160);
            ch_hs.append_byte (0x01); // ClientHello
            ba_be24 (ch_hs, ch_body.len);
            ba_append_u8 (ch_hs, ba_to_u8 (ch_body));
            var ch_hs_bytes = ba_to_u8 (ch_hs);

            var rec = new ByteArray.sized (ch_hs_bytes.length + 5);
            rec.append_byte (0x16); rec.append_byte (0x03); rec.append_byte (0x01);
            ba_be16 (rec, ch_hs_bytes.length);
            ba_append_u8 (rec, ch_hs_bytes);
            write_all (base_io_stream.get_output_stream (), ba_to_u8 (rec));

            // Read ServerHello
            uint8 rtype = 0;
            var sh_hs = read_plain_record (base_io_stream.get_input_stream (), out rtype);
            if (rtype != 0x16 || sh_hs.length < 40 || sh_hs[0] != 0x02)
                throw new TlsError.HANDSHAKE ("Expected ServerHello");

            int sh_sid_len = (int) sh_hs[38];
            int cs_off = 39 + sh_sid_len;
            if (cs_off + 5 > sh_hs.length)
                throw new TlsError.HANDSHAKE ("Malformed ServerHello");
            int cs = ((int) sh_hs[cs_off] << 8) | (int) sh_hs[cs_off + 1];
            if (cs != 0x1303)
                throw new TlsError.HANDSHAKE ("Server did not select TLS_CHACHA20_POLY1305_SHA256");
            int ext_off = cs_off + 3;
            int ext_len = ((int) sh_hs[ext_off] << 8) | (int) sh_hs[ext_off + 1];
            uint8[]? srv_pub = parse_x25519_key_share (sh_hs, ext_off + 2, ext_len, true);
            if (srv_pub == null)
                throw new TlsError.HANDSHAKE ("Missing X25519 key_share in ServerHello");

            var shared = TlsCrypto.x25519_scalarmult (priv, (!) srv_pub);
            var transcript = new ByteArray.sized (512);
            ba_append_u8 (transcript, ch_hs_bytes);
            ba_append_u8 (transcript, sh_hs);
            var thash_sh = TlsCrypto.sha256 (ba_to_u8 (transcript));

            derive_tls13_hs_keys (shared, thash_sh, true);
            TlsCrypto.zero_bytes (priv);
            TlsCrypto.zero_bytes (shared);

            // Read encrypted server handshake flight until Finished (0x14)
            var hs_buf = new ByteArray.sized (2048);
            bool got_sfin = false;
            while (!got_sfin) {
                uint8 ict = 0;
                uint8[]? chunk = tls_in.read_decrypted_record (out ict);
                if (chunk == null)
                    throw new TlsError.HANDSHAKE ("Unexpected EOF during server handshake");
                if (ict != 0x16)
                    throw new TlsError.HANDSHAKE ("Expected encrypted handshake record");
                ba_append_u8 (hs_buf, (!) chunk);

                var hb = hs_buf.data;
                int hp = 0;
                while (hp + 4 <= hb.length) {
                    uint8 htype = hb[hp];
                    int hlen = ((int) hb[hp + 1] << 16)
                             | ((int) hb[hp + 2] << 8)
                             | (int) hb[hp + 3];
                    if (hp + 4 + hlen > hb.length)
                        break;
                    if (htype == 0x14) { // Server Finished
                        if (hlen != 32)
                            throw new TlsError.HANDSHAKE ("Invalid Finished length");
                        var thash_pre_fin = TlsCrypto.sha256 (ba_to_u8 (transcript));
                        var fin_key = TlsCrypto.hkdf_expand_label (s_hs_secret, "finished", new uint8[0], 32);
                        var exp_fin = TlsCrypto.hmac_sha256 (fin_key, thash_pre_fin);
                        var got_fin = new uint8[32];
                        Memory.copy (Sys.byte_arr_addr (got_fin), Sys.byte_arr_addr (hb) + hp + 4, 32);
                        if (!TlsCrypto.ct_memcmp (got_fin, 0, exp_fin, 0, 32))
                            throw new TlsError.HANDSHAKE ("Server Finished verification failed");
                        ba_append_u8 (transcript, hb, hp, 4 + hlen);
                        got_sfin = true;
                        hp += 4 + hlen;
                        break;
                    }
                    ba_append_u8 (transcript, hb, hp, 4 + hlen);
                    hp += 4 + hlen;
                }
                if (hp > 0)
                    hs_buf.remove_range (0, hp);
            }

            var thash_sfin = TlsCrypto.sha256 (ba_to_u8 (transcript));
            derive_tls13_app_secrets (thash_sfin);

            // Send encrypted Client Finished under c_hs_secret
            var cfin_key = TlsCrypto.hkdf_expand_label (c_hs_secret, "finished", new uint8[0], 32);
            var cfin = TlsCrypto.hmac_sha256 (cfin_key, thash_sfin);
            var cfin_msg = new uint8[36];
            cfin_msg[0] = 0x14; cfin_msg[1] = 0; cfin_msg[2] = 0; cfin_msg[3] = 32;
            Memory.copy (Sys.byte_arr_addr (cfin_msg) + 4, Sys.byte_arr_addr (cfin), 32);
            tls_out.write_record (0x16, cfin_msg);

            // Switch to application traffic keys
            set_tx_secret (c_ap_secret);
            set_rx_secret (s_ap_secret);
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

        public override bool handshake (Cancellable? cancellable = null) throws Error {
            if (handshaked)
                return true;
            uint8 rtype = 0;
            var ch_hs = read_plain_record (base_io_stream.get_input_stream (), out rtype);
            if (rtype != 0x16 || ch_hs.length < 44 || ch_hs[0] != 0x01)
                throw new TlsError.HANDSHAKE ("Expected ClientHello");

            int sid_len = (int) ch_hs[38];
            var sid = new uint8[sid_len];
            if (sid_len > 0)
                Memory.copy (Sys.byte_arr_addr (sid), Sys.byte_arr_addr (ch_hs) + 39, (size_t) sid_len);
            int cs_off = 39 + sid_len;
            int cs_len = ((int) ch_hs[cs_off] << 8) | (int) ch_hs[cs_off + 1];
            int comp_off = cs_off + 2 + cs_len;
            int comp_len = (int) ch_hs[comp_off];
            int ext_off = comp_off + 1 + comp_len;
            int ext_len = ((int) ch_hs[ext_off] << 8) | (int) ch_hs[ext_off + 1];
            uint8[]? cli_pub = parse_x25519_key_share (ch_hs, ext_off + 2, ext_len, false);
            if (cli_pub == null)
                throw new TlsError.HANDSHAKE ("Missing X25519 key_share in ClientHello");

            var priv = new uint8[32];
            var rand = new uint8[32];
            TlsCrypto.random_bytes (priv);
            TlsCrypto.random_bytes (rand);
            var pub = TlsCrypto.x25519_public (priv);
            var shared = TlsCrypto.x25519_scalarmult (priv, (!) cli_pub);

            // Build RFC 8446 ServerHello
            var sh_exts = new ByteArray.sized (48);
            ba_be16 (sh_exts, 0x002b); ba_be16 (sh_exts, 2); ba_be16 (sh_exts, 0x0304);
            ba_be16 (sh_exts, 0x0033); ba_be16 (sh_exts, 4 + 32);
            ba_be16 (sh_exts, 0x001d); ba_be16 (sh_exts, 32);
            ba_append_u8 (sh_exts, pub);

            var sh_body = new ByteArray.sized (96);
            ba_be16 (sh_body, 0x0303);
            ba_append_u8 (sh_body, rand);
            sh_body.append_byte ((uint8) sid_len);
            ba_append_u8 (sh_body, sid);
            ba_be16 (sh_body, 0x1303);
            sh_body.append_byte (0);
            ba_be16 (sh_body, sh_exts.len);
            ba_append_u8 (sh_body, ba_to_u8 (sh_exts));

            var sh_hs = new ByteArray.sized (110);
            sh_hs.append_byte (0x02);
            ba_be24 (sh_hs, sh_body.len);
            ba_append_u8 (sh_hs, ba_to_u8 (sh_body));
            var sh_hs_bytes = ba_to_u8 (sh_hs);

            var rec = new ByteArray.sized (sh_hs_bytes.length + 5);
            rec.append_byte (0x16); rec.append_byte (0x03); rec.append_byte (0x03);
            ba_be16 (rec, sh_hs_bytes.length);
            ba_append_u8 (rec, sh_hs_bytes);
            write_all (base_io_stream.get_output_stream (), ba_to_u8 (rec));

            var transcript = new ByteArray.sized (512);
            ba_append_u8 (transcript, ch_hs);
            ba_append_u8 (transcript, sh_hs_bytes);
            var thash_sh = TlsCrypto.sha256 (ba_to_u8 (transcript));

            derive_tls13_hs_keys (shared, thash_sh, false);
            TlsCrypto.zero_bytes (priv);
            TlsCrypto.zero_bytes (shared);

            // EncryptedExtensions (empty)
            uint8[] ee_msg = { 0x08, 0x00, 0x00, 0x02, 0x00, 0x00 };
            ba_append_u8 (transcript, ee_msg);
            tls_out.write_record (0x16, ee_msg);

            // Server Finished
            var thash_pre_fin = TlsCrypto.sha256 (ba_to_u8 (transcript));
            var fin_key = TlsCrypto.hkdf_expand_label (s_hs_secret, "finished", new uint8[0], 32);
            var sfin = TlsCrypto.hmac_sha256 (fin_key, thash_pre_fin);
            var sfin_msg = new uint8[36];
            sfin_msg[0] = 0x14; sfin_msg[1] = 0; sfin_msg[2] = 0; sfin_msg[3] = 32;
            Memory.copy (Sys.byte_arr_addr (sfin_msg) + 4, Sys.byte_arr_addr (sfin), 32);
            ba_append_u8 (transcript, sfin_msg);
            tls_out.write_record (0x16, sfin_msg);

            var thash_sfin = TlsCrypto.sha256 (ba_to_u8 (transcript));
            derive_tls13_app_secrets (thash_sfin);
            set_tx_secret (s_ap_secret);

            // Verify Client Finished (encrypted under c_hs_secret)
            uint8 ict = 0;
            uint8[]? cli_fin_rec = tls_in.read_decrypted_record (out ict);
            if (cli_fin_rec == null || ict != 0x16 || ((!) cli_fin_rec).length != 36 || ((!) cli_fin_rec)[0] != 0x14)
                throw new TlsError.HANDSHAKE ("Expected Client Finished");
            var cfin_key = TlsCrypto.hkdf_expand_label (c_hs_secret, "finished", new uint8[0], 32);
            var exp_cfin = TlsCrypto.hmac_sha256 (cfin_key, thash_sfin);
            if (!TlsCrypto.ct_memcmp ((!) cli_fin_rec, 4, exp_cfin, 0, 32))
                throw new TlsError.HANDSHAKE ("Client Finished verification failed");

            set_rx_secret (c_ap_secret);
            handshaked = true;
            return true;
        }
    }
}
