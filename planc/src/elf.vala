// ELF64 static executable writer.
//
// Produces three loadable segments and no more:
//   1. R|X  ELF header + program headers + .text
//   2. R    .rodata
//   3. RW   .data (file-backed) followed by .bss (memory-only zero fill)
//
// Never a RWX segment (KR-03): the writable segment carries no X flag. There
// is no dynamic section, no interpreter and no relocation table: the image is
// final.
//
// Beyond the segments it writes the non-allocated sections that make the file
// inspectable -- .symtab, .strtab and .shstrtab. That is not cosmetic: with no
// section headers, objdump and nm report "no sections" and refuse to
// disassemble or list anything, which leaves the toolchain unverifiable.

namespace Planc {

    public class Symbol : Object {
        public string name;
        public int offset;   // offset inside .text
        public int size;     // byte length of the symbol's code

        public Symbol (string name, int offset, int size) {
            this.name = name;
            this.offset = offset;
            this.size = size;
        }
    }

    public class Elf : Object {

        public const uint64 BASE_ADDRESS = 0x400000;
        public const int HEADER_SIZE = 64;
        public const int PROGRAM_HEADER_SIZE = 56;
        public const int PROGRAM_HEADER_COUNT = 3;
        public const int SECTION_HEADER_SIZE = 64;
        public const int SECTION_HEADER_COUNT = 11;
        public const int PAGE_SIZE = 0x1000;
        public const int SYMBOL_ENTRY_SIZE = 24;

        public const uint32 SHT_NULL = 0;
        public const uint32 SHT_PROGBITS = 1;
        public const uint32 SHT_SYMTAB = 2;
        public const uint32 SHT_STRTAB = 3;
        public const uint32 SHT_NOBITS = 8;

        public const uint64 SHF_WRITE = 0x1;
        public const uint64 SHF_ALLOC = 0x2;
        public const uint64 SHF_EXECINSTR = 0x4;

        public const uint8 STB_GLOBAL = 1;
        public const uint8 STT_FUNC = 2;

        public const uint16 SHN_TEXT = 1;

        // Section indices, in the order the section headers are written.
        public const int SEC_NULL = 0;
        public const int SEC_TEXT = 1;
        public const int SEC_RODATA = 2;
        public const int SEC_DATA = 3;
        public const int SEC_BSS = 4;
        public const int SEC_SYMTAB = 5;
        public const int SEC_STRTAB = 6;
        public const int SEC_SHSTRTAB = 7;
        public const int SEC_DEBUG_LINE = 8;
        public const int SEC_DEBUG_ABBREV = 9;
        public const int SEC_DEBUG_INFO = 10;

        public struct Layout {
            public int text_offset;
            public int text_size;
            public int rodata_offset;
            public int rodata_size;
            public int data_offset;
            public int data_size;
            public int bss_size;
            public int symtab_offset;
            public int symtab_size;
            public int strtab_offset;
            public int strtab_size;
            public int shstrtab_offset;
            public int shstrtab_size;
            public int debug_line_offset;
            public int debug_line_size;
            public int debug_abbrev_offset;
            public int debug_abbrev_size;
            public int debug_info_offset;
            public int debug_info_size;
            public int sections_offset;
            public uint64 text_vaddr;
            public uint64 rodata_vaddr;
            public uint64 data_vaddr;
        }

        public static int align_up (int value, int alignment) {
            var rest = value % alignment;
            return rest == 0 ? value : value + (alignment - rest);
        }

        // .shstrtab is built from separate literals on purpose: a single Vala
        // string constant containing NULs would be truncated at the first one.
        // Layout: "\0" ".text\0" ".rodata\0" ".data\0" ".bss\0" ".symtab\0"
        //         ".strtab\0" ".shstrtab\0"
        private const int SHSTRTAB_SIZE = 1 + 6 + 8 + 6 + 5 + 8 + 8 + 10 + 12 + 14 + 12;
        private const uint32 NAME_TEXT = 1;
        private const uint32 NAME_RODATA = 7;
        private const uint32 NAME_DATA = 15;
        private const uint32 NAME_BSS = 21;
        private const uint32 NAME_SYMTAB = 26;
        private const uint32 NAME_STRTAB = 34;
        private const uint32 NAME_SHSTRTAB = 42;
        private const uint32 NAME_DEBUG_LINE = 52;
        private const uint32 NAME_DEBUG_ABBREV = 64;
        private const uint32 NAME_DEBUG_INFO = 78;

        private static int strtab_size (GenericArray<Symbol> symbols) {
            var size = 1;  // leading NUL
            foreach (var s in symbols)
                size += s.name.length + 1;
            return size;
        }

        public static Layout compute (int text_size, int rodata_size,
                                      int data_size, int bss_size,
                                      GenericArray<Symbol> symbols) {
            var l = Layout ();
            l.text_offset = HEADER_SIZE + PROGRAM_HEADER_SIZE * PROGRAM_HEADER_COUNT;
            l.text_size = text_size;
            l.text_vaddr = BASE_ADDRESS + (uint64) l.text_offset;

            l.rodata_offset = align_up (l.text_offset + text_size, PAGE_SIZE);
            l.rodata_size = rodata_size;
            l.rodata_vaddr = BASE_ADDRESS + (uint64) l.rodata_offset;

            // The data segment must start on a page of its own: two segments
            // may never map the same page with different permissions. An
            // empty .rodata still owns its page, so the data segment begins
            // on the next one.
            var rodata_end = l.rodata_offset + (rodata_size > 0 ? rodata_size : 1);
            l.data_offset = align_up (rodata_end, PAGE_SIZE);
            l.data_size = data_size;
            l.bss_size = bss_size;
            l.data_vaddr = BASE_ADDRESS + (uint64) l.data_offset;

            // Everything from here on is not loaded: it lives past the last
            // segment's p_filesz and no PT_LOAD covers it.
            l.symtab_offset = align_up (l.data_offset + data_size, 8);
            l.symtab_size = SYMBOL_ENTRY_SIZE * (1 + symbols.length);
            l.strtab_offset = l.symtab_offset + l.symtab_size;
            l.strtab_size = strtab_size (symbols);
            l.shstrtab_offset = l.strtab_offset + l.strtab_size;
            l.shstrtab_size = SHSTRTAB_SIZE;
            l.debug_line_offset = l.shstrtab_offset + l.shstrtab_size;
            l.debug_line_size = 0;
            l.debug_abbrev_offset = l.debug_line_offset;
            l.debug_abbrev_size = 0;
            l.debug_info_offset = l.debug_abbrev_offset;
            l.debug_info_size = 0;
            l.sections_offset = align_up (l.shstrtab_offset + l.shstrtab_size, 8);
            return l;
        }

        public static void set_dwarf_sizes (ref Layout l, int line_sz, int abbrev_sz, int info_sz) {
            l.debug_line_offset = l.shstrtab_offset + l.shstrtab_size;
            l.debug_line_size = line_sz;
            l.debug_abbrev_offset = l.debug_line_offset + l.debug_line_size;
            l.debug_abbrev_size = abbrev_sz;
            l.debug_info_offset = l.debug_abbrev_offset + l.debug_abbrev_size;
            l.debug_info_size = info_sz;
            l.sections_offset = align_up (l.debug_info_offset + l.debug_info_size, 8);
        }

        public static uint64 entry_for (Layout l, GenericArray<Symbol> symbols, string name) {
            foreach (var s in symbols) {
                if (s.name == name)
                    return l.text_vaddr + (uint64) s.offset;
            }
            Host.panic (@"no symbol named $name to use as entry point");
            return 0;
        }

        public static uint8[] build (uint8[] text, uint8[] rodata, uint8[] data,
                                     GenericArray<Symbol> symbols, Layout l,
                                     uint8[] debug_line, uint8[] debug_abbrev, uint8[] debug_info,
                                     string entry_name = "_start") {
            var f = new Buffer (4096);

            // _start, not main: the stub aligns rsp, calls main and exits
            // with its return value, so main obeys the standard convention.
            write_header (f, l, entry_for (l, symbols, entry_name));

            // Segment 1: R|X, covers headers and .text.
            write_program_header (f, 5 /* PF_R|PF_X */,
                                  l.text_offset, l.text_vaddr,
                                  l.text_size, l.text_size);

            // Segment 2: R, covers .rodata only.
            write_program_header (f, 4 /* PF_R */,
                                  l.rodata_offset, l.rodata_vaddr,
                                  l.rodata_size, l.rodata_size);

            // Segment 3: RW, covers .data in the file and .bss in memory.
            write_program_header (f, 6 /* PF_R|PF_W */,
                                  l.data_offset, l.data_vaddr,
                                  l.data_size, l.data_size + l.bss_size);

            expect_length (f, l.text_offset, "program headers");

            f.bytes (text);
            if (entry_name == "_kstart32" && text.length >= 40
                && text[8] == 0x02 && text[9] == 0xB0 && text[10] == 0xAD && text[11] == 0x1B) {
                // Patch Multiboot1 load_end_addr (+28) and bss_end_addr (+32) in .text
                uint32 load_end = (uint32) (l.data_vaddr + (uint64) l.data_size);
                uint32 bss_end = (uint32) (l.data_vaddr + (uint64) l.data_size + (uint64) l.bss_size);
                f.patch_u32le (l.text_offset + 28, load_end);
                f.patch_u32le (l.text_offset + 32, bss_end);
            }
            expect_length (f, l.text_offset + l.text_size, ".text");

            f.zeroes (l.rodata_offset - f.length);
            f.bytes (rodata);
            expect_length (f, l.rodata_offset + l.rodata_size, ".rodata");

            f.zeroes (l.data_offset - f.length);
            f.bytes (data);
            expect_length (f, l.data_offset + l.data_size, ".data");

            // .bss occupies no file bytes: the loader zero-fills p_memsz
            // beyond p_filesz.

            f.zeroes (l.symtab_offset - f.length);
            write_symbols (f, l, symbols);
            expect_length (f, l.symtab_offset + l.symtab_size, ".symtab");

            write_strtab (f, symbols);
            expect_length (f, l.strtab_offset + l.strtab_size, ".strtab");

            write_shstrtab (f);
            expect_length (f, l.shstrtab_offset + l.shstrtab_size, ".shstrtab");

            f.bytes (debug_line);
            expect_length (f, l.debug_line_offset + l.debug_line_size, ".debug_line");

            f.bytes (debug_abbrev);
            expect_length (f, l.debug_abbrev_offset + l.debug_abbrev_size, ".debug_abbrev");

            f.bytes (debug_info);
            expect_length (f, l.debug_info_offset + l.debug_info_size, ".debug_info");

            f.zeroes (l.sections_offset - f.length);
            write_sections (f, l);
            expect_length (f, l.sections_offset + SECTION_HEADER_SIZE * SECTION_HEADER_COUNT,
                           "section headers");

            return f.to_array ();
        }

        private static void expect_length (Buffer f, int expected, string what) {
            if (f.length != expected)
                Host.panic (@"$what at 0x$(Host.hex_u32 ((uint32) f.length)), layout says 0x$(Host.hex_u32 ((uint32) expected))");
        }

        private static void write_header (Buffer f, Layout l, uint64 entry) {
            f.bytes (new uint8[] { 0x7F, (uint8) 'E', (uint8) 'L', (uint8) 'F' });
            f.u8 (2);      // ELFCLASS64
            f.u8 (1);      // ELFDATA2LSB
            f.u8 (1);      // EV_CURRENT
            f.u8 (0);      // ELFOSABI_SYSV
            f.zeroes (8);  // padding of e_ident

            f.u16le (2);                                    // ET_EXEC
            f.u16le (62);                                   // EM_X86_64
            f.u32le (1);                                    // e_version
            f.u64le (entry);                                // e_entry
            f.u64le (HEADER_SIZE);                          // e_phoff
            f.u64le ((uint64) l.sections_offset);           // e_shoff
            f.u32le (0);                                    // e_flags
            f.u16le ((uint16) HEADER_SIZE);                 // e_ehsize
            f.u16le ((uint16) PROGRAM_HEADER_SIZE);         // e_phentsize
            f.u16le ((uint16) PROGRAM_HEADER_COUNT);        // e_phnum
            f.u16le ((uint16) SECTION_HEADER_SIZE);         // e_shentsize
            f.u16le ((uint16) SECTION_HEADER_COUNT);        // e_shnum
            f.u16le ((uint16) SEC_SHSTRTAB);                // e_shstrndx
        }

        private static void write_program_header (Buffer f, uint32 flags,
                                                  int offset, uint64 vaddr,
                                                  int filesz, int memsz) {
            f.u32le (1);                    // PT_LOAD
            f.u32le (flags);                // PF_X=1, PF_W=2, PF_R=4
            f.u64le ((uint64) offset);
            f.u64le (vaddr);
            f.u64le (vaddr);                // p_paddr
            f.u64le ((uint64) filesz);      // p_filesz
            f.u64le ((uint64) memsz);       // p_memsz: > filesz only with .bss
            f.u64le ((uint64) PAGE_SIZE);   // p_align
        }

        private static void write_symbols (Buffer f, Layout l, GenericArray<Symbol> symbols) {
            // Index 0 is the reserved null symbol.
            f.zeroes (SYMBOL_ENTRY_SIZE);

            uint32 name_offset = 1;  // the leading NUL of .strtab
            foreach (var s in symbols) {
                f.u32le (name_offset);                      // st_name
                f.u8 ((uint8) ((STB_GLOBAL << 4) | STT_FUNC));  // st_info
                f.u8 (0);                                   // st_other
                f.u16le (SHN_TEXT);                         // st_shndx
                f.u64le (l.text_vaddr + (uint64) s.offset); // st_value
                f.u64le ((uint64) s.size);                  // st_size
                name_offset += (uint32) s.name.length + 1;
            }
        }

        private static void write_strtab (Buffer f, GenericArray<Symbol> symbols) {
            f.u8 (0);
            foreach (var s in symbols) {
                f.ascii (s.name);
                f.u8 (0);
            }
        }

        private static void write_shstrtab (Buffer f) {
            f.u8 (0);
            f.ascii (".text");
            f.u8 (0);
            f.ascii (".rodata");
            f.u8 (0);
            f.ascii (".data");
            f.u8 (0);
            f.ascii (".bss");
            f.u8 (0);
            f.ascii (".symtab");
            f.u8 (0);
            f.ascii (".strtab");
            f.u8 (0);
            f.ascii (".shstrtab");
            f.u8 (0);
            f.ascii (".debug_line");
            f.u8 (0);
            f.ascii (".debug_abbrev");
            f.u8 (0);
            f.ascii (".debug_info");
            f.u8 (0);
        }

        private static void write_sections (Buffer f, Layout l) {
            // SEC_NULL
            write_section_header (f, 0, SHT_NULL, 0, 0, 0, 0, 0, 0, 0, 0);
            // SEC_TEXT
            write_section_header (f, NAME_TEXT, SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR,
                                  l.text_vaddr, (uint64) l.text_offset,
                                  (uint64) l.text_size, 0, 0, 16, 0);
            // SEC_RODATA
            write_section_header (f, NAME_RODATA, SHT_PROGBITS, SHF_ALLOC,
                                  l.rodata_vaddr, (uint64) l.rodata_offset,
                                  (uint64) l.rodata_size, 0, 0, 1, 0);
            // SEC_DATA
            write_section_header (f, NAME_DATA, SHT_PROGBITS, SHF_ALLOC | SHF_WRITE,
                                  l.data_vaddr, (uint64) l.data_offset,
                                  (uint64) l.data_size, 0, 0, 8, 0);
            // SEC_BSS: NOBITS, occupies no file bytes
            write_section_header (f, NAME_BSS, SHT_NOBITS, SHF_ALLOC | SHF_WRITE,
                                  l.data_vaddr + (uint64) l.data_size,
                                  (uint64) (l.data_offset + l.data_size),
                                  (uint64) l.bss_size, 0, 0, 8, 0);
            // SEC_SYMTAB: sh_link points at .strtab, sh_info at the first global.
            write_section_header (f, NAME_SYMTAB, SHT_SYMTAB, 0,
                                  0, (uint64) l.symtab_offset,
                                  (uint64) l.symtab_size,
                                  SEC_STRTAB, 1, 8, SYMBOL_ENTRY_SIZE);
            // SEC_STRTAB
            write_section_header (f, NAME_STRTAB, SHT_STRTAB, 0,
                                  0, (uint64) l.strtab_offset,
                                  (uint64) l.strtab_size, 0, 0, 1, 0);
            // SEC_SHSTRTAB
            write_section_header (f, NAME_SHSTRTAB, SHT_STRTAB, 0,
                                  0, (uint64) l.shstrtab_offset,
                                  (uint64) l.shstrtab_size, 0, 0, 1, 0);
            // SEC_DEBUG_LINE
            write_section_header (f, NAME_DEBUG_LINE, SHT_PROGBITS, 0,
                                  0, (uint64) l.debug_line_offset,
                                  (uint64) l.debug_line_size, 0, 0, 1, 0);
            // SEC_DEBUG_ABBREV
            write_section_header (f, NAME_DEBUG_ABBREV, SHT_PROGBITS, 0,
                                  0, (uint64) l.debug_abbrev_offset,
                                  (uint64) l.debug_abbrev_size, 0, 0, 1, 0);
            // SEC_DEBUG_INFO
            write_section_header (f, NAME_DEBUG_INFO, SHT_PROGBITS, 0,
                                  0, (uint64) l.debug_info_offset,
                                  (uint64) l.debug_info_size, 0, 0, 1, 0);
        }

        private static void write_section_header (Buffer f, uint32 name, uint32 type,
                                                  uint64 flags, uint64 addr,
                                                  uint64 offset, uint64 size,
                                                  uint32 link, uint32 info,
                                                  uint64 align, uint64 entry_size) {
            f.u32le (name);
            f.u32le (type);
            f.u64le (flags);
            f.u64le (addr);
            f.u64le (offset);
            f.u64le (size);
            f.u32le (link);
            f.u32le (info);
            f.u64le (align);
            f.u64le (entry_size);
        }
    }
}
