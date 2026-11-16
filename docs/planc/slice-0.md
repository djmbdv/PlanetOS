# planc, slice 0: a binary with nothing behind it

Slice 0 exists to answer one question before any design document is worth
trusting: **can a compiler written in Vala produce an x86_64 executable that
runs without libc, without a linker and without an assembler?**

It can. This document records exactly what is implemented, which bytes come out,
and what is deliberately absent.

Requirements this slice is meant to demonstrate: **I1**, **I2**, **TC-02**,
**TC-05** and **TC-08** in [00-requirements.md](../00-requirements.md).
KR-03 (no RWX segment) is also enforced and tested.

---

## 1. Source language coverage

The accepted grammar is exactly:

```
program    := function+
function   := 'void' IDENTIFIER '(' ')' '{' statement* '}'
statement  := ('print' '(' STRING ')' | 'exit' '(' INTEGER ')') ';'
```

`print` and `exit` are **not** library calls and not keywords: the parser treats
them as builtins and lowers them directly to syscalls. There are no variables,
no expressions, no control flow, no user functions beyond `main`, no types other
than `void`, and no parameters. Anything else is rejected with a positioned
diagnostic.

Two consequences worth stating, because they are mistakes the slice avoids:

- The entry point is `main` itself. There is no `_start` and no runtime
  prologue: `e_entry` is the address of the `main` symbol in `.text`.
- Falling off the end of `main` emits `exit(0)` explicitly. The process never
  returns to anything, because there is nothing to return to.

### String literals

`print("...")` accepts the escapes `\n`, `\t`, `\r`, `\\`, `\"` and `\0`. The
emitted length is the UTF-8 **byte** count, which is what `write(2)` wants. This
was verified rather than assumed: in Vala both `s[i]` and `s.data` yield raw
UTF-8 bytes, and `s.data.length == s.length` even for `"añb"` (4 bytes). The
buffer uses `s.data`, so a multi-byte literal is emitted verbatim.

## 2. Pipeline as implemented

| Stage | File | Output |
|---|---|---|
| Byte buffer | [buffer.vala](../../planc/src/buffer.vala) | little-endian writers over `uint8[]` |
| Lexer | [lexer.vala](../../planc/src/lexer.vala) | `TokenKind` + `Token` with `line`/`column` |
| AST | [ast.vala](../../planc/src/ast.vala) | `Program`, `Function`, `PrintStatement`, `ExitStatement` |
| Parser | [parser.vala](../../planc/src/parser.vala) | recursive descent, `ParseError` domain |
| Emitter | [emitter.vala](../../planc/src/emitter.vala) | `.text` bytes, `.rodata` bytes, pending rip patches |
| Codegen | [codegen.vala](../../planc/src/codegen.vala) | statement → instruction sequence, symbol table |
| ELF writer | [elf.vala](../../planc/src/elf.vala) | headers, layout, segments, sections, `.symtab` |
| Driver | [main.vala](../../planc/src/main.vala) | CLI, relocation resolution, file output |

The ELF writer **is** the assembler and the linker for this slice: there is no
intermediate object format and no archive. That is a slice-0 simplification, not
the target architecture — [02-compiler.md](../02-compiler.md) specifies a real
relocatable object format so that separate compilation can exist.

## 3. Emitted instructions

Every encoding is a hand-written function with its bytes documented in the
source. The full set used by slice 0:

| Instruction | Encoding | Used for |
|---|---|---|
| `mov eax, imm32` | `B8` + imm32 | syscall number |
| `mov edi, imm32` | `BF` + imm32 | fd / exit code |
| `mov edx, imm32` | `BA` + imm32 | byte count for `write` |
| `xor edi, edi` | `31 FF` | `exit(0)` without a 4-byte immediate |
| `syscall` | `0F 05` | all syscalls |
| `lea rsi, [rip+disp32]` | `48 8D 35` + disp32 | string address, patched after layout |

`objdump -d` on a compiled `print("hello\n")` shows exactly:

```
00000000004000b0 <main>:
  4000b0:	b8 01 00 00 00       	mov    $0x1,%eax
  4000b5:	bf 01 00 00 00       	mov    $0x1,%edi
  4000ba:	48 8d 35 3f 0f 00 00 	lea    0xf3f(%rip),%rsi        # 401000 <main+0xf50>
  4000c1:	ba 11 00 00 00       	mov    $0x11,%edx
  4000c6:	0f 05                	syscall
```

## 4. The first relocation

`lea rsi, [rip+disp32]` cannot be encoded before the final layout is known, so
the emitter records a `RipPatch { displacement, target }` and writes a zero
displacement. The driver resolves it after `Elf.compute`:

```
next    = text_vaddr + patch.displacement + 4
target  = rodata_vaddr + patch.target
disp32  = target - next                     (checked against int32)
```

This is a real, if minimal, relocation pass: it is the same shape that
`R_X86_64_PC32` will need in the full compiler, including the range check that
rejects a reference that does not fit.

## 5. Image layout

```
file offset   content                          segment        vaddr
0x0000        ELF64 header (64 B)              PT_LOAD R|X    0x400000
0x0040        program header 0 (56 B)                         
0x0078        program header 1 (56 B)                         
0x00b0        .text                            PT_LOAD R|X    0x4000b0
page-aligned  .rodata                          PT_LOAD R      0x401000
8-aligned     .symtab                          not loaded
              .strtab                          not loaded
              .shstrtab                        not loaded
8-aligned     section headers (6 × 64 B)       not loaded
```

Two `PT_LOAD` segments, never one with `W` and `X` together. `p_memsz` equals
`p_filesz` because there is no `.bss` yet. The three non-allocated sections live
past the last segment's `p_filesz`, so nothing maps them.

`e_entry` is the `main` symbol's address, and the symbol table carries exactly
one global `STT_FUNC` symbol.

### Why section headers were not optional

The first working version wrote program headers only, no sections. The binary ran
correctly — and `nm` said `no symbols` while `objdump -d` printed an empty
disassembly, because both tools look for section headers before anything else.
GDB still debugged it, and `readelf -l` still showed the segments, which is
exactly the trap: the artifact *worked* while being uninspectable.

Since TC-08 and the verification strategy in [06-verification.md](../06-verification.md)
depend on being able to disassemble and symbolicate the output, section headers
plus `.symtab`/`.strtab`/`.shstrtab` became part of slice 0. The lesson is
recorded here because it generalises: **"it runs" is a weaker property than "it
can be inspected".**

## 6. Syscalls, and why they are Linux's

Slice 0 targets the host, because the kernel does not exist yet. The numbers are
therefore Linux x86_64 numbers:

| Platform | write | exit | Note |
|---|---|---|---|
| Linux x86_64 (current test target) | `1` | `60` | used by this slice |
| `planetos` (target) | TBD | TBD | assigned in [05-userland-and-abi.md](../05-userland-and-abi.md) |

This is an explicit bootstrap decision, not a design statement. Two things make
it safe to postpone:

1. The syscall number is a **constant in the generator**, not an ABI leak. Moving
   to the target means filling a per-platform table.
2. What the slice actually proves is independent of which syscall it calls: the
   binary contains no call to any external symbol, so `nm -u` is empty and no
   dynamic loader is involved.

The register convention used is already the one the target will keep — `rax` for
the number and `rdi, rsi, rdx, r10, r8, r9` for the arguments — because `syscall`
clobbers `rcx` and `r11`.

## 7. Verification

```sh
./planc/build.sh
./planc/tests/run.sh
```

14 cases, all passing:

- **Valid (6):** `hello`, `multi` (two writes plus comments), `exit_code`
  (`exit(42)`), `empty` (empty body), `fallthrough` (implicit `exit(0)`),
  `escapes` (`\t` inside a literal). Each one must additionally satisfy, on the
  produced binary: `ET_EXEC`, exactly two `PT_LOAD`, no `RWE` flag, empty
  `nm -u`.
- **Invalid (8):** `missing_semicolon`, `unknown_function`,
  `unterminated_string`, `no_main`, `stray_character`, `print_needs_string`,
  `non_void_main`, `exit_needs_integer`. Each must exit 1, write no output file,
  and produce a diagnostic starting with `planc: ` carrying `line:column` — the
  only exception being `no_main`, which is a whole-program condition.

Determinism (TC-05) was checked by compiling twice and comparing digests:

```sh
$ planc hello.vala -o hello && planc hello.vala -o hello2
$ sha256sum hello hello2
12e8011b...  hello
12e8011b...  hello2
```

## 8. Vala constraints hit while writing this

These are language facts, not opinions, and they carry into the real compiler:

- Array indices are `int`. Using `size_t` in a loop variable fails with
  *Cannot convert from `size_t' to `long'*.
- `GenericArray<T>` requires `T` to be a reference type. A `struct` element type
  is rejected with *use `?' to box value types*; both `RipPatch` and `Symbol` are
  therefore `class … : Object`.
- `[Compact]` must sit on its own line before the class, and `GenericArray.add`
  on a compact instance triggers *duplicating instance, use unowned variable or
  explicitly invoke copy method*.
- Iterating a `GenericArray` with `var` yields a strong reference, so returning
  an element from a method declared `unowned` requires `foreach (unowned var …)`.
- A `const string` containing `NUL` bytes is truncated at the first one, because
  Vala passes it as a C string literal. `.shstrtab` is therefore built from
  separate literals.
- `dynamic` is a contextual keyword: `var dynamic = new int[4];` compiles, but
  `dynamic[0] = 9;` fails with *syntax error, expected identifier*.

## 9. What slice 0 deliberately does not do

| Missing | Consequence | Where it is specified |
|---|---|---|
| Variables, expressions, control flow | programs are straight-line writes | [02-compiler.md](../02-compiler.md) |
| Calls to user functions | no calling convention exercised yet | [01-architecture.md](../01-architecture.md) |
| Relocatable objects, linker | single translation unit only | [02-compiler.md](../02-compiler.md) |
| `.bss`, writable data | no globals or heap | [02-compiler.md](../02-compiler.md) |
| Stack frame setup | leaf code only, no `rbp` discipline | [02-compiler.md](../02-compiler.md) |
| DWARF | no line table, no variable info | [02-compiler.md](../02-compiler.md) |
| `[AsmBody]` | the mechanism kernel code depends on | [04-kernel.md](../04-kernel.md) |
| Self-hosting | slice 0 is built by `valac` (stage 0) | [06-verification.md](../06-verification.md) |

The next slice adds variables, a stack frame and a real calling convention,
because every later feature — closures, signals, `throws` — is expressed in
terms of them.
