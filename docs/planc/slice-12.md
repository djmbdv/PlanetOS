# planc, slice 12: `[AsmBody]` & built-in x86-64 assembler (`TC-04`, `VL-09`, `I5`)

Slice 12 implements the `[AsmBody("...")]` function/method attribute and a
self-contained AT&T-syntax x86-64 assembler inside `planc` (`planc/src/asm.vala`),
allowing privileged and low-level machine instructions to live directly inside
Vala declarations without invoking an external `as`.

Requirements demonstrated: **I1**, **I2**, **I4**, **I5**, **TC-02**, **TC-04**,
**TC-05**, **TC-08**, **VL-09**.

---

## 1. Attribute & declaration parsing (`planc/src/parser.vala`, `ast.vala`)

- Added `parse_attributes` for `[AsmBody("...")]` / `[AsmBody(@"...\n")]` and
  general `[Attr(...)]` attributes on top-level functions and class methods.
- Added `extern` modifier support; `[AsmBody]` functions may terminate with `;`
  or `{}` and carry `is_asm_body`, `asm_body`, `asm_line`, and `asm_column` on
  `Function`.
- In `Codegen.generate_function`, `[AsmBody]` functions emit their assembled
  machine code directly at the function symbol offset without injecting a Vala
  stack prologue/epilogue, supporting naked/leaf, ISR, context-switch, and
  `_start` routines.

## 2. Built-in x86-64 assembler (`planc/src/asm.vala`)

- **Syntax:** AT&T operand order (`op src, dst`), `%reg`, `$imm` (decimal/hex/
  binary/negative), `disp(%base,%index,scale)`, `sym(%rip)`, `#`/`//` comments,
  `;` or newline separators, local labels (`label:`) with forward/backward
  fixups, and `call` to Vala functions via `CallPatch`.
- **Directives & prefixes:** `.global`/`.globl`, `.align`/`.p2align`, `.byte`,
  `.word`, `.long`, `.quad`, and `lock`.
- **Instruction coverage:**
  - Data & ALU: `mov[bwlq]`, `movz*`, `movs*`, `lea[q]`, `push`/`pop`, `xchg`,
    `add`, `sub`, `and`, `or`, `xor`, `cmp`, `test`, `inc`, `dec`, `neg`, `not`,
    `shl`/`sal`/`shr`/`sar`/`rol`/`ror`, `mul`/`imul`/`div`/`idiv`, `bt`/`bts`/
    `btr`/`btc`, `cqo`/`cdq`/`cdqe`.
  - Control flow: `jmp`, `jcc` (`je`/`jne`/`jl`/`jle`/`jg`/`jge`/`jb`/`jbe`/
    `ja`/`jae`/`js`/`jns`/`jp`/`jnp`), `setcc`, `call`, `ret`/`retq`, `int`,
    `iretq`, `syscall`, `sysretq`.
  - Privileged / kernel (`VL-09`, `I5`): `cli`, `sti`, `hlt`, `nop`, `pause`,
    `clc`/`stc`/`cld`/`std`, `pushfq`/`popfq`, `swapgs`, `rdmsr`, `wrmsr`,
    `rdtsc`, `cpuid`, `invlpg`, `lgdt`, `lidt`, `sgdt`, `sidt`, `ltr`,
    `fxsave`, `fxrstor`, `mfence`/`lfence`/`sfence`, `wbinvd`, `ud2`, `int3`,
    `inb`/`inw`/`inl`, `outb`/`outw`/`outl`, and `%cr0`/`%cr2`/`%cr3`/`%cr4`/
    `%cr8` + segment register moves.
- **Diagnostics (`TC-08`):** invalid mnemonics, operands, or undefined labels
  emit positioned `[AsmBody]` errors.

## 3. Verification

- `./planc/tests/run.sh`: **163 cases, 163 pass, 0 fail** (adds `asm_body`,
  `check_leaks_asm_body`, and `asm_unknown_insn`).
- `./planc/bootstrap.sh`:
  - `planc2` & `planc3`: `da53c89a4a3e134f398249f5ac7e7049658d37cff20ae936c2d87b40b225887d` (`1343360` bytes).
  - ELF invariants: `ET_EXEC`, 3 `PT_LOAD` segments (`R E`, `R`, `RW`), zero `RWX`, empty `nm -u`.
  - Full suite under self-hosted `planc2`: **163 cases, 163 pass, 0 fail**.
