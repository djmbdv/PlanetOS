// x86_64 instruction emitter.
//
// Every instruction is a hand-written function with its bytes documented.
// There is no generic assembler yet; the set grows slice by slice and every
// encoding is verifiable with objdump.
//
// Encoding references: Intel SDM vol. 2.
//
// Relocations of slice 1, all resolved after the final layout is known:
//   RipPatch    .text -> .rodata   (string literals)
//   CallPatch   .text -> .text     (call rel32 to a symbol)
//   BranchPatch .text -> .text     (conditional and unconditional jumps)

namespace Planc {

    // A pending instruction-relative reference, resolved once the final layout
    // is known. This is the project's first relocation.
    public class RipPatch : Object {
        public int displacement;   // offset of the imm32 inside .text
        public int target;         // offset of the target inside its space
        public PatchSpace space = PatchSpace.RODATA;
    }

    // Which allocated buffer a rip-relative reference points into.
    public enum PatchSpace {
        RODATA,   // string literals
        DATA,     // initialized globals
        BSS,      // zero-initialized globals
        IAT       // Windows PE32+ Import Address Table slots
    }

    // Pending 64-bit absolute pointer in .data pointing into .rodata
    // (R_X86_64_64), used for global string variables.
    public class DataPatch : Object {
        public int data_offset;     // offset inside .data
        public int rodata_target;   // offset inside .rodata
    }

    // Pending 64-bit pointer inside .rodata (used in class vtables for
    // method pointers into .text and parent-vtable pointers into .rodata).
    public class RodataPatch : Object {
        public int rodata_offset;   // offset inside .rodata
        public bool is_text;        // true -> text_symbol; false -> rodata_target
        public string text_symbol = "";
        public int rodata_target = 0;
    }

    // call rel32 whose target is a symbol in .text.
    public class CallPatch : Object {
        public int displacement;   // offset of the rel32 inside .text
        public string callee;      // symbol name
    }

    // Branch targets are labels bound during generation. The rel32 itself is
    // written once the whole .text size is known, so forward references need
    // no backpatching inside the emitter.
    public class Label : Object {
        public int target = -1;    // offset inside .text, -1 until bound
        public bool adjusted = false;
    }

    public enum BranchKind {
        JMP,   // E9 rel32
        JE,    // 0F 84 rel32   jump if ZF
        JNE,   // 0F 85 rel32   jump if !ZF
        JL,    // 0F 8C rel32   jump if SF != OF (signed <)
        JLE,   // 0F 8E rel32
        JG,    // 0F 8F rel32
        JGE,   // 0F 8D rel32
        JAE,   // 0F 83 rel32   jump if !CF (unsigned >=)
        JBE,   // 0F 86 rel32   jump if CF || ZF (unsigned <=)
        JA,    // 0F 87 rel32   jump if !CF && !ZF (unsigned >)
        JB,    // 0F 82 rel32   jump if CF (unsigned <)
        JS,    // 0F 88 rel32   jump if SF (signed < 0)
        JNS,   // 0F 89 rel32   jump if !SF (signed >= 0)
        JP,    // 0F 8A rel32   jump if PF (parity / NaN)
        JO     // 0F 80 rel32   jump if OF (signed overflow)
    }

    public class BranchPatch : Object {
        public int displacement;   // offset of the rel32 inside .text
        public BranchKind kind;
        public Label label;
    }

    // Integer registers used by slice 1. The numeric value is the x86_64
    // register code (the low three bits of the ModRM byte); codes 8 and 9
    // (r8, r9) require a REX prefix.
    public enum Reg {
        RAX = 0, RCX = 1, RDX = 2, RBX = 3, RSP = 4, RBP = 5, RSI = 6, RDI = 7,
        R8 = 8, R9 = 9, R10 = 10, R11 = 11, R12 = 12, R13 = 13, R14 = 14, R15 = 15;

        public static bool is_extended (Reg r) {
            return r >= R8;
        }
    }

    public sealed class Emitter : Object {

        public Buffer code { get; private set; }
        public Buffer data { get; private set; }
        public Buffer init_data { get; private set; }   // .data: initialized globals
        public int bss_size { get; private set; }       // .bss: zeroed globals, bytes
        public GenericArray<RipPatch> patches { get; private set; }
        public GenericArray<DataPatch> data_patches { get; private set; }
        public GenericArray<RodataPatch> rodata_patches { get; private set; }
        public GenericArray<CallPatch> calls { get; private set; }
        public GenericArray<BranchPatch> branches { get; private set; }

        private GenericArray<string> string_literals;
        private GenericArray<int> string_offsets;
        private StrIndexMap string_index = new StrIndexMap ();
        public int rodata_bias { get; set; default = 0; }
        public bool target_windows { get; set; default = false; }

        public void emit_iat_call (int slot) {
            code.u8 (0xFF);
            code.u8 (0x15);
            record_rip (slot * 8, PatchSpace.IAT);
        }

        public void emit_win32_exit_edi () {
            code.u8 (0x89); code.u8 (0xF9);                         // mov ecx, edi
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xE4); code.u8 (0xF0); // and rsp, -16
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xEC); code.u8 (0x20); // sub rsp, 32
            emit_iat_call (Pe.IAT_EXIT_PROCESS);
            code.u8 (0xF4);                                         // hlt
        }

        public void emit_win32_write_buf (int fd) {
            // Input: rsi = buf, rdx = len. Preserves rbx, r12, rbp.
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54);                         // push r12
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xE4); code.u8 (0xF0); // and rsp, -16
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xEC); code.u8 (0x30); // sub rsp, 48
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xF3);         // mov rbx, rsi
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xD4);         // mov r12, rdx
            code.u8 (0xB9); code.u32le ((fd == 2) ? 0xFFFFFFF4u : 0xFFFFFFF5u); // mov ecx, STD_HANDLE
            emit_iat_call (Pe.IAT_GET_STD_HANDLE);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC1);         // mov rcx, rax
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDA);         // mov rdx, rbx
            code.u8 (0x45); code.u8 (0x89); code.u8 (0xE0);         // mov r8d, r12d
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x4C); code.u8 (0x24); code.u8 (0x28); // lea r9, [rsp+40]
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x20); code.u32le (0); // mov qword [rsp+32], 0
            emit_iat_call (Pe.IAT_WRITE_FILE);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x65); code.u8 (0xF0); // lea rsp, [rbp-16]
            code.u8 (0x41); code.u8 (0x5C);                         // pop r12
            pop_reg (Reg.RBX);
            pop_rbp ();
        }

        public Emitter () {
            code = new Buffer (1024);
            data = new Buffer (256);
            init_data = new Buffer (64);
            patches = new GenericArray<RipPatch> ();
            data_patches = new GenericArray<DataPatch> ();
            rodata_patches = new GenericArray<RodataPatch> ();
            calls = new GenericArray<CallPatch> ();
            branches = new GenericArray<BranchPatch> ();
            string_literals = new GenericArray<string> ();
            string_offsets = new GenericArray<int> ();
        }

        public int align_rodata_8 () {
            while (data.length % 8 != 0)
                data.u8 (0);
            return data.length;
        }

        public void add_rodata_u64 (uint64 v) {
            data.u64le (v);
        }

        public void add_rodata_text_ptr (string sym) {
            var p = new RodataPatch ();
            p.rodata_offset = data.length;
            p.is_text = true;
            p.text_symbol = sym;
            data.u64le (0);
            rodata_patches.add (p);
        }

        public void add_rodata_rodata_ptr (int target_off) {
            var p = new RodataPatch ();
            p.rodata_offset = data.length;
            p.is_text = false;
            p.rodata_target = target_off;
            data.u64le (0);
            rodata_patches.add (p);
        }

        // Reserves `bytes` (8-aligned) in .bss and returns its offset.
        public int add_bss_bytes (int bytes) {
            while (bss_size % 8 != 0)
                bss_size++;
            var offset = bss_size;
            bss_size += bytes;
            return offset;
        }

        // Reserves `bytes` zero bytes in .data and returns the base offset.
        public int add_data_bytes (int bytes) {
            var offset = init_data.length;
            init_data.zeroes (bytes);
            return offset;
        }

        // Records a DataPatch (R_X86_64_64) at `data_offset` pointing to
        // `rodata_offset`.
        public void add_data_patch (int data_offset, int rodata_offset) {
            var p = new DataPatch ();
            p.data_offset = data_offset;
            p.rodata_target = rodata_offset;
            data_patches.add (p);
        }

        // Registers an integer global: initialized globals append 8 bytes
        // to .data; zero-initialized ones only grow .bss.
        public int add_global (int64 value, bool initialized) {
            if (!initialized) {
                var slot = bss_size;
                bss_size += 8;
                return slot;
            }
            var offset = init_data.length;
            init_data.u64le ((uint64) value);
            return offset;
        }

        // Registers a string global in .data initialized to a .rodata string
        // pointer, patched via R_X86_64_64 after layout.
        public int add_string_global (int rodata_offset) {
            var offset = init_data.length;
            init_data.u64le (0);
            add_data_patch (offset, rodata_offset);
            return offset;
        }

        // lea rax, [rip + disp32]             48 8D 05 + disp32
        public void lea_rax_space (int offset, PatchSpace space) {
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x05);
            record_rip (offset, space);
        }

        // lea rcx, [rip + disp32]             48 8D 0D + disp32
        public void lea_rcx_space (int offset, PatchSpace space) {
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x0D);
            record_rip (offset, space);
        }

        // mov rax, [rip + disp32]            48 8B 05 + disp32
        public void load_global (int offset, PatchSpace space) {
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x05);
            record_rip (offset, space);
        }

        // mov [rip + disp32], rax            48 89 05 + disp32
        public void store_global (int offset, PatchSpace space) {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x05);
            record_rip (offset, space);
        }

        private void record_rip (int offset, PatchSpace space) {
            var patch = new RipPatch ();
            patch.displacement = code.length;
            patch.target = offset;
            patch.space = space;
            code.u32le (0);
            patches.add (patch);
        }

        // mov [rsp + d], rax                 48 89 44 24 d8 | 48 89 84 24 d32
        // Spills a stack argument into the caller's outgoing argument area.
        public void store_rsp (int disp) {
            if (disp >= 0 && disp <= 127) {
                code.u8 (0x48); code.u8 (0x89); code.u8 (0x44); code.u8 (0x24);
                code.u8 ((uint8) disp);
            } else {
                code.u8 (0x48); code.u8 (0x89); code.u8 (0x84); code.u8 (0x24);
                code.u32le ((uint32) disp);
            }
        }

        // mov rax, [rsp + d]                 48 8B 44 24 d8 | 48 8B 84 24 d32
        public void load_rsp (int disp) {
            if (disp >= 0 && disp <= 127) {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x44); code.u8 (0x24);
                code.u8 ((uint8) disp);
            } else {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x84); code.u8 (0x24);
                code.u32le ((uint32) disp);
            }
        }

        // Sign-extend low 8, 16, or 32 bits of rax to 64 bits.
        public void sign_extend_rax (int bits) {
            if (bits == 8) {
                code.u8 (0x48); code.u8 (0x0F); code.u8 (0xBE); code.u8 (0xC0); // movsx rax, al
            } else if (bits == 16) {
                code.u8 (0x48); code.u8 (0x0F); code.u8 (0xBF); code.u8 (0xC0); // movsx rax, ax
            } else if (bits == 32) {
                code.u8 (0x48); code.u8 (0x63); code.u8 (0xC0);                 // movsxd rax, eax
            }
        }

        // Appends a deduplicated string literal to .rodata with the 16-byte ABI
        // string header:
        //   +0  uint32 refcount = 0 (static .rodata literal)
        //   +4  uint32 hash = 0 (uncomputed)
        //   +8  uint64 length (UTF-8 byte count)
        //   +16 uint8  UTF-8 bytes..., 0x00
        // Returns its 8-byte aligned offset.
        public int add_string (string s) {
            int cached = string_index.lookup (s);
            if (cached >= 0)
                return cached - 1;
            while (data.length % 8 != 0)
                data.u8 (0);
            var offset = rodata_bias + data.length;
            data.u32le (0);
            data.u32le (0);
            data.u64le ((uint64) s.length);
            data.ascii (s);
            data.u8 (0);
            // Offsets can be 0, so the index stores offset + 1.
            string_index.put (s, offset + 1);
            return offset;
        }

        // lea rax, [rip + disp32]             48 8D 05 + disp32
        public void lea_rax_rip (int rodata_offset) {
            lea_rax_space (rodata_offset, PatchSpace.RODATA);
        }

        // lea rax, [rip + disp32] in .bss     48 8D 05 + disp32
        public void lea_rax_bss (int bss_offset) {
            lea_rax_space (bss_offset, PatchSpace.BSS);
        }

        public int here () {
            return code.length;
        }

        // ------------------------------------------------------------------
        // Labels and jumps.
        // ------------------------------------------------------------------

        public Label new_label () {
            return new Label ();
        }

        public int opt_level { get; set; default = 0; }
        private int last_push_rax_pos = -1;
        private int last_store_local_pos = -1;
        private int last_store_local_slot = -1;

        public void bind (Label l) {
            last_push_rax_pos = -1;
            last_store_local_pos = -1;
            l.target = code.length;
        }

        // Writes the branch opcode with a zero rel32 and records the patch.
        public void branch (BranchKind kind, Label l) {
            var p = new BranchPatch ();
            p.kind = kind;
            p.label = l;
            switch (kind) {
                case BranchKind.JMP:
                    p.displacement = code.length + 1;
                    code.u8 (0xE9);
                    break;
                case BranchKind.JE:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x84);
                    break;
                case BranchKind.JNE:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x85);
                    break;
                case BranchKind.JL:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x8C);
                    break;
                case BranchKind.JLE:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x8E);
                    break;
                case BranchKind.JG:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x8F);
                    break;
                case BranchKind.JGE:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x8D);
                    break;
                case BranchKind.JAE:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x83);
                    break;
                case BranchKind.JBE:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x86);
                    break;
                case BranchKind.JA:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x87);
                    break;
                case BranchKind.JB:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x82);
                    break;
                case BranchKind.JS:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x88);
                    break;
                case BranchKind.JNS:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x89);
                    break;
                case BranchKind.JO:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x80);
                    break;
                case BranchKind.JP:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x8A);
                    break;
            }
            code.u32le (0);
            branches.add (p);
        }

        // ------------------------------------------------------------------
        // Calls.
        // ------------------------------------------------------------------

        // call rel32                         E8 + rel32
        public void call_rel32 (string callee) {
            code.u8 (0xE8);
            var p = new CallPatch ();
            p.displacement = code.length;
            p.callee = callee;
            code.u32le (0);
            calls.add (p);
        }

        // ------------------------------------------------------------------
        // Stack frame.
        // ------------------------------------------------------------------

        // push rbp                           55
        public void push_rbp () {
            code.u8 (0x55);
        }

        // pop rbp                            5D
        public void pop_rbp () {
            code.u8 (0x5D);
        }

        // mov rbp, rsp                       48 89 E5
        public void mov_rsp_to_rbp () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xE5);
        }

        // sub rsp, imm                       48 83 EC imm8 | 48 81 EC imm32
        public void sub_rsp (int n) {
            if (n == 0)
                return;
            if (n >= -128 && n <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xEC);
                code.u8 ((uint8) n);
            } else {
                code.u8 (0x48); code.u8 (0x81); code.u8 (0xEC);
                code.u32le ((uint32) n);
            }
        }

        // add rsp, imm                       48 83 C4 imm8 | 48 81 C4 imm32
        public void add_rsp (int n) {
            if (n == 0)
                return;
            if (n >= -128 && n <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xC4);
                code.u8 ((uint8) n);
            } else {
                code.u8 (0x48); code.u8 (0x81); code.u8 (0xC4);
                code.u32le ((uint32) n);
            }
        }

        // push reg                           50+r | 41 50+r for r8/r9
        public void push_reg (Reg r) {
            if (Reg.is_extended (r))
                code.u8 (0x41);
            code.u8 ((uint8) (0x50 + ((int) r & 7)));
        }

        // pop reg                            58+r | 41 58+r for r8/r9
        public void pop_reg (Reg r) {
            if (Reg.is_extended (r))
                code.u8 (0x41);
            code.u8 ((uint8) (0x58 + ((int) r & 7)));
        }

        // leave                              C9   (mov rsp, rbp; pop rbp)
        public void leave () {
            if (reg_alloc_active && reg_alloc_save_count > 0) {
                int disp = -(reg_alloc_frame_bytes + 8 * reg_alloc_save_count);
                if (disp >= -128 && disp <= 127) {
                    code.u8 (0x48); code.u8 (0x8D); code.u8 (0x65);
                    code.u8 ((uint8) disp);
                } else {
                    code.u8 (0x48); code.u8 (0x8D); code.u8 (0xA5);
                    code.u32le ((uint32) disp);
                }
                if (reg_alloc_save_count >= 4) {
                    pop_reg (Reg.R15);
                    pop_reg (Reg.R14);
                }
                pop_reg (Reg.R13);
                pop_reg (Reg.R12);
            }
            code.u8 (0xC9);
        }

        // ret                                C3
        public void ret () {
            code.u8 (0xC3);
        }

        // ------------------------------------------------------------------
        // Moves.
        // ------------------------------------------------------------------

        // mov rax, imm: 32-bit sign-extended form (48 C7 C0 imm32) when the
        // value fits, movabs (48 B8 imm64) otherwise.
        public void mov_rax_imm (int64 v) {
            if (opt_level >= 1 && v == 0) {
                xor_eax ();
                return;
            }
            if (opt_level >= 2 && v > 0 && v <= int32.MAX) {
                code.u8 (0xB8);
                code.u32le ((uint32) v);
                return;
            }
            if (v >= int32.MIN && v <= int32.MAX) {
                code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC0);
                code.u32le ((uint32) (int32) v);
            } else {
                code.u8 (0x48); code.u8 (0xB8);
                code.u64le ((uint64) v);
            }
        }

        // mov rcx, rax                       48 89 C1
        public void mov_rcx_rax () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC1);
        }

        // mov rax, rcx                       48 89 C8
        public void mov_rax_rcx () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC8);
        }

        // mov rdx, rax                       48 89 C2
        public void mov_rdx_rax () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC2);
        }

        // mov rcx, rdx                       48 89 D1
        public void mov_rcx_rdx () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD1);
        }

        // mov rax, [rdx + disp]              48 8B 42 d8 | 48 8B 82 d32
        public void load_rdx_disp (int disp) {
            code.u8 (0x48); code.u8 (0x8B);
            emit_modrm_disp (0, 2, disp);
        }

        // mov rax, rdx                       48 89 D0
        public void mov_rax_rdx () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD0);
        }

        // mov rdi, rax                       48 89 C7
        public void mov_rdi_rax () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7);
        }

        // mov rax, rdi                       48 89 F8
        public void mov_rax_rdi () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xF8);
        }

        // mov rsi, rcx                       48 89 CE
        public void mov_rsi_rcx () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xCE);
        }

        // xor rax, 1                         48 83 F0 01
        public void xor_rax_one () {
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xF0); code.u8 (0x01);
        }

        private void emit_modrm_disp (uint8 reg, uint8 rm, int disp) {
            if (disp >= -128 && disp <= 127) {
                code.u8 ((uint8) (0x40 | (reg << 3) | rm));
                code.u8 ((uint8) disp);
            } else {
                code.u8 ((uint8) (0x80 | (reg << 3) | rm));
                code.u32le ((uint32) disp);
            }
        }

        // mov rax, [rax + disp]              48 8B 40 d8 | 48 8B 80 d32
        public void load_rax_disp (int disp) {
            code.u8 (0x48); code.u8 (0x8B);
            emit_modrm_disp (0, 0, disp);
        }

        // add rax, imm                       48 83 C0 imm8 | 48 05 imm32
        public void add_rax_imm (int disp) {
            if (disp == 0)
                return;
            if (opt_level >= 2 && disp == 1) {
                code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC0); // inc %rax
                return;
            }
            if (opt_level >= 2 && disp == -1) {
                code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC8); // dec %rax
                return;
            }
            if (disp >= -128 && disp <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xC0);
                code.u8 ((uint8) disp);
            } else {
                code.u8 (0x48); code.u8 (0x05);
                code.u32le ((uint32) disp);
            }
        }

        // mov [rcx + disp], rax              48 89 41 d8 | 48 89 81 d32
        public void store_rcx_disp_rax (int disp) {
            code.u8 (0x48); code.u8 (0x89);
            emit_modrm_disp (0, 1, disp);
        }

        // mov rax, [rcx + disp]              48 8B 41 d8 | 48 8B 81 d32
        public void load_rcx_disp_to_rax (int disp) {
            code.u8 (0x48); code.u8 (0x8B);
            emit_modrm_disp (0, 1, disp);
        }

        // mov [rax + disp], rcx              48 89 48 d8 | 48 89 88 d32
        public void store_rax_disp_rcx (int disp) {
            code.u8 (0x48); code.u8 (0x89);
            emit_modrm_disp (1, 0, disp);
        }

        // call qword ptr [rax + disp32]      FF 90 + disp32
        public void call_rax_disp (int disp) {
            code.u8 (0xFF); code.u8 (0x90);
            code.u32le ((uint32) disp);
        }

        // call rax                           FF D0
        public void call_rax () {
            code.u8 (0xFF); code.u8 (0xD0);
        }

        // lea rax, [rip + disp32] (.text)    48 8D 05 + disp32
        public void lea_rax_fn (string sym) {
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x05);
            var p = new CallPatch ();
            p.displacement = code.length;
            p.callee = sym;
            calls.add (p);
            code.u32le (0);
        }

        // mov rax, [rdi + disp32]            48 8B 87 + disp32
        public void load_rdi_disp_to_rax (int disp) {
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x87);
            code.u32le ((uint32) disp);
        }

        // lea rax, [rbp + d]                 48 8D 45 d8 | 48 8D 85 d32
        public void lea_rax_rbp_disp (int d) {
            code.u8 (0x48); code.u8 (0x8D);
            emit_modrm_disp (0, 5, d);
        }

        // lea rcx, [rbp + d]                 48 8D 4D d8 | 48 8D 8D d32
        public void lea_rcx_rbp_disp (int d) {
            code.u8 (0x48); code.u8 (0x8D);
            emit_modrm_disp (1, 5, d);
        }

        // mov rsi, rax                       48 89 C6
        public void mov_rsi_rax () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC6);
        }

        // mov rsi, [rsp]                     48 8B 34 24
        public void mov_rsi_rsp () {
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x34); code.u8 (0x24);
        }

        private int[] slot_reg_map = new int[0];
        private int reg_alloc_frame_bytes = 0;
        private int reg_alloc_save_count = 0;
        private bool reg_alloc_active = false;

        public void begin_reg_alloc (int frame_bytes, int reg_count = 4) {
            if (reg_count <= 0) {
                reg_alloc_active = false;
                reg_alloc_save_count = 0;
                return;
            }
            int save_n = (reg_count <= 2) ? 2 : 4;
            reg_alloc_frame_bytes = frame_bytes;
            reg_alloc_save_count = save_n;
            reg_alloc_active = true;
            slot_reg_map = new int[0];
            push_reg (Reg.R12);
            push_reg (Reg.R13);
            if (save_n >= 4) {
                push_reg (Reg.R14);
                push_reg (Reg.R15);
            }
        }

        public void end_reg_alloc () {
            reg_alloc_active = false;
            reg_alloc_frame_bytes = 0;
            reg_alloc_save_count = 0;
            slot_reg_map = new int[0];
        }

        public void assign_slot_reg (int slot, Reg r) {
            if (!reg_alloc_active || slot < 0)
                return;
            if (slot >= slot_reg_map.length) {
                int old_len = slot_reg_map.length;
                var grown = new int[slot + 8];
                for (int i = 0; i < old_len; i++)
                    grown[i] = slot_reg_map[i];
                for (int i = old_len; i < grown.length; i++)
                    grown[i] = -1;
                slot_reg_map = grown;
            }
            slot_reg_map[slot] = (int) r;
        }

        private int get_slot_reg (int slot) {
            if (reg_alloc_active && slot >= 0 && slot < slot_reg_map.length)
                return slot_reg_map[slot];
            return -1;
        }

        public void mov_reg_reg (Reg dst, Reg src) {
            if (dst == src) return;
            uint8 rex = (uint8) (0x48 | (Reg.is_extended (src) ? 4 : 0) | (Reg.is_extended (dst) ? 1 : 0));
            code.u8 (rex); code.u8 (0x89);
            code.u8 ((uint8) (0xC0 | (((int) src & 7) << 3) | ((int) dst & 7)));
        }

        public void zero_reg (Reg dst) {
            uint8 rex = (uint8) (0x40 | (Reg.is_extended (dst) ? 5 : 0));
            if (rex != 0x40)
                code.u8 (rex);
            code.u8 (0x31);
            code.u8 ((uint8) (0xC0 | (((int) dst & 7) << 3) | ((int) dst & 7)));
        }

        // mov qword ptr [rbp + d], 0         48 C7 45 d8 00000000 | 48 C7 85 d32 00000000
        public void zero_local (int slot) {
            if (async_task_rbp_offset != 0) {
                load_r10_async_task ();
                code.u8 (0x49); code.u8 (0xC7); code.u8 (0x82);
                code.u32le ((uint32) (80 + slot * 8));
                code.u32le (0);
                return;
            }
            int sr = get_slot_reg (slot);
            if (sr >= 0) {
                zero_reg ((Reg) sr);
                return;
            }
            code.u8 (0x48); code.u8 (0xC7);
            emit_modrm_disp (0, 5, slot_offset (slot));
            code.u32le (0);
        }

        public void zero_local_batch (int start_slot, int end_slot) {
            if (opt_level >= 2 && async_task_rbp_offset == 0 && end_slot - start_slot >= 2) {
                xor_eax ();
                for (int s = start_slot; s < end_slot; s++)
                    store_rbp_disp (slot_offset (s));
                return;
            }
            for (int s = start_slot; s < end_slot; s++)
                zero_local (s);
        }

        // Fills array elements [rax + 16 + 8*i] for 0 <= i < rcx with
        // empty string ptr in .rodata; preserves rax.
        public void emit_fill_empty_strings (int empty_str_off) {
            // lea rdx, [rip + empty_str_off]  48 8D 15 + disp32
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x15);
            record_rip (empty_str_off, PatchSpace.RODATA);
            // xor r8d, r8d                    45 31 C0
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
            var l_loop = new_label ();
            var l_done = new_label ();
            bind (l_loop);
            // cmp r8, rcx                     49 39 C8
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xC8);
            branch (BranchKind.JAE, l_done);
            // mov [rax + r8*8 + 16], rdx      4A 89 54 C0 10
            code.u8 (0x4A); code.u8 (0x89); code.u8 (0x54); code.u8 (0xC0); code.u8 (0x10);
            // inc r8                          49 FF C0
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC0);
            branch (BranchKind.JMP, l_loop);
            bind (l_done);
        }

        // cmp rcx, [rax + 8]                 48 3B 48 08
        public void cmp_rcx_rax_len () {
            code.u8 (0x48); code.u8 (0x3B); code.u8 (0x48); code.u8 (0x08);
        }

        // movzx eax, byte ptr [rax + rcx + 16]   0F B6 44 08 10
        public void load_byte_rax_rcx_16 () {
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x08); code.u8 (0x10);
        }

        // mov rax, [rax + rcx*8 + 16]        48 8B 44 C8 10
        public void load_qword_rax_rcx_16 () {
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x44); code.u8 (0xC8); code.u8 (0x10);
        }

        // lea rax, [rax + rcx*8 + 16]        48 8D 44 C8 10
        public void lea_rax_rax_rcx_8_16 () {
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x44); code.u8 (0xC8); code.u8 (0x10);
        }

        // lea rax, [rax + rcx + 16]          48 8D 44 08 10
        public void lea_rax_rax_rcx_1_16 () {
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x44); code.u8 (0x08); code.u8 (0x10);
        }

        // shl rcx, imm8                      48 C1 E1 imm8
        public void shl_rcx_imm (uint8 count) {
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE1); code.u8 (count);
        }

        // mov byte ptr [rcx + disp], al      88 41 d8 | 88 81 d32
        public void store_rcx_disp_byte_al (int disp) {
            code.u8 (0x88);
            emit_modrm_disp (0, 1, disp);
        }

        // movzx eax, byte ptr [rdx]          0F B6 02
        public void load_rdx_byte_to_zx_rax () {
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x02);
        }

        // mov [rax + 8], rcx                 48 89 48 08
        public void store_rax_8_rcx () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x48); code.u8 (0x08);
        }

        // mov r12d, eax                      41 89 C4
        public void mov_r12d_eax () {
            code.u8 (0x41); code.u8 (0x89); code.u8 (0xC4);
        }

        // mov edi, r12d                      44 89 E7
        public void mov_edi_r12d () {
            code.u8 (0x44); code.u8 (0x89); code.u8 (0xE7);
        }

        // shl rdi, 3                         48 C1 E7 03
        public void shl_rdi_3 () {
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE7); code.u8 (0x03);
        }

        // mov esi, imm32                     BE + imm32
        public void mov_esi_imm (uint32 v) {
            code.u8 (0xBE); code.u32le (v);
        }

        // mov rdi, imm
        public void mov_rdi_imm (int64 v) {
            if (v >= int32.MIN && v <= int32.MAX) {
                code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC7);
                code.u32le ((uint32) (int32) v);
            } else {
                code.u8 (0x48); code.u8 (0xBF);
                code.u64le ((uint64) v);
            }
        }

        // pop rcx                            59
        public void pop_rcx () {
            pop_reg (Reg.RCX);
        }

        // mov edi, eax                       89 C7   (zero-extends into rdi)
        public void mov_edi_eax () {
            code.u8 (0x89); code.u8 (0xC7);
        }

        // push rax / pop rax                 50 / 58
        public void push_rax () {
            int p = code.length;
            push_reg (Reg.RAX);
            if (opt_level >= 1 && code.length == p + 1)
                last_push_rax_pos = p;
            else
                last_push_rax_pos = -1;
        }
        public void pop_rax () {
            if (opt_level >= 1 && last_push_rax_pos >= 0 && code.length == last_push_rax_pos + 1) {
                code.truncate (last_push_rax_pos);
                last_push_rax_pos = -1;
                return;
            }
            last_push_rax_pos = -1;
            pop_reg (Reg.RAX);
        }

        // ------------------------------------------------------------------
        // Locals: slots live at [rbp - 8*(slot+1)]. Positive displacements
        // reach the incoming stack arguments above the return address.
        // ------------------------------------------------------------------

        public int async_task_rbp_offset { get; set; default = 0; }

        private void load_r10_async_task () {
            code.u8 (0x4C); code.u8 (0x8B);
            emit_modrm_disp (2, 5, async_task_rbp_offset);
        }

        public static int slot_offset (int slot) {
            return -8 * (slot + 1);
        }

        // mov rax, [rbp + d]                 48 8B 45 d8 | 48 8B 85 d32
        public void load_rbp_disp (int d) {
            if (d >= -128 && d <= 127) {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x45);
                code.u8 ((uint8) d);
            } else {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x85);
                code.u32le ((uint32) d);
            }
        }

        // mov [rbp + d], rax                 48 89 45 d8 | 48 89 85 d32
        public void store_rbp_disp (int d) {
            if (d >= -128 && d <= 127) {
                code.u8 (0x48); code.u8 (0x89); code.u8 (0x45);
                code.u8 ((uint8) d);
            } else {
                code.u8 (0x48); code.u8 (0x89); code.u8 (0x85);
                code.u32le ((uint32) d);
            }
        }

        // mov rax, [rbp - d]                 48 8B 45 d8 | 48 8B 85 d32
        public void load_local (int slot) {
            if (async_task_rbp_offset != 0) {
                load_r10_async_task ();
                code.u8 (0x49); code.u8 (0x8B); code.u8 (0x82);
                code.u32le ((uint32) (80 + slot * 8));
                return;
            }
            if (opt_level >= 1 && last_store_local_slot == slot && code.length == last_store_local_pos) {
                last_store_local_slot = -1;
                return;
            }
            last_store_local_slot = -1;
            int sr = get_slot_reg (slot);
            if (sr >= 0) {
                mov_reg_reg (Reg.RAX, (Reg) sr);
                return;
            }
            load_rbp_disp (slot_offset (slot));
        }

        // mov rcx, [rbp - d] | mov rcx, rN
        public void load_local_to_rcx (int slot) {
            if (async_task_rbp_offset != 0) {
                load_r10_async_task ();
                code.u8 (0x49); code.u8 (0x8B); code.u8 (0x8A);
                code.u32le ((uint32) (80 + slot * 8));
                return;
            }
            int sr = get_slot_reg (slot);
            if (sr >= 0) {
                mov_reg_reg (Reg.RCX, (Reg) sr);
                return;
            }
            int d = slot_offset (slot);
            if (d >= -128 && d <= 127) {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4D);
                code.u8 ((uint8) d);
            } else {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x8D);
                code.u32le ((uint32) d);
            }
        }

        // mov [rbp - d], rax                 48 89 45 d8 | 48 89 85 d32
        public void store_local (int slot) {
            if (async_task_rbp_offset != 0) {
                load_r10_async_task ();
                code.u8 (0x49); code.u8 (0x89); code.u8 (0x82);
                code.u32le ((uint32) (80 + slot * 8));
                return;
            }
            int sr = get_slot_reg (slot);
            if (sr >= 0) {
                mov_reg_reg ((Reg) sr, Reg.RAX);
            } else {
                store_rbp_disp (slot_offset (slot));
            }
            if (opt_level >= 1) {
                last_store_local_slot = slot;
                last_store_local_pos = code.length;
            }
        }

        public void lea_local (int slot) {
            if (async_task_rbp_offset != 0) {
                load_r10_async_task ();
                code.u8 (0x49); code.u8 (0x8D); code.u8 (0x82);
                code.u32le ((uint32) (80 + slot * 8));
                return;
            }
            if (get_slot_reg (slot) >= 0) {
                Host.eprintln (@"planc: internal error: lea_local on register-allocated slot $slot");
            }
            lea_rax_rbp_disp (slot_offset (slot));
        }

        // mov [rbp - d], reg: stores an incoming argument register into its
        // slot in the prologue. REX.R covers r8/r9.
        public void store_local_reg (int slot, Reg src) {
            if (async_task_rbp_offset != 0) {
                load_r10_async_task ();
                uint8 rex = (uint8) (0x49 | (Reg.is_extended (src) ? 4 : 0));
                var src_low = (int) src & 7;
                code.u8 (rex); code.u8 (0x89);
                code.u8 ((uint8) (0x80 | (src_low << 3) | 0x02));
                code.u32le ((uint32) (80 + slot * 8));
                return;
            }
            int sr = get_slot_reg (slot);
            if (sr >= 0) {
                mov_reg_reg ((Reg) sr, src);
                return;
            }
            var d = slot_offset (slot);
            uint8 rex = (uint8) (0x48 | (Reg.is_extended (src) ? 4 : 0));
            var src_low = (int) src & 7;
            if (d >= -128 && d <= 127) {
                code.u8 (rex); code.u8 (0x89);
                code.u8 ((uint8) (0x40 | (src_low << 3) | 0x05));
                code.u8 ((uint8) d);
            } else {
                code.u8 (rex); code.u8 (0x89);
                code.u8 ((uint8) (0x80 | (src_low << 3) | 0x05));
                code.u32le ((uint32) d);
            }
        }

        // ------------------------------------------------------------------
        // Arithmetic and logic. All take operands in rax (left/destination)
        // and rcx (right).
        // ------------------------------------------------------------------

        // xor eax, eax                       31 C0
        public void xor_eax () {
            code.u8 (0x31); code.u8 (0xC0);
        }

        // add rax, rcx                       48 01 C8
        public void add_rax_rcx () {
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xC8);
        }

        // sub rax, rcx                       48 29 C8
        public void sub_rax_rcx () {
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xC8);
        }

        // imul rax, rcx                      48 0F AF C1
        public void imul_rax_rcx () {
            code.u8 (0x48); code.u8 (0x0F); code.u8 (0xAF); code.u8 (0xC1);
        }

        // cqo                                48 99   (sign-extend rax into rdx:rax)
        public void cqo () {
            code.u8 (0x48); code.u8 (0x99);
        }

        // idiv rcx                           48 F7 F9   (quotient rax, remainder rdx)
        public void idiv_rcx () {
            code.u8 (0x48); code.u8 (0xF7); code.u8 (0xF9);
        }

        // div rcx                            48 F7 F1   (unsigned quotient rax, remainder rdx)
        public void div_rcx () {
            code.u8 (0x48); code.u8 (0xF7); code.u8 (0xF1);
        }

        // neg rax                            48 F7 D8
        public void neg_rax () {
            code.u8 (0x48); code.u8 (0xF7); code.u8 (0xD8);
        }

        // not rax                            48 F7 D0
        public void not_rax () {
            code.u8 (0x48); code.u8 (0xF7); code.u8 (0xD0);
        }

        // and rax, rcx                       48 21 C8
        public void and_rax_rcx () {
            code.u8 (0x48); code.u8 (0x21); code.u8 (0xC8);
        }

        // or rax, rcx                        48 09 C8
        public void or_rax_rcx () {
            code.u8 (0x48); code.u8 (0x09); code.u8 (0xC8);
        }

        // xor rax, rdx                       48 31 D0
        public void xor_rax_rdx () {
            code.u8 (0x48); code.u8 (0x31); code.u8 (0xD0);
        }

        // sub rax, rdx                       48 29 D0
        public void sub_rax_rdx () {
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xD0);
        }

        // xor rax, rcx                       48 31 C8
        public void xor_rax_rcx () {
            code.u8 (0x48); code.u8 (0x31); code.u8 (0xC8);
        }

        // shl rax, cl                        48 D3 E0
        public void shl_rax_cl () {
            code.u8 (0x48); code.u8 (0xD3); code.u8 (0xE0);
        }

        // sar rax, cl                        48 D3 F8
        public void sar_rax_cl () {
            code.u8 (0x48); code.u8 (0xD3); code.u8 (0xF8);
        }

        // shr rax, cl                        48 D3 E8   (logical unsigned right shift)
        public void shr_rax_cl () {
            code.u8 (0x48); code.u8 (0xD3); code.u8 (0xE8);
        }

        // mov eax, eax                       89 C0      (zero-extend low 32 bits into rax)
        public void mov_eax_eax () {
            code.u8 (0x89); code.u8 (0xC0);
        }

        // and eax, imm32                     25 + imm32 (zero-extends low bits into rax)
        public void and_eax_imm32 (uint32 v) {
            code.u8 (0x25); code.u32le (v);
        }

        // cmp rax, rcx                       48 39 C8
        public void cmp_rax_rcx () {
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xC8);
        }

        // sub rax, imm32                     48 FF C8 | 48 83 E8 imm8 | 48 2D imm32
        public void sub_rax_imm (int disp) {
            if (disp == 0)
                return;
            if (opt_level >= 2 && disp == 1) {
                code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC8); // dec %rax
                return;
            }
            if (opt_level >= 2 && disp == -1) {
                code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC0); // inc %rax
                return;
            }
            if (disp >= -128 && disp <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xE8);
                code.u8 ((uint8) disp);
            } else {
                code.u8 (0x48); code.u8 (0x2D);
                code.u32le ((uint32) disp);
            }
        }

        // cmp rax, imm32                     48 83 F8 imm8 | 48 3D imm32
        public void cmp_rax_imm (int32 v) {
            if (v >= -128 && v <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xF8);
                code.u8 ((uint8) v);
            } else {
                code.u8 (0x48); code.u8 (0x3D);
                code.u32le ((uint32) v);
            }
        }

        // imul rax, rax, imm32               48 6B C0 imm8 | 48 69 C0 imm32
        public void imul_rax_imm (int32 v) {
            if (v >= -128 && v <= 127) {
                code.u8 (0x48); code.u8 (0x6B); code.u8 (0xC0);
                code.u8 ((uint8) v);
            } else {
                code.u8 (0x48); code.u8 (0x69); code.u8 (0xC0);
                code.u32le ((uint32) v);
            }
        }

        // and rax, imm32                     48 83 E0 imm8 | 48 25 imm32
        public void and_rax_imm (int32 v) {
            if (v >= -128 && v <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xE0);
                code.u8 ((uint8) v);
            } else {
                code.u8 (0x48); code.u8 (0x25);
                code.u32le ((uint32) v);
            }
        }

        // or rax, imm32                      48 83 C8 imm8 | 48 0D imm32
        public void or_rax_imm (int32 v) {
            if (v >= -128 && v <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xC8);
                code.u8 ((uint8) v);
            } else {
                code.u8 (0x48); code.u8 (0x0D);
                code.u32le ((uint32) v);
            }
        }

        // xor rax, imm32                     48 83 F0 imm8 | 48 35 imm32
        public void xor_rax_imm (int32 v) {
            if (v >= -128 && v <= 127) {
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xF0);
                code.u8 ((uint8) v);
            } else {
                code.u8 (0x48); code.u8 (0x35);
                code.u32le ((uint32) v);
            }
        }

        // shl rax, imm8                      48 D1 E0 | 48 C1 E0 imm8
        public void shl_rax_imm (uint8 c) {
            if (c == 0) return;
            if (c == 1) { code.u8 (0x48); code.u8 (0xD1); code.u8 (0xE0); }
            else { code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE0); code.u8 (c & 63); }
        }

        // sar rax, imm8                      48 D1 F8 | 48 C1 F8 imm8
        public void sar_rax_imm (uint8 c) {
            if (c == 0) return;
            if (c == 1) { code.u8 (0x48); code.u8 (0xD1); code.u8 (0xF8); }
            else { code.u8 (0x48); code.u8 (0xC1); code.u8 (0xF8); code.u8 (c & 63); }
        }

        // shr rax, imm8                      48 D1 E8 | 48 C1 E8 imm8
        public void shr_rax_imm (uint8 c) {
            if (c == 0) return;
            if (c == 1) { code.u8 (0x48); code.u8 (0xD1); code.u8 (0xE8); }
            else { code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE8); code.u8 (c & 63); }
        }

        // xor edx, edx                       31 D2
        public void xor_edx () {
            code.u8 (0x31); code.u8 (0xD2);
        }

        // test rax, rax                      48 85 C0
        public void test_rax_rax () {
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC0);
        }

        // test rdx, rdx                      48 85 D2
        public void test_rdx_rdx () {
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2);
        }

        // setcc al (cc: 94=E, 95=NE, 9C=L, 9E=LE, 9F=G, 9D=GE)
        public void setcc_al (uint8 cc) {
            code.u8 (0x0F); code.u8 (cc); code.u8 (0xC0);
        }

        // movzx eax, al                      0F B6 C0
        public void movzx_eax_al () {
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0xC0);
        }

        // Hash 64-bit integer/pointer in rax into non-negative 31-bit int in rax.
        // Clobbers rcx.
        public void emit_hash_int64 () {
            mov_rcx_rax ();
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE9); code.u8 (32); // shr rcx, 32
            xor_rax_rcx ();
            mov_rcx_rax ();
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE9); code.u8 (16); // shr rcx, 16
            xor_rax_rcx ();
            code.u8 (0xB9); code.u32le (0x045d9f3bu);                     // mov ecx, 0x45d9f3b
            imul_rax_rcx ();
            mov_rcx_rax ();
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE9); code.u8 (16); // shr rcx, 16
            xor_rax_rcx ();
            code.u8 (0x25); code.u32le (0x7fffffffu);                     // and eax, 0x7fffffff
        }

        // Hash null-terminated UTF-8 string in rax (FNV-1a) into non-negative 31-bit int in rax.
        // Clobbers rcx, rdx.
        public void emit_hash_str () {
            var loop_lbl = new Label ();
            var done_lbl = new Label ();
            mov_rcx_rax ();
            mov_eax (216613626u);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9);               // test rcx, rcx
            branch (BranchKind.JE, done_lbl);
            bind (loop_lbl);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x11);               // movzx edx, byte [rcx]
            code.u8 (0x85); code.u8 (0xD2);                               // test edx, edx
            branch (BranchKind.JE, done_lbl);
            code.u8 (0x31); code.u8 (0xD0);                               // xor eax, edx
            code.u8 (0x69); code.u8 (0xC0); code.u32le (16777619u);       // imul eax, eax, 16777619
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1);               // inc rcx
            branch (BranchKind.JMP, loop_lbl);
            bind (done_lbl);
            code.u8 (0x25); code.u32le (0x7fffffffu);                     // and eax, 0x7fffffff
        }

        // ------------------------------------------------------------------
        // Syscall plumbing (slice 0, unchanged).
        // ------------------------------------------------------------------

        // mov eax, imm32                      B8 + imm32
        public void mov_eax (uint32 v) {
            code.u8 (0xB8);
            code.u32le (v);
        }

        // mov edi, imm32                      BF + imm32
        public void mov_edi (uint32 v) {
            code.u8 (0xBF);
            code.u32le (v);
        }

        // mov edx, imm32                      BA + imm32
        public void mov_edx (uint32 v) {
            code.u8 (0xBA);
            code.u32le (v);
        }

        // xor edi, edi                        31 FF
        public void zero_edi () {
            code.u8 (0x31);
            code.u8 (0xFF);
        }

        // syscall                             0F 05
        public void syscall () {
            code.u8 (0x0F);
            code.u8 (0x05);
        }

        // lea rsi, [rip + disp32]             48 8D 35 + disp32
        // Leaves the displacement zeroed and records it for the linker step.
        public void lea_rsi_rip (int data_offset) {
            code.u8 (0x48);
            code.u8 (0x8D);
            code.u8 (0x35);
            var patch = new RipPatch ();
            patch.displacement = code.length;
            patch.target = data_offset;
            code.u32le (0);
            patches.add (patch);
        }

        // ------------------------------------------------------------------
        // Slice 3/4 runtime intrinsics in .text.
        // ------------------------------------------------------------------

        // void __planc_write_str(string* rdi) -> writes bytes to stdout in O(1).
        public void int80 () {
            code.u8 (0xCD); code.u8 (0x80);
        }

        // `lock (obj)` uses a spinlock table in .bss striped by the object
        // address: two threads locking the same object always contend on the
        // same word. The lock is not recursive.
        public const int LOCK_STRIPES = 32;

        public int lock_table_bytes () {
            return LOCK_STRIPES * 8;
        }

        // __planc_lock_slot (rdi = object) -> rax = address of its lock word.
        public void emit_rt_lock_slot (int lock_bss_base) {
            // mov rax, rdi                 48 89 F8
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xF8);
            // shr rax, 4                   48 C1 E8 04
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE8); code.u8 (0x04);
            // and eax, LOCK_STRIPES - 1    83 E0 1F
            code.u8 (0x83); code.u8 (0xE0); code.u8 ((uint8) (LOCK_STRIPES - 1));
            // shl rax, 3                   48 C1 E0 03
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE0); code.u8 (0x03);
            lea_rcx_space (lock_bss_base, PatchSpace.BSS);
            // add rax, rcx                 48 01 C8
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xC8);
            ret ();
        }

        // __planc_lock_acquire (rdi = object): spin until the word is ours.
        public void emit_rt_lock_acquire (int lock_bss_base) {
            var l_spin = new_label ();
            var l_got = new_label ();
            call_rel32 ("__planc_lock_slot");
            // mov rcx, rax                 48 89 C1
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC1);
            bind (l_spin);
            // mov eax, 1                   B8 01 00 00 00
            mov_eax (1);
            // xchg [rcx], rax              48 87 01  (implicitly locked)
            code.u8 (0x48); code.u8 (0x87); code.u8 (0x01);
            test_rax_rax ();
            branch (BranchKind.JE, l_got);
            // pause                        F3 90
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_spin);
            bind (l_got);
            ret ();
        }

        // __planc_lock_release (rdi = object): publish the word as free.
        public void emit_rt_lock_release (int lock_bss_base) {
            call_rel32 ("__planc_lock_slot");
            // mov qword ptr [rax], 0       48 C7 00 00 00 00 00
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x00);
            code.u8 (0x00); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            ret ();
        }

        public void emit_rt_write_str (bool freestanding = false, bool target_planetos = false) {
            if (target_planetos) {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x77); code.u8 (0x08); // mov rsi, [rdi + 8]
                code.u8 (0x48); code.u8 (0x8D); code.u8 (0x7F); code.u8 (0x10); // lea rdi, [rdi + 16]
                mov_eax (1);
                int80 ();
                ret ();
                return;
            }
            if (freestanding) {
                push_rbp ();
                mov_rsp_to_rbp ();
                // mov rsi, [rdi + 8]; lea rdi, [rdi + 16]
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x77); code.u8 (0x08);
                code.u8 (0x48); code.u8 (0x8D); code.u8 (0x7F); code.u8 (0x10);
                call_rel32 ("__planet_console_write");
                leave ();
                ret ();
                return;
            }
            if (target_windows) {
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x57); code.u8 (0x08); // mov rdx, [rdi+8]
                code.u8 (0x48); code.u8 (0x8D); code.u8 (0x77); code.u8 (0x10); // lea rsi, [rdi+16]
                emit_win32_write_buf (1);
                ret ();
                return;
            }
            // mov rdx, [rdi + 8]              48 8B 57 08
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x57); code.u8 (0x08);
            // lea rsi, [rdi + 16]             48 8D 77 10
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x77); code.u8 (0x10);
            mov_edi (1);
            mov_eax (1);
            syscall ();
            ret ();
        }

        // int64 __planc_str_eq(string* rdi, string* rsi) -> 0 or 1 in rax.
        public void emit_rt_str_eq () {
            var l_loop = new_label ();
            var l_false = new_label ();
            var l_true = new_label ();
            // cmp rdi, rsi                    48 39 F7
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xF7);
            branch (BranchKind.JE, l_true);
            // test rdi, rdi                   48 85 FF
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_false);
            // test rsi, rsi                   48 85 F6
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6);
            branch (BranchKind.JE, l_false);
            // mov r8, [rdi + 8]               4C 8B 47 08
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08);
            // cmp r8, [rsi + 8]               4C 3B 46 08
            code.u8 (0x4C); code.u8 (0x3B); code.u8 (0x46); code.u8 (0x08);
            branch (BranchKind.JNE, l_false);
            // xor ecx, ecx                    31 C9
            code.u8 (0x31); code.u8 (0xC9);
            bind (l_loop);
            // cmp rcx, r8                     4C 39 C1
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC1);
            branch (BranchKind.JE, l_true);
            // movzx eax, byte ptr [rdi + rcx + 16]  0F B6 44 0F 10
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x0F); code.u8 (0x10);
            // movzx edx, byte ptr [rsi + rcx + 16]  0F B6 54 0E 10
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x54); code.u8 (0x0E); code.u8 (0x10);
            // cmp eax, edx                    39 D0
            code.u8 (0x39); code.u8 (0xD0);
            branch (BranchKind.JNE, l_false);
            // inc rcx                         48 FF C1
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1);
            branch (BranchKind.JMP, l_loop);
            bind (l_false);
            xor_eax ();
            ret ();
            bind (l_true);
            mov_eax (1);
            ret ();
        }

        // Writes panic message to stderr and exits 134.
        public void emit_rt_panic (int msg_rodata_offset, int msg_len, bool freestanding = false, bool target_planetos = false) {
            if (target_windows) {
                lea_rsi_rip (msg_rodata_offset + 16);
                mov_edx ((uint32) msg_len);
                emit_win32_write_buf (2);
                mov_edi (134);
                emit_win32_exit_edi ();
                return;
            }
            if (target_planetos) {
                code.u8 (0x48); code.u8 (0x8D); code.u8 (0x3D);
                record_rip (msg_rodata_offset + 16, PatchSpace.RODATA);
                mov_esi_imm ((uint32) msg_len);
                mov_eax (1);
                int80 ();
                mov_edi (134);
                mov_eax (11);
                int80 ();
                return;
            }
            if (freestanding) {
                // lea rdi, [rip + msg_rodata_offset + 16]
                code.u8 (0x48); code.u8 (0x8D); code.u8 (0x3D);
                record_rip (msg_rodata_offset + 16, PatchSpace.RODATA);
                mov_esi_imm ((uint32) msg_len);
                call_rel32 ("__planet_panic");
                code.u8 (0xFA); code.u8 (0xF4); code.u8 (0xEB); code.u8 (0xFD); // cli; hlt; jmp -3
                return;
            }
            mov_eax (1);
            mov_edi (2);
            lea_rsi_rip (msg_rodata_offset + 16);
            mov_edx ((uint32) msg_len);
            syscall ();
            mov_edi (134);
            mov_eax (60);
            syscall ();
        }

        // Shared decimal formatter: converts int64/uint64 in `rdi` into [rbp - 32 .. rbp],
        // leaving start pointer in `rcx` and length in `rbp - rcx`.
        private void emit_format_int_to_stack (bool is_unsigned = false) {
            var l_pos = new_label ();
            var l_loop = new_label ();
            var l_done = new_label ();
            // mov rcx, rbp                    48 89 E9
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xE9);
            // mov rax, rdi                    48 89 F8
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xF8);
            if (!is_unsigned) {
                // xor r8d, r8d                45 31 C0
                code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
                test_rax_rax ();
                branch (BranchKind.JGE, l_pos);
                neg_rax ();
                // mov r8d, 1                  41 B8 01 00 00 00
                code.u8 (0x41); code.u8 (0xB8); code.u32le (1);
                bind (l_pos);
            }
            // mov r9d, 10                     41 B9 0A 00 00 00
            code.u8 (0x41); code.u8 (0xB9); code.u32le (10);
            bind (l_loop);
            // xor edx, edx                    31 D2
            code.u8 (0x31); code.u8 (0xD2);
            // div r9                          49 F7 F1
            code.u8 (0x49); code.u8 (0xF7); code.u8 (0xF1);
            // add edx, 48                     83 C2 30
            code.u8 (0x83); code.u8 (0xC2); code.u8 (0x30);
            // dec rcx                         48 FF C9
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9);
            // mov [rcx], dl                   88 11
            code.u8 (0x88); code.u8 (0x11);
            test_rax_rax ();
            branch (BranchKind.JNE, l_loop);
            if (!is_unsigned) {
                // test r8d, r8d               45 85 C0
                code.u8 (0x45); code.u8 (0x85); code.u8 (0xC0);
                branch (BranchKind.JE, l_done);
                // dec rcx                     48 FF C9
                code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9);
                // mov byte ptr [rcx], '-'     C6 01 2D
                code.u8 (0xC6); code.u8 (0x01); code.u8 (0x2D);
                bind (l_done);
            }
        }

        private void emit_rt_write_int_impl (bool is_unsigned, bool freestanding, bool target_planetos) {
            push_rbp ();
            mov_rsp_to_rbp ();
            sub_rsp (32);
            emit_format_int_to_stack (is_unsigned);
            if (target_windows) {
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xCE); // mov rsi, rcx
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xEA); // mov rdx, rbp
                code.u8 (0x48); code.u8 (0x29); code.u8 (0xCA); // sub rdx, rcx
                emit_win32_write_buf (1);
                leave ();
                ret ();
                return;
            }
            if (target_planetos) {
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xCF);
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xEE);
                code.u8 (0x48); code.u8 (0x29); code.u8 (0xCE);
                mov_eax (1);
                int80 ();
                leave ();
                ret ();
                return;
            }
            if (freestanding) {
                // mov rdi, rcx; mov rsi, rbp; sub rsi, rcx
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xCF);
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xEE);
                code.u8 (0x48); code.u8 (0x29); code.u8 (0xCE);
                call_rel32 ("__planet_console_write");
                leave ();
                ret ();
                return;
            }
            // mov rsi, rcx                    48 89 CE
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xCE);
            // mov rdx, rbp                    48 89 EA
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xEA);
            // sub rdx, rcx                    48 29 CA
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xCA);
            mov_edi (1);
            mov_eax (1);
            syscall ();
            leave ();
            ret ();
        }

        // void __planc_write_int(int64 rdi) -> formats signed decimal to stdout.
        public void emit_rt_write_int (bool freestanding = false, bool target_planetos = false) {
            emit_rt_write_int_impl (false, freestanding, target_planetos);
        }

        // void __planc_write_uint(uint64 rdi) -> formats unsigned decimal to stdout.
        public void emit_rt_write_uint (bool freestanding = false, bool target_planetos = false) {
            emit_rt_write_int_impl (true, freestanding, target_planetos);
        }

        // ------------------------------------------------------------------
        // Slice 5 safe allocator, atomic ref/unref, and dynamic strings.
        // ------------------------------------------------------------------

        // void* __planc_alloc(uint64 rdi = payload_bytes, uint64 rsi = elem_ref)
        public void emit_rt_weak (GenericArray<Symbol> symbols) {
            // __planc_weak_make(rdi = obj_ptr) -> rax = weak_box (+1 ref) or 0
            var s_make = here ();
            var l_make_zero = new_label ();
            var l_make_retain = new_label ();
            // test rdi, rdi
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_make_zero);
            // mov rax, [rdi + 16]; test rax, rax; jne retain
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JNE, l_make_retain);
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            sub_rsp (8);
            // mov rbx, rdi; mov edi, 8; xor esi, esi; call __planc_alloc
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);
            code.u8 (0xBF); code.u32le (8u);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            // mov [rax + 16], rbx; mov [rbx + 16], rax
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x58); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x10);
            add_rsp (8);
            pop_reg (Reg.RBX);
            pop_rbp ();
            bind (l_make_retain);
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            sub_rsp (8);
            // mov rbx, rax; mov rdi, rax; call __planc_ref; mov rax, rbx
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC3);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7);
            call_rel32 ("__planc_ref");
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD8);
            add_rsp (8);
            pop_reg (Reg.RBX);
            pop_rbp ();
            ret ();
            bind (l_make_zero);
            code.u8 (0x31); code.u8 (0xC0); // xor eax, eax
            ret ();
            symbols.add (new Symbol ("__planc_weak_make", s_make, here () - s_make));

            // __planc_weak_load(rdi = weak_box) -> rax = obj_ptr (+1 ref) or 0
            var s_load = here ();
            var l_load_zero = new_label ();
            // test rdi, rdi; je zero
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_load_zero);
            // mov rax, [rdi + 16]; test rax, rax; je zero
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_load_zero);
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            sub_rsp (8);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC3); // mov rbx, rax
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7); // mov rdi, rax
            call_rel32 ("__planc_ref");
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD8); // mov rax, rbx
            add_rsp (8);
            pop_reg (Reg.RBX);
            pop_rbp ();
            ret ();
            bind (l_load_zero);
            code.u8 (0x31); code.u8 (0xC0);
            ret ();
            symbols.add (new Symbol ("__planc_weak_load", s_load, here () - s_load));

            // __planc_weak_clear(rdi = obj_ptr)
            var s_clr = here ();
            var l_clr_done = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_clr_done);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x10); // mov rax, [rdi + 16]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC0); // test rax, rax
            branch (BranchKind.JE, l_clr_done);
            // mov qword ptr [rax + 16], 0; mov qword ptr [rdi + 16], 0
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x40); code.u8 (0x10); code.u32le (0u);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x47); code.u8 (0x10); code.u32le (0u);
            push_rbp ();
            mov_rsp_to_rbp ();
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7); // mov rdi, rax
            call_rel32 ("__planc_unref");
            pop_rbp ();
            bind (l_clr_done);
            ret ();
            symbols.add (new Symbol ("__planc_weak_clear", s_clr, here () - s_clr));
        }

        public void emit_rt_alloc (int bss_base, Label mem_panic_lbl, int free_heap_bss_off = -1, bool target_planetos = false) {
            var l_class_loop = new_label ();
            var l_found_class = new_label ();
            var l_arena_carve = new_label ();
            var l_new_slab = new_label ();
            var l_init_header = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            // push r12; push r13; push r14
            code.u8 (0x41); code.u8 (0x54);
            code.u8 (0x41); code.u8 (0x55);
            code.u8 (0x41); code.u8 (0x56);

            // mov r12, rdi; mov r13, rsi
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFC);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF5);
            // lea rbx, [rip + bss_base]       48 8D 1D + disp32
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x1D);
            record_rip (bss_base, PatchSpace.BSS);

            // lock inc qword ptr [rbx]        F0 48 FF 03 (alloc_count++)
            code.u8 (0xF0); code.u8 (0x48); code.u8 (0xFF); code.u8 (0x03);

            // total = r12 + 16 -> r14
            // mov r14, r12; add r14, 16
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0xE6);
            code.u8 (0x49); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x10);

            // Find size class c in 0..7 (32..4096 bytes)
            // xor ecx, ecx; mov edx, 32
            code.u8 (0x31); code.u8 (0xC9);
            code.u8 (0xBA); code.u32le (32);
            bind (l_class_loop);
            // cmp r14, rdx                    49 39 D6
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xD6);
            branch (BranchKind.JBE, l_found_class);
            // shl rdx, 1                      48 D1 E2
            code.u8 (0x48); code.u8 (0xD1); code.u8 (0xE2);
            // inc ecx                         FF C1
            code.u8 (0xFF); code.u8 (0xC1);
            // cmp ecx, 8                      83 F9 08
            code.u8 (0x83); code.u8 (0xF9); code.u8 (0x08);
            branch (BranchKind.JL, l_class_loop);

            // Large allocation (> 4096)
            if (target_planetos) {
                // rdi = (r14 + 4095) >> 12 (num_pages)
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7); // mov rdi, r14
                code.u8 (0x48); code.u8 (0x81); code.u8 (0xC7); code.u32le (4095);
                code.u8 (0x48); code.u8 (0xC1); code.u8 (0xEF); code.u8 (0x0C); // shr rdi, 12
                mov_eax (3);
                int80 ();
                test_rax_rax ();
                branch (BranchKind.JE, mem_panic_lbl);
                code.u8 (0xB1); code.u8 (0xFF); // mov cl, 255
                branch (BranchKind.JMP, l_init_header);
            } else {
            // Large allocation (> 4096): mmap(align4k(total) + 4096) + PROT_NONE guard
            // mov rdi, r14                    4C 89 F7
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7);
            // add rdi, 4095                   48 81 C7 FF 0F 00 00
            code.u8 (0x48); code.u8 (0x81); code.u8 (0xC7); code.u32le (4095);
            // and rdi, -4096                  48 81 E7 00 F0 FF FF
            code.u8 (0x48); code.u8 (0x81); code.u8 (0xE7); code.u32le (0xFFFFF000u);
            // mov r14, rdi                    49 89 FE
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFE);
            // mov rsi, rdi; add rsi, 4096
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFE);
            code.u8 (0x48); code.u8 (0x81); code.u8 (0xC6); code.u32le (4096);
            emit_mmap_anon_rw ();
            test_rax_rax ();
            branch (BranchKind.JS, mem_panic_lbl);
            // mov r12, rax                    49 89 C4
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4);
            if (!target_windows) {
                // mprotect(r12 + r14, 4096, PROT_NONE)
                // mov rdi, r12; add rdi, r14
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
                code.u8 (0x4C); code.u8 (0x01); code.u8 (0xF7);
                mov_esi_imm (4096);
                // xor edx, edx; mov eax, 10; syscall
                code.u8 (0x31); code.u8 (0xD2);
                mov_eax (10);
                syscall ();
            }
            // mov rax, r12; mov cl, 255; jmp l_init_header
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
            code.u8 (0xB1); code.u8 (0xFF);
            branch (BranchKind.JMP, l_init_header);
            }

            // Small/medium class 0..7: acquire allocator spinlock [rbx + 96]
            bind (l_found_class);
            var l_alloc_lock = new_label ();
            var l_alloc_locked = new_label ();
            bind (l_alloc_lock);
            // mov eax, 1; xchg [rbx + 96], eax; test eax, eax; je l_alloc_locked
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x43); code.u8 (0x60);
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_alloc_locked);
            // pause                           F3 90
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_alloc_lock);
            bind (l_alloc_locked);

            // Check free_lists[rcx]
            // mov rax, [rbx + rcx*8 + 32]     48 8B 44 CB 20
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x44); code.u8 (0xCB); code.u8 (0x20);
            test_rax_rax ();
            branch (BranchKind.JE, l_arena_carve);
            // Pop block: mov r8, [rax + 8]; mov [rbx + rcx*8 + 32], r8
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x40); code.u8 (0x08);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x44); code.u8 (0xCB); code.u8 (0x20);
            // Release spinlock: mov dword ptr [rbx + 96], 0
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x60); code.u32le (0);
            // Zero cap (rdx) bytes of recycled block
            // mov r12, rax; mov r14, rcx; mov rdi, r12; mov rcx, rdx; shr rcx, 3; xor eax, eax; rep stosq
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xCE);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD1);
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE9); code.u8 (0x03);
            xor_eax ();
            code.u8 (0xF3); code.u8 (0x48); code.u8 (0xAB);
            // mov rax, r12; mov rcx, r14; jmp l_init_header
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF1);
            branch (BranchKind.JMP, l_init_header);

            // Bump carve from current 64KB slab
            bind (l_arena_carve);
            // mov r8, [rbx + 16]; mov r9, [rbx + 24]
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x43); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x4B); code.u8 (0x18);
            // test r8, r8; je l_new_slab
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_new_slab);
            // mov rax, r8; add rax, rdx; cmp rax, r9; ja l_new_slab
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC0);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xD0);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC8);
            branch (BranchKind.JA, l_new_slab);
            // mov [rbx + 16], rax; release spinlock; mov rax, r8; jmp l_init_header
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x10);
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x60); code.u32le (0);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC0);
            branch (BranchKind.JMP, l_init_header);

            // Map new 64KB slab + 4KB PROT_NONE guard page (0x11000)
            bind (l_new_slab);
            if (free_heap_bss_off >= 0) {
                // Freestanding static 256 KiB BSS heap: only valid if [rbx + 24] == 0
                code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x18); code.u8 (0x00);
                branch (BranchKind.JNE, mem_panic_lbl);
                code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x25); // lea r12, [rip + free_heap_bss_off]
                record_rip (free_heap_bss_off, PatchSpace.BSS);
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
                code.u8 (0x48); code.u8 (0x01); code.u8 (0xD0);
                code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x10); // arena_cur = r12 + rdx
                code.u8 (0x4D); code.u8 (0x89); code.u8 (0xE1);
                code.u8 (0x49); code.u8 (0x81); code.u8 (0xC1); code.u32le (0x40000); // 256 KiB
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0x4B); code.u8 (0x18); // arena_end
                code.u8 (0xC7); code.u8 (0x43); code.u8 (0x60); code.u32le (0); // unlock
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0); // rax = r12
                branch (BranchKind.JMP, l_init_header);
            } else if (target_planetos) {
                // PlanetOS userland: allocate 4 KiB page via SYS_ALLOC_PAGE (3)
                push_reg (Reg.RCX);
                push_reg (Reg.RDX);
                code.u8 (0xBF); code.u32le (1); // mov edi, 1
                mov_eax (3);
                int80 ();
                pop_reg (Reg.RDX);
                pop_reg (Reg.RCX);
                test_rax_rax ();
                branch (BranchKind.JE, mem_panic_lbl);
                code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4); // mov r12, rax
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
                code.u8 (0x48); code.u8 (0x01); code.u8 (0xD0);
                code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x10); // arena_cur = r12 + rdx
                code.u8 (0x4D); code.u8 (0x89); code.u8 (0xE1);
                code.u8 (0x49); code.u8 (0x81); code.u8 (0xC1); code.u32le (0x1000); // 4 KiB
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0x4B); code.u8 (0x18); // arena_end
                code.u8 (0xC7); code.u8 (0x43); code.u8 (0x60); code.u32le (0); // unlock
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
                branch (BranchKind.JMP, l_init_header);
            } else {
            push_reg (Reg.RCX);
            push_reg (Reg.RDX);
            mov_esi_imm (0x11000);
            emit_mmap_anon_rw ();
            test_rax_rax ();
            branch (BranchKind.JS, mem_panic_lbl);
            // mov r12, rax
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4);
            // mprotect(r12 + 0x10000, 4096, 0)
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
            code.u8 (0x48); code.u8 (0x81); code.u8 (0xC7); code.u32le (0x10000);
            mov_esi_imm (4096);
            code.u8 (0x31); code.u8 (0xD2);
            mov_eax (10);
            syscall ();
            pop_reg (Reg.RDX);
            pop_reg (Reg.RCX);
            // arena_cur = r12 + rdx; arena_end = r12 + 0x10000; rax = r12
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xD0);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x10);
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0xE1);
            code.u8 (0x49); code.u8 (0x81); code.u8 (0xC1); code.u32le (0x10000);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x4B); code.u8 (0x18);
            // Release spinlock: mov dword ptr [rbx + 96], 0
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x60); code.u32le (0);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
            }

            // Header: refcount=1, elem_ref=r13b, size_class=cl, magic=0x504C
            bind (l_init_header);
            // mov dword ptr [rax], 1
            code.u8 (0xC7); code.u8 (0x00); code.u32le (1);
            // mov byte ptr [rax + 4], r13b    44 88 68 04
            code.u8 (0x44); code.u8 (0x88); code.u8 (0x68); code.u8 (0x04);
            // mov byte ptr [rax + 5], cl      88 48 05
            code.u8 (0x88); code.u8 (0x48); code.u8 (0x05);
            // mov word ptr [rax + 6], 0x504C  66 C7 40 06 4C 50
            code.u8 (0x66); code.u8 (0xC7); code.u8 (0x40); code.u8 (0x06);
            code.u8 (0x4C); code.u8 (0x50);

            // pop r14; pop r13; pop r12; pop rbx; leave; ret
            code.u8 (0x41); code.u8 (0x5E);
            code.u8 (0x41); code.u8 (0x5D);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        private void emit_mmap_anon_rw () {
            if (target_windows) {
                var l_ok = new_label ();
                push_rbp ();
                mov_rsp_to_rbp ();
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xE4); code.u8 (0xF0); // and rsp, -16
                code.u8 (0x48); code.u8 (0x83); code.u8 (0xEC); code.u8 (0x20); // sub rsp, 32
                code.u8 (0x31); code.u8 (0xC9);                                 // xor ecx, ecx
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xF2);                 // mov rdx, rsi
                code.u8 (0x41); code.u8 (0xB8); code.u32le (0x3000);            // mov r8d, MEM_COMMIT|MEM_RESERVE
                code.u8 (0x41); code.u8 (0xB9); code.u32le (0x04);              // mov r9d, PAGE_READWRITE
                emit_iat_call (Pe.IAT_VIRTUAL_ALLOC);
                test_rax_rax ();
                branch (BranchKind.JNE, l_ok);
                code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC8);                 // dec rax
                bind (l_ok);
                leave ();
                return;
            }
            zero_edi ();
            mov_edx (3);
            // mov r10d, 0x22                  41 BA 22 00 00 00
            code.u8 (0x41); code.u8 (0xBA); code.u32le (0x22);
            // mov r8, -1                      49 C7 C0 FF FF FF FF
            code.u8 (0x49); code.u8 (0xC7); code.u8 (0xC0); code.u32le (0xFFFFFFFFu);
            // xor r9d, r9d                    45 31 C9
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC9);
            mov_eax (9);
            syscall ();
        }

        // void* __planc_ref(void* rdi) -> returns rdi in rax.
        public void emit_rt_arena_alloc (int arena_bss_off, int cursor_bss_off) {
            // rdi = payload_bytes, esi = elem_ref (unused, always 0)
            var l_have_cur = new_label ();
            var l_fallback = new_label ();
            // rcx = [cursor_bss_off]
            load_global (cursor_bss_off, PatchSpace.BSS);
            test_rax_rax ();
            branch (BranchKind.JNE, l_have_cur);
            lea_rax_bss (arena_bss_off);
            bind (l_have_cur);
            mov_rcx_rax ();
            // rdx = rcx + 16 + ((rdi + 7) & ~7)
            // mov rax, rdi; add rax, 7; and rax, -8; add rax, 16; add rax, rcx
            mov_rax_rdi ();
            add_rax_imm (7);
            // and rax, -8   48 83 E0 F8
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xE0); code.u8 (0xF8);
            add_rax_imm (16);
            add_rax_rcx ();
            mov_rdx_rax ();
            // cmp rdx, arena_bss_off + 65536
            lea_rax_bss (arena_bss_off + 65536);
            // cmp rdx, rax   48 39 C2
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xC2);
            branch (BranchKind.JA, l_fallback);
            // [cursor_bss_off] = rdx
            mov_rax_rdx ();
            store_global (cursor_bss_off, PatchSpace.BSS);
            // Zero 16-byte header (refcount = 0 = immortal, len = 0) and return rcx in rax
            xor_eax ();
            store_rcx_disp_rax (0);
            store_rcx_disp_rax (8);
            mov_rax_rcx ();
            ret ();
            bind (l_fallback);
            // Fallback to heap __planc_alloc (rdi, esi already set)
            call_rel32 ("__planc_alloc");
            ret ();
        }

        public void emit_rt_ref (Label mem_panic_lbl) {
            var l_done = new_label ();
            // mov rax, rdi                    48 89 F8
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xF8);
            // test rdi, rdi                   48 85 FF
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_done);
            // Compact instances are not reference counted: tag 3 means the
            // program owns the block and frees it explicitly.
            // cmp byte ptr [rdi + 4], 3       80 7F 04 03
            code.u8 (0x80); code.u8 (0x7F); code.u8 (0x04); code.u8 (0x03);
            branch (BranchKind.JE, l_done);
            // mov edx, [rdi]                  8B 17
            code.u8 (0x8B); code.u8 (0x17);
            // test edx, edx                   85 D2
            code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JE, l_done);
            // cmp edx, 0xDEADDEAD             81 FA AD DE AD DE
            code.u8 (0x81); code.u8 (0xFA); code.u32le (0xDEADDEADu);
            branch (BranchKind.JE, mem_panic_lbl);
            // cmp word ptr [rdi + 6], 0x504C  66 81 7F 06 4C 50
            code.u8 (0x66); code.u8 (0x81); code.u8 (0x7F); code.u8 (0x06);
            code.u8 (0x4C); code.u8 (0x50);
            branch (BranchKind.JNE, mem_panic_lbl);
            // lock inc dword ptr [rdi]        F0 FF 07
            code.u8 (0xF0); code.u8 (0xFF); code.u8 (0x07);
            bind (l_done);
            ret ();
        }

        // void __planc_compact_free(void* rdi)
        // Turns a compact block into a plain one and lets the normal free path
        // recycle it. Tag 0 skips the vtable finalizer, which compact objects
        // do not have.
        public void emit_rt_compact_free (Label mem_panic_lbl) {
            // The block is poisoned on free, so a second `free ()` panics
            // instead of handing the same block to the allocator twice.
            // cmp dword ptr [rdi], 0xDEADDEAD  81 3F AD DE AD DE
            code.u8 (0x81); code.u8 (0x3F); code.u32le (0xDEADDEADu);
            branch (BranchKind.JE, mem_panic_lbl);
            // mov dword ptr [rdi], 1          C7 07 01 00 00 00
            code.u8 (0xC7); code.u8 (0x07); code.u32le (1);
            // mov byte ptr [rdi + 4], 0        C6 47 04 00
            code.u8 (0xC6); code.u8 (0x47); code.u8 (0x04); code.u8 (0x00);
            // jmp __planc_unref                E9 rel32
            jmp_rel32 ("__planc_unref");
        }

        public void jmp_rel32 (string target) {
            code.u8 (0xE9);
            var p = new CallPatch ();
            p.displacement = code.length;
            p.callee = target;
            code.u32le (0);
            calls.add (p);
        }

        // void __planc_unref(void* rdi)
        public void emit_rt_unref (int bss_base, Label mem_panic_lbl) {
            var l_ret = new_label ();
            var l_free_self = new_label ();
            var l_class_dtor = new_label ();
            var l_elem_loop = new_label ();
            var l_elem_done = new_label ();

            // test rdi, rdi                   48 85 FF
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_ret);
            // Compact instances (tag 3) are freed explicitly, never here.
            // cmp byte ptr [rdi + 4], 3       80 7F 04 03
            code.u8 (0x80); code.u8 (0x7F); code.u8 (0x04); code.u8 (0x03);
            branch (BranchKind.JE, l_ret);
            // mov eax, [rdi]                  8B 07
            code.u8 (0x8B); code.u8 (0x07);
            // test eax, eax                   85 C0
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_ret);
            // cmp eax, 0xDEADDEAD             3D AD DE AD DE
            code.u8 (0x3D); code.u32le (0xDEADDEADu);
            branch (BranchKind.JE, mem_panic_lbl);
            // cmp word ptr [rdi + 6], 0x504C  66 81 7F 06 4C 50
            code.u8 (0x66); code.u8 (0x81); code.u8 (0x7F); code.u8 (0x06);
            code.u8 (0x4C); code.u8 (0x50);
            branch (BranchKind.JNE, mem_panic_lbl);
            // lock dec dword ptr [rdi]        F0 FF 0F
            code.u8 (0xF0); code.u8 (0xFF); code.u8 (0x0F);
            branch (BranchKind.JNE, l_ret);

            // Refcount reached 0.
            // cmp byte ptr [rdi + 4], 0       80 7F 04 00
            code.u8 (0x80); code.u8 (0x7F); code.u8 (0x04); code.u8 (0x00);
            branch (BranchKind.JE, l_free_self);
            // cmp byte ptr [rdi + 4], 2       80 7F 04 02 (class instance)
            code.u8 (0x80); code.u8 (0x7F); code.u8 (0x04); code.u8 (0x02);
            branch (BranchKind.JE, l_class_dtor);

            // Recursive unref for reference-type array elements (kind == 1)
            // mov dword ptr [rdi], 0xDEADDEAD C7 07 AD DE AD DE
            code.u8 (0xC7); code.u8 (0x07); code.u32le (0xDEADDEADu);
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            sub_rsp (8);
            // mov rbx, rdi; xor r12d, r12d; mov r13, [rbx + 8]
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xE4);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x6B); code.u8 (0x08);
            bind (l_elem_loop);
            // cmp r12, r13                    4D 39 EC
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xEC);
            branch (BranchKind.JAE, l_elem_done);
            // mov rdi, [rbx + r12*8 + 16]     4A 8B 7C E3 10
            code.u8 (0x4A); code.u8 (0x8B); code.u8 (0x7C); code.u8 (0xE3); code.u8 (0x10);
            call_rel32 ("__planc_unref");
            // inc r12                         49 FF C4
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC4);
            branch (BranchKind.JMP, l_elem_loop);
            bind (l_elem_done);
            // mov rdi, rbx                    48 89 DF
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            add_rsp (8);
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            pop_rbp ();
            branch (BranchKind.JMP, l_free_self);

            // Class finalizer: vtable is at [rdi + 8], finalizer slot at vtable[0].
            // Keeps refcount == 0 during dtor so `this.helper()` is safe.
            bind (l_class_dtor);
            // mov rax, [rdi + 8]              48 8B 47 08
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08);
            // mov rax, [rax]                  48 8B 00
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x00);
            // test rax, rax                   48 85 C0
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_free_self);
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            sub_rsp (8);
            // mov rbx, rdi                    48 89 FB
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);
            // call rax                        FF D0
            code.u8 (0xFF); code.u8 (0xD0);
            // mov rdi, rbx                    48 89 DF
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            add_rsp (8);
            pop_reg (Reg.RBX);
            pop_rbp ();

            bind (l_free_self);
            // mov dword ptr [rdi], 0xDEADDEAD C7 07 AD DE AD DE
            code.u8 (0xC7); code.u8 (0x07); code.u32le (0xDEADDEADu);
            // lea rdx, [rip + bss_base]       48 8D 15 + disp32
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x15);
            record_rip (bss_base, PatchSpace.BSS);
            // lock inc qword ptr [rdx + 8]    F0 48 FF 42 08 (free_count++)
            code.u8 (0xF0); code.u8 (0x48); code.u8 (0xFF); code.u8 (0x42); code.u8 (0x08);
            // movzx ecx, byte ptr [rdi + 5]   0F B6 4F 05
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x4F); code.u8 (0x05);
            // cmp ecx, 8                      83 F9 08
            code.u8 (0x83); code.u8 (0xF9); code.u8 (0x08);
            branch (BranchKind.JAE, l_ret);
            // Acquire allocator spinlock [rdx + 96]
            var l_unref_lock = new_label ();
            var l_unref_locked = new_label ();
            bind (l_unref_lock);
            // mov eax, 1; xchg [rdx + 96], eax; test eax, eax; je l_unref_locked
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x42); code.u8 (0x60);
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_unref_locked);
            // pause
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_unref_lock);
            bind (l_unref_locked);

            // Push block onto free_lists[rcx]
            // mov r8, [rdx + rcx*8 + 32]      4C 8B 44 CA 20
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x44); code.u8 (0xCA); code.u8 (0x20);
            // mov [rdi + 8], r8               4C 89 47 08
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x47); code.u8 (0x08);
            // mov [rdx + rcx*8 + 32], rdi     48 89 7C CA 20
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x7C); code.u8 (0xCA); code.u8 (0x20);
            // Release spinlock: mov dword ptr [rdx + 96], 0
            code.u8 (0xC7); code.u8 (0x42); code.u8 (0x60); code.u32le (0);

            bind (l_ret);
            ret ();
        }

        // string* __planc_str_concat(string* rdi, string* rsi)
        public void emit_rt_str_concat () {
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14

            // mov r12, rdi; mov r13, rsi
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFC);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF5);
            // mov r14, [r12 + 8]              4D 8B 74 24 08
            code.u8 (0x4D); code.u8 (0x8B); code.u8 (0x74); code.u8 (0x24); code.u8 (0x08);
            // mov rbx, [r13 + 8]              49 8B 5D 08
            code.u8 (0x49); code.u8 (0x8B); code.u8 (0x5D); code.u8 (0x08);

            // rdi = r14 + rbx + 1; xor esi, esi; call __planc_alloc
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xDF);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC7);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");

            // [rax + 8] = r14 + rbx
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF1);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xD9);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x48); code.u8 (0x08);

            // Copy r14 bytes from r12 + 16 to rax + 16
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7); // mov rdi, rax
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10); // add rdi, 16
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE6); // mov rsi, r12
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x10); // add rsi, 16
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF1); // mov rcx, r14
            code.u8 (0xF3); code.u8 (0xA4);                 // rep movsb

            // Copy rbx bytes from r13 + 16
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEE); // mov rsi, r13
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x10); // add rsi, 16
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9); // mov rcx, rbx
            code.u8 (0xF3); code.u8 (0xA4);                 // rep movsb

            // Trailing NUL: mov byte ptr [rdi], 0
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00);

            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        private void emit_rt_int_to_str_impl (bool is_unsigned) {
            push_rbp ();
            mov_rsp_to_rbp ();
            sub_rsp (32);
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            emit_format_int_to_stack (is_unsigned);
            // mov r12, rcx; mov rbx, rbp; sub rbx, rcx
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xCC);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xEB);
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xCB);
            // rdi = rbx + 1; xor esi, esi; call __planc_alloc
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC7);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            // [rax + 8] = rbx
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x58); code.u8 (0x08);
            // Copy rbx bytes from r12 to rax + 16
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7); // mov rdi, rax
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10); // add rdi, 16
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE6); // mov rsi, r12
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9); // mov rcx, rbx
            code.u8 (0xF3); code.u8 (0xA4);                 // rep movsb
            // mov byte ptr [rdi], 0
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00);
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        // string* __planc_int_to_str(int64 rdi)
        public void emit_rt_int_to_str () {
            emit_rt_int_to_str_impl (false);
        }

        // string* __planc_uint_to_str(uint64 rdi)
        public void emit_rt_uint_to_str () {
            emit_rt_int_to_str_impl (true);
        }

        public void emit_check_leaks (int bss_base, Label leak_panic_lbl) {
            // lea rdx, [rip + bss_base]       48 8D 15 + disp32
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x15);
            record_rip (bss_base, PatchSpace.BSS);
            // mov rax, [rdx]                  48 8B 02
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x02);
            // cmp rax, [rdx + 8]              48 3B 42 08
            code.u8 (0x48); code.u8 (0x3B); code.u8 (0x42); code.u8 (0x08);
            branch (BranchKind.JNE, leak_panic_lbl);
        }

        // int64 __planc_is_instance(void* rdi, void* rsi)
        public void emit_rt_is_instance () {
            var l_loop = new_label ();
            var l_match = new_label ();
            var l_done = new_label ();
            xor_eax ();
            // test rdi, rdi                   48 85 FF
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_done);
            // mov rdx, [rdi + 8]              48 8B 57 08
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x57); code.u8 (0x08);
            bind (l_loop);
            // cmp rdx, rsi                    48 39 F2
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xF2);
            branch (BranchKind.JE, l_match);
            // mov rdx, [rdx + 8]              48 8B 52 08
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x52); code.u8 (0x08);
            // test rdx, rdx                   48 85 D2
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JNE, l_loop);
            ret ();
            bind (l_match);
            mov_eax (1);
            bind (l_done);
            ret ();
        }

        // string* __planc_str_slice(string* rdi, int64 rsi_start, int64 rdx_end)
        public void emit_rt_str_slice (int empty_str_off, bool bounds_check, Label bounds_panic_lbl) {
            var l_empty = new_label ();
            if (bounds_check) {
                // cmp rdx, [rdi + 8]          48 3B 57 08
                code.u8 (0x48); code.u8 (0x3B); code.u8 (0x57); code.u8 (0x08);
                branch (BranchKind.JA, bounds_panic_lbl);
                // cmp rsi, rdx                48 39 D6
                code.u8 (0x48); code.u8 (0x39); code.u8 (0xD6);
                branch (BranchKind.JA, bounds_panic_lbl);
            }
            // mov rax, rdx; sub rax, rsi      48 89 D0 | 48 29 F0
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD0);
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xF0);
            // test rax, rax; jle l_empty
            test_rax_rax ();
            branch (BranchKind.JLE, l_empty);

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14  (stack 16-byte aligned)

            // r12 = src (rdi), r13 = start (rsi), rbx = slice_len (rax)
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFC);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF5);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC3);

            // rdi = rbx + 1; xor esi, esi; call __planc_alloc
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC7);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");

            // [rax + 8] = rbx
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x58); code.u8 (0x08);
            // Copy rbx bytes from (r12 + 16 + r13) to (rax + 16)
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7); // mov rdi, rax
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10); // add rdi, 16
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE6); // mov rsi, r12
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x10); // add rsi, 16
            code.u8 (0x4C); code.u8 (0x01); code.u8 (0xEE); // add rsi, r13
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9); // mov rcx, rbx
            code.u8 (0xF3); code.u8 (0xA4);                 // rep movsb
            // Trailing NUL: mov byte ptr [rdi], 0
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00);

            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();

            bind (l_empty);
            lea_rax_rip (empty_str_off);
            ret ();
        }

        // string* __planc_str_strip(string* rdi)
        public void emit_rt_str_strip () {
            var l_lead = new_label ();
            var l_lead_next = new_label ();
            var l_lead_done = new_label ();
            var l_trail = new_label ();
            var l_trail_next = new_label ();
            var l_trail_done = new_label ();

            // mov rcx, [rdi + 8]           48 8B 4F 08
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4F); code.u8 (0x08);
            // xor esi, esi                 31 F6
            code.u8 (0x31); code.u8 (0xF6);

            bind (l_lead);
            // cmp rsi, rcx                 48 39 CE
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xCE);
            branch (BranchKind.JAE, l_lead_done);
            // movzx eax, byte ptr [rdi + rsi + 16]   0F B6 44 37 10
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x37); code.u8 (0x10);
            // cmp al, 0x20; je l_lead_next
            code.u8 (0x3C); code.u8 (0x20);
            branch (BranchKind.JE, l_lead_next);
            // cmp al, 0x09; jb l_lead_done
            code.u8 (0x3C); code.u8 (0x09);
            branch (BranchKind.JB, l_lead_done);
            // cmp al, 0x0D; ja l_lead_done
            code.u8 (0x3C); code.u8 (0x0D);
            branch (BranchKind.JA, l_lead_done);
            bind (l_lead_next);
            // inc rsi                      48 FF C6
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6);
            branch (BranchKind.JMP, l_lead);

            bind (l_lead_done);
            // mov rdx, rcx                 48 89 CA
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xCA);

            bind (l_trail);
            // cmp rdx, rsi                 48 39 F2
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xF2);
            branch (BranchKind.JBE, l_trail_done);
            // movzx eax, byte ptr [rdi + rdx + 15]   0F B6 44 17 0F
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x17); code.u8 (0x0F);
            // cmp al, 0x20; je l_trail_next
            code.u8 (0x3C); code.u8 (0x20);
            branch (BranchKind.JE, l_trail_next);
            // cmp al, 0x09; jb l_trail_done
            code.u8 (0x3C); code.u8 (0x09);
            branch (BranchKind.JB, l_trail_done);
            // cmp al, 0x0D; ja l_trail_done
            code.u8 (0x3C); code.u8 (0x0D);
            branch (BranchKind.JA, l_trail_done);
            bind (l_trail_next);
            // dec rdx                      48 FF CA
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xCA);
            branch (BranchKind.JMP, l_trail);

            bind (l_trail_done);
            jmp_rel32 ("__planc_str_slice");
        }

        // void* __planc_iface_lookup(void* rdi, int64 rax_iface_id)
        // Preserves rdi, rsi, rdx, rcx, r8, r9; clobbers only r10, r11, rax.
        public void emit_rt_iface_lookup () {
            var l_loop = new_label ();
            var l_found = new_label ();
            var l_not_found = new_label ();

            // test rdi, rdi                   48 85 FF
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_not_found);
            // mov r10, [rdi + 8]              4C 8B 57 08 (vtable)
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x57); code.u8 (0x08);
            // mov r10, [r10 + 16]             4D 8B 52 10 (itable_ptr)
            code.u8 (0x4D); code.u8 (0x8B); code.u8 (0x52); code.u8 (0x10);
            // test r10, r10                   4D 85 D2
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JE, l_not_found);

            bind (l_loop);
            // mov r11, [r10]                  4D 8B 1A
            code.u8 (0x4D); code.u8 (0x8B); code.u8 (0x1A);
            // test r11, r11                   4D 85 DB
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xDB);
            branch (BranchKind.JE, l_not_found);
            // cmp r11, rax                    49 39 C3
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xC3);
            branch (BranchKind.JE, l_found);
            // add r10, 16                     49 83 C2 10
            code.u8 (0x49); code.u8 (0x83); code.u8 (0xC2); code.u8 (0x10);
            branch (BranchKind.JMP, l_loop);

            bind (l_found);
            // mov rax, [r10 + 8]              49 8B 42 08
            code.u8 (0x49); code.u8 (0x8B); code.u8 (0x42); code.u8 (0x08);
            ret ();

            bind (l_not_found);
            xor_eax ();
            ret ();
        }

        // string[] __planc_build_args(int64 rdi_argc, uint8** rsi_argv)
        public void emit_rt_build_args () {
            if (target_windows) {
                emit_rt_build_args_win32 ();
                return;
            }
            var l_arg_loop = new_label ();
            var l_strlen = new_label ();
            var l_strlen_done = new_label ();
            var l_done = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14  (stack 16-byte aligned)

            // mov r12, rdi; mov r13, rsi
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFC);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF5);

            // rdi = argc * 8; esi = 1; call __planc_alloc
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE7); code.u8 (0x03); // shl rdi, 3
            code.u8 (0xBE); code.u32le (1);                                 // mov esi, 1
            call_rel32 ("__planc_alloc");

            // [rax + 8] = r12 (argc); r14 = arr
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x60); code.u8 (0x08); // mov [rax + 8], r12
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC6);                 // mov r14, rax

            // xor ebx, ebx (i = 0)
            code.u8 (0x31); code.u8 (0xDB);
            bind (l_arg_loop);
            // cmp rbx, r12                    4C 39 E3
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xE3);
            branch (BranchKind.JGE, l_done);

            // rdx = [r13 + rbx * 8 + 0]       49 8B 54 DD 00
            code.u8 (0x49); code.u8 (0x8B); code.u8 (0x54); code.u8 (0xDD); code.u8 (0x00);
            // xor ecx, ecx
            code.u8 (0x31); code.u8 (0xC9);
            bind (l_strlen);
            // cmp byte ptr [rdx + rcx], 0     80 3C 0A 00
            code.u8 (0x80); code.u8 (0x3C); code.u8 (0x0A); code.u8 (0x00);
            branch (BranchKind.JE, l_strlen_done);
            // inc rcx                         48 FF C1
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1);
            branch (BranchKind.JMP, l_strlen);

            bind (l_strlen_done);
            // push rdx; push rcx
            code.u8 (0x52);
            code.u8 (0x51);
            // lea rdi, [rcx + 1]              48 8D 79 01
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x79); code.u8 (0x01);
            // xor esi, esi
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            // pop rcx; pop rsi
            code.u8 (0x59);
            code.u8 (0x5E);
            // [rax + 8] = rcx                 48 89 48 08
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x48); code.u8 (0x08);
            // lea rdi, [rax + 16]             48 8D 78 10
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x78); code.u8 (0x10);
            // rep movsb                       F3 A4
            code.u8 (0xF3); code.u8 (0xA4);
            // mov byte ptr [rdi], 0           C6 07 00
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00);
            // mov [r14 + rbx * 8 + 16], rax   49 89 44 DE 10
            code.u8 (0x49); code.u8 (0x89); code.u8 (0x44); code.u8 (0xDE); code.u8 (0x10);
            // inc rbx                         48 FF C3
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC3);
            branch (BranchKind.JMP, l_arg_loop);

            bind (l_done);
            // mov rax, r14                    4C 89 F0
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        private void emit_rt_build_args_win32 () {
            var l_c_ws = new_label ();
            var l_c_tok = new_label ();
            var l_c_q = new_label ();
            var l_c_uq = new_label ();
            var l_c_done = new_label ();
            var l_p_ws = new_label ();
            var l_p_q = new_label ();
            var l_p_uq = new_label ();
            var l_p_alloc = new_label ();
            var l_done = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            code.u8 (0x41); code.u8 (0x57); // push r15
            sub_rsp (40); // 16-byte aligned + 32-byte Win64 shadow

            emit_iat_call (Pe.IAT_GET_COMMAND_LINE_A);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC5); // mov r13, rax (cmdline)

            // Pass 1: count tokens in r12
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xE4); // xor r12d, r12d
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEE); // mov rsi, r13

            bind (l_c_ws);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06); // movzx eax, byte ptr [rsi]
            code.u8 (0x84); code.u8 (0xC0);                 // test al, al
            branch (BranchKind.JE, l_c_done);
            code.u8 (0x3C); code.u8 (0x20);                 // cmp al, ' '
            branch (BranchKind.JE, l_c_tok);
            code.u8 (0x3C); code.u8 (0x09);                 // cmp al, '\t'
            branch (BranchKind.JNE, l_c_q);
            bind (l_c_tok);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            branch (BranchKind.JMP, l_c_ws);

            bind (l_c_q);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC4); // inc r12 (argc++)
            code.u8 (0x3C); code.u8 (0x22);                 // cmp al, '"'
            branch (BranchKind.JNE, l_c_uq);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            var l_c_q_loop = new_label ();
            bind (l_c_q_loop);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06); // movzx eax, byte ptr [rsi]
            code.u8 (0x84); code.u8 (0xC0);                 // test al, al
            branch (BranchKind.JE, l_c_done);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            code.u8 (0x3C); code.u8 (0x22);                 // cmp al, '"'
            branch (BranchKind.JNE, l_c_q_loop);
            branch (BranchKind.JMP, l_c_ws);

            bind (l_c_uq);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06); // movzx eax, byte ptr [rsi]
            code.u8 (0x84); code.u8 (0xC0);                 // test al, al
            branch (BranchKind.JE, l_c_done);
            code.u8 (0x3C); code.u8 (0x20);                 // cmp al, ' '
            branch (BranchKind.JE, l_c_ws);
            code.u8 (0x3C); code.u8 (0x09);                 // cmp al, '\t'
            branch (BranchKind.JE, l_c_ws);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            branch (BranchKind.JMP, l_c_uq);

            bind (l_c_done);
            // Allocate string[] of length r12
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7); // mov rdi, r12
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE7); code.u8 (0x03); // shl rdi, 3
            code.u8 (0xBE); code.u32le (1);                 // mov esi, 1
            call_rel32 ("__planc_alloc");
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x60); code.u8 (0x08); // mov [rax + 8], r12
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC6); // mov r14, rax

            // Pass 2: populate string[]
            code.u8 (0x31); code.u8 (0xDB);                 // xor ebx, ebx
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0xEF); // mov r15, r13

            bind (l_p_ws);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xE3); // cmp rbx, r12
            branch (BranchKind.JGE, l_done);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x07); // movzx eax, byte ptr [r15]
            code.u8 (0x84); code.u8 (0xC0);                 // test al, al
            branch (BranchKind.JE, l_done);
            code.u8 (0x3C); code.u8 (0x20);                 // cmp al, ' '
            branch (BranchKind.JE, l_p_q);
            code.u8 (0x3C); code.u8 (0x09);                 // cmp al, '\t'
            branch (BranchKind.JNE, l_p_uq);
            bind (l_p_q);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC7); // inc r15
            branch (BranchKind.JMP, l_p_ws);

            bind (l_p_uq);
            code.u8 (0x31); code.u8 (0xC9);                 // xor ecx, ecx
            code.u8 (0x3C); code.u8 (0x22);                 // cmp al, '"'
            var l_p_unquoted = new_label ();
            branch (BranchKind.JNE, l_p_unquoted);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC7); // inc r15
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xFA); // mov rdx, r15
            var l_p_ql = new_label ();
            bind (l_p_ql);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x04); code.u8 (0x0F);
            code.u8 (0x84); code.u8 (0xC0);                 // test al, al
            var l_p_q_advance = new_label ();
            branch (BranchKind.JE, l_p_q_advance);
            code.u8 (0x3C); code.u8 (0x22);                 // cmp al, '"'
            branch (BranchKind.JE, l_p_q_advance);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_p_ql);
            bind (l_p_q_advance);
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xCF); // add r15, rcx
            code.u8 (0x41); code.u8 (0x80); code.u8 (0x3F); code.u8 (0x22); // cmp byte ptr [r15], '"'
            branch (BranchKind.JNE, l_p_alloc);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC7); // inc r15
            branch (BranchKind.JMP, l_p_alloc);

            bind (l_p_unquoted);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xFA); // mov rdx, r15
            var l_p_ul = new_label ();
            bind (l_p_ul);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x04); code.u8 (0x0F);
            code.u8 (0x84); code.u8 (0xC0);                 // test al, al
            var l_p_u_adv = new_label ();
            branch (BranchKind.JE, l_p_u_adv);
            code.u8 (0x3C); code.u8 (0x20);
            branch (BranchKind.JE, l_p_u_adv);
            code.u8 (0x3C); code.u8 (0x09);
            branch (BranchKind.JE, l_p_u_adv);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_p_ul);
            bind (l_p_u_adv);
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xCF); // add r15, rcx

            bind (l_p_alloc);
            code.u8 (0x52);                                 // push rdx
            code.u8 (0x51);                                 // push rcx
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x79); code.u8 (0x01); // lea rdi, [rcx + 1]
            code.u8 (0x31); code.u8 (0xF6);                 // xor esi, esi
            call_rel32 ("__planc_alloc");
            code.u8 (0x59);                                 // pop rcx
            code.u8 (0x5E);                                 // pop rsi
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x48); code.u8 (0x08); // mov [rax + 8], rcx
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x78); code.u8 (0x10); // lea rdi, [rax + 16]
            code.u8 (0xF3); code.u8 (0xA4);                 // rep movsb
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00); // mov byte ptr [rdi], 0
            code.u8 (0x49); code.u8 (0x89); code.u8 (0x44); code.u8 (0xDE); code.u8 (0x10); // mov [r14 + rbx * 8 + 16], rax
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC3); // inc rbx
            branch (BranchKind.JMP, l_p_ws);

            bind (l_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF0); // mov rax, r14
            add_rsp (40);
            code.u8 (0x41); code.u8 (0x5F); // pop r15
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        // bool __planc_str_has_prefix(string* rdi, string* rsi)
        public void emit_rt_str_has_prefix () {
            var l_true = new_label ();
            var l_false = new_label ();
            // test rdi, rdi; je l_false
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_false);
            // test rsi, rsi; je l_false
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6);
            branch (BranchKind.JE, l_false);
            // mov r8, [rdi + 8]; mov r9, [rsi + 8]
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x4E); code.u8 (0x08);
            // cmp r9, r8; ja l_false
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xC1);
            branch (BranchKind.JA, l_false);
            // test r9, r9; je l_true
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC9);
            branch (BranchKind.JE, l_true);
            // add rdi, 16; add rsi, 16; mov rcx, r9; xor eax, eax; repe cmpsb; sete al; ret
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC9);
            xor_eax ();
            code.u8 (0xF3); code.u8 (0xA6);
            code.u8 (0x0F); code.u8 (0x94); code.u8 (0xC0);
            ret ();
            bind (l_true);
            mov_eax (1);
            ret ();
            bind (l_false);
            xor_eax ();
            ret ();
        }

        // bool __planc_str_has_suffix(string* rdi, string* rsi)
        public void emit_rt_str_has_suffix () {
            var l_true = new_label ();
            var l_false = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_false);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6);
            branch (BranchKind.JE, l_false);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x4E); code.u8 (0x08);
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xC1);
            branch (BranchKind.JA, l_false);
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC9);
            branch (BranchKind.JE, l_true);
            // sub r8, r9; lea rdi, [rdi + r8 + 16]; add rsi, 16; mov rcx, r9; xor eax, eax; repe cmpsb; sete al; ret
            code.u8 (0x4D); code.u8 (0x29); code.u8 (0xC8);
            code.u8 (0x4A); code.u8 (0x8D); code.u8 (0x7C); code.u8 (0x07); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC9);
            xor_eax ();
            code.u8 (0xF3); code.u8 (0xA6);
            code.u8 (0x0F); code.u8 (0x94); code.u8 (0xC0);
            ret ();
            bind (l_true);
            mov_eax (1);
            ret ();
            bind (l_false);
            xor_eax ();
            ret ();
        }

        // int __planc_str_ascii_casecmp(string* rdi, string* rsi)
        // Sets rdx = UINT64_MAX and falls through to __planc_str_ascii_ncasecmp.
        public void emit_rt_str_ascii_casecmp () {
            // mov rdx, -1 (48 C7 C2 FF FF FF FF)
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC2);
            code.u8 (0xFF); code.u8 (0xFF); code.u8 (0xFF); code.u8 (0xFF);
        }

        // int __planc_str_ascii_ncasecmp(string* rdi, string* rsi, size_t rdx)
        public void emit_rt_str_ascii_ncasecmp () {
            var l_zero = new_label ();
            var l_s1_null = new_label ();
            var l_s2_null = new_label ();
            var l_loop = new_label ();
            var l_after_loop = new_label ();
            var l_s1_shorter = new_label ();
            var l_cmp_c2 = new_label ();
            var l_cmp_diff = new_label ();

            // test rdx, rdx; je l_zero
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JE, l_zero);

            // null guards: (null, null)->0, (null, s2)->-1, (s1, null)->1
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_s1_null);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6); // test rsi, rsi
            branch (BranchKind.JE, l_s2_null);

            // r8 = [rdi + 8], r9 = [rsi + 8], r10 = min(r8, r9, rdx)
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x4E); code.u8 (0x08);
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0xC2); // mov r10, r8
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xC1); // cmp r9, r8
            code.u8 (0x73); code.u8 (0x03);                 // jae +3
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0xCA); // mov r10, r9
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xD2); // cmp rdx, r10
            code.u8 (0x73); code.u8 (0x03);                 // jae +3
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xD2); // mov r10, rdx

            // rdi += 16, rsi += 16, rcx = 0
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x10);
            code.u8 (0x31); code.u8 (0xC9);                 // xor ecx, ecx

            bind (l_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xD1); // cmp rcx, r10
            branch (BranchKind.JAE, l_after_loop);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x04); code.u8 (0x0F); // movzx eax, byte [rdi + rcx]
            code.u8 (0x44); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x1C); code.u8 (0x0E); // movzx r11d, byte [rsi + rcx]

            // if ('A' <= al <= 'Z') al += 32
            code.u8 (0x83); code.u8 (0xF8); code.u8 (65);
            branch (BranchKind.JB, l_cmp_c2);
            code.u8 (0x83); code.u8 (0xF8); code.u8 (90);
            branch (BranchKind.JA, l_cmp_c2);
            code.u8 (0x83); code.u8 (0xC0); code.u8 (32);

            bind (l_cmp_c2);
            // if ('A' <= r11b <= 'Z') r11d += 32
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xFB); code.u8 (65);
            branch (BranchKind.JB, l_cmp_diff);
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xFB); code.u8 (90);
            branch (BranchKind.JA, l_cmp_diff);
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xC3); code.u8 (32);

            bind (l_cmp_diff);
            code.u8 (0x44); code.u8 (0x29); code.u8 (0xD8); // sub eax, r11d
            var l_next = new_label ();
            branch (BranchKind.JE, l_next);
            code.u8 (0x48); code.u8 (0x98);                 // cdqe
            ret ();

            bind (l_next);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_loop);

            bind (l_after_loop);
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xD2); // cmp r10, rdx
            branch (BranchKind.JE, l_zero);
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xC8); // cmp r8, r9
            branch (BranchKind.JE, l_zero);
            branch (BranchKind.JB, l_s1_shorter);
            // s1 longer: return (int)(uint8)s1[r10]
            code.u8 (0x42); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x04); code.u8 (0x17); // movzx eax, byte [rdi + r10]
            ret ();

            bind (l_s1_shorter);
            // s1 shorter: return -(int)(uint8)s2[r10]
            code.u8 (0x42); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x04); code.u8 (0x16); // movzx eax, byte [rsi + r10]
            code.u8 (0xF7); code.u8 (0xD8);                 // neg eax
            code.u8 (0x48); code.u8 (0x98);                 // cdqe
            ret ();

            bind (l_s1_null);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6); // test rsi, rsi
            branch (BranchKind.JE, l_zero);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC0); // mov rax, -1
            code.u8 (0xFF); code.u8 (0xFF); code.u8 (0xFF); code.u8 (0xFF);
            ret ();

            bind (l_s2_null);
            mov_eax (1);
            ret ();

            bind (l_zero);
            xor_eax ();
            ret ();
        }

        // int64 __planc_utf8_char_count(string* rdi)
        public void emit_rt_utf8_char_count () {
            var l_loop = new_label ();
            var l_cont = new_label ();
            var l_done = new_label ();
            xor_eax ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_done);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08); // mov r8, [rdi + 8]
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x77); code.u8 (0x10); // lea rsi, [rdi + 16]
            code.u8 (0x31); code.u8 (0xC9); // xor ecx, ecx
            bind (l_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC1); // cmp rcx, r8
            branch (BranchKind.JGE, l_done);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x14); code.u8 (0x0E); // movzx edx, [rsi + rcx]
            code.u8 (0x80); code.u8 (0xE2); code.u8 (0xC0); // and dl, 0xC0
            code.u8 (0x80); code.u8 (0xFA); code.u8 (0x80); // cmp dl, 0x80
            branch (BranchKind.JE, l_cont);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC0); // inc rax
            bind (l_cont);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_loop);
            bind (l_done);
            ret ();
        }

        // uint32 __planc_utf8_get_char(string* rdi, int64 rsi)
        public void emit_rt_utf8_get_char () {
            var l_try3 = new_label ();
            var l_try4 = new_label ();
            var l_bad = new_label ();
            var l_ret = new_label ();
            xor_eax ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_ret);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08); // mov r8, [rdi + 8]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6); // test rsi, rsi
            branch (BranchKind.JL, l_ret);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC6); // cmp rsi, r8
            branch (BranchKind.JGE, l_ret);
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x4C); code.u8 (0x37); code.u8 (0x10); // lea r9, [rdi + rsi + 16]
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x01); // movzx eax, [r9]
            code.u8 (0x3D); code.u8 (0x80); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00); // cmp eax, 0x80
            branch (BranchKind.JB, l_ret);
            // 2-byte
            code.u8 (0x89); code.u8 (0xC2); // mov edx, eax
            code.u8 (0x83); code.u8 (0xE2); code.u8 (0xE0); // and edx, 0xE0
            code.u8 (0x81); code.u8 (0xFA); code.u8 (0xC0); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_try3);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x56); code.u8 (0x01); // lea rdx, [rsi + 1]
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2); // cmp rdx, r8
            branch (BranchKind.JGE, l_bad);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x49); code.u8 (0x01); // movzx ecx, [r9 + 1]
            code.u8 (0x89); code.u8 (0xCA); // mov edx, ecx
            code.u8 (0x83); code.u8 (0xE2); code.u8 (0xC0); // and edx, 0xC0
            code.u8 (0x81); code.u8 (0xFA); code.u8 (0x80); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_bad);
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x1F); // and eax, 0x1F
            code.u8 (0xC1); code.u8 (0xE0); code.u8 (0x06); // shl eax, 6
            code.u8 (0x83); code.u8 (0xE1); code.u8 (0x3F); // and ecx, 0x3F
            code.u8 (0x09); code.u8 (0xC8); // or eax, ecx
            ret ();
            // 3-byte
            bind (l_try3);
            code.u8 (0x89); code.u8 (0xC2);
            code.u8 (0x83); code.u8 (0xE2); code.u8 (0xF0);
            code.u8 (0x81); code.u8 (0xFA); code.u8 (0xE0); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_try4);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x56); code.u8 (0x02);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2);
            branch (BranchKind.JGE, l_bad);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x49); code.u8 (0x01); // ecx=[r9+1]
            code.u8 (0x45); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x51); code.u8 (0x02); // r10d=[r9+2]
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x0F);
            code.u8 (0xC1); code.u8 (0xE0); code.u8 (0x0C);
            code.u8 (0x83); code.u8 (0xE1); code.u8 (0x3F);
            code.u8 (0xC1); code.u8 (0xE1); code.u8 (0x06);
            code.u8 (0x09); code.u8 (0xC8);
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xE2); code.u8 (0x3F);
            code.u8 (0x44); code.u8 (0x09); code.u8 (0xD0);
            ret ();
            // 4-byte
            bind (l_try4);
            code.u8 (0x89); code.u8 (0xC2);
            code.u8 (0x83); code.u8 (0xE2); code.u8 (0xF8);
            code.u8 (0x81); code.u8 (0xFA); code.u8 (0xF0); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_bad);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x56); code.u8 (0x03);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2);
            branch (BranchKind.JGE, l_bad);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x49); code.u8 (0x01); // ecx=[r9+1]
            code.u8 (0x45); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x51); code.u8 (0x02); // r10d=[r9+2]
            code.u8 (0x45); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x59); code.u8 (0x03); // r11d=[r9+3]
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x07);
            code.u8 (0xC1); code.u8 (0xE0); code.u8 (0x12);
            code.u8 (0x83); code.u8 (0xE1); code.u8 (0x3F);
            code.u8 (0xC1); code.u8 (0xE1); code.u8 (0x0C);
            code.u8 (0x09); code.u8 (0xC8);
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xE2); code.u8 (0x3F);
            code.u8 (0x41); code.u8 (0xC1); code.u8 (0xE2); code.u8 (0x06);
            code.u8 (0x44); code.u8 (0x09); code.u8 (0xD0);
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xE3); code.u8 (0x3F);
            code.u8 (0x44); code.u8 (0x09); code.u8 (0xD8);
            ret ();
            bind (l_bad);
            mov_eax (0xFFFD);
            bind (l_ret);
            ret ();
        }

        // bool __planc_utf8_validate(string* rdi)
        public void emit_rt_utf8_validate () {
            var l_loop = new_label ();
            var l_try2 = new_label ();
            var l_try3 = new_label ();
            var l_try4 = new_label ();
            var l_ok = new_label ();
            var l_bad = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_bad);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08); // mov r8, [rdi + 8]
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x4F); code.u8 (0x10); // lea r9, [rdi + 16]
            code.u8 (0x31); code.u8 (0xC9); // xor ecx, ecx
            bind (l_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC1); // cmp rcx, r8
            branch (BranchKind.JGE, l_ok);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x04); code.u8 (0x09); // movzx eax, [r9 + rcx]
            code.u8 (0x3D); code.u8 (0x80); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JAE, l_try2);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_loop);
            bind (l_try2);
            code.u8 (0x89); code.u8 (0xC2);
            code.u8 (0x83); code.u8 (0xE2); code.u8 (0xE0);
            code.u8 (0x81); code.u8 (0xFA); code.u8 (0xC0); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_try3);
            code.u8 (0x3D); code.u8 (0xC2); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00); // cmp eax, 0xC2
            branch (BranchKind.JB, l_bad);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x51); code.u8 (0x01); // lea rdx, [rcx + 1]
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2);
            branch (BranchKind.JGE, l_bad);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x04); code.u8 (0x11); // movzx eax, [r9 + rdx]
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0xC0);
            code.u8 (0x3D); code.u8 (0x80); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_bad);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC1); code.u8 (0x02); // add rcx, 2
            branch (BranchKind.JMP, l_loop);
            bind (l_try3);
            code.u8 (0x89); code.u8 (0xC2);
            code.u8 (0x83); code.u8 (0xE2); code.u8 (0xF0);
            code.u8 (0x81); code.u8 (0xFA); code.u8 (0xE0); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_try4);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x51); code.u8 (0x02); // lea rdx, [rcx + 2]
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2);
            branch (BranchKind.JGE, l_bad);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x09); code.u8 (0x01); // [r9+rcx+1]
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0xC0);
            code.u8 (0x3D); code.u8 (0x80); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_bad);
            code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x09); code.u8 (0x02); // [r9+rcx+2]
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0xC0);
            code.u8 (0x3D); code.u8 (0x80); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_bad);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC1); code.u8 (0x03);
            branch (BranchKind.JMP, l_loop);
            bind (l_try4);
            code.u8 (0x89); code.u8 (0xC2);
            code.u8 (0x83); code.u8 (0xE2); code.u8 (0xF8);
            code.u8 (0x81); code.u8 (0xFA); code.u8 (0xF0); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
            branch (BranchKind.JNE, l_bad);
            code.u8 (0x3D); code.u8 (0xF4); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00); // cmp eax, 0xF4
            branch (BranchKind.JA, l_bad);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x51); code.u8 (0x03); // lea rdx, [rcx + 3]
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2);
            branch (BranchKind.JGE, l_bad);
            for (int off_b = 1; off_b <= 3; off_b++) {
                code.u8 (0x41); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x09); code.u8 ((uint8) off_b);
                code.u8 (0x83); code.u8 (0xE0); code.u8 (0xC0);
                code.u8 (0x3D); code.u8 (0x80); code.u8 (0x00); code.u8 (0x00); code.u8 (0x00);
                branch (BranchKind.JNE, l_bad);
            }
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC1); code.u8 (0x04);
            branch (BranchKind.JMP, l_loop);
            bind (l_ok);
            mov_eax (1);
            ret ();
            bind (l_bad);
            xor_eax ();
            ret ();
        }

        // int64 __planc_str_index_of(string* rdi, string* rsi, int64 rdx_start)
        public void emit_rt_str_index_of () {
            var l_ok_start = new_label ();
            var l_loop = new_label ();
            var l_inner = new_label ();
            var l_next = new_label ();
            var l_found = new_label ();
            var l_not_found = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_not_found);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6); // test rsi, rsi
            branch (BranchKind.JE, l_not_found);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08); // mov r8, [rdi+8]
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x4E); code.u8 (0x08); // mov r9, [rsi+8]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2); // test rdx, rdx
            branch (BranchKind.JNS, l_ok_start);
            code.u8 (0x31); code.u8 (0xD2); // xor edx, edx
            bind (l_ok_start);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2); // cmp rdx, r8
            branch (BranchKind.JG, l_not_found);
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC9); // test r9, r9
            branch (BranchKind.JNE, l_loop);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD0); // mov rax, rdx
            ret ();
            bind (l_loop);
            code.u8 (0x4A); code.u8 (0x8D); code.u8 (0x04); code.u8 (0x0A); // lea rax, [rdx+r9]
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC0); // cmp rax, r8
            branch (BranchKind.JG, l_not_found);
            code.u8 (0x31); code.u8 (0xC9); // xor ecx, ecx
            bind (l_inner);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC9); // cmp rcx, r9
            branch (BranchKind.JGE, l_found);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x04); code.u8 (0x0A); // lea rax, [rdx+rcx]
            code.u8 (0x44); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x54); code.u8 (0x07); code.u8 (0x10); // movzx r10d, [rdi+rax+16]
            code.u8 (0x44); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x5C); code.u8 (0x0E); code.u8 (0x10); // movzx r11d, [rsi+rcx+16]
            code.u8 (0x45); code.u8 (0x39); code.u8 (0xDA); // cmp r10d, r11d
            branch (BranchKind.JNE, l_next);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_inner);
            bind (l_next);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC2); // inc rdx
            branch (BranchKind.JMP, l_loop);
            bind (l_found);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD0); // mov rax, rdx
            ret ();
            bind (l_not_found);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC0); code.u32le (0xFFFFFFFFu); // mov rax, -1
            ret ();
        }

        // int64 __planc_str_last_index_of(string* rdi, string* rsi, int64 rdx_min_start)
        public void emit_rt_str_last_index_of () {
            var l_ok_start = new_label ();
            var l_loop = new_label ();
            var l_inner = new_label ();
            var l_next = new_label ();
            var l_found = new_label ();
            var l_not_found = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_not_found);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6); // test rsi, rsi
            branch (BranchKind.JE, l_not_found);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08); // mov r8, [rdi+8]
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x4E); code.u8 (0x08); // mov r9, [rsi+8]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2); // test rdx, rdx
            branch (BranchKind.JNS, l_ok_start);
            code.u8 (0x31); code.u8 (0xD2); // xor edx, edx
            bind (l_ok_start);
            // if r9 > r8 -> -1
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xC1); // cmp r9, r8
            branch (BranchKind.JG, l_not_found);
            // r11 = r8 - r9 (max start pos)
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0xC3); // mov r11, r8
            code.u8 (0x4D); code.u8 (0x29); code.u8 (0xCB); // sub r11, r9
            // if r9 == 0: if r8 >= rdx return r8 else -1
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC9); // test r9, r9
            branch (BranchKind.JNE, l_loop);
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xD0); // cmp r8, rdx
            branch (BranchKind.JL, l_not_found);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC0); // mov rax, r8
            ret ();
            bind (l_loop);
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xD3); // cmp r11, rdx
            branch (BranchKind.JL, l_not_found);
            code.u8 (0x31); code.u8 (0xC9); // xor ecx, ecx
            bind (l_inner);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC9); // cmp rcx, r9
            branch (BranchKind.JGE, l_found);
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x04); code.u8 (0x0B); // lea rax, [r11+rcx]
            code.u8 (0x44); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x54); code.u8 (0x07); code.u8 (0x10); // movzx r10d, [rdi+rax+16]
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x0E); code.u8 (0x10); // movzx eax, [rsi+rcx+16]
            code.u8 (0x41); code.u8 (0x39); code.u8 (0xC2); // cmp r10d, eax
            branch (BranchKind.JNE, l_next);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_inner);
            bind (l_next);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xCB); // dec r11
            branch (BranchKind.JMP, l_loop);
            bind (l_found);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xD8); // mov rax, r11
            ret ();
            bind (l_not_found);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC0); code.u32le (0xFFFFFFFFu); // mov rax, -1
            ret ();
        }

        // Encodes `rsi` (0x80..0x10FFFF) as a stack-allocated string and forwards
        // `(rdi, needle_on_stack, rdx)` to `target_fn` (`__planc_str_[last_]index_of`).
        private void emit_rt_char_utf8_fallback (string target_fn) {
            var l_3or4 = new_label ();
            var l_4bytes = new_label ();
            var l_call = new_label ();
            var l_invalid = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            sub_rsp (32);
            // mov qword ptr [rsp], 0; mov qword ptr [rsp+16], 0
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x04); code.u8 (0x24); code.u32le (0u);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x10); code.u32le (0u);
            // cmp rsi, 0x7FF; ja l_3or4 (unsigned handles negative too)
            code.u8 (0x48); code.u8 (0x81); code.u8 (0xFE); code.u32le (0x7FFu);
            branch (BranchKind.JA, l_3or4);
            // 2-byte UTF-8
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x08); code.u32le (2u);
            code.u8 (0x89); code.u8 (0xF0); // mov eax, esi
            code.u8 (0xC1); code.u8 (0xE8); code.u8 (6); // shr eax, 6
            code.u8 (0x0D); code.u32le (0xC0u); // or eax, 0xC0
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x10); // mov [rsp+16], al
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x3F); // and eax, 0x3F
            code.u8 (0x0D); code.u32le (0x80u); // or eax, 0x80
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x11); // mov [rsp+17], al
            branch (BranchKind.JMP, l_call);

            bind (l_3or4);
            code.u8 (0x48); code.u8 (0x81); code.u8 (0xFE); code.u32le (0xFFFFu);
            branch (BranchKind.JA, l_4bytes);
            // 3-byte UTF-8
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x08); code.u32le (3u);
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0xC1); code.u8 (0xE8); code.u8 (12);
            code.u8 (0x0D); code.u32le (0xE0u);
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x10);
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0xC1); code.u8 (0xE8); code.u8 (6);
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x3F);
            code.u8 (0x0D); code.u32le (0x80u);
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x11);
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x3F);
            code.u8 (0x0D); code.u32le (0x80u);
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x12);
            branch (BranchKind.JMP, l_call);

            bind (l_4bytes);
            code.u8 (0x48); code.u8 (0x81); code.u8 (0xFE); code.u32le (0x10FFFFu);
            branch (BranchKind.JA, l_invalid);
            // 4-byte UTF-8
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x08); code.u32le (4u);
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0xC1); code.u8 (0xE8); code.u8 (18);
            code.u8 (0x0D); code.u32le (0xF0u);
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x10);
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0xC1); code.u8 (0xE8); code.u8 (12);
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x3F);
            code.u8 (0x0D); code.u32le (0x80u);
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x11);
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0xC1); code.u8 (0xE8); code.u8 (6);
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x3F);
            code.u8 (0x0D); code.u32le (0x80u);
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x12);
            code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0x83); code.u8 (0xE0); code.u8 (0x3F);
            code.u8 (0x0D); code.u32le (0x80u);
            code.u8 (0x88); code.u8 (0x44); code.u8 (0x24); code.u8 (0x13);

            bind (l_call);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xE6); // mov rsi, rsp
            call_rel32 (target_fn);
            leave ();
            ret ();

            bind (l_invalid);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC0); code.u32le (0xFFFFFFFFu); // mov rax, -1
            leave ();
            ret ();
        }

        // int64 __planc_str_index_of_char(string* rdi, int64 rsi_ch, int64 rdx_start)
        public void emit_rt_str_index_of_char () {
            var l_ok_start = new_label ();
            var l_loop = new_label ();
            var l_next = new_label ();
            var l_not_found = new_label ();
            var l_utf8 = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_not_found);
            // cmp rsi, 0x7F; ja l_utf8
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xFE); code.u8 (0x7F);
            branch (BranchKind.JA, l_utf8);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x08); // mov r8, [rdi+8]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2); // test rdx, rdx
            branch (BranchKind.JNS, l_ok_start);
            code.u8 (0x31); code.u8 (0xD2); // xor edx, edx
            bind (l_ok_start);
            code.u8 (0x40); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0xF6); // movzx esi, sil
            bind (l_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xC2); // cmp rdx, r8
            branch (BranchKind.JGE, l_not_found);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x17); code.u8 (0x10); // movzx eax, [rdi+rdx+16]
            code.u8 (0x39); code.u8 (0xF0); // cmp eax, esi
            branch (BranchKind.JNE, l_next);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD0); // mov rax, rdx
            ret ();
            bind (l_next);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC2); // inc rdx
            branch (BranchKind.JMP, l_loop);
            bind (l_not_found);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC0); code.u32le (0xFFFFFFFFu); // mov rax, -1
            ret ();
            bind (l_utf8);
            emit_rt_char_utf8_fallback ("__planc_str_index_of");
        }

        // int64 __planc_str_last_index_of_char(string* rdi, int64 rsi_ch, int64 rdx_min_start)
        public void emit_rt_str_last_index_of_char () {
            var l_ok_start = new_label ();
            var l_loop = new_label ();
            var l_next = new_label ();
            var l_not_found = new_label ();
            var l_utf8 = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_not_found);
            // cmp rsi, 0x7F; ja l_utf8
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xFE); code.u8 (0x7F);
            branch (BranchKind.JA, l_utf8);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4F); code.u8 (0x08); // mov rcx, [rdi+8]
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9); // dec rcx
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2); // test rdx, rdx
            branch (BranchKind.JNS, l_ok_start);
            code.u8 (0x31); code.u8 (0xD2); // xor edx, edx
            bind (l_ok_start);
            code.u8 (0x40); code.u8 (0x0F); code.u8 (0xB6); code.u8 (0xF6); // movzx esi, sil
            bind (l_loop);
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xD1); // cmp rcx, rdx
            branch (BranchKind.JL, l_not_found);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x44); code.u8 (0x0F); code.u8 (0x10); // movzx eax, [rdi+rcx+16]
            code.u8 (0x39); code.u8 (0xF0); // cmp eax, esi
            branch (BranchKind.JNE, l_next);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC8); // mov rax, rcx
            ret ();
            bind (l_next);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9); // dec rcx
            branch (BranchKind.JMP, l_loop);
            bind (l_not_found);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0xC0); code.u32le (0xFFFFFFFFu); // mov rax, -1
            ret ();
            bind (l_utf8);
            emit_rt_char_utf8_fallback ("__planc_str_last_index_of");
        }

        // int64 __planc_str_to_int(string* rdi)
        public void emit_rt_str_to_int () {
            var l_ws = new_label ();
            var l_ws_next = new_label ();
            var l_sign = new_label ();
            var l_plus = new_label ();
            var l_digits = new_label ();
            var l_done = new_label ();
            var l_zero = new_label ();

            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_zero);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4F); code.u8 (0x08); // mov rcx, [rdi + 8]
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10); // add rdi, 16
            bind (l_ws);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9); // test rcx, rcx
            branch (BranchKind.JLE, l_zero);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x07); // movzx eax, byte ptr [rdi]
            code.u8 (0x83); code.u8 (0xF8); code.u8 (32);   // cmp eax, ' '
            branch (BranchKind.JE, l_ws_next);
            code.u8 (0x83); code.u8 (0xF8); code.u8 (9);    // cmp eax, '\t'
            branch (BranchKind.JL, l_sign);
            code.u8 (0x83); code.u8 (0xF8); code.u8 (13);   // cmp eax, '\r'
            branch (BranchKind.JLE, l_ws_next);
            branch (BranchKind.JMP, l_sign);
            bind (l_ws_next);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC7); // inc rdi
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9); // dec rcx
            branch (BranchKind.JMP, l_ws);

            bind (l_sign);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0); // xor r8d, r8d
            code.u8 (0x80); code.u8 (0x3F); code.u8 (0x2D); // cmp byte ptr [rdi], '-'
            branch (BranchKind.JNE, l_plus);
            code.u8 (0x41); code.u8 (0xB8); code.u32le (1); // mov r8d, 1
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC7); // inc rdi
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9); // dec rcx
            xor_eax ();
            branch (BranchKind.JMP, l_digits);

            bind (l_plus);
            code.u8 (0x80); code.u8 (0x3F); code.u8 (0x2B); // cmp byte ptr [rdi], '+'
            code.u8 (0x75); code.u8 (0x06);                 // jne +6
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC7); // inc rdi
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9); // dec rcx
            xor_eax ();

            bind (l_digits);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9); // test rcx, rcx
            branch (BranchKind.JLE, l_done);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x17); // movzx edx, byte ptr [rdi]
            code.u8 (0x83); code.u8 (0xEA); code.u8 (48);   // sub edx, '0'
            code.u8 (0x83); code.u8 (0xFA); code.u8 (9);    // cmp edx, 9
            branch (BranchKind.JA, l_done);
            code.u8 (0x48); code.u8 (0x6B); code.u8 (0xC0); code.u8 (0x0A); // imul rax, rax, 10
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xD0); // add rax, rdx
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC7); // inc rdi
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9); // dec rcx
            branch (BranchKind.JMP, l_digits);

            bind (l_done);
            code.u8 (0x45); code.u8 (0x85); code.u8 (0xC0); // test r8d, r8d
            code.u8 (0x74); code.u8 (0x03);                 // je +3
            neg_rax ();
            ret ();

            bind (l_zero);
            xor_eax ();
            ret ();
        }

        // string* __planc_bytes_to_str(uint8[]* rdi, int64 rsi_len)
        public void emit_rt_bytes_to_str () {
            var l_alloc = new_label ();
            var l_done = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13 (16-byte aligned)

            // mov r12, rdi; mov r13, rsi
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFC);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF5);
            // test r12, r12; jz zero_len
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xE4);
            code.u8 (0x74); code.u8 (0x12);
            // test r13, r13; js zero_len
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xED);
            code.u8 (0x78); code.u8 (0x0D);
            // clamp r13 to [r12 + 8]
            code.u8 (0x49); code.u8 (0x8B); code.u8 (0x44); code.u8 (0x24); code.u8 (0x08); // mov rax, [r12 + 8]
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xC5); // cmp r13, rax
            branch (BranchKind.JBE, l_alloc);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC5); // mov r13, rax
            branch (BranchKind.JMP, l_alloc);
            // zero_len: xor r13d, r13d
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xED);

            bind (l_alloc);
            // lea rdi, [r13 + 1]; xor esi, esi; call __planc_alloc
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x7D); code.u8 (0x01);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            // [rax + 8] = r13
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x68); code.u8 (0x08);
            // lea rdi, [rax + 16]
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x78); code.u8 (0x10);
            // test r13, r13; je l_done
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xED);
            branch (BranchKind.JE, l_done);
            // lea rsi, [r12 + 16]; mov rcx, r13; rep movsb
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x74); code.u8 (0x24); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE9);
            code.u8 (0xF3); code.u8 (0xA4);

            bind (l_done);
            // mov byte ptr [rdi], 0
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00);
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            leave ();
            ret ();
        }

        // string* __planc_bytes_cast_str(uint8[]* rdi)
        // Scans up to the first NUL byte or array length, then calls __planc_bytes_to_str.
        public void emit_rt_bytes_cast_str () {
            var l_loop = new_label ();
            var l_call = new_label ();
            // xor esi, esi
            code.u8 (0x31); code.u8 (0xF6);
            // test rdi, rdi; je l_call
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_call);
            // mov rcx, [rdi + 8]
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4F); code.u8 (0x08);
            bind (l_loop);
            // cmp rsi, rcx; jae l_call
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xCE);
            branch (BranchKind.JAE, l_call);
            // cmp byte ptr [rdi + rsi + 16], 0; je l_call
            code.u8 (0x80); code.u8 (0x7C); code.u8 (0x37); code.u8 (0x10); code.u8 (0x00);
            branch (BranchKind.JE, l_call);
            // inc rsi; jmp l_loop
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6);
            branch (BranchKind.JMP, l_loop);
            bind (l_call);
            push_rbp ();
            mov_rsp_to_rbp ();
            call_rel32 ("__planc_bytes_to_str");
            leave ();
            ret ();
        }

        // void __planc_eprint(string* rdi)
        public void emit_rt_eprint () {
            var l_done = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_done);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x57); code.u8 (0x08); // mov rdx, [rdi + 8]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2); // test rdx, rdx
            branch (BranchKind.JLE, l_done);
            if (target_windows) {
                push_rbp ();
                mov_rsp_to_rbp ();
                push_reg (Reg.RBX);
                sub_rsp (56); // 16-byte aligned
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB); // mov rbx, rdi
                code.u8 (0xB9); code.u32le (0xFFFFFFF4u); // mov ecx, STD_ERROR_HANDLE (-12)
                emit_iat_call (Pe.IAT_GET_STD_HANDLE);
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xC1); // mov rcx, rax
                code.u8 (0x48); code.u8 (0x8D); code.u8 (0x53); code.u8 (0x10); // lea rdx, [rbx + 16]
                code.u8 (0x44); code.u8 (0x8B); code.u8 (0x43); code.u8 (0x08); // mov r8d, [rbx + 8]
                code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x4C); code.u8 (0x24); code.u8 (0x28); // lea r9, [rsp + 40]
                code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x20); code.u32le (0); // mov qword [rsp+32], 0
                emit_iat_call (Pe.IAT_WRITE_FILE);
                add_rsp (56);
                pop_reg (Reg.RBX);
                leave ();
                ret ();
                bind (l_done);
                ret ();
                return;
            }
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x77); code.u8 (0x10); // lea rsi, [rdi + 16]
            mov_edi (2);
            mov_eax (1);
            syscall ();
            bind (l_done);
            ret ();
        }

        // void __planc_chmod(string* rdi_path, int64 rsi_mode)
        public void emit_rt_chmod () {
            if (target_windows) {
                ret ();
                return;
            }
            var l_done = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_done);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10); // add rdi, 16
            mov_eax (90);
            syscall ();
            bind (l_done);
            ret ();
        }

        // (string* rax, Error* rdx) __planc_read_file(string* rdi_path)
        public void emit_rt_read_file (int err_msg_off, int domain_id) {
            if (target_windows) {
                emit_rt_read_file_win32 (err_msg_off, domain_id);
                return;
            }
            var l_rd_loop = new_label ();
            var l_rd_done = new_label ();
            var l_err_free = new_label ();
            var l_err_close = new_label ();
            var l_err = new_label ();
            var l_ret = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            code.u8 (0x41); code.u8 (0x57); // push r15
            sub_rsp (8); // 16-byte aligned

            code.u8 (0x49); code.u8 (0xC7); code.u8 (0xC4); code.u32le (0xFFFFFFFFu); // mov r12, -1
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_err);

            // open(path + 16, O_RDONLY=0, 0)
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10);
            code.u8 (0x31); code.u8 (0xF6);
            code.u8 (0x31); code.u8 (0xD2);
            mov_eax (2);
            syscall ();
            test_rax_rax ();
            branch (BranchKind.JS, l_err);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4); // mov r12, rax (fd)

            // size = lseek(fd, 0, SEEK_END=2)
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7); // mov rdi, r12
            code.u8 (0x31); code.u8 (0xF6);
            mov_edx (2);
            mov_eax (8);
            syscall ();
            test_rax_rax ();
            branch (BranchKind.JS, l_err_close);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC5); // mov r13, rax (size)

            // lseek(fd, 0, SEEK_SET=0)
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
            code.u8 (0x31); code.u8 (0xF6);
            code.u8 (0x31); code.u8 (0xD2);
            mov_eax (8);
            syscall ();
            test_rax_rax ();
            branch (BranchKind.JS, l_err_close);

            // str = __planc_alloc(size + 1, 0)
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x7D); code.u8 (0x01); // lea rdi, [r13 + 1]
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC6); // mov r14, rax
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0x6E); code.u8 (0x08); // mov [r14 + 8], r13
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x46); code.u8 (0x10); code.u8 (0x00); // mov byte ptr [r14 + 16], 0

            code.u8 (0x31); code.u8 (0xDB); // xor ebx, ebx
            bind (l_rd_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xEB); // cmp rbx, r13
            branch (BranchKind.JAE, l_rd_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7); // mov rdi, r12
            // lea rsi, [r14 + rbx + 16] -> 49 8D 74 1E 10
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x74); code.u8 (0x1E); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEA); // mov rdx, r13
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xDA); // sub rdx, rbx
            xor_eax ();
            syscall ();
            // cmp rax, -4 (EINTR)
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xF8); code.u8 (0xFC);
            branch (BranchKind.JE, l_rd_loop);
            test_rax_rax ();
            branch (BranchKind.JS, l_err_free);
            branch (BranchKind.JE, l_rd_done);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xC3); // add rbx, rax
            branch (BranchKind.JMP, l_rd_loop);

            bind (l_rd_done);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0x5E); code.u8 (0x08); // mov [r14 + 8], rbx
            // lea rdi, [r14 + rbx + 16]; mov byte ptr [rdi], 0
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x7C); code.u8 (0x1E); code.u8 (0x10);
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00);
            // close(fd)
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
            mov_eax (3);
            syscall ();
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF0); // mov rax, r14
            xor_edx ();
            branch (BranchKind.JMP, l_ret);

            bind (l_err_free);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7); // mov rdi, r14
            call_rel32 ("__planc_unref");

            bind (l_err_close);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7); // mov rdi, r12
            mov_eax (3);
            syscall ();

            bind (l_err);
            mov_rdi_imm (24);
            mov_esi_imm (1);
            call_rel32 ("__planc_alloc");
            mov_rcx_rax ();
            mov_rax_imm (1);
            store_rcx_disp_rax (8);
            lea_rax_rip (err_msg_off);
            store_rcx_disp_rax (16);
            mov_rax_imm ((int64) domain_id);
            store_rcx_disp_rax (24);
            mov_rax_imm (1);
            store_rcx_disp_rax (32);
            mov_rdx_rcx_copy ();
            xor_eax ();

            bind (l_ret);
            add_rsp (8);
            code.u8 (0x41); code.u8 (0x5F); // pop r15
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        // mov rdx, rcx                       48 89 CA
        private void mov_rdx_rcx_copy () {
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xCA);
        }

        // (int64 rax, Error* rdx) __planc_write_file(string* rdi_path, uint8[]* rsi_data)
        public void emit_rt_write_file (int err_msg_off, int domain_id) {
            if (target_windows) {
                emit_rt_write_file_win32 (err_msg_off, domain_id);
                return;
            }
            var l_wr_loop = new_label ();
            var l_wr_done = new_label ();
            var l_err_close = new_label ();
            var l_err = new_label ();
            var l_ret = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            code.u8 (0x41); code.u8 (0x57); // push r15
            sub_rsp (8); // 16-byte aligned

            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_err);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6); // test rsi, rsi
            branch (BranchKind.JE, l_err);

            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF6); // mov r14, rsi
            code.u8 (0x4D); code.u8 (0x8B); code.u8 (0x6E); code.u8 (0x08); // mov r13, [r14 + 8]
            code.u8 (0x31); code.u8 (0xDB); // xor ebx, ebx

            // open(path + 16, O_WRONLY|O_CREAT|O_TRUNC = 0x241, 0644 = 420)
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xC7); code.u8 (0x10);
            mov_esi_imm (0x241);
            mov_edx (420);
            mov_eax (2);
            syscall ();
            test_rax_rax ();
            branch (BranchKind.JS, l_err);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4); // mov r12, rax

            bind (l_wr_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xEB); // cmp rbx, r13
            branch (BranchKind.JAE, l_wr_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7); // mov rdi, r12
            // lea rsi, [r14 + rbx + 16]
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x74); code.u8 (0x1E); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEA); // mov rdx, r13
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xDA); // sub rdx, rbx
            mov_eax (1);
            syscall ();
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xF8); code.u8 (0xFC); // cmp rax, -4
            branch (BranchKind.JE, l_wr_loop);
            test_rax_rax ();
            branch (BranchKind.JLE, l_err_close);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xC3); // add rbx, rax
            branch (BranchKind.JMP, l_wr_loop);

            bind (l_wr_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7); // mov rdi, r12
            mov_eax (3);
            syscall ();
            xor_eax ();
            xor_edx ();
            branch (BranchKind.JMP, l_ret);

            bind (l_err_close);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
            mov_eax (3);
            syscall ();

            bind (l_err);
            mov_rdi_imm (24);
            mov_esi_imm (1);
            call_rel32 ("__planc_alloc");
            mov_rcx_rax ();
            mov_rax_imm (1);
            store_rcx_disp_rax (8);
            lea_rax_rip (err_msg_off);
            store_rcx_disp_rax (16);
            mov_rax_imm ((int64) domain_id);
            store_rcx_disp_rax (24);
            mov_rax_imm (1);
            store_rcx_disp_rax (32);
            mov_rdx_rcx_copy ();
            xor_eax ();

            bind (l_ret);
            add_rsp (8);
            code.u8 (0x41); code.u8 (0x5F); // pop r15
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        private void emit_rt_read_file_win32 (int err_msg_off, int domain_id) {
            var l_rd_loop = new_label ();
            var l_rd_done = new_label ();
            var l_err_free = new_label ();
            var l_err_close = new_label ();
            var l_err = new_label ();
            var l_ret = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            code.u8 (0x41); code.u8 (0x57); // push r15
            sub_rsp (72);

            code.u8 (0x49); code.u8 (0xC7); code.u8 (0xC4); code.u32le (0xFFFFFFFFu); // mov r12, -1
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_err);

            // CreateFileA(rdi + 16, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x4F); code.u8 (0x10); // lea rcx, [rdi + 16]
            code.u8 (0xBA); code.u32le (0x80000000u); // mov edx, GENERIC_READ
            code.u8 (0x41); code.u8 (0xB8); code.u32le (1); // mov r8d, FILE_SHARE_READ
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC9); // xor r9d, r9d
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x20); code.u32le (3); // [rsp+32] = OPEN_EXISTING
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x28); code.u32le (0x80); // [rsp+40] = FILE_ATTRIBUTE_NORMAL
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x30); code.u32le (0); // [rsp+48] = NULL
            emit_iat_call (Pe.IAT_CREATE_FILE_A);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xF8); code.u8 (0xFF); // cmp rax, -1
            branch (BranchKind.JE, l_err);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4); // mov r12, rax

            // GetFileSizeEx(r12, &rsp[56])
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE1); // mov rcx, r12
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x54); code.u8 (0x24); code.u8 (0x38); // lea rdx, [rsp + 56]
            emit_iat_call (Pe.IAT_GET_FILE_SIZE_EX);
            code.u8 (0x85); code.u8 (0xC0); // test eax, eax
            branch (BranchKind.JE, l_err_close);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x6C); code.u8 (0x24); code.u8 (0x38); // mov r13, [rsp + 56]

            // str = __planc_alloc(r13 + 1, 0)
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x7D); code.u8 (0x01); // lea rdi, [r13 + 1]
            code.u8 (0x31); code.u8 (0xF6); // xor esi, esi
            call_rel32 ("__planc_alloc");
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC6); // mov r14, rax
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0x6E); code.u8 (0x08); // mov [r14 + 8], r13
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x46); code.u8 (0x10); code.u8 (0x00); // mov byte [r14 + 16], 0

            code.u8 (0x31); code.u8 (0xDB); // xor ebx, ebx
            bind (l_rd_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xEB); // cmp rbx, r13
            branch (BranchKind.JAE, l_rd_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE9); // mov rcx, r13
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xD9); // sub rcx, rbx
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC8); // mov r8, rcx
            // clamp r8 to 0x40000000
            code.u8 (0x49); code.u8 (0x81); code.u8 (0xF8); code.u32le (0x40000000u);
            var l_no_clamp = new_label ();
            branch (BranchKind.JBE, l_no_clamp);
            code.u8 (0x41); code.u8 (0xB8); code.u32le (0x40000000u);
            bind (l_no_clamp);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE1); // mov rcx, r12
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x54); code.u8 (0x1E); code.u8 (0x10); // lea rdx, [r14 + rbx + 16]
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x4C); code.u8 (0x24); code.u8 (0x38); // lea r9, [rsp + 56]
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x20); code.u32le (0); // [rsp+32] = NULL
            emit_iat_call (Pe.IAT_READ_FILE);
            code.u8 (0x85); code.u8 (0xC0); // test eax, eax
            branch (BranchKind.JE, l_err_free);
            code.u8 (0x8B); code.u8 (0x44); code.u8 (0x24); code.u8 (0x38); // mov eax, [rsp + 56]
            code.u8 (0x85); code.u8 (0xC0); // test eax, eax
            branch (BranchKind.JE, l_rd_done);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xC3); // add rbx, rax
            branch (BranchKind.JMP, l_rd_loop);

            bind (l_rd_done);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0x5E); code.u8 (0x08); // mov [r14 + 8], rbx
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x7C); code.u8 (0x1E); code.u8 (0x10); // lea rdi, [r14 + rbx + 16]
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00); // mov byte [rdi], 0
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE1); // mov rcx, r12
            emit_iat_call (Pe.IAT_CLOSE_HANDLE);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF0); // mov rax, r14
            xor_edx ();
            branch (BranchKind.JMP, l_ret);

            bind (l_err_free);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7); // mov rdi, r14
            call_rel32 ("__planc_unref");

            bind (l_err_close);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE1); // mov rcx, r12
            emit_iat_call (Pe.IAT_CLOSE_HANDLE);

            bind (l_err);
            mov_rdi_imm (24);
            mov_esi_imm (1);
            call_rel32 ("__planc_alloc");
            mov_rcx_rax ();
            mov_rax_imm (1);
            store_rcx_disp_rax (8);
            lea_rax_rip (err_msg_off);
            store_rcx_disp_rax (16);
            mov_rax_imm ((int64) domain_id);
            store_rcx_disp_rax (24);
            mov_rax_imm (1);
            store_rcx_disp_rax (32);
            mov_rdx_rcx_copy ();
            xor_eax ();

            bind (l_ret);
            add_rsp (72);
            code.u8 (0x41); code.u8 (0x5F); // pop r15
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        private void emit_rt_write_file_win32 (int err_msg_off, int domain_id) {
            var l_wr_loop = new_label ();
            var l_wr_done = new_label ();
            var l_err_close = new_label ();
            var l_err = new_label ();
            var l_ret = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            code.u8 (0x41); code.u8 (0x57); // push r15
            sub_rsp (72);

            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
            branch (BranchKind.JE, l_err);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xF6); // test rsi, rsi
            branch (BranchKind.JE, l_err);

            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF6); // mov r14, rsi
            code.u8 (0x4D); code.u8 (0x8B); code.u8 (0x6E); code.u8 (0x08); // mov r13, [r14 + 8]
            code.u8 (0x31); code.u8 (0xDB); // xor ebx, ebx

            // CreateFileA(rdi + 16, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL)
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x4F); code.u8 (0x10); // lea rcx, [rdi + 16]
            code.u8 (0xBA); code.u32le (0x40000000u); // mov edx, GENERIC_WRITE
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0); // xor r8d, r8d
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC9); // xor r9d, r9d
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x20); code.u32le (2); // [rsp+32] = CREATE_ALWAYS
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x28); code.u32le (0x80); // [rsp+40] = FILE_ATTRIBUTE_NORMAL
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x30); code.u32le (0); // [rsp+48] = NULL
            emit_iat_call (Pe.IAT_CREATE_FILE_A);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xF8); code.u8 (0xFF); // cmp rax, -1
            branch (BranchKind.JE, l_err);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC4); // mov r12, rax

            bind (l_wr_loop);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0xEB); // cmp rbx, r13
            branch (BranchKind.JAE, l_wr_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE9); // mov rcx, r13
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xD9); // sub rcx, rbx
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC8); // mov r8, rcx
            code.u8 (0x49); code.u8 (0x81); code.u8 (0xF8); code.u32le (0x40000000u);
            var l_no_clamp = new_label ();
            branch (BranchKind.JBE, l_no_clamp);
            code.u8 (0x41); code.u8 (0xB8); code.u32le (0x40000000u);
            bind (l_no_clamp);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE1); // mov rcx, r12
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0x54); code.u8 (0x1E); code.u8 (0x10); // lea rdx, [r14 + rbx + 16]
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x4C); code.u8 (0x24); code.u8 (0x38); // lea r9, [rsp + 56]
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x20); code.u32le (0); // [rsp+32] = NULL
            emit_iat_call (Pe.IAT_WRITE_FILE);
            code.u8 (0x85); code.u8 (0xC0); // test eax, eax
            branch (BranchKind.JE, l_err_close);
            code.u8 (0x8B); code.u8 (0x44); code.u8 (0x24); code.u8 (0x38); // mov eax, [rsp + 56]
            code.u8 (0x85); code.u8 (0xC0); // test eax, eax
            branch (BranchKind.JE, l_err_close);
            code.u8 (0x48); code.u8 (0x01); code.u8 (0xC3); // add rbx, rax
            branch (BranchKind.JMP, l_wr_loop);

            bind (l_wr_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE1); // mov rcx, r12
            emit_iat_call (Pe.IAT_CLOSE_HANDLE);
            xor_eax ();
            xor_edx ();
            branch (BranchKind.JMP, l_ret);

            bind (l_err_close);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE1); // mov rcx, r12
            emit_iat_call (Pe.IAT_CLOSE_HANDLE);

            bind (l_err);
            mov_rdi_imm (24);
            mov_esi_imm (1);
            call_rel32 ("__planc_alloc");
            mov_rcx_rax ();
            mov_rax_imm (1);
            store_rcx_disp_rax (8);
            lea_rax_rip (err_msg_off);
            store_rcx_disp_rax (16);
            mov_rax_imm ((int64) domain_id);
            store_rcx_disp_rax (24);
            mov_rax_imm (1);
            store_rcx_disp_rax (32);
            mov_rdx_rcx_copy ();
            xor_eax ();

            bind (l_ret);
            add_rsp (72);
            code.u8 (0x41); code.u8 (0x5F); // pop r15
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        // Reads ap[ap[0]++] where rdi/rax holds ap (uint64[] payload at +16).
        public void emit_va_arg () {
            mov_rcx_rax ();
            load_rcx_disp_to_rax (16);
            // lea rdx, [rax + 1]             48 8D 50 01
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x50); code.u8 (0x01);
            // mov [rcx + 16], rdx            48 89 51 10
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x51); code.u8 (0x10);
            // mov rax, [rcx + rax*8 + 16]    48 8B 44 C1 10
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x44); code.u8 (0xC1); code.u8 (0x10);
        }

        // int __planc_cpu_count()
        public void emit_rt_cpu_count () {
            if (target_windows) {
                // Keep Windows host compilation single-threaded and deterministic.
                mov_eax (1);
                ret ();
                return;
            }
            var l_byte_loop = new_label ();
            var l_bit_loop = new_label ();
            var l_next_byte = new_label ();
            var l_set_one = new_label ();
            var l_done = new_label ();
            var l_ret = new_label ();

            sub_rsp (136);
            zero_edi ();
            mov_esi_imm (128);
            // mov rdx, rsp                    48 89 E2
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xE2);
            mov_eax (204); // SYS_sched_getaffinity
            syscall ();
            test_rax_rax ();
            branch (BranchKind.JLE, l_set_one);

            // xor r8d, r8d; xor ecx, ecx
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
            code.u8 (0x31); code.u8 (0xC9);
            bind (l_byte_loop);
            // cmp rcx, rax                    48 39 C1
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xC1);
            branch (BranchKind.JGE, l_done);
            // movzx edx, byte ptr [rsp + rcx] 0F B6 14 0C
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x14); code.u8 (0x0C);
            // test edx, edx                   85 D2
            code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JE, l_next_byte);
            bind (l_bit_loop);
            // shr edx, 1                      D1 EA
            code.u8 (0xD1); code.u8 (0xEA);
            // adc r8d, 0                      41 83 D0 00
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xD0); code.u8 (0x00);
            // test edx, edx                   85 D2
            code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JNE, l_bit_loop);
            bind (l_next_byte);
            // inc rcx                         48 FF C1
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1);
            branch (BranchKind.JMP, l_byte_loop);

            bind (l_done);
            // mov eax, r8d                    44 89 C0
            code.u8 (0x44); code.u8 (0x89); code.u8 (0xC0);
            // test eax, eax                   85 C0
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JG, l_ret);

            bind (l_set_one);
            mov_eax (1);

            bind (l_ret);
            add_rsp (136);
            ret ();
        }

        // int64 __planc_thread_spawn(delegate_ptr rdi, int64 arg rsi)
        public void emit_rt_thread_spawn (bool target_planetos = false) {
            if (target_windows) {
                var l_ret_zero = new_label ();
                var l_tramp = new_label ();
                var l_spawn = new_label ();

                push_rbp ();
                mov_rsp_to_rbp ();
                push_reg (Reg.RBX);
                code.u8 (0x41); code.u8 (0x54); // push r12
                code.u8 (0x41); code.u8 (0x55); // push r13
                sub_rsp (56); // 16-byte aligned + 32 shadow + 16 args

                code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
                branch (BranchKind.JE, l_ret_zero);
                code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x27); // mov r12, [rdi] (fn_addr)
                code.u8 (0x49); code.u8 (0x89); code.u8 (0xF5); // mov r13, rsi (arg)

                mov_rdi_imm (16);
                mov_esi_imm (1);
                call_rel32 ("__planc_alloc");
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0x60); code.u8 (0x10); // mov [rax + 16], r12
                code.u8 (0x4C); code.u8 (0x89); code.u8 (0x68); code.u8 (0x18); // mov [rax + 24], r13
                code.u8 (0x49); code.u8 (0x89); code.u8 (0xC1); // mov r9, rax (lpParameter)
                code.u8 (0x31); code.u8 (0xC9);                 // xor ecx, ecx (lpThreadAttributes = NULL)
                code.u8 (0x31); code.u8 (0xD2);                 // xor edx, edx (dwStackSize = 0)
                // lea r8, [rip + l_tramp]
                code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x05);
                var p_tramp = new BranchPatch ();
                p_tramp.kind = BranchKind.JMP;
                p_tramp.label = l_tramp;
                p_tramp.displacement = code.length;
                branches.add (p_tramp);
                code.u32le (0);
                code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x20); code.u32le (0); // [rsp+32] = 0
                code.u8 (0x48); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x28); code.u32le (0); // [rsp+40] = NULL
                emit_iat_call (Pe.IAT_CREATE_THREAD);
                branch (BranchKind.JMP, l_spawn);

                bind (l_ret_zero);
                xor_eax ();

                bind (l_spawn);
                add_rsp (56);
                code.u8 (0x41); code.u8 (0x5D); // pop r13
                code.u8 (0x41); code.u8 (0x5C); // pop r12
                pop_reg (Reg.RBX);
                leave ();
                ret ();

                // Win64 LPTHREAD_START_ROUTINE trampoline: rcx = block*
                bind (l_tramp);
                push_rbp ();
                mov_rsp_to_rbp ();
                push_reg (Reg.RBX);
                sub_rsp (40); // 16-byte aligned
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xCB); // mov rbx, rcx
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x7B); code.u8 (0x18); // mov rdi, [rbx + 24] (arg)
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x43); code.u8 (0x10); // mov rax, [rbx + 16] (fn)
                code.u8 (0xFF); code.u8 (0xD0); // call rax
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF); // mov rdi, rbx
                call_rel32 ("__planc_unref");
                xor_eax ();
                add_rsp (40);
                pop_reg (Reg.RBX);
                leave ();
                ret ();
                return;
            }
            if (target_planetos) {
                // A PlanetOS thread is a kernel task: SYS_THREAD_SPAWN(entry in
                // rdi, arg in rsi) returns the tid. The entry runs in the same
                // address space, so it must exit instead of returning.
                var l_ret = new_label ();
                push_rbp ();
                mov_rsp_to_rbp ();
                // test rdi, rdi; je l_ret
                code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
                branch (BranchKind.JE, l_ret);
                // mov rax, [rdi]; mov rdi, rax
                code.u8 (0x48); code.u8 (0x8B); code.u8 (0x07);
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7);
                mov_eax (27);
                code.u8 (0xCD); code.u8 (0x80);
                leave ();
                ret ();
                bind (l_ret);
                xor_eax ();
                leave ();
                ret ();
                return;
            }
            var l_err = new_label ();
            var l_err_unmap = new_label ();
            var l_child = new_label ();
            var l_done = new_label ();

            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14

            // r12 = fn_ptr [rdi + 0], r13 = env_ptr [rdi + 8], r14 = arg rsi
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x27);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x6F); code.u8 (0x08);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF6);

            mov_esi_imm (0x100000);
            emit_mmap_anon_rw ();
            test_rax_rax ();
            branch (BranchKind.JS, l_err);

            // rbx = stack_base
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC3);
            // lea r10, [rbx + 0x100000 - 16]  4C 8D 93 F0 FF 0F 00
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x93); code.u32le (0xFFFF0u);
            // mov dword ptr [r10], 1          41 C7 02 01 00 00 00
            code.u8 (0x41); code.u8 (0xC7); code.u8 (0x02); code.u32le (1);
            // mov [r10 + 8], rbx              49 89 5A 08
            code.u8 (0x49); code.u8 (0x89); code.u8 (0x5A); code.u8 (0x08);
            // lea rsi, [rbx + 0x100000 - 40]  48 8D B3 D8 FF 0F 00
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0xB3); code.u32le (0xFFFD8u);
            // mov [rsi + 0], r12; mov [rsi + 8], r13; mov [rsi + 16], r14
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x26);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x6E); code.u8 (0x08);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x76); code.u8 (0x10);

            // mov edi, 0x01210F00 (CLONE_VM|FS|FILES|SIGHAND|THREAD|CHILD_CLEARTID|CHILD_SETTID)
            code.u8 (0xBF); code.u32le (0x01210F00u);
            // xor edx, edx; xor r8d, r8d; mov eax, 56 (SYS_clone); syscall
            code.u8 (0x31); code.u8 (0xD2);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
            mov_eax (56);
            syscall ();
            test_rax_rax ();
            branch (BranchKind.JE, l_child);
            branch (BranchKind.JS, l_err_unmap);

            // Parent: return ctrl (r10)
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xD0);
            branch (BranchKind.JMP, l_done);

            bind (l_err_unmap);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF); // mov rdi, rbx
            mov_esi_imm (0x100000);
            mov_eax (11);
            syscall ();

            bind (l_err);
            xor_eax ();

            bind (l_done);
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();

            bind (l_child);
            code.u8 (0x59); // pop rcx (fn_ptr)
            code.u8 (0x5F); // pop rdi (env_ptr)
            code.u8 (0x5E); // pop rsi (arg)
            code.u8 (0xFF); code.u8 (0xD1); // call rcx
            zero_edi ();
            mov_eax (60); // SYS_exit
            syscall ();
        }

        // void __planc_thread_join(int64 ctrl rdi)
        public void emit_rt_thread_join (bool target_planetos = false) {
            if (target_windows) {
                var l_done = new_label ();
                code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF); // test rdi, rdi
                branch (BranchKind.JE, l_done);
                push_reg (Reg.RBX);
                sub_rsp (32); // 16-byte aligned (push rbx = 8 + 8 ret = 16, +32 = 48)
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB); // mov rbx, rdi
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xF9); // mov rcx, rdi
                code.u8 (0xBA); code.u32le (0xFFFFFFFFu); // mov edx, INFINITE
                emit_iat_call (Pe.IAT_WAIT_FOR_SINGLE_OBJECT);
                code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9); // mov rcx, rbx
                emit_iat_call (Pe.IAT_CLOSE_HANDLE);
                add_rsp (32);
                pop_reg (Reg.RBX);
                bind (l_done);
                ret ();
                return;
            }
            if (target_planetos) {
                // The spawn result is the tid: SYS_WAIT(tid).
                mov_eax (17);
                code.u8 (0xCD); code.u8 (0x80);
                ret ();
                return;
            }
            var l_wait = new_label ();
            var l_unmap = new_label ();
            var l_ret = new_label ();

            // test rdi, rdi; je l_ret
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_ret);
            push_reg (Reg.RBX);
            // mov rbx, rdi
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);

            bind (l_wait);
            // mov edx, [rbx]; test edx, edx; je l_unmap
            code.u8 (0x8B); code.u8 (0x13);
            code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JE, l_unmap);
            // mov rdi, rbx; xor esi, esi; xor r10d, r10d; mov eax, 202 (SYS_futex); syscall
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            code.u8 (0x31); code.u8 (0xF6);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xD2);
            mov_eax (202);
            syscall ();
            branch (BranchKind.JMP, l_wait);

            bind (l_unmap);
            // mov rdi, [rbx + 8]; mov esi, 0x100000; mov eax, 11 (SYS_munmap); syscall
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x7B); code.u8 (0x08);
            mov_esi_imm (0x100000);
            mov_eax (11);
            syscall ();
            pop_reg (Reg.RBX);

            bind (l_ret);
            ret ();
        }

        // void __planc_spin_lock(int[] lock_arr rdi)
        public void emit_rt_spin_lock () {
            var l_loop = new_label ();
            var l_ret = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_ret);
            bind (l_loop);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x47); code.u8 (0x10); // xchg [rdi + 16], eax
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_ret);
            code.u8 (0xF3); code.u8 (0x90); // pause
            branch (BranchKind.JMP, l_loop);
            bind (l_ret);
            ret ();
        }

        // void __planc_spin_unlock(int[] lock_arr rdi)
        public void emit_rt_spin_unlock () {
            var l_ret = new_label ();
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_ret);
            code.u8 (0xC7); code.u8 (0x47); code.u8 (0x10); code.u32le (0); // mov dword ptr [rdi + 16], 0
            bind (l_ret);
            ret ();
        }

        // ------------------------------------------------------------------
        // x86-64-v3 / SSE2 scalar float & double encoders.
        // ------------------------------------------------------------------

        public void movq_xmm_rax (int xmm) {
            code.u8 (0x66); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x6E);
            code.u8 ((uint8) (0xC0 + (xmm & 7) * 8));
        }

        public void movq_rax_xmm (int xmm) {
            code.u8 (0x66); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x7E);
            code.u8 ((uint8) (0xC0 + (xmm & 7) * 8));
        }

        public void movq_xmm1_rcx () {
            code.u8 (0x66); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x6E); code.u8 (0xC9);
        }

        public void push_xmm0 () {
            sub_rsp (8);
            code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x11); code.u8 (0x04); code.u8 (0x24);
        }

        public void pop_xmm1 () {
            code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x10); code.u8 (0x0C); code.u8 (0x24);
            add_rsp (8);
        }

        public void pop_xmm0 () {
            code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x10); code.u8 (0x04); code.u8 (0x24);
            add_rsp (8);
        }

        public void movsd_mem_rax_xmm0 () {
            code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x11); code.u8 (0x00);
        }

        public void movsd_xmm0_mem_rax () {
            code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x10); code.u8 (0x00);
        }

        public void movss_mem_rax_xmm0 () {
            code.u8 (0xF3); code.u8 (0x0F); code.u8 (0x11); code.u8 (0x00);
        }

        public void movss_xmm0_mem_rax () {
            code.u8 (0xF3); code.u8 (0x0F); code.u8 (0x10); code.u8 (0x00);
        }

        public void addsd_xmm0_xmm1 () { code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x58); code.u8 (0xC1); }
        public void subsd_xmm0_xmm1 () { code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x5C); code.u8 (0xC1); }
        public void mulsd_xmm0_xmm1 () { code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x59); code.u8 (0xC1); }
        public void divsd_xmm0_xmm1 () { code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x5E); code.u8 (0xC1); }

        public void addss_xmm0_xmm1 () { code.u8 (0xF3); code.u8 (0x0F); code.u8 (0x58); code.u8 (0xC1); }
        public void subss_xmm0_xmm1 () { code.u8 (0xF3); code.u8 (0x0F); code.u8 (0x5C); code.u8 (0xC1); }
        public void mulss_xmm0_xmm1 () { code.u8 (0xF3); code.u8 (0x0F); code.u8 (0x59); code.u8 (0xC1); }
        public void divss_xmm0_xmm1 () { code.u8 (0xF3); code.u8 (0x0F); code.u8 (0x5E); code.u8 (0xC1); }

        public void pxor_xmm0_xmm1 ()  { code.u8 (0x66); code.u8 (0x0F); code.u8 (0xEF); code.u8 (0xC1); }

        public void ucomisd_xmm0_xmm0 () { code.u8 (0x66); code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC0); }
        public void ucomisd_xmm0_xmm1 () { code.u8 (0x66); code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC1); }
        public void ucomisd_xmm1_xmm0 () { code.u8 (0x66); code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC8); }
        public void ucomiss_xmm0_xmm0 () { code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC0); }
        public void ucomiss_xmm0_xmm1 () { code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC1); }
        public void ucomiss_xmm1_xmm0 () { code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC8); }

        public void setcc_cl (uint8 cc) { code.u8 (0x0F); code.u8 (cc); code.u8 (0xC1); }
        public void and_al_cl () { code.u8 (0x20); code.u8 (0xC8); }
        public void or_al_cl ()  { code.u8 (0x08); code.u8 (0xC8); }

        public void cvtsi2sd_xmm0_rax () { code.u8 (0xF2); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x2A); code.u8 (0xC0); }
        public void cvtsi2ss_xmm0_rax () { code.u8 (0xF3); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x2A); code.u8 (0xC0); }
        public void cvttsd2si_rax_xmm0 () { code.u8 (0xF2); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x2C); code.u8 (0xC0); }
        public void cvttss2si_rax_xmm0 () { code.u8 (0xF3); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x2C); code.u8 (0xC0); }
        public void cvtss2sd_xmm0_xmm0 () { code.u8 (0xF3); code.u8 (0x0F); code.u8 (0x5A); code.u8 (0xC0); }
        public void cvtsd2ss_xmm0_xmm0 () { code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x5A); code.u8 (0xC0); }

        // double __planc_str_to_double(string* rdi) -> xmm0
        public void emit_rt_str_to_double () {
            var l_skip_ws = new_label ();
            var l_ws_done = new_label ();
            var l_check_sign = new_label ();
            var l_int_loop = new_label ();
            var l_check_dot = new_label ();
            var l_frac_loop = new_label ();
            var l_check_exp = new_label ();
            var l_exp_loop = new_label ();
            var l_scale = new_label ();
            var l_mul10 = new_label ();
            var l_div10 = new_label ();
            var l_apply_sign = new_label ();
            var l_zero = new_label ();
            var l_ret = new_label ();

            // test rdi, rdi; je l_zero
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_zero);
            // rcx = [rdi + 8] (len), rsi = rdi + 16 (ptr), rdx = rsi + rcx (end)
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4F); code.u8 (0x08);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x77); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x14); code.u8 (0x0E);

            bind (l_skip_ws);
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xD6); // cmp rsi, rdx
            branch (BranchKind.JAE, l_zero);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06); // movzx eax, byte [rsi]
            code.u8 (0x3C); code.u8 (0x20); // ' '
            branch (BranchKind.JE, l_ws_done);
            code.u8 (0x3C); code.u8 (0x09); // '\t'
            branch (BranchKind.JE, l_ws_done);
            code.u8 (0x3C); code.u8 (0x0A); // '\n'
            branch (BranchKind.JE, l_ws_done);
            code.u8 (0x3C); code.u8 (0x0D); // '\r'
            branch (BranchKind.JE, l_ws_done);
            branch (BranchKind.JMP, l_check_sign);
            bind (l_ws_done);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            branch (BranchKind.JMP, l_skip_ws);

            bind (l_check_sign);
            // r10d = neg (0/1), r8 = mantissa, r9 = exp10, r11d = sig_digits
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xD2); // xor r10d, r10d
            code.u8 (0x4D); code.u8 (0x31); code.u8 (0xC0); // xor r8, r8
            code.u8 (0x4D); code.u8 (0x31); code.u8 (0xC9); // xor r9, r9
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xDB); // xor r11d, r11d
            code.u8 (0x3C); code.u8 (0x2D); // '-'
            var l_not_minus = new_label ();
            branch (BranchKind.JNE, l_not_minus);
            code.u8 (0x41); code.u8 (0xB2); code.u8 (0x01); // mov r10b, 1
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            branch (BranchKind.JMP, l_int_loop);
            bind (l_not_minus);
            code.u8 (0x3C); code.u8 (0x2B); // '+'
            branch (BranchKind.JNE, l_int_loop);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi

            bind (l_int_loop);
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xD6); // cmp rsi, rdx
            branch (BranchKind.JAE, l_scale);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06); // movzx eax, byte [rsi]
            code.u8 (0x2C); code.u8 (0x30); // sub al, '0'
            code.u8 (0x3C); code.u8 (0x09); // cmp al, 9
            branch (BranchKind.JA, l_check_dot);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            // if r11d < 18: r8 = r8 * 10 + rax; r11d++ else r9++
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xFB); code.u8 (0x12);
            var l_int_over = new_label ();
            branch (BranchKind.JAE, l_int_over);
            code.u8 (0x4D); code.u8 (0x6B); code.u8 (0xC0); code.u8 (0x0A); // imul r8, r8, 10
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xC0); // add r8, rax
            code.u8 (0x41); code.u8 (0xFF); code.u8 (0xC3); // inc r11d
            branch (BranchKind.JMP, l_int_loop);
            bind (l_int_over);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC1); // inc r9
            branch (BranchKind.JMP, l_int_loop);

            bind (l_check_dot);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06); // movzx eax, byte [rsi]
            code.u8 (0x3C); code.u8 (0x2E); // '.'
            branch (BranchKind.JNE, l_check_exp);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi

            bind (l_frac_loop);
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xD6);
            branch (BranchKind.JAE, l_scale);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06);
            code.u8 (0x2C); code.u8 (0x30);
            code.u8 (0x3C); code.u8 (0x09);
            branch (BranchKind.JA, l_check_exp);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xFB); code.u8 (0x12);
            branch (BranchKind.JAE, l_frac_loop);
            code.u8 (0x4D); code.u8 (0x6B); code.u8 (0xC0); code.u8 (0x0A); // imul r8, r8, 10
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xC0); // add r8, rax
            code.u8 (0x41); code.u8 (0xFF); code.u8 (0xC3); // inc r11d
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC9); // dec r9
            branch (BranchKind.JMP, l_frac_loop);

            bind (l_check_exp);
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xD6);
            branch (BranchKind.JAE, l_scale);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06);
            code.u8 (0x0C); code.u8 (0x20); // or al, 0x20 (lowercase)
            code.u8 (0x3C); code.u8 (0x65); // 'e'
            branch (BranchKind.JNE, l_scale);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6); // inc rsi
            // rcx = exp_neg (0/1), r11 = exp_val
            code.u8 (0x31); code.u8 (0xC9); // xor ecx, ecx
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xDB); // xor r11d, r11d
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xD6);
            branch (BranchKind.JAE, l_scale);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06);
            code.u8 (0x3C); code.u8 (0x2D); // '-'
            var l_exp_not_minus = new_label ();
            branch (BranchKind.JNE, l_exp_not_minus);
            code.u8 (0xB1); code.u8 (0x01); // mov cl, 1
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6);
            branch (BranchKind.JMP, l_exp_loop);
            bind (l_exp_not_minus);
            code.u8 (0x3C); code.u8 (0x2B); // '+'
            branch (BranchKind.JNE, l_exp_loop);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6);

            bind (l_exp_loop);
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xD6);
            var l_exp_done = new_label ();
            branch (BranchKind.JAE, l_exp_done);
            code.u8 (0x0F); code.u8 (0xB6); code.u8 (0x06);
            code.u8 (0x2C); code.u8 (0x30);
            code.u8 (0x3C); code.u8 (0x09);
            branch (BranchKind.JA, l_exp_done);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC6);
            // if r11 < 1000: r11 = r11 * 10 + rax
            code.u8 (0x49); code.u8 (0x81); code.u8 (0xFB); code.u32le (1000);
            branch (BranchKind.JAE, l_exp_loop);
            code.u8 (0x4D); code.u8 (0x6B); code.u8 (0xDB); code.u8 (0x0A); // imul r11, r11, 10
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xC3); // add r11, rax
            branch (BranchKind.JMP, l_exp_loop);

            bind (l_exp_done);
            code.u8 (0x84); code.u8 (0xC9); // test cl, cl
            var l_exp_add = new_label ();
            branch (BranchKind.JE, l_exp_add);
            code.u8 (0x4D); code.u8 (0x29); code.u8 (0xD9); // sub r9, r11
            branch (BranchKind.JMP, l_scale);
            bind (l_exp_add);
            code.u8 (0x4D); code.u8 (0x01); code.u8 (0xD9); // add r9, r11

            bind (l_scale);
            // cvtsi2sd xmm0, r8
            code.u8 (0xF2); code.u8 (0x49); code.u8 (0x0F); code.u8 (0x2A); code.u8 (0xC0);
            mov_rax_imm (0x4024000000000000); // 10.0
            movq_xmm_rax (1);
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC9); // test r9, r9
            branch (BranchKind.JE, l_apply_sign);
            branch (BranchKind.JS, l_div10);

            bind (l_mul10);
            mulsd_xmm0_xmm1 ();
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC9); // dec r9
            branch (BranchKind.JNE, l_mul10);
            branch (BranchKind.JMP, l_apply_sign);

            bind (l_div10);
            divsd_xmm0_xmm1 ();
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC1); // inc r9
            branch (BranchKind.JNE, l_div10);

            bind (l_apply_sign);
            code.u8 (0x45); code.u8 (0x84); code.u8 (0xD2); // test r10b, r10b
            branch (BranchKind.JE, l_ret);
            mov_rax_imm ((int64) 0x8000000000000000);
            movq_xmm_rax (1);
            pxor_xmm0_xmm1 ();
            branch (BranchKind.JMP, l_ret);

            bind (l_zero);
            code.u8 (0x66); code.u8 (0x0F); code.u8 (0x57); code.u8 (0xC0); // xorpd xmm0, xmm0
            bind (l_ret);
            ret ();
        }

        // string* __planc_double_to_str(double xmm0) -> rax
        public void emit_rt_double_to_str () {
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            sub_rsp (64);

            // r14 = write cursor at [rsp], r13 = digits buffer at [rsp + 32]
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x34); code.u8 (0x24); // lea r14, [rsp]
            code.u8 (0x4C); code.u8 (0x8D); code.u8 (0x6C); code.u8 (0x24); code.u8 (0x20); // lea r13, [rsp + 32]

            var l_nan = new_label ();
            var l_pos = new_label ();
            var l_inf = new_label ();
            var l_zero = new_label ();
            var l_scale_up = new_label ();
            var l_scale_down = new_label ();
            var l_digits = new_label ();
            var l_digit_loop = new_label ();
            var l_round_done = new_label ();
            var l_trim_loop = new_label ();
            var l_format = new_label ();
            var l_sci = new_label ();
            var l_alloc = new_label ();

            // NaN check: ucomisd xmm0, xmm0; jp l_nan
            code.u8 (0x66); code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC0);
            branch (BranchKind.JP, l_nan);

            // Sign bit check
            movq_rax_xmm (0);
            test_rax_rax ();
            branch (BranchKind.JNS, l_pos);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x2D); // mov byte [r14], '-'
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6); // inc r14
            code.u8 (0x48); code.u8 (0xB9); code.u64le (0x7FFFFFFFFFFFFFFF); // mov rcx, imm64
            code.u8 (0x48); code.u8 (0x21); code.u8 (0xC8); // and rax, rcx
            movq_xmm_rax (0);

            bind (l_pos);
            code.u8 (0x48); code.u8 (0xB9); code.u64le (0x7FF0000000000000); // mov rcx, imm64
            cmp_rax_rcx ();
            branch (BranchKind.JE, l_inf);
            test_rax_rax ();
            branch (BranchKind.JE, l_zero);

            // Scale xmm0 into [1.0, 10.0) with r12d = exp10
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xE4); // xor r12d, r12d
            mov_rax_imm (0x4024000000000000); // 10.0 in xmm1
            movq_xmm_rax (1);
            mov_rax_imm (0x3FF0000000000000); // 1.0 in xmm2
            movq_xmm_rax (2);

            bind (l_scale_up);
            ucomisd_xmm0_xmm1 ();
            branch (BranchKind.JB, l_scale_down);
            divsd_xmm0_xmm1 ();
            code.u8 (0x41); code.u8 (0xFF); code.u8 (0xC4); // inc r12d
            branch (BranchKind.JMP, l_scale_up);

            bind (l_scale_down);
            // ucomisd xmm0, xmm2 (1.0)
            code.u8 (0x66); code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC2);
            branch (BranchKind.JAE, l_digits);
            mulsd_xmm0_xmm1 ();
            code.u8 (0x41); code.u8 (0xFF); code.u8 (0xCC); // dec r12d
            branch (BranchKind.JMP, l_scale_down);

            bind (l_digits);
            // Extract 15 digits into [r13 + 0..14]
            code.u8 (0x31); code.u8 (0xC9); // xor ecx, ecx
            bind (l_digit_loop);
            code.u8 (0x83); code.u8 (0xF9); code.u8 (0x0F); // cmp ecx, 15
            var l_digits_done = new_label ();
            branch (BranchKind.JAE, l_digits_done);
            cvttsd2si_rax_xmm0 ();
            code.u8 (0x83); code.u8 (0xF8); code.u8 (0x09); // cmp eax, 9
            var l_d_ok = new_label ();
            branch (BranchKind.JBE, l_d_ok);
            mov_eax (9);
            bind (l_d_ok);
            // cvtsi2sd xmm3, rax
            code.u8 (0xF2); code.u8 (0x48); code.u8 (0x0F); code.u8 (0x2A); code.u8 (0xD8);
            // subsd xmm0, xmm3
            code.u8 (0xF2); code.u8 (0x0F); code.u8 (0x5C); code.u8 (0xC3);
            mulsd_xmm0_xmm1 (); // * 10.0
            code.u8 (0x04); code.u8 (0x30); // add al, '0'
            code.u8 (0x41); code.u8 (0x88); code.u8 (0x44); code.u8 (0x0D); code.u8 (0x00); // mov [r13 + rcx], al
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC1); // inc rcx
            branch (BranchKind.JMP, l_digit_loop);

            bind (l_digits_done);
            // Round using remaining fractional * 10 in xmm0 against 5.0
            mov_rax_imm (0x4014000000000000); // 5.0 in xmm3
            movq_xmm_rax (3);
            code.u8 (0x66); code.u8 (0x0F); code.u8 (0x2E); code.u8 (0xC3); // ucomisd xmm0, xmm3
            branch (BranchKind.JB, l_round_done);
            mov_eax (14); // rcx = 14
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC1);
            var l_carry_loop = new_label ();
            bind (l_carry_loop);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9);
            var l_carry_top = new_label ();
            branch (BranchKind.JS, l_carry_top);
            code.u8 (0x41); code.u8 (0xFE); code.u8 (0x44); code.u8 (0x0D); code.u8 (0x00); // inc byte [r13 + rcx]
            code.u8 (0x41); code.u8 (0x80); code.u8 (0x7C); code.u8 (0x0D); code.u8 (0x00); code.u8 (0x3A); // cmp byte [r13 + rcx], '9'+1
            branch (BranchKind.JB, l_round_done);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x44); code.u8 (0x0D); code.u8 (0x00); code.u8 (0x30); // mov byte [r13 + rcx], '0'
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9); // dec rcx
            branch (BranchKind.JMP, l_carry_loop);
            bind (l_carry_top);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x45); code.u8 (0x00); code.u8 (0x31); // mov byte [r13], '1'
            code.u8 (0x41); code.u8 (0xFF); code.u8 (0xC4); // inc r12d

            bind (l_round_done);
            // rbx = len_d = 15, trim trailing '0' down to 1
            mov_eax (15);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC3); // mov rbx, rax
            bind (l_trim_loop);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xFB); code.u8 (0x01); // cmp rbx, 1
            branch (BranchKind.JBE, l_format);
            code.u8 (0x41); code.u8 (0x80); code.u8 (0x7C); code.u8 (0x1D); code.u8 (0xFF); code.u8 (0x30); // cmp byte [r13 + rbx - 1], '0'
            branch (BranchKind.JNE, l_format);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xCB); // dec rbx
            branch (BranchKind.JMP, l_trim_loop);

            bind (l_format);
            // Check -4 <= r12d < 15
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xFC); code.u8 (0xFC); // cmp r12d, -4
            branch (BranchKind.JL, l_sci);
            code.u8 (0x41); code.u8 (0x83); code.u8 (0xFC); code.u8 (0x0F); // cmp r12d, 15
            branch (BranchKind.JGE, l_sci);

            // Fixed notation:
            code.u8 (0x45); code.u8 (0x85); code.u8 (0xE4); // test r12d, r12d
            var l_fix_ge0 = new_label ();
            branch (BranchKind.JNS, l_fix_ge0);
            // exp < 0: "0." + (-exp - 1)*'0' + digits[0..rbx]
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x30); // '0'
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x46); code.u8 (0x01); code.u8 (0x2E); // '.'
            code.u8 (0x49); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x02); // add r14, 2
            // ecx = -r12d - 1
            code.u8 (0x44); code.u8 (0x89); code.u8 (0xE1); // mov ecx, r12d
            code.u8 (0xF7); code.u8 (0xD9); // neg ecx
            code.u8 (0xFF); code.u8 (0xC9); // dec ecx
            var l_fz_loop = new_label ();
            var l_fz_done = new_label ();
            bind (l_fz_loop);
            code.u8 (0x85); code.u8 (0xC9); // test ecx, ecx
            branch (BranchKind.JLE, l_fz_done);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x30);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            code.u8 (0xFF); code.u8 (0xC9);
            branch (BranchKind.JMP, l_fz_loop);
            bind (l_fz_done);
            // copy rbx bytes from r13 to r14
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEE); // mov rsi, r13
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7); // mov rdi, r14
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9); // mov rcx, rbx
            code.u8 (0xF3); code.u8 (0xA4); // rep movsb
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xDE); // add r14, rbx
            branch (BranchKind.JMP, l_alloc);

            bind (l_fix_ge0);
            // int_digits = r12d + 1
            code.u8 (0x45); code.u8 (0x8D); code.u8 (0x44); code.u8 (0x24); code.u8 (0x01); // lea r8d, [r12 + 1]
            // copy min(r8, rbx) digits
            code.u8 (0x4D); code.u8 (0x63); code.u8 (0xC0); // movsxd r8, r8d
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xD8); // cmp r8, rbx
            var l_pad_int = new_label ();
            branch (BranchKind.JA, l_pad_int);
            // r8 <= rbx: copy r8 bytes
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEE); // mov rsi, r13
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7); // mov rdi, r14
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC1); // mov rcx, r8
            code.u8 (0xF3); code.u8 (0xA4);
            code.u8 (0x4D); code.u8 (0x01); code.u8 (0xC6); // add r14, r8
            // if r8 < rbx: emit '.' and remaining (rbx - r8) bytes
            code.u8 (0x49); code.u8 (0x39); code.u8 (0xD8);
            branch (BranchKind.JAE, l_alloc);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x2E); // '.'
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEE); // mov rsi, r13
            code.u8 (0x4C); code.u8 (0x01); code.u8 (0xC6); // add rsi, r8
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7); // mov rdi, r14
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9); // rcx = rbx
            code.u8 (0x4C); code.u8 (0x29); code.u8 (0xC1); // sub rcx, r8
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xCE); // add r14, rcx
            code.u8 (0xF3); code.u8 (0xA4);                 // rep movsb
            branch (BranchKind.JMP, l_alloc);

            bind (l_pad_int);
            // r8 > rbx: copy rbx bytes, then (r8 - rbx) '0's
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEE);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9);
            code.u8 (0xF3); code.u8 (0xA4);
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xDE); // add r14, rbx
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC1); // mov rcx, r8
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xD9); // sub rcx, rbx
            var l_pad0 = new_label ();
            bind (l_pad0);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9);
            branch (BranchKind.JLE, l_alloc);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x30);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9);
            branch (BranchKind.JMP, l_pad0);

            bind (l_sci);
            // Scientific: d[0] + (if rbx > 1: '.' + d[1..]) + 'e' + [+-] + digits
            code.u8 (0x41); code.u8 (0x8A); code.u8 (0x45); code.u8 (0x00); // mov al, [r13]
            code.u8 (0x41); code.u8 (0x88); code.u8 (0x06); // mov [r14], al
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0xFB); code.u8 (0x01);
            var l_sci_exp = new_label ();
            branch (BranchKind.JBE, l_sci_exp);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x2E); // '.'
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            code.u8 (0x4D); code.u8 (0x8D); code.u8 (0x75); code.u8 (0x01); // lea rsi, [r13 + 1]
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x4B); code.u8 (0xFF); // lea rcx, [rbx - 1]
            code.u8 (0x49); code.u8 (0x01); code.u8 (0xCE); // add r14, rcx (before rep movsb clobbers rcx)
            code.u8 (0xF3); code.u8 (0xA4);

            bind (l_sci_exp);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x65); // 'e'
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            code.u8 (0x45); code.u8 (0x85); code.u8 (0xE4); // test r12d, r12d
            var l_sci_pos = new_label ();
            branch (BranchKind.JNS, l_sci_pos);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x2D); // '-'
            code.u8 (0x41); code.u8 (0xF7); code.u8 (0xDC); // neg r12d
            var l_sci_digits = new_label ();
            branch (BranchKind.JMP, l_sci_digits);
            bind (l_sci_pos);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x2B); // '+'
            bind (l_sci_digits);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            // Format r12d (>= 0) into 2 or 3 digits via division by 10
            code.u8 (0x44); code.u8 (0x89); code.u8 (0xE0); // mov eax, r12d
            code.u8 (0xB9); code.u32le (10); // mov ecx, 10
            code.u8 (0x31); code.u8 (0xDB); // xor ebx, ebx (count)
            var l_ediv = new_label ();
            bind (l_ediv);
            code.u8 (0x31); code.u8 (0xD2); // xor edx, edx
            code.u8 (0xF7); code.u8 (0xF1); // div ecx
            code.u8 (0x80); code.u8 (0xC2); code.u8 (0x30); // add dl, '0'
            code.u8 (0x52); // push rdx
            code.u8 (0xFF); code.u8 (0xC3); // inc ebx
            test_rax_rax ();
            branch (BranchKind.JNE, l_ediv);
            // Pad at least 2 digits
            code.u8 (0x83); code.u8 (0xFB); code.u8 (0x02);
            var l_epop = new_label ();
            branch (BranchKind.JAE, l_epop);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x30);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            bind (l_epop);
            code.u8 (0x85); code.u8 (0xDB);
            branch (BranchKind.JLE, l_alloc);
            code.u8 (0x58); // pop rax
            code.u8 (0x41); code.u8 (0x88); code.u8 (0x06);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);
            code.u8 (0xFF); code.u8 (0xCB);
            branch (BranchKind.JMP, l_epop);

            bind (l_nan);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x6E); // 'n'
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x46); code.u8 (0x01); code.u8 (0x61); // 'a'
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x46); code.u8 (0x02); code.u8 (0x6E); // 'n'
            code.u8 (0x49); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x03);
            branch (BranchKind.JMP, l_alloc);

            bind (l_inf);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x69); // 'i'
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x46); code.u8 (0x01); code.u8 (0x6E); // 'n'
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x46); code.u8 (0x02); code.u8 (0x66); // 'f'
            code.u8 (0x49); code.u8 (0x83); code.u8 (0xC6); code.u8 (0x03);
            branch (BranchKind.JMP, l_alloc);

            bind (l_zero);
            code.u8 (0x41); code.u8 (0xC6); code.u8 (0x06); code.u8 (0x30); // '0'
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6);

            bind (l_alloc);
            // rbx = len = r14 - rsp
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF3); // mov rbx, r14
            code.u8 (0x48); code.u8 (0x29); code.u8 (0xE3); // sub rbx, rsp
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x7B); code.u8 (0x01); // lea rdi, [rbx + 1]
            mov_esi_imm (0);
            call_rel32 ("__planc_alloc");
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x58); code.u8 (0x08); // mov [rax + 8], rbx
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xE6); // mov rsi, rsp
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x78); code.u8 (0x10); // lea rdi, [rax + 16]
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD9); // mov rcx, rbx
            code.u8 (0xF3); code.u8 (0xA4); // rep movsb
            code.u8 (0xC6); code.u8 (0x07); code.u8 (0x00); // mov byte [rdi], 0

            add_rsp (64);
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
        }

        // Async/goroutine M:N runtime:
        // bss_base layout (64 bytes):
        //   +0  q_head, +8 q_tail, +16 q_lock, +24 active_tasks,
        //   +32 futex_word, +40 stop_flag, +48 waiters_sleeping
        // AsyncTask layout (allocated via __planc_alloc(64 + 8*slots, 0)):
        //   +16 q_next, +24 state_pc, +32 resume_fn, +40 result,
        //   +48 err, +56 waiter, +64 done_flag, +72 task_lock, +80.. frame
        public void emit_rt_async (int bss_base, GenericArray<Symbol> symbols) {
            // 1. void __planc_async_enqueue(AsyncTask* rdi)
            int fn_start = here ();
            var l_enq_lock = new_label ();
            var l_enq_locked = new_label ();
            var l_enq_empty = new_label ();
            var l_enq_unlock = new_label ();
            var l_enq_done = new_label ();
            // lea rdx, [rip + bss_base]       48 8D 15 disp32
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x15);
            record_rip (bss_base, PatchSpace.BSS);
            bind (l_enq_lock);
            code.u8 (0xB8); code.u32le (1); // mov eax, 1
            code.u8 (0x87); code.u8 (0x42); code.u8 (0x10); // xchg [rdx + 16], eax
            code.u8 (0x85); code.u8 (0xC0); // test eax, eax
            branch (BranchKind.JE, l_enq_locked);
            code.u8 (0xF3); code.u8 (0x90); // pause
            branch (BranchKind.JMP, l_enq_lock);
            bind (l_enq_locked);
            // mov qword ptr [rdi + 16], 0     48 C7 47 10 00 00 00 00
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x47); code.u8 (0x10); code.u32le (0);
            // mov r8, [rdx + 8]               4C 8B 42 08
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x42); code.u8 (0x08);
            // test r8, r8                     4D 85 C0
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_enq_empty);
            // mov [r8 + 16], rdi              49 89 78 10
            code.u8 (0x49); code.u8 (0x89); code.u8 (0x78); code.u8 (0x10);
            // mov [rdx + 8], rdi              48 89 7A 08
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x7A); code.u8 (0x08);
            branch (BranchKind.JMP, l_enq_unlock);
            bind (l_enq_empty);
            // mov [rdx], rdi                  48 89 3A
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x3A);
            // mov [rdx + 8], rdi              48 89 7A 08
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x7A); code.u8 (0x08);
            bind (l_enq_unlock);
            // mov dword ptr [rdx + 16], 0     C7 42 10 00 00 00 00
            code.u8 (0xC7); code.u8 (0x42); code.u8 (0x10); code.u32le (0);
            // lock inc dword ptr [rdx + 32]   F0 FF 42 20
            code.u8 (0xF0); code.u8 (0xFF); code.u8 (0x42); code.u8 (0x20);
            // cmp qword ptr [rdx + 48], 0     48 83 7A 30 00
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7A); code.u8 (0x30); code.u8 (0x00);
            branch (BranchKind.JE, l_enq_done);
            // SYS_futex(&futex_word, FUTEX_WAKE, 1, 0, 0, 0)
            // lea rdi, [rdx + 32]             48 8D 7A 20
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x7A); code.u8 (0x20);
            mov_esi_imm (1);
            mov_edx (1);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xD2); // xor r10d, r10d
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0); // xor r8d, r8d
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC9); // xor r9d, r9d
            mov_eax (202);
            syscall ();
            bind (l_enq_done);
            ret ();
            symbols.add (new Symbol ("__planc_async_enqueue", fn_start, here () - fn_start));

            // 2. AsyncTask* __planc_async_spawn(void* rdi, int64 rsi)
            fn_start = here ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            sub_rsp (8);
            // mov r12, rdi; shl rsi, 3; lea rdi, [rsi + 64]; xor esi, esi
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFC);
            code.u8 (0x48); code.u8 (0xC1); code.u8 (0xE6); code.u8 (0x03);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x7E); code.u8 (0x40);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            // mov rbx, rax; mov [rbx + 32], r12
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC3);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x63); code.u8 (0x20);
            // lea rdx, [rip + bss_base]; lock inc qword ptr [rdx + 24]
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x15);
            record_rip (bss_base, PatchSpace.BSS);
            code.u8 (0xF0); code.u8 (0x48); code.u8 (0xFF); code.u8 (0x42); code.u8 (0x18);
            // mov rdi, rbx; call __planc_ref (refcount = 2: caller + scheduler)
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            call_rel32 ("__planc_ref");
            // mov rax, rbx
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD8);
            add_rsp (8);
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_async_spawn", fn_start, here () - fn_start));

            // 3. int64 __planc_async_await(AsyncTask* rdi, AsyncTask* rsi)
            // Returns 1 if suspended, 0 if child already finished.
            fn_start = here ();
            var l_aw_lock = new_label ();
            var l_aw_locked = new_label ();
            var l_aw_done = new_label ();
            bind (l_aw_lock);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x47); code.u8 (0x48); // xchg [rdi + 72], eax
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_aw_locked);
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_aw_lock);
            bind (l_aw_locked);
            // cmp qword ptr [rdi + 64], 0     48 83 7F 40 00
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7F); code.u8 (0x40); code.u8 (0x00);
            branch (BranchKind.JNE, l_aw_done);
            // mov [rdi + 56], rsi             48 89 77 38
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x77); code.u8 (0x38);
            // mov dword ptr [rdi + 72], 0     C7 47 48 00 00 00 00
            code.u8 (0xC7); code.u8 (0x47); code.u8 (0x48); code.u32le (0);
            mov_eax (1);
            ret ();
            bind (l_aw_done);
            code.u8 (0xC7); code.u8 (0x47); code.u8 (0x48); code.u32le (0);
            xor_eax ();
            ret ();
            symbols.add (new Symbol ("__planc_async_await", fn_start, here () - fn_start));

            // 4. void __planc_async_finish(AsyncTask* rdi, int64 rsi, void* rdx)
            fn_start = here ();
            var l_fin_lock = new_label ();
            var l_fin_locked = new_label ();
            var l_fin_no_waiter = new_label ();
            var l_fin_done = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            // mov rbx, rdi; mov [rbx + 40], rsi; mov [rbx + 48], rdx; mov qword ptr [rbx + 24], -1
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x73); code.u8 (0x28);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x53); code.u8 (0x30);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x18); code.u32le (0xFFFFFFFFu);
            bind (l_fin_lock);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x43); code.u8 (0x48); // xchg [rbx + 72], eax
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_fin_locked);
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_fin_lock);
            bind (l_fin_locked);
            // mov qword ptr [rbx + 64], 1     48 C7 43 40 01 00 00 00
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x40); code.u32le (1);
            // mov r12, [rbx + 56]             4C 8B 63 38
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x63); code.u8 (0x38);
            // mov qword ptr [rbx + 56], 0     48 C7 43 38 00 00 00 00
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x38); code.u32le (0);
            // mov dword ptr [rbx + 72], 0     C7 43 48 00 00 00 00
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x48); code.u32le (0);
            // test r12, r12; je l_fin_no_waiter
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xE4);
            branch (BranchKind.JE, l_fin_no_waiter);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7); // mov rdi, r12
            call_rel32 ("__planc_async_enqueue");
            bind (l_fin_no_waiter);
            // mov rdi, rbx; call __planc_unref
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            call_rel32 ("__planc_unref");
            // lea rdx, [rip + bss_base]; lock dec qword ptr [rdx + 24]
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x15);
            record_rip (bss_base, PatchSpace.BSS);
            code.u8 (0xF0); code.u8 (0x48); code.u8 (0xFF); code.u8 (0x4A); code.u8 (0x18);
            branch (BranchKind.JNE, l_fin_done);
            // All tasks finished: stop_flag = 1; futex_word++; wake all waiters
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x42); code.u8 (0x28); code.u32le (1);
            code.u8 (0xF0); code.u8 (0xFF); code.u8 (0x42); code.u8 (0x20);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7A); code.u8 (0x30); code.u8 (0x00);
            branch (BranchKind.JE, l_fin_done);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x7A); code.u8 (0x20);
            mov_esi_imm (1);
            mov_edx (0x7FFFFFFF);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xD2);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC9);
            mov_eax (202);
            syscall ();
            bind (l_fin_done);
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_async_finish", fn_start, here () - fn_start));

            // 5. void __planc_async_worker_loop()
            fn_start = here ();
            var l_wk_loop = new_label ();
            var l_wk_lock = new_label ();
            var l_wk_locked = new_label ();
            var l_wk_has_next = new_label ();
            var l_wk_empty = new_label ();
            var l_wk_exit = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            sub_rsp (8);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x1D); // lea rbx, [rip + bss_base]
            record_rip (bss_base, PatchSpace.BSS);
            bind (l_wk_loop);
            bind (l_wk_lock);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x43); code.u8 (0x10); // xchg [rbx + 16], eax
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_wk_locked);
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_wk_lock);
            bind (l_wk_locked);
            // mov rax, [rbx]                  48 8B 03
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x03);
            test_rax_rax ();
            branch (BranchKind.JE, l_wk_empty);
            // mov r8, [rax + 16]; mov [rbx], r8; test r8, r8; jne l_wk_has_next; mov [rbx + 8], 0
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x40); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x03);
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JNE, l_wk_has_next);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x08); code.u32le (0);
            bind (l_wk_has_next);
            // mov qword ptr [rax + 16], 0; mov dword ptr [rbx + 16], 0
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x40); code.u8 (0x10); code.u32le (0);
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            // mov rdi, rax; mov r10, [rax + 32]; call r10
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xC7);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x50); code.u8 (0x20);
            code.u8 (0x41); code.u8 (0xFF); code.u8 (0xD2);
            branch (BranchKind.JMP, l_wk_loop);

            bind (l_wk_empty);
            // mov dword ptr [rbx + 16], 0
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            // if stop_flag != 0 or active_tasks == 0: exit
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x28); code.u8 (0x00);
            branch (BranchKind.JNE, l_wk_exit);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x18); code.u8 (0x00);
            branch (BranchKind.JE, l_wk_exit);
            // expected = [rbx + 32]; re-check q_head, stop_flag, active_tasks before futex_wait
            code.u8 (0x8B); code.u8 (0x53); code.u8 (0x20); // mov edx, [rbx + 32]
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x3B); code.u8 (0x00); // cmp qword [rbx], 0
            branch (BranchKind.JNE, l_wk_loop);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x28); code.u8 (0x00);
            branch (BranchKind.JNE, l_wk_exit);
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x18); code.u8 (0x00);
            branch (BranchKind.JE, l_wk_exit);
            // lock inc qword ptr [rbx + 48]
            code.u8 (0xF0); code.u8 (0x48); code.u8 (0xFF); code.u8 (0x43); code.u8 (0x30);
            // SYS_futex(&futex_word, FUTEX_WAIT=0, expected=edx, 0, 0, 0)
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x7B); code.u8 (0x20);
            code.u8 (0x31); code.u8 (0xF6); // xor esi, esi
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xD2);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC9);
            mov_eax (202);
            syscall ();
            // lock dec qword ptr [rbx + 48]
            code.u8 (0xF0); code.u8 (0x48); code.u8 (0xFF); code.u8 (0x4B); code.u8 (0x30);
            branch (BranchKind.JMP, l_wk_loop);

            bind (l_wk_exit);
            add_rsp (8);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_async_worker_loop", fn_start, here () - fn_start));

            // 6. void __planc_async_run(int64 rdi /* workers */)
            fn_start = here ();
            var l_run_single = new_label ();
            var l_run_done = new_label ();
            var l_run_cap_ok = new_label ();
            var l_spawn_loop = new_label ();
            var l_spawn_done = new_label ();
            var l_parent_next = new_label ();
            var l_clone_fail = new_label ();
            var l_join_loop = new_label ();
            var l_join_wait = new_label ();
            var l_join_unmap = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            sub_rsp (512);
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x1D); // lea rbx, [rip + bss_base]
            record_rip (bss_base, PatchSpace.BSS);
            // stop_flag = 0
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x28); code.u32le (0);
            // if active_tasks == 0: return
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x18); code.u8 (0x00);
            branch (BranchKind.JE, l_run_done);
            // r12 = workers; if r12 <= 1: l_run_single
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xFC);
            code.u8 (0x49); code.u8 (0x83); code.u8 (0xFC); code.u8 (0x01);
            branch (BranchKind.JLE, l_run_single);
            // clamp r12 to 64
            code.u8 (0x49); code.u8 (0x83); code.u8 (0xFC); code.u8 (0x40);
            branch (BranchKind.JLE, l_run_cap_ok);
            code.u8 (0x49); code.u8 (0xC7); code.u8 (0xC4); code.u32le (64);
            bind (l_run_cap_ok);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xCC); // dec r12 (extra workers)
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xED); // xor r13d, r13d (spawned)

            bind (l_spawn_loop);
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xE5); // cmp r13, r12
            branch (BranchKind.JGE, l_spawn_done);
            mov_esi_imm (0x10000);
            emit_mmap_anon_rw ();
            test_rax_rax ();
            branch (BranchKind.JS, l_spawn_done);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC6); // mov r14, rax
            code.u8 (0x41); code.u8 (0xC7); code.u8 (0x06); code.u32le (1); // mov dword [r14], 1
            // mov [rsp + r13*8], r14        4E 89 34 EC
            code.u8 (0x4E); code.u8 (0x89); code.u8 (0x34); code.u8 (0xEC);
            // SYS_clone(0x00210F00, r14 + 0x10000, 0, r14, 0)
            mov_edi (0x00210F00);
            code.u8 (0x49); code.u8 (0x8D); code.u8 (0xB6); code.u32le (0x10000); // lea rsi, [r14 + 0x10000]
            code.u8 (0x31); code.u8 (0xD2); // xor edx, edx
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0xF2); // mov r10, r14
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0); // xor r8d, r8d
            mov_eax (56);
            syscall ();
            test_rax_rax ();
            branch (BranchKind.JS, l_clone_fail);
            branch (BranchKind.JNE, l_parent_next);
            // Child thread
            call_rel32 ("__planc_async_worker_loop");
            code.u8 (0x31); code.u8 (0xFF); // xor edi, edi
            mov_eax (60);
            syscall ();

            bind (l_clone_fail);
            // munmap(r14, 0x10000)
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7);
            mov_esi_imm (0x10000);
            mov_eax (11);
            syscall ();
            branch (BranchKind.JMP, l_spawn_done);

            bind (l_parent_next);
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC5); // inc r13
            branch (BranchKind.JMP, l_spawn_loop);

            bind (l_spawn_done);
            call_rel32 ("__planc_async_worker_loop");
            // Join all r13 spawned threads
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xE4); // xor r12d, r12d
            bind (l_join_loop);
            code.u8 (0x4D); code.u8 (0x39); code.u8 (0xEC); // cmp r12, r13
            branch (BranchKind.JGE, l_run_done);
            // mov r14, [rsp + r12*8]        4E 8B 34 E4
            code.u8 (0x4E); code.u8 (0x8B); code.u8 (0x34); code.u8 (0xE4);
            bind (l_join_wait);
            code.u8 (0x41); code.u8 (0x8B); code.u8 (0x16); // mov edx, [r14]
            code.u8 (0x85); code.u8 (0xD2); // test edx, edx
            branch (BranchKind.JE, l_join_unmap);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7); // mov rdi, r14
            code.u8 (0x31); code.u8 (0xF6); // xor esi, esi (FUTEX_WAIT)
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xD2);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC9);
            mov_eax (202);
            syscall ();
            branch (BranchKind.JMP, l_join_wait);
            bind (l_join_unmap);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF7);
            mov_esi_imm (0x10000);
            mov_eax (11);
            syscall ();
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC4); // inc r12
            branch (BranchKind.JMP, l_join_loop);

            bind (l_run_single);
            call_rel32 ("__planc_async_worker_loop");

            bind (l_run_done);
            add_rsp (512);
            code.u8 (0x41); code.u8 (0x5E); // pop r14
            code.u8 (0x41); code.u8 (0x5D); // pop r13
            code.u8 (0x41); code.u8 (0x5C); // pop r12
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_async_run", fn_start, here () - fn_start));
        }

        // Signal runtime (Slice 14):
        // bss_base: 8 bytes (next_sig_id counter)
        // SigNode layout (allocated via __planc_alloc(32, 0)):
        //   +16 next, +24 id, +32 fn_ptr, +40 env_ptr
        public void emit_rt_signal (int bss_base, GenericArray<Symbol> symbols) {
            // 1. int64 __planc_sig_connect(void** rdi, void* rsi, void* rdx)
            int fn_start = here ();
            var l_no_ref = new_label ();
            var l_empty = new_label ();
            var l_tail_loop = new_label ();
            var l_done = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            code.u8 (0x41); code.u8 (0x56); // push r14
            // rbx = slot_addr, r12 = fn, r13 = env
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF4);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xD5);
            // if env != 0: __planc_ref(env)
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xED);
            branch (BranchKind.JE, l_no_ref);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEF);
            call_rel32 ("__planc_ref");
            bind (l_no_ref);
            // node = __planc_alloc(32, 0)
            mov_rdi_imm (32);
            code.u8 (0x31); code.u8 (0xF6); // xor esi, esi
            call_rel32 ("__planc_alloc");
            // r14 = lock_xadd(&bss_base, 1) + 1
            code.u8 (0x48); code.u8 (0x8D); code.u8 (0x15);
            record_rip (bss_base, PatchSpace.BSS);
            code.u8 (0x49); code.u8 (0xC7); code.u8 (0xC6); code.u32le (1);
            code.u8 (0xF0); code.u8 (0x4C); code.u8 (0x01); code.u8 (0x32); // lock xadd [rdx], r14
            code.u8 (0x49); code.u8 (0xFF); code.u8 (0xC6); // inc r14
            // node->next = 0; node->id = r14; node->fn = r12; node->env = r13
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x40); code.u8 (0x10); code.u32le (0);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x70); code.u8 (0x18);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x60); code.u8 (0x20);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x68); code.u8 (0x28);
            // Append to *rbx
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x0B); // mov rcx, [rbx]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9);
            branch (BranchKind.JE, l_empty);
            bind (l_tail_loop);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x51); code.u8 (0x10); // mov rdx, [rcx + 16]
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JE, l_done);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD1); // mov rcx, rdx
            branch (BranchKind.JMP, l_tail_loop);
            bind (l_done);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x41); code.u8 (0x10); // mov [rcx + 16], rax
            // return id (r14)
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0x41); code.u8 (0x5E);
            code.u8 (0x41); code.u8 (0x5D);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            bind (l_empty);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x03); // mov [rbx], rax
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xF0);
            code.u8 (0x41); code.u8 (0x5E);
            code.u8 (0x41); code.u8 (0x5D);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_sig_connect", fn_start, here () - fn_start));

            // 2. void __planc_sig_disconnect(void** rdi, int64 rsi)
            fn_start = here ();
            var l_dc_loop = new_label ();
            var l_dc_found = new_label ();
            var l_dc_head = new_label ();
            var l_dc_unlink_done = new_label ();
            var l_dc_no_env = new_label ();
            var l_dc_exit = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            // rbx = slot_addr, r12 = id, rcx = prev (0), rdx = cur (*rbx)
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF4);
            code.u8 (0x31); code.u8 (0xC9);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x13); // mov rdx, [rbx]
            bind (l_dc_loop);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xD2);
            branch (BranchKind.JE, l_dc_exit);
            code.u8 (0x4C); code.u8 (0x39); code.u8 (0x62); code.u8 (0x18); // cmp [rdx + 24], r12
            branch (BranchKind.JE, l_dc_found);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD1); // prev = cur
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x52); code.u8 (0x10); // cur = [cur + 16]
            branch (BranchKind.JMP, l_dc_loop);
            bind (l_dc_found);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x42); code.u8 (0x10); // rax = cur->next
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9);
            branch (BranchKind.JE, l_dc_head);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x41); code.u8 (0x10); // prev->next = rax
            branch (BranchKind.JMP, l_dc_unlink_done);
            bind (l_dc_head);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x03); // *rbx = rax
            bind (l_dc_unlink_done);
            // rbx = cur; if cur->env != 0: __planc_unref(cur->env); __planc_unref(cur)
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xD3);
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x7B); code.u8 (0x28);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_dc_no_env);
            call_rel32 ("__planc_unref");
            bind (l_dc_no_env);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            call_rel32 ("__planc_unref");
            bind (l_dc_exit);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_sig_disconnect", fn_start, here () - fn_start));

            // 3. void __planc_sig_free_list(void* rdi)
            fn_start = here ();
            var l_fl_loop = new_label ();
            var l_fl_no_env = new_label ();
            var l_fl_done = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB); // rbx = cur
            bind (l_fl_loop);
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xDB);
            branch (BranchKind.JE, l_fl_done);
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x63); code.u8 (0x10); // r12 = cur->next
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x7B); code.u8 (0x28); // rdi = cur->env
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_fl_no_env);
            call_rel32 ("__planc_unref");
            bind (l_fl_no_env);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xDF);
            call_rel32 ("__planc_unref");
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE3); // rbx = r12
            branch (BranchKind.JMP, l_fl_loop);
            bind (l_fl_done);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_sig_free_list", fn_start, here () - fn_start));
        }

        // Channel<T> and Mutex runtime (Slice 15):
        // Channel layout (__planc_alloc(48, 0)):
        //   +16 chan_lock, +24 val_head, +32 val_tail,
        //   +40 wait_head, +48 wait_tail, +56 closed
        // ChanVal layout (__planc_alloc(16, 0)):
        //   +16 next, +24 value
        // Mutex layout (__planc_alloc(16, 0)):
        //   +16 lock_word
        public void emit_rt_sync (GenericArray<Symbol> symbols) {
            // 1. void* __planc_chan_new()
            int fn_start = here ();
            mov_rdi_imm (48);
            code.u8 (0x31); code.u8 (0xF6); // xor esi, esi
            call_rel32 ("__planc_alloc");
            ret ();
            symbols.add (new Symbol ("__planc_chan_new", fn_start, here () - fn_start));

            // 2. void __planc_chan_send(void* rdi /* ch */, int64 rsi /* val */)
            fn_start = here ();
            var l_cs_lock = new_label ();
            var l_cs_locked = new_label ();
            var l_cs_closed = new_label ();
            var l_cs_vempty = new_label ();
            var l_cs_wcheck = new_label ();
            var l_cs_wake = new_label ();
            var l_cs_done = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x41); code.u8 (0x55); // push r13
            sub_rsp (8);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB); // rbx = ch
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF4); // r12 = val
            // alloc node = __planc_alloc(16, 0) before taking lock
            mov_rdi_imm (16);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xC5); // r13 = node
            code.u8 (0x4D); code.u8 (0x89); code.u8 (0x65); code.u8 (0x18); // [r13 + 24] = val
            // acquire chan_lock [rbx + 16]
            bind (l_cs_lock);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x43); code.u8 (0x10);
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_cs_locked);
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_cs_lock);
            bind (l_cs_locked);
            // if closed != 0: unlock and free node
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x38); code.u8 (0x00);
            branch (BranchKind.JNE, l_cs_closed);
            // append r13 to val_tail [rbx + 32]
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4B); code.u8 (0x20); // rcx = val_tail
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9);
            branch (BranchKind.JE, l_cs_vempty);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x69); code.u8 (0x10); // val_tail->next = r13
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x6B); code.u8 (0x20); // val_tail = r13
            branch (BranchKind.JMP, l_cs_wcheck);
            bind (l_cs_vempty);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x6B); code.u8 (0x18); // val_head = r13
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x6B); code.u8 (0x20); // val_tail = r13
            bind (l_cs_wcheck);
            // pop waiter from wait_head [rbx + 40]
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x6B); code.u8 (0x28); // r13 = wait_head
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xED);
            branch (BranchKind.JNE, l_cs_wake);
            // unlock and return
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            branch (BranchKind.JMP, l_cs_done);
            bind (l_cs_wake);
            // wait_head = r13->next; if 0: wait_tail = 0; r13->next = 0
            code.u8 (0x49); code.u8 (0x8B); code.u8 (0x45); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x28);
            test_rax_rax ();
            var l_cs_wh_nz = new_label ();
            branch (BranchKind.JNE, l_cs_wh_nz);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x30); code.u32le (0);
            bind (l_cs_wh_nz);
            code.u8 (0x49); code.u8 (0xC7); code.u8 (0x45); code.u8 (0x10); code.u32le (0);
            // unlock
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEF); // rdi = r13
            call_rel32 ("__planc_async_enqueue");
            branch (BranchKind.JMP, l_cs_done);
            bind (l_cs_closed);
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xEF);
            call_rel32 ("__planc_unref");
            bind (l_cs_done);
            add_rsp (8);
            code.u8 (0x41); code.u8 (0x5D);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_chan_send", fn_start, here () - fn_start));

            // 3. (rax=status, rdx=val) __planc_chan_try_recv(void* rdi /* ch */, void* rsi /* waiter */)
            // status 0 = got val in rdx (or closed with 0); status 1 = suspended (waiter enqueued).
            fn_start = here ();
            var l_cr_lock = new_label ();
            var l_cr_locked = new_label ();
            var l_cr_empty = new_label ();
            var l_cr_wempty = new_label ();
            var l_cr_closed = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB); // rbx = ch
            code.u8 (0x49); code.u8 (0x89); code.u8 (0xF4); // r12 = waiter
            bind (l_cr_lock);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x43); code.u8 (0x10);
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_cr_locked);
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_cr_lock);
            bind (l_cr_locked);
            // check val_head [rbx + 24]
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x7B); code.u8 (0x18); // rdi = val_head
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
            branch (BranchKind.JE, l_cr_empty);
            // pop val_head: rax = [rdi + 16]; val_head = rax; if 0: val_tail = 0
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x47); code.u8 (0x10);
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x18);
            test_rax_rax ();
            var l_cr_vh_nz = new_label ();
            branch (BranchKind.JNE, l_cr_vh_nz);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x20); code.u32le (0);
            bind (l_cr_vh_nz);
            // r12 = [rdi + 24] (val); unlock; __planc_unref(rdi); rax = 0; rdx = r12
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x67); code.u8 (0x18);
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            call_rel32 ("__planc_unref");
            xor_eax ();
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE2); // mov rdx, r12
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();

            bind (l_cr_empty);
            // if closed != 0: unlock; return (0, 0)
            code.u8 (0x48); code.u8 (0x83); code.u8 (0x7B); code.u8 (0x38); code.u8 (0x00);
            branch (BranchKind.JNE, l_cr_closed);
            // enqueue waiter r12 onto wait_tail [rbx + 48]
            code.u8 (0x49); code.u8 (0xC7); code.u8 (0x44); code.u8 (0x24); code.u8 (0x10); code.u32le (0); // r12->next = 0
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x4B); code.u8 (0x30); // rcx = wait_tail
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xC9);
            branch (BranchKind.JE, l_cr_wempty);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x61); code.u8 (0x10); // wait_tail->next = r12
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x63); code.u8 (0x30); // wait_tail = r12
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            mov_eax (1);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            bind (l_cr_wempty);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x63); code.u8 (0x28); // wait_head = r12
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x63); code.u8 (0x30); // wait_tail = r12
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            mov_eax (1);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();

            bind (l_cr_closed);
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            xor_eax ();
            xor_edx ();
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_chan_try_recv", fn_start, here () - fn_start));

            // 4. void __planc_chan_close(void* rdi /* ch */)
            fn_start = here ();
            var l_cc_lock = new_label ();
            var l_cc_locked = new_label ();
            var l_cc_loop = new_label ();
            var l_cc_done = new_label ();
            push_rbp ();
            mov_rsp_to_rbp ();
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xFB);
            bind (l_cc_lock);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x43); code.u8 (0x10);
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_cc_locked);
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_cc_lock);
            bind (l_cc_locked);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x38); code.u32le (1); // closed = 1
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x63); code.u8 (0x28); // r12 = wait_head
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x28); code.u32le (0);
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x43); code.u8 (0x30); code.u32le (0);
            code.u8 (0xC7); code.u8 (0x43); code.u8 (0x10); code.u32le (0);
            bind (l_cc_loop);
            code.u8 (0x4D); code.u8 (0x85); code.u8 (0xE4);
            branch (BranchKind.JE, l_cc_done);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
            code.u8 (0x4D); code.u8 (0x8B); code.u8 (0x64); code.u8 (0x24); code.u8 (0x10); // r12 = r12->next
            code.u8 (0x48); code.u8 (0xC7); code.u8 (0x47); code.u8 (0x10); code.u32le (0);
            call_rel32 ("__planc_async_enqueue");
            branch (BranchKind.JMP, l_cc_loop);
            bind (l_cc_done);
            code.u8 (0x41); code.u8 (0x5C);
            pop_reg (Reg.RBX);
            leave ();
            ret ();
            symbols.add (new Symbol ("__planc_chan_close", fn_start, here () - fn_start));

            // 5. void* __planc_mutex_new()
            fn_start = here ();
            mov_rdi_imm (16);
            code.u8 (0x31); code.u8 (0xF6);
            call_rel32 ("__planc_alloc");
            ret ();
            symbols.add (new Symbol ("__planc_mutex_new", fn_start, here () - fn_start));

            // 6. void __planc_mutex_lock(void* rdi)
            fn_start = here ();
            var l_ml_loop = new_label ();
            var l_ml_done = new_label ();
            bind (l_ml_loop);
            code.u8 (0xB8); code.u32le (1);
            code.u8 (0x87); code.u8 (0x47); code.u8 (0x10);
            code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_ml_done);
            code.u8 (0xF3); code.u8 (0x90);
            branch (BranchKind.JMP, l_ml_loop);
            bind (l_ml_done);
            ret ();
            symbols.add (new Symbol ("__planc_mutex_lock", fn_start, here () - fn_start));

            // 7. void __planc_mutex_unlock(void* rdi)
            fn_start = here ();
            code.u8 (0xC7); code.u8 (0x47); code.u8 (0x10); code.u32le (0);
            ret ();
            symbols.add (new Symbol ("__planc_mutex_unlock", fn_start, here () - fn_start));
        }
    }
}
