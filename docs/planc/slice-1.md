# planc, slice 1: variables, a stack frame and a real calling convention

Slice 0 proved the chain end to end with straight-line code. Slice 1 answers
the next question: **can the compiler generate functions that call each other
under one documented convention, keep locals on a frame the debugger can
walk, and branch?** Every later feature — closures, signals, `throws` — is
expressed in terms of these three things, which is why they come first.

Requirements demonstrated: **I1**, **I2**, **TC-02**, **TC-05**, **TC-08**
(still true: `nm -u` is empty, output is byte-identical across runs, gdb
walks frames) plus the first exercise of the calling convention defined in
[01-architecture.md §3.1](../01-architecture.md).

---

## 1. Source language coverage

```
program   := function+
function  := type IDENT '(' params? ')' block
type      := 'int' | 'void'
params    := 'int' IDENT (',' 'int' IDENT)*
block     := '{' statement* '}'
statement := 'print' '(' STRING ')' ';'
           | 'exit' '(' expr ')' ';'
           | 'return' expr? ';'
           | 'int' IDENT ('=' expr)? ';'
           | IDENT '=' expr ';'
           | 'if' '(' expr ')' stmt ('else' stmt)?
           | 'while' '(' expr ')' stmt
           | block
           | expr ';'
expr      := lor
lor       := land ('||' land)*
land      := cmp ('&&' cmp)*
cmp       := add (('<' | '>' | '<=' | '>=' | '==' | '!=') add)?
add       := mul (('+' | '-') mul)*
mul       := unary (('*' | '/' | '%') unary)*
unary     := ('-' | '!') unary | primary
primary   := INTEGER | IDENT | IDENT '(' args ')' | '(' expr ')'
```

Decisions the dialect makes, all of them deliberate:

- `int` is a **64-bit signed integer**. There is no `bool`: comparisons and
  logic yield `0` or `1`, and any expression may appear in a condition
  (`0` is false). A `bool` type arrives with the real type system.
- Locals have **function-level scope**: two declarations of the same name
  anywhere in one function are a semantic error, matching Vala's rejection of
  shadowing.
- A declaration without an initializer is **zero-initialized**; there is no
  "used before assigned" analysis yet (pass 6 of [02-compiler.md](../02-compiler.md)).
- `&&` and `||` **short-circuit** — the right operand is not evaluated when
  the left one decides. This is Vala's semantics, not C's, and the test
  suite proves it with a side effect that must not happen.
- Falling off the end of any function returns `0` in `rax`, so every exit
  code is deterministic even for `void main` (TC-05).
- `print` and `exit` stay builtins lowered to syscalls. `exit` now takes a
  full expression; `print` still takes a string literal only (printing a
  computed integer needs the runtime's string code, slice 3).

## 2. The calling convention, as implemented

From [01-architecture.md §3.1](../01-architecture.md), now enforced by codegen:

| Aspect | Rule | Status |
|---|---|---|
| Arguments | `rdi, rsi, rdx, rcx, r8, r9` | implemented; more than six is a positioned semantic error |
| Return | `rax` | implemented |
| Callee-saved | `rbx`, `rbp`, `r12`–`r15` | codegen touches only `rbp`, so nothing can be violated yet |
| Alignment at `call` | 16 bytes | enforced statically, see below |
| Red zone | none | no code reads below `rsp` |
| Stack arguments | right to left | **deferred**: >6 arguments are rejected |

### The alignment rule

At every `call` instruction `rsp` must be 16-byte aligned. Codegen tracks the
number of live intermediate pushes statically (`push_depth`): expression
trees spill their left operand with `push rax` across the evaluation of the
right one, and calls may nest inside that. Pushes and pops cancel in pairs,
so only the live depth decides:

- depth even: nothing to do;
- depth odd: `sub rsp, 8` **after** the argument registers are loaded, `call`,
  `add rsp, 8` afterwards. The pad sits below everything live, so no value
  moves, and the two instructions cancel exactly.

The first implementation got this wrong in two ways worth recording: padding
before popping the argument registers made the pops read the pad instead of
the arguments (recursion returned garbage), and keying the parity to
`depth + args` instead of `depth` was simply the wrong sum. Both were caught
by `tests/valid/alignment.vala` and `recursion.vala`, not by inspection.

### Entry: `_start`, not `main`

`main` is now called like any other function. The generated `_start` stub is
the entry point:

```
xor    ebp, ebp          ; 31 ED       outermost frame marker for backtraces
and    rsp, -16          ; 48 83 E4 F0
call   main              ; E8 rel32
mov    edi, eax          ; 89 C7       exit code = main's return value
mov    eax, 60           ; B8 3C 00 00 00
syscall                  ; 0F 05
```

This gives every function — `main` included — the same entry convention
(`rsp % 16 == 8`), makes `int main()` the way to produce an exit code, and
keeps `exit(n)` available as a direct syscall for early exits. `e_entry`
points at `_start`, which is a real symbol in `.symtab`.

## 3. Stack frame

```
        entry            rsp % 16 == 8   (return address pushed)
push rbp                 rsp % 16 == 0
mov rbp, rsp             frame base
sub rsp, 16k             locals, 16-aligned
```

Every value lives at `[rbp - 8*(slot+1)]`: parameters spill there in the
prologue (`rdi` → slot 0, `rsi` → slot 1, …), locals get the following slots.
There is **no register allocation yet** — every variable access is a load or
store through `rbp`. That is a slice decision: the frame-pointer discipline
is what makes gdb backtraces work (verified below), and a register allocator
built on top of a correct frame is easier to trust than one built in its
place. `return` uses `leave; ret` from any nesting depth, which is exactly
why `rbp` discipline exists.

Frame sizes come from a pre-pass that counts declarations in the body
(including blocks inside `if`/`while`), because the `sub rsp` immediate must
be known when the prologue is emitted.

## 4. Control flow and the second relocation class

Branches use labels bound during generation; the `rel32` fields are written
zero and resolved after the final layout, exactly like the rip patches of
slice 0 — but targeting `.text` instead of `.rodata`:

```
BranchPatch { displacement (offset of rel32 in .text), kind, label }
delta = label.target - (displacement + 4)      checked against int32
```

Backward jumps (loop edges) are bound before the patch is recorded, forward
jumps after; the mechanism does not care. Encodings: `jmp E9`, `je 0F 84`,
`jne 0F 85`, `jl 0F 8C`, `jle 0F 8E`, `jg 0F 8F`, `jge 0F 8D`, all rel32.
Comparisons are `cmp rax, rcx` + `setcc al` + `movzx eax, al`, so a
comparison is an ordinary value. Conditions are `test rax, rax` + `je/jne`.

Calls are the third relocation class: `call rel32` (`E8`) records a
`CallPatch { displacement, callee }`, resolved against the symbol table once
all function sizes are known. Forward and recursive references fall out of
resolving after layout — no declaration order is imposed on source.

## 5. Semantic analysis

The parser no longer rejects only on syntax; codegen performs a first
semantic pass and reports positioned diagnostics through a new
`SemanticError` domain, printed as `planc: semantic error: …`:

| Check | Diagnostic |
|---|---|
| reference to an unknown variable | `unknown variable: x at l:c` |
| duplicate declaration in one function | `duplicate variable: x at l:c` |
| call to an unknown function | `unknown function: f at l:c` |
| wrong argument count | `f expects 2 argument(s), got 3 at l:c` |
| more than six arguments | `more than 6 arguments are not supported yet` |
| `void` call used as a value | `void function 'f' cannot be used as a value at l:c` |
| `return` with/without value against the return type | `RETURN_MISMATCH` |
| `main` with parameters | `main takes no parameters at l:c` |

The checks live in codegen, not in a separate pass, because there is no
symbol table yet: function signatures are looked up directly in the program.
A dedicated analysis pass appears when the type system does.

## 6. Verification

```sh
./planc/build.sh
./planc/tests/run.sh     # 42 cases, 42 pass
```

- **Valid (25):** the six slice-0 cases still pass unchanged, plus `arith`
  (precedence), `vars`, `calls`, `recursion` (factorial), `while_loop`,
  `if_else`, `comparisons`, `shortcircuit` (side effect must not happen),
  `divmod`, `negative`, `zero_init`, `nested_calls`, `six_args`,
  `alignment` (odd live-push depth across nested calls), `void_call`,
  `exit_expr`, `not_operator`, `big_literal` (the `movabs` path, 1234567890123),
  `return_in_loop` (return from inside `while`/`if`). Each still must satisfy
  `ET_EXEC`, exactly two `PT_LOAD`, no RWX segment, empty `nm -u`.
- **Invalid (17):** the slice-0 syntax cases plus the semantic ones listed in
  §5. Each must exit 1, write no output file, and carry `line:column`
  (except whole-program conditions).

One slice-0 invalid case was **retired**: `non_void_main` rejected `int
main()`, which is now the supported way to return an exit status.

Determinism (TC-05) and debuggability (TC-08), measured on the factorial
program:

```
$ sha256sum d1 d2            # same program compiled twice
75b7fb1f…  d1
75b7fb1f…  d2
$ nm -u d1 | wc -l           # undefined symbols
0
$ gdb -batch -ex 'break fact' -ex run -ex bt ./d1
#0  … in fact ()
#1  … in main ()
```

## 7. Vala constraints hit while writing this

New since slice 0, same rule: language facts, not opinions.

- `GenericArray` has **no `remove_at`** (glib-2.0 vapi); the per-function
  local list is reset by reassigning a fresh array instead.
- Enums cannot declare instance **properties** (`public bool extended { get … }`
  in an enum is rejected: *properties are not allowed in `Reg'*); a static
  method does the job.
- Enum values in arithmetic need an explicit cast: `0x50 + (r & 7)` does not
  compile, `((int) r & 7)` does.

## 8. What slice 1 deliberately does not do

| Missing | Consequence | Where it is specified |
|---|---|---|
| Strings and arrays as values | `print` takes literals only | [03-runtime-and-stdlib.md](../03-runtime-and-stdlib.md) |
| `bool`, unsigned, narrower integers | `int` is the only type | [01-architecture.md §3.2](../01-architecture.md) |
| More than six arguments, stack arguments | positioned error at the call | [01-architecture.md §3.1](../01-architecture.md) |
| Globals, `.bss`, writable data | no state between calls | [02-compiler.md](../02-compiler.md) |
| `switch`, `do`, `for`, `break`, `continue` | loops are `while` only | [02-compiler.md](../02-compiler.md) |
| Register allocation | every access is a memory access | [02-compiler.md](../02-compiler.md) |
| Relocatable objects, separate compilation | single translation unit | [02-compiler.md](../02-compiler.md) |
| DWARF line tables | gdb sees functions, not lines | [02-compiler.md](../02-compiler.md) |
| `[AsmBody]` | the mechanism kernel code depends on | [04-kernel.md](../04-kernel.md) |
| Self-hosting | still built by `valac` (stage 0) | [06-verification.md](../06-verification.md) |

The next slice is the one the ABI table above makes obvious: more than six
arguments requires stack arguments, and the register allocator removes the
load/store round trips. Both are compiler-internal; the language side grows
next with globals and the first real data types.
