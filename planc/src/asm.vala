// Built-in x86_64 assembler for [AsmBody("...")] functions (TC-04, VL-09, I5).
//
// Accepts AT&T syntax matching docs/05-userland-and-abi.md (%reg, $imm,
// disp(%base,%index,scale), local labels, and calls to Vala functions).
// Encodes directly into Emitter.code with zero external assembler invocation.

namespace Planc {

    public enum AsmOpKind {
        NONE,
        REG,
        CREG,
        SREG,
        IMM,
        MEM,
        SYM
    }

    public class AsmOp : Object {
        public AsmOpKind kind = AsmOpKind.NONE;
        public int reg = -1;       // 0..15 for REG/CREG/SREG
        public int width = 64;     // 8, 16, 32, 64 for REG
        public bool is_high8 = false;
        public int64 imm = 0;
        public int base_reg = -1;
        public int index_reg = -1;
        public int scale = 1;
        public int32 disp = 0;
        public bool is_rip = false;
        public string sym = "";
    }

    public class AsmLabelFixup : Object {
        public int code_off;
        public string label_name;
        public int line;
        public int col;
    }

    public class AsmAssembler : Object {
        private Emitter emitter;
        private Program program;
        private Function fn;
        private GenericArray<string> label_names;
        private GenericArray<int> label_offsets;
        private GenericArray<AsmLabelFixup> label_fixups;

        public AsmAssembler (Emitter emitter, Program program, Function fn) {
            this.emitter = emitter;
            this.program = program;
            this.fn = fn;
            this.label_names = new GenericArray<string> ();
            this.label_offsets = new GenericArray<int> ();
            this.label_fixups = new GenericArray<AsmLabelFixup> ();
        }

        public static void assemble (Emitter emitter, Program program, Function fn) throws SemanticError {
            var a = new AsmAssembler (emitter, program, fn);
            a.run ();
        }

        private void fail (int rel_line, string msg) throws SemanticError {
            throw new SemanticError.TYPE_MISMATCH (
                @"[AsmBody] $(fn.name): $msg at $(fn.asm_line + rel_line):$(fn.asm_column)");
        }

        private int find_label (string name) {
            for (int i = 0; i < label_names.length; i++) {
                if (label_names[i] == name)
                    return label_offsets[i];
            }
            return -1;
        }

        private void run () throws SemanticError {
            var src = fn.asm_body;
            int n = src.length;
            int i = 0;
            int rel_line = 0;

            while (i < n) {
                int line_start = i;
                while (i < n && src[i] != '\n' && src[i] != ';')
                    i++;
                var raw_line = src[line_start:i];
                bool is_nl = (i < n && src[i] == '\n');
                if (i < n)
                    i++;
                assemble_line (raw_line, rel_line);
                if (is_nl)
                    rel_line++;
            }

            foreach (var fx in label_fixups) {
                int target = find_label (fx.label_name);
                if (target >= 0) {
                    int rel = target - (fx.code_off + 4);
                    emitter.code.patch_u32le (fx.code_off, (uint32) rel);
                } else if (program.find (fx.label_name) != null) {
                    var cp = new CallPatch () {
                        displacement = fx.code_off,
                        callee = fx.label_name
                    };
                    emitter.calls.add (cp);
                } else {
                    fail (fx.line, @"undefined label or symbol '$(fx.label_name)'");
                }
            }
        }

        private static string strip_comment (string s) {
            for (int i = 0; i < s.length; i++) {
                if (s[i] == '#')
                    return s[0:i];
                if (s[i] == '/' && i + 1 < s.length && s[i + 1] == '/')
                    return s[0:i];
            }
            return s;
        }

        private static string trim_ws (string s) {
            int a = 0;
            int b = s.length;
            while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r'))
                a++;
            while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r'))
                b--;
            return s[a:b];
        }

        private static bool is_ws (uint8 c) {
            return c == ' ' || c == '\t' || c == '\r';
        }

        private static string ascii_lower (string s) {
            var sb = new StrBuilder ();
            for (int i = 0; i < s.length; i++) {
                uint8 c = s[i];
                if (c >= 'A' && c <= 'Z')
                    c = (uint8) (c + 32);
                sb.append_c ((char) c);
            }
            return sb.str;
        }

        private void assemble_line (string raw_line, int rel_line) throws SemanticError {
            var line = trim_ws (strip_comment (raw_line));
            if (line == "")
                return;

            // Handle one or more `label:` prefixes.
            while (true) {
                int colon = -1;
                for (int k = 0; k < line.length; k++) {
                    uint8 c = line[k];
                    if (c == ':') { colon = k; break; }
                    if (is_ws (c) || c == ',' || c == '(' || c == '$') break;
                }
                if (colon < 0)
                    break;
                var lname = trim_ws (line[0:colon]);
                if (lname == "")
                    fail (rel_line, "empty label name");
                label_names.add (lname);
                label_offsets.add (emitter.here ());
                line = trim_ws (line[colon + 1:line.length]);
                if (line == "")
                    return;
            }

            // Directives.
            if (line[0] == '.') {
                handle_directive (line, rel_line);
                return;
            }

            // Optional `lock` prefix.
            int sp = 0;
            while (sp < line.length && !is_ws (line[sp]))
                sp++;
            var mnem = ascii_lower (line[0:sp]);
            var rest = trim_ws (line[sp:line.length]);
            if (mnem == "lock") {
                emitter.code.u8 (0xF0);
                if (rest == "")
                    return;
                sp = 0;
                while (sp < rest.length && !is_ws (rest[sp]))
                    sp++;
                mnem = ascii_lower (rest[0:sp]);
                rest = trim_ws (rest[sp:rest.length]);
            }

            var ops = new GenericArray<AsmOp> ();
            if (rest != "")
                split_operands (rest, ops, rel_line);

            encode_insn (mnem, ops, rel_line);
        }

        private void handle_directive (string line, int rel_line) throws SemanticError {
            int sp = 0;
            while (sp < line.length && !is_ws (line[sp]))
                sp++;
            var dir = ascii_lower (line[0:sp]);
            var rest = trim_ws (line[sp:line.length]);
            if (dir == ".global" || dir == ".globl")
                return;
            if (dir == ".align" || dir == ".p2align") {
                int64 a = parse_int_val (rest, rel_line);
                if (dir == ".p2align")
                    a = (int64) 1 << (int) a;
                if (a > 1) {
                    while ((emitter.here () % (int) a) != 0)
                        emitter.code.u8 (0x90);
                }
                return;
            }
            if (dir == ".byte" || dir == ".word" || dir == ".long" || dir == ".quad") {
                var parts = split_top_commas (rest);
                foreach (var p in parts) {
                    int64 v = parse_int_val (trim_ws (p), rel_line);
                    if (dir == ".byte") emitter.code.u8 ((uint8) v);
                    else if (dir == ".word") emitter.code.u16le ((uint16) v);
                    else if (dir == ".long") emitter.code.u32le ((uint32) v);
                    else emitter.code.u64le ((uint64) v);
                }
                return;
            }
            fail (rel_line, @"unsupported assembler directive '$dir'");
        }

        private static GenericArray<string> split_top_commas (string s) {
            var res = new GenericArray<string> ();
            int depth = 0;
            int start = 0;
            for (int i = 0; i < s.length; i++) {
                uint8 c = s[i];
                if (c == '(') depth++;
                else if (c == ')' && depth > 0) depth--;
                else if (c == ',' && depth == 0) {
                    res.add (s[start:i]);
                    start = i + 1;
                }
            }
            res.add (s[start:s.length]);
            return res;
        }

        private void split_operands (string rest, GenericArray<AsmOp> ops, int rel_line) throws SemanticError {
            var parts = split_top_commas (rest);
            foreach (var p in parts) {
                var t = trim_ws (p);
                if (t == "")
                    fail (rel_line, "empty operand");
                ops.add (parse_operand (t, rel_line));
            }
        }

        private static int64 parse_int_val (string raw, int rel_line = 0) throws SemanticError {
            var s = trim_ws (raw);
            if (s == "")
                throw new SemanticError.TYPE_MISMATCH (@"[AsmBody] expected integer at +$rel_line");
            bool neg = false;
            int idx = 0;
            if (s[0] == '-') { neg = true; idx = 1; }
            else if (s[0] == '+') { idx = 1; }
            var body = s[idx:s.length];
            uint64 v = 0;
            if (body.has_prefix ("0x") || body.has_prefix ("0X")) {
                for (int k = 2; k < body.length; k++) {
                    uint8 c = body[k];
                    uint64 d = 0;
                    if (c >= '0' && c <= '9') d = (uint64) (c - '0');
                    else if (c >= 'a' && c <= 'f') d = (uint64) (10 + c - 'a');
                    else if (c >= 'A' && c <= 'F') d = (uint64) (10 + c - 'A');
                    else throw new SemanticError.TYPE_MISMATCH (@"[AsmBody] invalid hex literal '$s'");
                    v = v * 16 + d;
                }
            } else if (body.has_prefix ("0b") || body.has_prefix ("0B")) {
                for (int k = 2; k < body.length; k++) {
                    uint8 c = body[k];
                    if (c != '0' && c != '1')
                        throw new SemanticError.TYPE_MISMATCH (@"[AsmBody] invalid binary literal '$s'");
                    v = v * 2 + (uint64) (c - '0');
                }
            } else {
                if (body.length == 0)
                    throw new SemanticError.TYPE_MISMATCH (@"[AsmBody] invalid integer '$s'");
                for (int k = 0; k < body.length; k++) {
                    uint8 c = body[k];
                    if (c < '0' || c > '9')
                        throw new SemanticError.TYPE_MISMATCH (@"[AsmBody] invalid integer '$s'");
                    v = v * 10 + (uint64) (c - '0');
                }
            }
            return neg ? -(int64) v : (int64) v;
        }

        private static bool lookup_gpr (string name, out int code, out int width, out bool high8) {
            code = -1;
            width = 64;
            high8 = false;
            var r = ascii_lower (name);
            if (r == "rax") { code = 0; width = 64; return true; }
            if (r == "rcx") { code = 1; width = 64; return true; }
            if (r == "rdx") { code = 2; width = 64; return true; }
            if (r == "rbx") { code = 3; width = 64; return true; }
            if (r == "rsp") { code = 4; width = 64; return true; }
            if (r == "rbp") { code = 5; width = 64; return true; }
            if (r == "rsi") { code = 6; width = 64; return true; }
            if (r == "rdi") { code = 7; width = 64; return true; }
            if (r == "r8")  { code = 8; width = 64; return true; }
            if (r == "r9")  { code = 9; width = 64; return true; }
            if (r == "r10") { code = 10; width = 64; return true; }
            if (r == "r11") { code = 11; width = 64; return true; }
            if (r == "r12") { code = 12; width = 64; return true; }
            if (r == "r13") { code = 13; width = 64; return true; }
            if (r == "r14") { code = 14; width = 64; return true; }
            if (r == "r15") { code = 15; width = 64; return true; }

            if (r == "eax") { code = 0; width = 32; return true; }
            if (r == "ecx") { code = 1; width = 32; return true; }
            if (r == "edx") { code = 2; width = 32; return true; }
            if (r == "ebx") { code = 3; width = 32; return true; }
            if (r == "esp") { code = 4; width = 32; return true; }
            if (r == "ebp") { code = 5; width = 32; return true; }
            if (r == "esi") { code = 6; width = 32; return true; }
            if (r == "edi") { code = 7; width = 32; return true; }
            if (r == "r8d")  { code = 8; width = 32; return true; }
            if (r == "r9d")  { code = 9; width = 32; return true; }
            if (r == "r10d") { code = 10; width = 32; return true; }
            if (r == "r11d") { code = 11; width = 32; return true; }
            if (r == "r12d") { code = 12; width = 32; return true; }
            if (r == "r13d") { code = 13; width = 32; return true; }
            if (r == "r14d") { code = 14; width = 32; return true; }
            if (r == "r15d") { code = 15; width = 32; return true; }

            if (r == "ax") { code = 0; width = 16; return true; }
            if (r == "cx") { code = 1; width = 16; return true; }
            if (r == "dx") { code = 2; width = 16; return true; }
            if (r == "bx") { code = 3; width = 16; return true; }
            if (r == "sp") { code = 4; width = 16; return true; }
            if (r == "bp") { code = 5; width = 16; return true; }
            if (r == "si") { code = 6; width = 16; return true; }
            if (r == "di") { code = 7; width = 16; return true; }
            if (r == "r8w")  { code = 8; width = 16; return true; }
            if (r == "r9w")  { code = 9; width = 16; return true; }
            if (r == "r10w") { code = 10; width = 16; return true; }
            if (r == "r11w") { code = 11; width = 16; return true; }
            if (r == "r12w") { code = 12; width = 16; return true; }
            if (r == "r13w") { code = 13; width = 16; return true; }
            if (r == "r14w") { code = 14; width = 16; return true; }
            if (r == "r15w") { code = 15; width = 16; return true; }

            if (r == "al")  { code = 0; width = 8; return true; }
            if (r == "cl")  { code = 1; width = 8; return true; }
            if (r == "dl")  { code = 2; width = 8; return true; }
            if (r == "bl")  { code = 3; width = 8; return true; }
            if (r == "spl") { code = 4; width = 8; return true; }
            if (r == "bpl") { code = 5; width = 8; return true; }
            if (r == "sil") { code = 6; width = 8; return true; }
            if (r == "dil") { code = 7; width = 8; return true; }
            if (r == "ah")  { code = 4; width = 8; high8 = true; return true; }
            if (r == "ch")  { code = 5; width = 8; high8 = true; return true; }
            if (r == "dh")  { code = 6; width = 8; high8 = true; return true; }
            if (r == "bh")  { code = 7; width = 8; high8 = true; return true; }
            if (r == "r8b")  { code = 8; width = 8; return true; }
            if (r == "r9b")  { code = 9; width = 8; return true; }
            if (r == "r10b") { code = 10; width = 8; return true; }
            if (r == "r11b") { code = 11; width = 8; return true; }
            if (r == "r12b") { code = 12; width = 8; return true; }
            if (r == "r13b") { code = 13; width = 8; return true; }
            if (r == "r14b") { code = 14; width = 8; return true; }
            if (r == "r15b") { code = 15; width = 8; return true; }
            return false;
        }

        private AsmOp parse_operand (string t, int rel_line) throws SemanticError {
            var op = new AsmOp ();
            if (t[0] == '$') {
                op.kind = AsmOpKind.IMM;
                op.imm = parse_int_val (t[1:t.length], rel_line);
                return op;
            }
            if (t[0] == '%') {
                var rname = ascii_lower (t[1:t.length]);
                if (rname.has_prefix ("cr")) {
                    int cr = (int) parse_int_val (rname[2:rname.length], rel_line);
                    op.kind = AsmOpKind.CREG;
                    op.reg = cr;
                    return op;
                }
                if (rname == "es") { op.kind = AsmOpKind.SREG; op.reg = 0; return op; }
                if (rname == "cs") { op.kind = AsmOpKind.SREG; op.reg = 1; return op; }
                if (rname == "ss") { op.kind = AsmOpKind.SREG; op.reg = 2; return op; }
                if (rname == "ds") { op.kind = AsmOpKind.SREG; op.reg = 3; return op; }
                if (rname == "fs") { op.kind = AsmOpKind.SREG; op.reg = 4; return op; }
                if (rname == "gs") { op.kind = AsmOpKind.SREG; op.reg = 5; return op; }

                int c = 0;
                int w = 64;
                bool h8 = false;
                if (!lookup_gpr (rname, out c, out w, out h8))
                    fail (rel_line, @"unknown register '$t'");
                op.kind = AsmOpKind.REG;
                op.reg = c;
                op.width = w;
                op.is_high8 = h8;
                return op;
            }

            // Check memory operand: disp(%base,%index,scale)
            int lp = -1;
            int rp = -1;
            for (int i = 0; i < t.length; i++) {
                if (t[i] == '(') lp = i;
                else if (t[i] == ')') rp = i;
            }
            if (lp >= 0 && rp > lp) {
                op.kind = AsmOpKind.MEM;
                var disp_str = trim_ws (t[0:lp]);
                var inner = trim_ws (t[lp + 1:rp]);
                var parts = split_top_commas (inner);
                if (parts.length >= 1) {
                    var b = trim_ws (parts[0]);
                    if (b != "") {
                        if (b[0] != '%')
                            fail (rel_line, @"expected '%reg' in memory base '$t'");
                        var bn = ascii_lower (b[1:b.length]);
                        if (bn == "rip") {
                            op.is_rip = true;
                            if (disp_str != "")
                                op.sym = disp_str;
                            return op;
                        }
                        int bc = 0;
                        int bw = 64;
                        bool bh8 = false;
                        if (!lookup_gpr (bn, out bc, out bw, out bh8))
                            fail (rel_line, @"unknown base register '$b'");
                        op.base_reg = bc;
                    }
                }
                if (disp_str != "")
                    op.disp = (int32) parse_int_val (disp_str, rel_line);
                if (parts.length >= 2) {
                    var ix = trim_ws (parts[1]);
                    if (ix != "") {
                        if (ix[0] != '%')
                            fail (rel_line, @"expected '%reg' in memory index '$t'");
                        int ic = 0;
                        int iw = 64;
                        bool ih8 = false;
                        if (!lookup_gpr (ix[1:ix.length], out ic, out iw, out ih8))
                            fail (rel_line, @"unknown index register '$ix'");
                        op.index_reg = ic;
                    }
                }
                if (parts.length >= 3) {
                    int sc = (int) parse_int_val (parts[2], rel_line);
                    if (sc != 1 && sc != 2 && sc != 4 && sc != 8)
                        fail (rel_line, @"invalid scale '$sc' in '$t'");
                    op.scale = sc;
                }
                return op;
            }

            if ((t[0] >= '0' && t[0] <= '9') || t[0] == '-') {
                op.kind = AsmOpKind.MEM;
                op.disp = (int32) parse_int_val (t, rel_line);
                return op;
            }
            op.kind = AsmOpKind.SYM;
            op.sym = t;
            return op;
        }

        // ------------------------------------------------------------------
        // Low-level REX + ModRM + SIB emission.
        // ------------------------------------------------------------------

        private void emit_rex (bool w64, int reg, int index, int rm, bool force_rex = false) {
            uint8 rex = 0x40;
            if (w64) rex |= 0x08;
            if (reg >= 8) rex |= 0x04;
            if (index >= 8) rex |= 0x02;
            if (rm >= 8) rex |= 0x01;
            if (rex != 0x40 || force_rex)
                emitter.code.u8 (rex);
        }

        private void emit_prefix_and_rex (int width, int reg, AsmOp rm_op, bool force_rex = false) {
            if (width == 16)
                emitter.code.u8 (0x66);
            bool w64 = (width == 64);
            int idx = (rm_op.kind == AsmOpKind.MEM) ? rm_op.index_reg : -1;
            int rm = (rm_op.kind == AsmOpKind.MEM) ? rm_op.base_reg : rm_op.reg;
            if (width == 8 && !force_rex) {
                if (reg >= 4 && reg <= 7) force_rex = true;
                if (rm_op.kind == AsmOpKind.REG && !rm_op.is_high8 && rm >= 4 && rm <= 7) force_rex = true;
            }
            emit_rex (w64, reg, idx, rm, force_rex);
        }

        private void emit_modrm_op (int reg_field, AsmOp rm_op, int rel_line) {
            if (rm_op.kind == AsmOpKind.REG) {
                emitter.code.u8 ((uint8) (0xC0 | ((reg_field & 7) << 3) | (rm_op.reg & 7)));
                return;
            }
            if (rm_op.is_rip) {
                emitter.code.u8 ((uint8) (((reg_field & 7) << 3) | 5));
                if (rm_op.sym != "") {
                    label_fixups.add (new AsmLabelFixup () {
                        code_off = emitter.here (),
                        label_name = rm_op.sym,
                        line = rel_line,
                        col = 0
                    });
                    emitter.code.u32le (0);
                } else {
                    emitter.code.u32le ((uint32) rm_op.disp);
                }
                return;
            }
            int b = rm_op.base_reg;
            int ix = rm_op.index_reg;
            int32 disp = rm_op.disp;
            int sbits = (rm_op.scale == 8) ? 3 : ((rm_op.scale == 4) ? 2 : ((rm_op.scale == 2) ? 1 : 0));

            if (b < 0 && ix < 0) {
                emitter.code.u8 ((uint8) (((reg_field & 7) << 3) | 4));
                emitter.code.u8 (0x25);
                emitter.code.u32le ((uint32) disp);
                return;
            }

            bool need_sib = (ix >= 0) || ((b & 7) == 4);
            int mod = 0;
            if (b < 0) {
                mod = 0;
            } else if (disp == 0 && (b & 7) != 5) {
                mod = 0;
            } else if (disp >= -128 && disp <= 127) {
                mod = 1;
            } else {
                mod = 2;
            }

            int rm_bits = need_sib ? 4 : (b & 7);
            emitter.code.u8 ((uint8) ((mod << 6) | ((reg_field & 7) << 3) | rm_bits));
            if (need_sib) {
                int sib_idx = (ix >= 0) ? (ix & 7) : 4;
                int sib_base = (b >= 0) ? (b & 7) : 5;
                emitter.code.u8 ((uint8) ((sbits << 6) | (sib_idx << 3) | sib_base));
            }
            if (b < 0 || mod == 2)
                emitter.code.u32le ((uint32) disp);
            else if (mod == 1)
                emitter.code.u8 ((uint8) disp);
        }

        private static int infer_width (string mnem, AsmOp? a, AsmOp? b, out string stem) {
            stem = mnem;
            if (mnem == "movzbq" || mnem == "movzbl" || mnem == "movzwq" || mnem == "movzx"
                || mnem == "movsbq" || mnem == "movswq" || mnem == "movslq" || mnem == "movsx"
                || mnem == "iretq" || mnem == "sysretq" || mnem == "pushfq" || mnem == "popfq"
                || mnem == "inb" || mnem == "inw" || mnem == "inl"
                || mnem == "outb" || mnem == "outw" || mnem == "outl"
                || mnem == "cqo" || mnem == "cdq" || mnem == "cdqe"
                || mnem == "jmp" || mnem == "call" || mnem == "ret" || mnem == "retq"
                || mnem == "nop" || mnem == "pause" || mnem == "hlt"
                || mnem == "cli" || mnem == "sti" || mnem == "clc" || mnem == "stc"
                || mnem == "cld" || mnem == "std" || mnem == "leave"
                || mnem == "swapgs" || mnem == "rdmsr" || mnem == "wrmsr"
                || mnem == "rdtsc" || mnem == "cpuid" || mnem == "wbinvd"
                || mnem == "mfence" || mnem == "lfence" || mnem == "sfence"
                || mnem == "ud2" || mnem == "int" || mnem == "int3"
                || mnem == "syscall" || mnem == "invlpg" || mnem == "lgdt" || mnem == "lidt"
                || mnem == "sgdt" || mnem == "sidt" || mnem == "ltr"
                || mnem == "fxsave" || mnem == "fxrstor") {
                return 64;
            }
            int len = mnem.length;
            if (len >= 3) {
                uint8 last = mnem[len - 1];
                if (last == 'q' || last == 'l' || last == 'w' || last == 'b') {
                    var base_m = mnem[0:len - 1];
                    if (base_m == "mov" || base_m == "lea" || base_m == "push" || base_m == "pop"
                        || base_m == "add" || base_m == "sub" || base_m == "and" || base_m == "or"
                        || base_m == "xor" || base_m == "cmp" || base_m == "test"
                        || base_m == "inc" || base_m == "dec" || base_m == "neg" || base_m == "not"
                        || base_m == "shl" || base_m == "sal" || base_m == "shr" || base_m == "sar"
                        || base_m == "rol" || base_m == "ror"
                        || base_m == "mul" || base_m == "imul" || base_m == "div" || base_m == "idiv"
                        || base_m == "xchg" || base_m == "bt" || base_m == "bts" || base_m == "btr" || base_m == "btc") {
                        stem = base_m;
                        if (last == 'q') return 64;
                        if (last == 'l') return 32;
                        if (last == 'w') return 16;
                        return 8;
                    }
                }
            }
            if (b != null && b.kind == AsmOpKind.REG) return b.width;
            if (a != null && a.kind == AsmOpKind.REG) return a.width;
            return 64;
        }

        private static uint8 cc_code (string cc) {
            if (cc == "o") return 0x80;
            if (cc == "no") return 0x81;
            if (cc == "b" || cc == "c" || cc == "nae") return 0x82;
            if (cc == "ae" || cc == "nb" || cc == "nc") return 0x83;
            if (cc == "e" || cc == "z") return 0x84;
            if (cc == "ne" || cc == "nz") return 0x85;
            if (cc == "be" || cc == "na") return 0x86;
            if (cc == "a" || cc == "nbe") return 0x87;
            if (cc == "s") return 0x88;
            if (cc == "ns") return 0x89;
            if (cc == "p" || cc == "pe") return 0x8A;
            if (cc == "np" || cc == "po") return 0x8B;
            if (cc == "l" || cc == "nge") return 0x8C;
            if (cc == "ge" || cc == "nl") return 0x8D;
            if (cc == "le" || cc == "ng") return 0x8E;
            if (cc == "g" || cc == "nle") return 0x8F;
            return 0;
        }

        private void emit_branch_target (string sym, int rel_line) {
            label_fixups.add (new AsmLabelFixup () {
                code_off = emitter.here (),
                label_name = sym,
                line = rel_line,
                col = 0
            });
            emitter.code.u32le (0);
        }

        private void encode_insn (string mnem, GenericArray<AsmOp> ops, int rel_line) throws SemanticError {
            string stem = mnem;
            AsmOp? op0 = (ops.length >= 1) ? ops[0] : null;
            AsmOp? op1 = (ops.length >= 2) ? ops[1] : null;
            int width = infer_width (mnem, op0, op1, out stem);

            // 0-operand instructions
            if (ops.length == 0) {
                switch (stem) {
                    case "ret": case "retq": emitter.code.u8 (0xC3); return;
                    case "iretq":  emitter.code.u8 (0x48); emitter.code.u8 (0xCF); return;
                    case "syscall": emitter.code.u8 (0x0F); emitter.code.u8 (0x05); return;
                    case "sysretq": emitter.code.u8 (0x48); emitter.code.u8 (0x0F); emitter.code.u8 (0x07); return;
                    case "cli":    emitter.code.u8 (0xFA); return;
                    case "sti":    emitter.code.u8 (0xFB); return;
                    case "hlt":    emitter.code.u8 (0xF4); return;
                    case "nop":    emitter.code.u8 (0x90); return;
                    case "pause":  emitter.code.u8 (0xF3); emitter.code.u8 (0x90); return;
                    case "clc":    emitter.code.u8 (0xF8); return;
                    case "stc":    emitter.code.u8 (0xF9); return;
                    case "cld":    emitter.code.u8 (0xFC); return;
                    case "std":    emitter.code.u8 (0xFD); return;
                    case "leave":  emitter.code.u8 (0xC9); return;
                    case "cqo":    emitter.code.u8 (0x48); emitter.code.u8 (0x99); return;
                    case "cdq":    emitter.code.u8 (0x99); return;
                    case "cdqe":   emitter.code.u8 (0x48); emitter.code.u8 (0x98); return;
                    case "pushfq": emitter.code.u8 (0x9C); return;
                    case "popfq":  emitter.code.u8 (0x9D); return;
                    case "swapgs": emitter.code.u8 (0x0F); emitter.code.u8 (0x01); emitter.code.u8 (0xF8); return;
                    case "rdmsr":  emitter.code.u8 (0x0F); emitter.code.u8 (0x32); return;
                    case "wrmsr":  emitter.code.u8 (0x0F); emitter.code.u8 (0x30); return;
                    case "rdtsc":  emitter.code.u8 (0x0F); emitter.code.u8 (0x31); return;
                    case "cpuid":  emitter.code.u8 (0x0F); emitter.code.u8 (0xA2); return;
                    case "wbinvd": emitter.code.u8 (0x0F); emitter.code.u8 (0x09); return;
                    case "ud2":    emitter.code.u8 (0x0F); emitter.code.u8 (0x0B); return;
                    case "int3":   emitter.code.u8 (0xCC); return;
                    case "mfence": emitter.code.u8 (0x0F); emitter.code.u8 (0xAE); emitter.code.u8 (0xF0); return;
                    case "lfence": emitter.code.u8 (0x0F); emitter.code.u8 (0xAE); emitter.code.u8 (0xE8); return;
                    case "sfence": emitter.code.u8 (0x0F); emitter.code.u8 (0xAE); emitter.code.u8 (0xF8); return;
                    default:
                        fail (rel_line, @"unknown 0-operand instruction '$mnem'");
                        break;
                }
            }

            // 1-operand instructions
            if (ops.length == 1 && op0 != null) {
                if (stem == "push") {
                    if (op0.kind == AsmOpKind.REG) {
                        if (op0.reg >= 8) emitter.code.u8 (0x41);
                        emitter.code.u8 ((uint8) (0x50 + (op0.reg & 7)));
                        return;
                    }
                    if (op0.kind == AsmOpKind.IMM) {
                        if (op0.imm >= -128 && op0.imm <= 127) {
                            emitter.code.u8 (0x6A);
                            emitter.code.u8 ((uint8) op0.imm);
                        } else {
                            emitter.code.u8 (0x68);
                            emitter.code.u32le ((uint32) op0.imm);
                        }
                        return;
                    }
                    if (op0.kind == AsmOpKind.MEM) {
                        emit_prefix_and_rex (32, 0, op0);
                        emitter.code.u8 (0xFF);
                        emit_modrm_op (6, op0, rel_line);
                        return;
                    }
                }
                if (stem == "pop") {
                    if (op0.kind == AsmOpKind.REG) {
                        if (op0.reg >= 8) emitter.code.u8 (0x41);
                        emitter.code.u8 ((uint8) (0x58 + (op0.reg & 7)));
                        return;
                    }
                    if (op0.kind == AsmOpKind.MEM) {
                        emit_prefix_and_rex (32, 0, op0);
                        emitter.code.u8 (0x8F);
                        emit_modrm_op (0, op0, rel_line);
                        return;
                    }
                }
                if (stem == "int" && op0.kind == AsmOpKind.IMM) {
                    emitter.code.u8 (0xCD);
                    emitter.code.u8 ((uint8) op0.imm);
                    return;
                }
                if (stem == "jmp") {
                    if (op0.kind == AsmOpKind.SYM) {
                        emitter.code.u8 (0xE9);
                        emit_branch_target (op0.sym, rel_line);
                        return;
                    }
                    emit_prefix_and_rex (32, 0, op0);
                    emitter.code.u8 (0xFF);
                    emit_modrm_op (4, op0, rel_line);
                    return;
                }
                if (stem == "call") {
                    if (op0.kind == AsmOpKind.SYM) {
                        emitter.code.u8 (0xE8);
                        emit_branch_target (op0.sym, rel_line);
                        return;
                    }
                    emit_prefix_and_rex (32, 0, op0);
                    emitter.code.u8 (0xFF);
                    emit_modrm_op (2, op0, rel_line);
                    return;
                }
                if (stem.has_prefix ("j") && stem.length >= 2 && op0.kind == AsmOpKind.SYM) {
                    uint8 cc = cc_code (stem[1:stem.length]);
                    if (cc != 0) {
                        emitter.code.u8 (0x0F);
                        emitter.code.u8 (cc);
                        emit_branch_target (op0.sym, rel_line);
                        return;
                    }
                }
                if (stem.has_prefix ("set") && stem.length >= 4) {
                    uint8 cc = cc_code (stem[3:stem.length]);
                    if (cc != 0) {
                        emit_prefix_and_rex (8, 0, op0);
                        emitter.code.u8 (0x0F);
                        emitter.code.u8 ((uint8) (cc + 0x10));
                        emit_modrm_op (0, op0, rel_line);
                        return;
                    }
                }
                if (stem == "inc" || stem == "dec" || stem == "neg" || stem == "not"
                    || stem == "mul" || stem == "imul" || stem == "div" || stem == "idiv") {
                    bool is_fe = (stem == "inc" || stem == "dec");
                    int ext = 0;
                    if (stem == "dec") ext = 1;
                    else if (stem == "not") ext = 2;
                    else if (stem == "neg") ext = 3;
                    else if (stem == "mul") ext = 4;
                    else if (stem == "imul") ext = 5;
                    else if (stem == "div") ext = 6;
                    else if (stem == "idiv") ext = 7;
                    emit_prefix_and_rex (width, 0, op0);
                    emitter.code.u8 ((uint8) ((width == 8) ? (is_fe ? 0xFE : 0xF6) : (is_fe ? 0xFF : 0xF7)));
                    emit_modrm_op (ext, op0, rel_line);
                    return;
                }
                if (stem == "invlpg" || stem == "lgdt" || stem == "lidt" || stem == "sgdt" || stem == "sidt") {
                    int ext = (stem == "sgdt") ? 0 : ((stem == "sidt") ? 1 : ((stem == "lgdt") ? 2 : ((stem == "lidt") ? 3 : 7)));
                    emit_prefix_and_rex (32, 0, op0);
                    emitter.code.u8 (0x0F); emitter.code.u8 (0x01);
                    emit_modrm_op (ext, op0, rel_line);
                    return;
                }
                if (stem == "ltr") {
                    emit_prefix_and_rex (32, 0, op0);
                    emitter.code.u8 (0x0F); emitter.code.u8 (0x00);
                    emit_modrm_op (3, op0, rel_line);
                    return;
                }
                if (stem == "fxsave" || stem == "fxrstor") {
                    emit_prefix_and_rex (32, 0, op0);
                    emitter.code.u8 (0x0F); emitter.code.u8 (0xAE);
                    emit_modrm_op ((stem == "fxsave") ? 0 : 1, op0, rel_line);
                    return;
                }
                fail (rel_line, @"unsupported 1-operand instruction '$mnem'");
            }

            // 2-operand instructions (AT&T: op0 = src, op1 = dst)
            if (ops.length == 2 && op0 != null && op1 != null) {
                if (stem == "out") {
                    if (op0.kind == AsmOpKind.REG && op0.reg == 0 && op1.kind == AsmOpKind.REG && op1.reg == 2 && op1.width == 16) {
                        if (op0.width == 8) { emitter.code.u8 (0xEE); return; }
                        if (op0.width == 16) { emitter.code.u8 (0x66); emitter.code.u8 (0xEF); return; }
                        if (op0.width == 32) { emitter.code.u8 (0xEF); return; }
                    }
                    if (op0.kind == AsmOpKind.REG && op0.reg == 0 && op1.kind == AsmOpKind.IMM) {
                        if (op0.width == 8) { emitter.code.u8 (0xE6); emitter.code.u8 ((uint8) op1.imm); return; }
                        if (op0.width == 32) { emitter.code.u8 (0xE7); emitter.code.u8 ((uint8) op1.imm); return; }
                    }
                    fail (rel_line, "invalid operands for 'out'");
                    return;
                }
                if (stem == "in") {
                    if (op0.kind == AsmOpKind.REG && op0.reg == 2 && op0.width == 16 && op1.kind == AsmOpKind.REG && op1.reg == 0) {
                        if (op1.width == 8) { emitter.code.u8 (0xEC); return; }
                        if (op1.width == 16) { emitter.code.u8 (0x66); emitter.code.u8 (0xED); return; }
                        if (op1.width == 32) { emitter.code.u8 (0xED); return; }
                    }
                    if (op0.kind == AsmOpKind.IMM && op1.kind == AsmOpKind.REG && op1.reg == 0) {
                        if (op1.width == 8) { emitter.code.u8 (0xE4); emitter.code.u8 ((uint8) op0.imm); return; }
                        if (op1.width == 32) { emitter.code.u8 (0xE5); emitter.code.u8 ((uint8) op0.imm); return; }
                    }
                    fail (rel_line, "invalid operands for 'in'");
                    return;
                }
                if (stem == "mov") {
                    if (op0.kind == AsmOpKind.CREG && op1.kind == AsmOpKind.REG) {
                        emit_rex (false, op0.reg, -1, op1.reg);
                        emitter.code.u8 (0x0F); emitter.code.u8 (0x20);
                        emit_modrm_op (op0.reg, op1, rel_line);
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG && op1.kind == AsmOpKind.CREG) {
                        emit_rex (false, op1.reg, -1, op0.reg);
                        emitter.code.u8 (0x0F); emitter.code.u8 (0x22);
                        emit_modrm_op (op1.reg, op0, rel_line);
                        return;
                    }
                    if (op0.kind == AsmOpKind.SREG && op1.kind == AsmOpKind.REG) {
                        emit_prefix_and_rex (width, op0.reg, op1);
                        emitter.code.u8 (0x8C);
                        emit_modrm_op (op0.reg, op1, rel_line);
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG && op1.kind == AsmOpKind.SREG) {
                        emit_rex (false, op1.reg, -1, op0.reg);
                        emitter.code.u8 (0x8E);
                        emit_modrm_op (op1.reg, op0, rel_line);
                        return;
                    }
                    if (op0.kind == AsmOpKind.IMM && op1.kind == AsmOpKind.REG) {
                        if (width == 64 && (op0.imm < -2147483648 || op0.imm > 2147483647)) {
                            emit_rex (true, 0, -1, op1.reg);
                            emitter.code.u8 ((uint8) (0xB8 + (op1.reg & 7)));
                            emitter.code.u64le ((uint64) op0.imm);
                            return;
                        }
                        if (width == 8) {
                            emit_prefix_and_rex (8, 0, op1);
                            emitter.code.u8 ((uint8) (0xB0 + (op1.reg & 7)));
                            emitter.code.u8 ((uint8) op0.imm);
                            return;
                        }
                        if (width == 64) {
                            emit_prefix_and_rex (64, 0, op1);
                            emitter.code.u8 (0xC7);
                            emit_modrm_op (0, op1, rel_line);
                            emitter.code.u32le ((uint32) op0.imm);
                            return;
                        }
                        emit_prefix_and_rex (width, 0, op1);
                        emitter.code.u8 ((uint8) (0xB8 + (op1.reg & 7)));
                        if (width == 16) emitter.code.u16le ((uint16) op0.imm);
                        else emitter.code.u32le ((uint32) op0.imm);
                        return;
                    }
                    if (op0.kind == AsmOpKind.IMM && op1.kind == AsmOpKind.MEM) {
                        emit_prefix_and_rex (width, 0, op1);
                        emitter.code.u8 ((uint8) ((width == 8) ? 0xC6 : 0xC7));
                        emit_modrm_op (0, op1, rel_line);
                        if (width == 8) emitter.code.u8 ((uint8) op0.imm);
                        else if (width == 16) emitter.code.u16le ((uint16) op0.imm);
                        else emitter.code.u32le ((uint32) op0.imm);
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG) {
                        emit_prefix_and_rex (width, op0.reg, op1);
                        emitter.code.u8 ((uint8) ((width == 8) ? 0x88 : 0x89));
                        emit_modrm_op (op0.reg, op1, rel_line);
                        return;
                    }
                    if (op1.kind == AsmOpKind.REG && op0.kind == AsmOpKind.MEM) {
                        emit_prefix_and_rex (width, op1.reg, op0);
                        emitter.code.u8 ((uint8) ((width == 8) ? 0x8A : 0x8B));
                        emit_modrm_op (op1.reg, op0, rel_line);
                        return;
                    }
                }
                if (stem == "lea" && op0.kind == AsmOpKind.MEM && op1.kind == AsmOpKind.REG) {
                    emit_prefix_and_rex (op1.width, op1.reg, op0);
                    emitter.code.u8 (0x8D);
                    emit_modrm_op (op1.reg, op0, rel_line);
                    return;
                }
                if ((stem == "movzbq" || stem == "movzbl" || stem == "movzwq" || stem == "movzx")
                    && op1.kind == AsmOpKind.REG) {
                    bool is_w = (stem == "movzwq") || (op0.kind == AsmOpKind.REG && op0.width == 16);
                    int dst_w = (stem == "movzbl") ? 32 : op1.width;
                    emit_prefix_and_rex (dst_w, op1.reg, op0);
                    emitter.code.u8 (0x0F);
                    emitter.code.u8 ((uint8) (is_w ? 0xB7 : 0xB6));
                    emit_modrm_op (op1.reg, op0, rel_line);
                    return;
                }
                if ((stem == "movsbq" || stem == "movswq" || stem == "movslq" || stem == "movsx")
                    && op1.kind == AsmOpKind.REG) {
                    if (stem == "movslq" || (op0.kind == AsmOpKind.REG && op0.width == 32)) {
                        emit_prefix_and_rex (64, op1.reg, op0);
                        emitter.code.u8 (0x63);
                        emit_modrm_op (op1.reg, op0, rel_line);
                        return;
                    }
                    bool is_w = (stem == "movswq") || (op0.kind == AsmOpKind.REG && op0.width == 16);
                    emit_prefix_and_rex (op1.width, op1.reg, op0);
                    emitter.code.u8 (0x0F);
                    emitter.code.u8 ((uint8) (is_w ? 0xBF : 0xBE));
                    emit_modrm_op (op1.reg, op0, rel_line);
                    return;
                }
                if (stem == "xchg") {
                    if (op0.kind == AsmOpKind.REG) {
                        emit_prefix_and_rex (width, op0.reg, op1);
                        emitter.code.u8 ((uint8) ((width == 8) ? 0x86 : 0x87));
                        emit_modrm_op (op0.reg, op1, rel_line);
                        return;
                    }
                    if (op1.kind == AsmOpKind.REG) {
                        emit_prefix_and_rex (width, op1.reg, op0);
                        emitter.code.u8 ((uint8) ((width == 8) ? 0x86 : 0x87));
                        emit_modrm_op (op1.reg, op0, rel_line);
                        return;
                    }
                }
                if (stem == "add" || stem == "or" || stem == "and" || stem == "sub" || stem == "xor" || stem == "cmp") {
                    int alu = (stem == "add") ? 0 : ((stem == "or") ? 1 : ((stem == "and") ? 4 : ((stem == "sub") ? 5 : ((stem == "xor") ? 6 : 7))));
                    if (op0.kind == AsmOpKind.IMM) {
                        emit_prefix_and_rex (width, 0, op1);
                        if (width == 8) {
                            emitter.code.u8 (0x80);
                            emit_modrm_op (alu, op1, rel_line);
                            emitter.code.u8 ((uint8) op0.imm);
                        } else if (op0.imm >= -128 && op0.imm <= 127) {
                            emitter.code.u8 (0x83);
                            emit_modrm_op (alu, op1, rel_line);
                            emitter.code.u8 ((uint8) op0.imm);
                        } else {
                            emitter.code.u8 (0x81);
                            emit_modrm_op (alu, op1, rel_line);
                            if (width == 16) emitter.code.u16le ((uint16) op0.imm);
                            else emitter.code.u32le ((uint32) op0.imm);
                        }
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG) {
                        emit_prefix_and_rex (width, op0.reg, op1);
                        emitter.code.u8 ((uint8) (alu * 8 + ((width == 8) ? 0 : 1)));
                        emit_modrm_op (op0.reg, op1, rel_line);
                        return;
                    }
                    if (op1.kind == AsmOpKind.REG && op0.kind == AsmOpKind.MEM) {
                        emit_prefix_and_rex (width, op1.reg, op0);
                        emitter.code.u8 ((uint8) (alu * 8 + ((width == 8) ? 2 : 3)));
                        emit_modrm_op (op1.reg, op0, rel_line);
                        return;
                    }
                }
                if (stem == "test") {
                    if (op0.kind == AsmOpKind.IMM) {
                        emit_prefix_and_rex (width, 0, op1);
                        emitter.code.u8 ((uint8) ((width == 8) ? 0xF6 : 0xF7));
                        emit_modrm_op (0, op1, rel_line);
                        if (width == 8) emitter.code.u8 ((uint8) op0.imm);
                        else if (width == 16) emitter.code.u16le ((uint16) op0.imm);
                        else emitter.code.u32le ((uint32) op0.imm);
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG) {
                        emit_prefix_and_rex (width, op0.reg, op1);
                        emitter.code.u8 ((uint8) ((width == 8) ? 0x84 : 0x85));
                        emit_modrm_op (op0.reg, op1, rel_line);
                        return;
                    }
                }
                if (stem == "shl" || stem == "sal" || stem == "shr" || stem == "sar" || stem == "rol" || stem == "ror") {
                    int ext = (stem == "rol") ? 0 : ((stem == "ror") ? 1 : ((stem == "shr") ? 5 : ((stem == "sar") ? 7 : 4)));
                    emit_prefix_and_rex (width, 0, op1);
                    if (op0.kind == AsmOpKind.IMM) {
                        emitter.code.u8 ((uint8) ((width == 8) ? 0xC0 : 0xC1));
                        emit_modrm_op (ext, op1, rel_line);
                        emitter.code.u8 ((uint8) op0.imm);
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG && op0.reg == 1 && op0.width == 8) {
                        emitter.code.u8 ((uint8) ((width == 8) ? 0xD2 : 0xD3));
                        emit_modrm_op (ext, op1, rel_line);
                        return;
                    }
                }
                if (stem == "imul" && op1.kind == AsmOpKind.REG) {
                    emit_prefix_and_rex (op1.width, op1.reg, op0);
                    emitter.code.u8 (0x0F); emitter.code.u8 (0xAF);
                    emit_modrm_op (op1.reg, op0, rel_line);
                    return;
                }
                if (stem == "bt" || stem == "bts" || stem == "btr" || stem == "btc") {
                    int ext = (stem == "bt") ? 4 : ((stem == "bts") ? 5 : ((stem == "btr") ? 6 : 7));
                    uint8 opc = (stem == "bt") ? 0xA3 : ((stem == "bts") ? 0xAB : ((stem == "btr") ? 0xB3 : 0xBB));
                    if (op0.kind == AsmOpKind.IMM) {
                        emit_prefix_and_rex (width, 0, op1);
                        emitter.code.u8 (0x0F); emitter.code.u8 (0xBA);
                        emit_modrm_op (ext, op1, rel_line);
                        emitter.code.u8 ((uint8) op0.imm);
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG) {
                        emit_prefix_and_rex (width, op0.reg, op1);
                        emitter.code.u8 (0x0F); emitter.code.u8 (opc);
                        emit_modrm_op (op0.reg, op1, rel_line);
                        return;
                    }
                }
                if (stem == "inb" || stem == "inw" || stem == "inl") {
                    int pw = (stem == "inb") ? 8 : ((stem == "inw") ? 16 : 32);
                    if (pw == 16) emitter.code.u8 (0x66);
                    if (op0.kind == AsmOpKind.IMM) {
                        emitter.code.u8 ((uint8) ((pw == 8) ? 0xE4 : 0xE5));
                        emitter.code.u8 ((uint8) op0.imm);
                        return;
                    }
                    if (op0.kind == AsmOpKind.REG && op0.reg == 2 && op0.width == 16) {
                        emitter.code.u8 ((uint8) ((pw == 8) ? 0xEC : 0xED));
                        return;
                    }
                }
                if (stem == "outb" || stem == "outw" || stem == "outl") {
                    int pw = (stem == "outb") ? 8 : ((stem == "outw") ? 16 : 32);
                    if (pw == 16) emitter.code.u8 (0x66);
                    if (op1.kind == AsmOpKind.IMM) {
                        emitter.code.u8 ((uint8) ((pw == 8) ? 0xE6 : 0xE7));
                        emitter.code.u8 ((uint8) op1.imm);
                        return;
                    }
                    if (op1.kind == AsmOpKind.REG && op1.reg == 2 && op1.width == 16) {
                        emitter.code.u8 ((uint8) ((pw == 8) ? 0xEE : 0xEF));
                        return;
                    }
                }
            }

            fail (rel_line, @"unsupported instruction or operand combination '$mnem'");
        }
    }
}
