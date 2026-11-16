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
        BSS       // zero-initialized globals
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
        JS     // 0F 88 rel32   jump if SF (signed < 0)
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
        R8 = 8, R9 = 9;

        public static bool is_extended (Reg r) {
            return r >= R8;
        }
    }

    public class Emitter : Object {

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
            for (int i = 0; i < string_literals.length; i++) {
                if (string_literals[i] == s)
                    return string_offsets[i];
            }
            while (data.length % 8 != 0)
                data.u8 (0);
            var offset = data.length;
            data.u32le (0);
            data.u32le (0);
            data.u64le ((uint64) s.length);
            data.ascii (s);
            data.u8 (0);
            string_literals.add (s);
            string_offsets.add (offset);
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

        public void bind (Label l) {
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
                case BranchKind.JS:
                    p.displacement = code.length + 2;
                    code.u8 (0x0F); code.u8 (0x88);
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

        // mov qword ptr [rbp + d], 0         48 C7 45 d8 00000000 | 48 C7 85 d32 00000000
        public void zero_local (int slot) {
            code.u8 (0x48); code.u8 (0xC7);
            emit_modrm_disp (0, 5, slot_offset (slot));
            code.u32le (0);
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
        public void push_rax () { push_reg (Reg.RAX); }
        public void pop_rax () { pop_reg (Reg.RAX); }

        // ------------------------------------------------------------------
        // Locals: slots live at [rbp - 8*(slot+1)]. Positive displacements
        // reach the incoming stack arguments above the return address.
        // ------------------------------------------------------------------

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
            load_rbp_disp (slot_offset (slot));
        }

        // mov [rbp - d], rax                 48 89 45 d8 | 48 89 85 d32
        public void store_local (int slot) {
            store_rbp_disp (slot_offset (slot));
        }

        // mov [rbp - d], reg: stores an incoming argument register into its
        // slot in the prologue. REX.R covers r8/r9.
        public void store_local_reg (int slot, Reg src) {
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

        // cmp rax, rcx                       48 39 C8
        public void cmp_rax_rcx () {
            code.u8 (0x48); code.u8 (0x39); code.u8 (0xC8);
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
        public void emit_rt_write_str () {
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
        public void emit_rt_panic (int msg_rodata_offset, int msg_len) {
            mov_eax (1);
            mov_edi (2);
            lea_rsi_rip (msg_rodata_offset + 16);
            mov_edx ((uint32) msg_len);
            syscall ();
            mov_edi (134);
            mov_eax (60);
            syscall ();
        }

        // Shared decimal formatter: converts int64 in `rdi` into [rbp - 32 .. rbp],
        // leaving start pointer in `rcx` and length in `rbp - rcx`.
        private void emit_format_int_to_stack () {
            var l_pos = new_label ();
            var l_loop = new_label ();
            var l_done = new_label ();
            // mov rcx, rbp                    48 89 E9
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xE9);
            // mov rax, rdi                    48 89 F8
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xF8);
            // xor r8d, r8d                    45 31 C0
            code.u8 (0x45); code.u8 (0x31); code.u8 (0xC0);
            test_rax_rax ();
            branch (BranchKind.JGE, l_pos);
            neg_rax ();
            // mov r8d, 1                      41 B8 01 00 00 00
            code.u8 (0x41); code.u8 (0xB8); code.u32le (1);
            bind (l_pos);
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
            // test r8d, r8d                   45 85 C0
            code.u8 (0x45); code.u8 (0x85); code.u8 (0xC0);
            branch (BranchKind.JE, l_done);
            // dec rcx                         48 FF C9
            code.u8 (0x48); code.u8 (0xFF); code.u8 (0xC9);
            // mov byte ptr [rcx], '-'         C6 01 2D
            code.u8 (0xC6); code.u8 (0x01); code.u8 (0x2D);
            bind (l_done);
        }

        // void __planc_write_int(int64 rdi) -> formats signed decimal to stdout.
        public void emit_rt_write_int () {
            push_rbp ();
            mov_rsp_to_rbp ();
            sub_rsp (32);
            emit_format_int_to_stack ();
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

        // ------------------------------------------------------------------
        // Slice 5 safe allocator, atomic ref/unref, and dynamic strings.
        // ------------------------------------------------------------------

        // void* __planc_alloc(uint64 rdi = payload_bytes, uint64 rsi = elem_ref)
        public void emit_rt_alloc (int bss_base, Label mem_panic_lbl) {
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
            // mprotect(r12 + r14, 4096, PROT_NONE)
            // mov rdi, r12; add rdi, r14
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE7);
            code.u8 (0x4C); code.u8 (0x01); code.u8 (0xF7);
            mov_esi_imm (4096);
            // xor edx, edx; mov eax, 10; syscall
            code.u8 (0x31); code.u8 (0xD2);
            mov_eax (10);
            syscall ();
            // mov rax, r12; mov cl, 255; jmp l_init_header
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);
            code.u8 (0xB1); code.u8 (0xFF);
            branch (BranchKind.JMP, l_init_header);

            // Small/medium class 0..7: check free_lists[rcx]
            bind (l_found_class);
            // mov rax, [rbx + rcx*8 + 32]     48 8B 44 CB 20
            code.u8 (0x48); code.u8 (0x8B); code.u8 (0x44); code.u8 (0xCB); code.u8 (0x20);
            test_rax_rax ();
            branch (BranchKind.JE, l_arena_carve);
            // Pop block: mov r8, [rax + 8]; mov [rbx + rcx*8 + 32], r8
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x40); code.u8 (0x08);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x44); code.u8 (0xCB); code.u8 (0x20);
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
            // mov [rbx + 16], rax; mov rax, r8; jmp l_init_header
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x43); code.u8 (0x10);
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xC0);
            branch (BranchKind.JMP, l_init_header);

            // Map new 64KB slab + 4KB PROT_NONE guard page (0x11000)
            bind (l_new_slab);
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
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0xE0);

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
        public void emit_rt_ref (Label mem_panic_lbl) {
            var l_done = new_label ();
            // mov rax, rdi                    48 89 F8
            code.u8 (0x48); code.u8 (0x89); code.u8 (0xF8);
            // test rdi, rdi                   48 85 FF
            code.u8 (0x48); code.u8 (0x85); code.u8 (0xFF);
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
            // Push block onto free_lists[rcx]
            // mov r8, [rdx + rcx*8 + 32]      4C 8B 44 CA 20
            code.u8 (0x4C); code.u8 (0x8B); code.u8 (0x44); code.u8 (0xCA); code.u8 (0x20);
            // mov [rdi + 8], r8               4C 89 47 08
            code.u8 (0x4C); code.u8 (0x89); code.u8 (0x47); code.u8 (0x08);
            // mov [rdx + rcx*8 + 32], rdi     48 89 7C CA 20
            code.u8 (0x48); code.u8 (0x89); code.u8 (0x7C); code.u8 (0xCA); code.u8 (0x20);

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

        // string* __planc_int_to_str(int64 rdi)
        public void emit_rt_int_to_str () {
            push_rbp ();
            mov_rsp_to_rbp ();
            sub_rsp (32);
            push_reg (Reg.RBX);
            code.u8 (0x41); code.u8 (0x54); // push r12
            emit_format_int_to_stack ();
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
    }
}
