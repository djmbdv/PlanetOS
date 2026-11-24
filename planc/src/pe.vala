// PE32+ (Windows x86-64) static/import executable writer.
//
// Produces four sections:
//   1. .text  (R|X)  code
//   2. .rdata (R)    read-only constants & vtables
//   3. .data  (R|W)  initialized globals + zero-filled BSS tail (VirtualSize)
//   4. .idata (R|W)  Import Directory, ILT, IAT, and KERNEL32.dll hint/names
//
// Uses fixed ImageBase (NX_COMPAT, no DYNAMIC_BASE) so RIP-relative and
// 64-bit .rdata/.data pointers require no base relocations.

namespace Planc {

    public struct PeLayout {
        public uint64 image_base;
        public uint32 text_rva;
        public uint32 text_raw_off;
        public uint32 text_raw_size;
        public uint32 text_vsize;
        public uint32 rodata_rva;
        public uint32 rodata_raw_off;
        public uint32 rodata_raw_size;
        public uint32 rodata_vsize;
        public uint32 data_rva;
        public uint32 data_raw_off;
        public uint32 data_raw_size;
        public uint32 data_vsize;
        public int data_size;
        public uint32 idata_rva;
        public uint32 idata_raw_off;
        public uint32 idata_raw_size;
        public uint32 idata_vsize;
        public uint32 iat_rva;
        public uint32 iat_size;
        public uint32 ilt_rva;
        public uint32 size_of_image;
        public uint64 text_vaddr;
        public uint64 rodata_vaddr;
        public uint64 data_vaddr;
        public uint64 iat_vaddr;
    }

    public sealed class Pe : Object {

        public const uint64 DEFAULT_IMAGE_BASE = 0x140000000UL;
        public const int SECTION_ALIGN = 0x1000;
        public const int FILE_ALIGN = 0x200;
        public const int HEADER_RAW_SIZE = 0x400;

        public const int IAT_EXIT_PROCESS = 0;
        public const int IAT_GET_STD_HANDLE = 1;
        public const int IAT_WRITE_FILE = 2;
        public const int IAT_VIRTUAL_ALLOC = 3;
        public const int IAT_COUNT = 4;

        private static uint32 align_u32 (uint32 v, uint32 a) {
            uint32 r = v % a;
            return (r == 0) ? v : (v + (a - r));
        }

        private static string[] kernel32_names () {
            return new string[] {
                "ExitProcess",
                "GetStdHandle",
                "WriteFile",
                "VirtualAlloc"
            };
        }

        private static uint8[] build_idata (uint32 idata_rva, out uint32 ilt_off, out uint32 iat_off, out uint32 iat_size) {
            var names = kernel32_names ();
            int n = names.length;
            uint32 dir_size = 40; // 2 * IMAGE_IMPORT_DESCRIPTOR (KERNEL32 + null)
            uint32 table_size = (uint32) ((n + 1) * 8);
            ilt_off = dir_size;
            iat_off = ilt_off + table_size;
            iat_size = table_size;

            var buf = new Buffer (256);
            // Reserve Import Directory + ILT + IAT (filled once hint/name RVAs are known)
            for (uint32 i = 0; i < dir_size + table_size * 2; i++)
                buf.u8 (0);

            var hn_rvas = new uint32[n];
            for (int i = 0; i < n; i++) {
                if ((buf.length % 2) != 0) buf.u8 (0);
                hn_rvas[i] = idata_rva + (uint32) buf.length;
                buf.u16le (0); // Hint = 0
                for (int k = 0; k < names[i].length; k++)
                    buf.u8 ((uint8) names[i][k]);
                buf.u8 (0);
            }

            uint32 dll_name_rva = idata_rva + (uint32) buf.length;
            string dll = "KERNEL32.dll";
            for (int k = 0; k < dll.length; k++)
                buf.u8 ((uint8) dll[k]);
            buf.u8 (0);

            var raw = buf.to_array ();

            // IMAGE_IMPORT_DESCRIPTOR[0] at offset 0:
            //   OriginalFirstThunk (+0), TimeDateStamp (+4), ForwarderChain (+8), Name (+12), FirstThunk (+16)
            put_u32 (raw, 0, idata_rva + ilt_off);
            put_u32 (raw, 12, dll_name_rva);
            put_u32 (raw, 16, idata_rva + iat_off);

            // Fill ILT and IAT with Hint/Name RVAs
            for (int i = 0; i < n; i++) {
                put_u64 (raw, (int) ilt_off + i * 8, (uint64) hn_rvas[i]);
                put_u64 (raw, (int) iat_off + i * 8, (uint64) hn_rvas[i]);
            }
            return raw;
        }

        private static void put_u32 (uint8[] buf, int off, uint32 v) {
            buf[off + 0] = (uint8) (v & 0xff);
            buf[off + 1] = (uint8) ((v >> 8) & 0xff);
            buf[off + 2] = (uint8) ((v >> 16) & 0xff);
            buf[off + 3] = (uint8) ((v >> 24) & 0xff);
        }

        private static void put_u64 (uint8[] buf, int off, uint64 v) {
            for (int k = 0; k < 8; k++)
                buf[off + k] = (uint8) ((v >> (8 * k)) & 0xff);
        }

        public static PeLayout compute (int text_len, int rodata_len, int data_len, int bss_len, uint64 image_base = 0) {
            var l = PeLayout ();
            l.image_base = (image_base != 0) ? image_base : DEFAULT_IMAGE_BASE;

            uint32 cur_rva = SECTION_ALIGN;
            uint32 cur_raw = HEADER_RAW_SIZE;

            l.text_rva = cur_rva;
            l.text_raw_off = cur_raw;
            l.text_vsize = (uint32) ((text_len > 0) ? text_len : 1);
            l.text_raw_size = align_u32 (l.text_vsize, FILE_ALIGN);
            cur_rva += align_u32 (l.text_vsize, SECTION_ALIGN);
            cur_raw += l.text_raw_size;

            l.rodata_rva = cur_rva;
            l.rodata_raw_off = cur_raw;
            l.rodata_vsize = (uint32) ((rodata_len > 0) ? rodata_len : 1);
            l.rodata_raw_size = align_u32 (l.rodata_vsize, FILE_ALIGN);
            cur_rva += align_u32 (l.rodata_vsize, SECTION_ALIGN);
            cur_raw += l.rodata_raw_size;

            l.data_size = data_len;
            l.data_rva = cur_rva;
            l.data_raw_off = cur_raw;
            uint32 dv = (uint32) (data_len + bss_len);
            l.data_vsize = (dv > 0) ? dv : 1;
            l.data_raw_size = (data_len > 0) ? align_u32 ((uint32) data_len, FILE_ALIGN) : FILE_ALIGN;
            cur_rva += align_u32 (l.data_vsize, SECTION_ALIGN);
            cur_raw += l.data_raw_size;

            uint32 ilt_off = 0;
            uint32 iat_off = 0;
            uint32 iat_size = 0;
            var idata_probe = build_idata (cur_rva, out ilt_off, out iat_off, out iat_size);
            l.idata_rva = cur_rva;
            l.idata_raw_off = cur_raw;
            l.idata_vsize = (uint32) idata_probe.length;
            l.idata_raw_size = align_u32 (l.idata_vsize, FILE_ALIGN);
            l.ilt_rva = cur_rva + ilt_off;
            l.iat_rva = cur_rva + iat_off;
            l.iat_size = iat_size;
            cur_rva += align_u32 (l.idata_vsize, SECTION_ALIGN);

            l.size_of_image = cur_rva;
            l.text_vaddr = l.image_base + (uint64) l.text_rva;
            l.rodata_vaddr = l.image_base + (uint64) l.rodata_rva;
            l.data_vaddr = l.image_base + (uint64) l.data_rva;
            l.iat_vaddr = l.image_base + (uint64) l.iat_rva;
            return l;
        }

        private static void write_sec_hdr (Buffer b, string name, uint32 vsize, uint32 rva,
                                           uint32 raw_size, uint32 raw_off, uint32 chars) {
            for (int i = 0; i < 8; i++)
                b.u8 ((i < name.length) ? (uint8) name[i] : 0);
            b.u32le (vsize);
            b.u32le (rva);
            b.u32le (raw_size);
            b.u32le (raw_off);
            b.u32le (0); // PointerToRelocations
            b.u32le (0); // PointerToLinenumbers
            b.u16le (0); // NumberOfRelocations
            b.u16le (0); // NumberOfLinenumbers
            b.u32le (chars);
        }

        public static uint8[] build (PeLayout PeLayout,
                                     uint8[] text, uint8[] rodata, uint8[] data,
                                     int entry_offset) {
            uint32 ilt_off = 0;
            uint32 iat_off = 0;
            uint32 iat_size = 0;
            var idata = build_idata (PeLayout.idata_rva, out ilt_off, out iat_off, out iat_size);

            var hdr = new Buffer ();
            // DOS header (64 bytes): "MZ", e_lfanew = 0x40
            hdr.u16le (0x5A4D);
            for (int i = 2; i < 0x3C; i++) hdr.u8 (0);
            hdr.u32le (0x40);

            // PE signature + COFF header (24 bytes)
            hdr.u32le (0x00004550); // "PE\0\0"
            hdr.u16le (0x8664);     // IMAGE_FILE_MACHINE_AMD64
            hdr.u16le (4);          // NumberOfSections
            hdr.u32le (0);          // TimeDateStamp
            hdr.u32le (0);          // PointerToSymbolTable
            hdr.u32le (0);          // NumberOfSymbols
            hdr.u16le (240);        // SizeOfOptionalHeader (PE32+)
            hdr.u16le (0x0022);     // EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE

            // Optional Header (PE32+, 240 bytes)
            hdr.u16le (0x020B);     // Magic = PE32+
            hdr.u8 (1);             // MajorLinkerVersion
            hdr.u8 (0);             // MinorLinkerVersion
            hdr.u32le (PeLayout.text_raw_size);
            hdr.u32le (PeLayout.rodata_raw_size + PeLayout.data_raw_size + PeLayout.idata_raw_size);
            hdr.u32le (0);          // SizeOfUninitializedData
            hdr.u32le (PeLayout.text_rva + (uint32) entry_offset);
            hdr.u32le (PeLayout.text_rva);
            hdr.u64le (PeLayout.image_base);
            hdr.u32le (SECTION_ALIGN);
            hdr.u32le (FILE_ALIGN);
            hdr.u16le (6);          // MajorOSVersion
            hdr.u16le (0);          // MinorOSVersion
            hdr.u16le (0);          // MajorImageVersion
            hdr.u16le (0);          // MinorImageVersion
            hdr.u16le (6);          // MajorSubsystemVersion
            hdr.u16le (0);          // MinorSubsystemVersion
            hdr.u32le (0);          // Win32VersionValue
            hdr.u32le (PeLayout.size_of_image);
            hdr.u32le (HEADER_RAW_SIZE);
            hdr.u32le (0);          // CheckSum
            hdr.u16le (3);          // Subsystem = WINDOWS_CUI
            hdr.u16le (0x0100);     // DllCharacteristics = NX_COMPAT (fixed base)
            hdr.u64le (0x100000);   // SizeOfStackReserve
            hdr.u64le (0x1000);     // SizeOfStackCommit
            hdr.u64le (0x100000);   // SizeOfHeapReserve
            hdr.u64le (0x1000);     // SizeOfHeapCommit
            hdr.u32le (0);          // LoaderFlags
            hdr.u32le (16);         // NumberOfRvaAndSizes

            // Data Directories (16 * 8 = 128 bytes)
            for (int di = 0; di < 16; di++) {
                if (di == 1) {
                    hdr.u32le (PeLayout.idata_rva);
                    hdr.u32le (40);
                } else if (di == 12) {
                    hdr.u32le (PeLayout.iat_rva);
                    hdr.u32le (PeLayout.iat_size);
                } else {
                    hdr.u32le (0);
                    hdr.u32le (0);
                }
            }

            // Section Headers (4 * 40 = 160 bytes)
            write_sec_hdr (hdr, ".text", PeLayout.text_vsize, PeLayout.text_rva,
                           PeLayout.text_raw_size, PeLayout.text_raw_off, 0x60000020);
            write_sec_hdr (hdr, ".rdata", PeLayout.rodata_vsize, PeLayout.rodata_rva,
                           PeLayout.rodata_raw_size, PeLayout.rodata_raw_off, 0x40000040);
            write_sec_hdr (hdr, ".data", PeLayout.data_vsize, PeLayout.data_rva,
                           PeLayout.data_raw_size, PeLayout.data_raw_off, 0xC0000040u);
            write_sec_hdr (hdr, ".idata", PeLayout.idata_vsize, PeLayout.idata_rva,
                           PeLayout.idata_raw_size, PeLayout.idata_raw_off, 0xC0000040u);

            while (hdr.length < HEADER_RAW_SIZE)
                hdr.u8 (0);

            uint32 total_file_size = PeLayout.idata_raw_off + PeLayout.idata_raw_size;
            var out_bytes = new uint8[total_file_size];
            var hdr_arr = hdr.to_array ();
            for (int i = 0; i < hdr_arr.length; i++) out_bytes[i] = hdr_arr[i];
            for (int i = 0; i < text.length; i++) out_bytes[PeLayout.text_raw_off + i] = text[i];
            for (int i = 0; i < rodata.length; i++) out_bytes[PeLayout.rodata_raw_off + i] = rodata[i];
            for (int i = 0; i < data.length; i++) out_bytes[PeLayout.data_raw_off + i] = data[i];
            for (int i = 0; i < idata.length; i++) out_bytes[PeLayout.idata_raw_off + i] = idata[i];

            return out_bytes;
        }
    }
}
