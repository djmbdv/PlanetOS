// DWARF v4 debug info emitter (.debug_line, .debug_abbrev, .debug_info).
// Produces standard DWARF v4 tables consumable by gdb/addr2line today and by
// a self-hosted PlanetOS debugger (`plandbg`) without libc/libdwarf.

namespace Planc {

    public class DebugLineEntry : Object {
        public int text_offset { get; set; }
        public int file_id { get; set; default = 1; }
        public int line { get; set; }
    }

    public class DebugVar : Object {
        public string name { get; set; }
        public int slot { get; set; }
        public ValaType var_type { get; set; }
        public bool is_param { get; set; default = false; }
    }

    public class DebugFunc : Object {
        public string name { get; set; }
        public int start_offset { get; set; }
        public int end_offset { get; set; }
        public int line { get; set; }
        public GenericArray<DebugVar> vars { get; private set; }

        public DebugFunc () {
            vars = new GenericArray<DebugVar> ();
        }
    }

    public class Dwarf : Object {

        private static void uleb128 (Buffer b, uint64 val) {
            uint64 v = val;
            while (true) {
                uint8 byte_val = (uint8) (v & 0x7Fu);
                v = v >> 7;
                if (v != 0)
                    byte_val = (uint8) (byte_val | 0x80u);
                b.u8 (byte_val);
                if (v == 0)
                    break;
            }
        }

        private static void sleb128 (Buffer b, int64 val) {
            int64 v = val;
            bool more = true;
            while (more) {
                uint8 byte_val = (uint8) (v & 0x7F);
                v = v >> 7;
                if ((v == 0 && (byte_val & 0x40) == 0)
                    || (v == -1 && (byte_val & 0x40) != 0)) {
                    more = false;
                } else {
                    byte_val = (uint8) (byte_val | 0x80u);
                }
                b.u8 (byte_val);
            }
        }

        private static void patch_u32le (Buffer b, int offset, uint32 val) {
            b.patch_u32le (offset, val);
        }

        public static void build (string source_file,
                                  uint64 text_vaddr,
                                  int text_size,
                                  GenericArray<DebugLineEntry> lines,
                                  GenericArray<DebugFunc> funcs,
                                  out uint8[] out_line,
                                  out uint8[] out_abbrev,
                                  out uint8[] out_info) {
            out_line = build_line (source_file, text_vaddr, text_size, lines);
            out_abbrev = build_abbrev ();
            out_info = build_info (source_file, text_vaddr, text_size, funcs);
        }

        private static uint8[] build_line (string source_file,
                                           uint64 text_vaddr,
                                           int text_size,
                                           GenericArray<DebugLineEntry> lines) {
            var b = new Buffer ();
            int len_pos = b.length;
            b.u32le (0); // unit_length placeholder
            b.u16le (4); // DWARF version 4
            int hdr_len_pos = b.length;
            b.u32le (0); // header_length placeholder
            int hdr_start = b.length;

            b.u8 (1);  // minimum_instruction_length
            b.u8 (1);  // maximum_operations_per_instruction
            b.u8 (1);  // default_is_stmt
            b.u8 ((uint8) (-5 & 0xFF)); // line_base = -5
            b.u8 (14); // line_range = 14
            b.u8 (13); // opcode_base = 13

            // Standard opcode lengths (opcodes 1..12)
            b.u8 (0); b.u8 (1); b.u8 (1); b.u8 (1);
            b.u8 (1); b.u8 (0); b.u8 (0); b.u8 (0);
            b.u8 (1); b.u8 (0); b.u8 (0); b.u8 (1);

            // include_directories: empty
            b.u8 (0);

            // file_names: 1 entry (file_id = 1)
            b.ascii (source_file);
            b.u8 (0);
            uleb128 (b, 0); // dir index
            uleb128 (b, 0); // mtime
            uleb128 (b, 0); // size
            b.u8 (0);       // end of file_names

            int hdr_end = b.length;
            patch_u32le (b, hdr_len_pos, (uint32) (hdr_end - hdr_start));

            if (lines.length > 0) {
                int cur_line = 1;
                uint64 cur_addr = text_vaddr + (uint64) lines[0].text_offset;
                // DW_LNE_set_address (extended opcode 2, len 9)
                b.u8 (0);
                uleb128 (b, 9);
                b.u8 (2);
                b.u64le (cur_addr);

                for (int i = 0; i < lines.length; i++) {
                    var e = lines[i];
                    uint64 addr = text_vaddr + (uint64) e.text_offset;
                    if (addr > cur_addr) {
                        b.u8 (2); // DW_LNS_advance_pc
                        uleb128 (b, addr - cur_addr);
                        cur_addr = addr;
                    }
                    if (e.line != cur_line) {
                        b.u8 (3); // DW_LNS_advance_line
                        sleb128 (b, (int64) (e.line - cur_line));
                        cur_line = e.line;
                    }
                    b.u8 (1); // DW_LNS_copy
                }
            }

            // End sequence at text_vaddr + text_size
            uint64 end_addr = text_vaddr + (uint64) text_size;
            b.u8 (0);
            uleb128 (b, 9);
            b.u8 (2); // DW_LNE_set_address
            b.u64le (end_addr);

            b.u8 (0);
            uleb128 (b, 1);
            b.u8 (1); // DW_LNE_end_sequence

            patch_u32le (b, len_pos, (uint32) (b.length - 4));
            return b.to_array ();
        }

        private static uint8[] build_abbrev () {
            var b = new Buffer ();

            // Abbrev 1: DW_TAG_compile_unit (0x11), children = yes (1)
            uleb128 (b, 1);
            uleb128 (b, 0x11);
            b.u8 (1);
            uleb128 (b, 0x25); uleb128 (b, 0x08); // DW_AT_producer : DW_FORM_string
            uleb128 (b, 0x03); uleb128 (b, 0x08); // DW_AT_name     : DW_FORM_string
            uleb128 (b, 0x11); uleb128 (b, 0x01); // DW_AT_low_pc   : DW_FORM_addr
            uleb128 (b, 0x12); uleb128 (b, 0x06); // DW_AT_high_pc  : DW_FORM_data4
            uleb128 (b, 0x10); uleb128 (b, 0x17); // DW_AT_stmt_list: DW_FORM_sec_offset
            b.u8 (0); b.u8 (0);

            // Abbrev 2: DW_TAG_subprogram (0x2e), children = yes (1)
            uleb128 (b, 2);
            uleb128 (b, 0x2e);
            b.u8 (1);
            uleb128 (b, 0x03); uleb128 (b, 0x08); // DW_AT_name       : DW_FORM_string
            uleb128 (b, 0x11); uleb128 (b, 0x01); // DW_AT_low_pc     : DW_FORM_addr
            uleb128 (b, 0x12); uleb128 (b, 0x06); // DW_AT_high_pc    : DW_FORM_data4
            uleb128 (b, 0x40); uleb128 (b, 0x18); // DW_AT_frame_base : DW_FORM_exprloc
            b.u8 (0); b.u8 (0);

            // Abbrev 3: DW_TAG_base_type (0x24), children = no (0)
            uleb128 (b, 3);
            uleb128 (b, 0x24);
            b.u8 (0);
            uleb128 (b, 0x03); uleb128 (b, 0x08); // DW_AT_name      : DW_FORM_string
            uleb128 (b, 0x3e); uleb128 (b, 0x0b); // DW_AT_encoding  : DW_FORM_data1
            uleb128 (b, 0x0b); uleb128 (b, 0x0b); // DW_AT_byte_size : DW_FORM_data1
            b.u8 (0); b.u8 (0);

            // Abbrev 4: DW_TAG_formal_parameter (0x05), children = no (0)
            uleb128 (b, 4);
            uleb128 (b, 0x05);
            b.u8 (0);
            uleb128 (b, 0x03); uleb128 (b, 0x08); // DW_AT_name     : DW_FORM_string
            uleb128 (b, 0x49); uleb128 (b, 0x13); // DW_AT_type     : DW_FORM_ref4
            uleb128 (b, 0x02); uleb128 (b, 0x18); // DW_AT_location : DW_FORM_exprloc
            b.u8 (0); b.u8 (0);

            // Abbrev 5: DW_TAG_variable (0x34), children = no (0)
            uleb128 (b, 5);
            uleb128 (b, 0x34);
            b.u8 (0);
            uleb128 (b, 0x03); uleb128 (b, 0x08); // DW_AT_name     : DW_FORM_string
            uleb128 (b, 0x49); uleb128 (b, 0x13); // DW_AT_type     : DW_FORM_ref4
            uleb128 (b, 0x02); uleb128 (b, 0x18); // DW_AT_location : DW_FORM_exprloc
            b.u8 (0); b.u8 (0);

            b.u8 (0); // end of abbrev table
            return b.to_array ();
        }

        private static uint32 emit_base_type (Buffer b, string name, uint8 enc, uint8 size) {
            uint32 cu_off = (uint32) b.length;
            uleb128 (b, 3);
            b.ascii (name);
            b.u8 (0);
            b.u8 (enc);
            b.u8 (size);
            return cu_off;
        }

        private static uint8[] build_info (string source_file,
                                           uint64 text_vaddr,
                                           int text_size,
                                           GenericArray<DebugFunc> funcs) {
            var b = new Buffer ();
            int len_pos = b.length;
            b.u32le (0); // unit_length placeholder
            b.u16le (4); // DWARF version 4
            b.u32le (0); // debug_abbrev_offset
            b.u8 (8);    // address_size = 8

            // CU DIE (abbrev 1)
            uleb128 (b, 1);
            b.ascii ("planc"); b.u8 (0);
            b.ascii (source_file); b.u8 (0);
            b.u64le (text_vaddr);
            b.u32le ((uint32) text_size);
            b.u32le (0); // DW_AT_stmt_list -> offset 0 in .debug_line

            // Base types inside CU: signed=5, unsigned=7, float=4, bool=2
            uint32 ty_int = emit_base_type (b, "int64", 5, 8);
            uint32 ty_ptr = emit_base_type (b, "ptr", 7, 8);
            uint32 ty_fp = emit_base_type (b, "double", 4, 8);
            uint32 ty_bool = emit_base_type (b, "bool", 2, 1);

            for (int fi = 0; fi < funcs.length; fi++) {
                var fn = funcs[fi];
                if (fn.end_offset <= fn.start_offset)
                    continue;
                uleb128 (b, 2); // DW_TAG_subprogram
                b.ascii (fn.name); b.u8 (0);
                b.u64le (text_vaddr + (uint64) fn.start_offset);
                b.u32le ((uint32) (fn.end_offset - fn.start_offset));
                // DW_AT_frame_base = DW_OP_reg6 (rbp = 0x56)
                uleb128 (b, 1);
                b.u8 (0x56);

                for (int vi = 0; vi < fn.vars.length; vi++) {
                    var dv = fn.vars[vi];
                    if (dv.name.has_prefix ("#"))
                        continue;
                    uleb128 (b, dv.is_param ? 4 : 5);
                    b.ascii (dv.name); b.u8 (0);
                    uint32 ty_ref = ty_ptr;
                    if (dv.var_type == ValaType.INT || dv.var_type == ValaType.ENUM)
                        ty_ref = ty_int;
                    else if (dv.var_type == ValaType.FLOAT || dv.var_type == ValaType.DOUBLE)
                        ty_ref = ty_fp;
                    else if (dv.var_type == ValaType.BOOL)
                        ty_ref = ty_bool;
                    b.u32le (ty_ref);

                    // DW_AT_location: DW_OP_fbreg (0x91) + sleb128(-8 * (slot + 1))
                    var loc = new Buffer ();
                    loc.u8 (0x91);
                    sleb128 (loc, (int64) (-8 * (dv.slot + 1)));
                    var loc_bytes = loc.to_array ();
                    uleb128 (b, (uint64) loc_bytes.length);
                    for (int bi = 0; bi < loc_bytes.length; bi++)
                        b.u8 (loc_bytes[bi]);
                }
                b.u8 (0); // end of subprogram children
            }

            b.u8 (0); // end of CU children
            patch_u32le (b, len_pos, (uint32) (b.length - 4));
            return b.to_array ();
        }
    }
}
