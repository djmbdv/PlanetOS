# Slice 56 — operator pipeline: bounded recursion and cheaper integer operators

Analysis of how `planc` handles operators (`lexer` → `parser` → `opt` → AST codegen →
`PuzzleRA`) found two defects and several easy instruction-selection wins. All are
implemented here; the dialect is unchanged.

## 1. Expression recursion no longer overflows the compiler stack

**Symptom.** A flat chain such as `a+b+a+b+…` crashed the compiler at ~64 operators
(`0xC00000FD`, `STATUS_STACK_OVERFLOW`) at `-O0`, and at ~70 at `-O1`. A *balanced*
tree of 65 535 operators compiled fine, so the problem was depth, not size.

**Cause.** `Vala` compiles `gen_expr_impl` and `expr_type_full` into single C functions
with one stack slot per temporary, so each recursive level cost
**32 KB** (`mov $0x7d28,%eax` / `mov $0x7ec8,%eax` before `___chkstk_ms`). With a 1 MB
stack that is ~30 levels of headroom, not 64.

**Fix.**
- `codegen.vala`: the `BinaryExpr` branch of `gen_expr_impl` moved to `gen_binary ()`
  and the `BinaryExpr` branch of `expr_type_full` moved to `type_of_binary ()`, so the
  recursive frames shrank to **200 B** and **232 B** (~100× smaller).
- Explicit depth guards: `MAX_EXPR_DEPTH = 400` in `gen_expr`, `expr_type_full` and
  `prepare_expr` (each wrapped in `try/finally` so the counter never leaks), `600` in
  `Optimizer.opt_expr` (deeper subtrees are left unoptimized) and `600` in
  `PuzzleRA.check_expr_supported` (deeper functions fall back to the AST path).
  Exceeding the limit is now a positioned diagnostic:

  ```
  x.vala:4:12: semantic error: expression nested too deeply (more than 400 levels)
  ```

Measured after the change: `-O0` compiles 399 chained operators and rejects 405 with
that diagnostic (it used to crash at 64).

## 2. Division and modulo by a power of two leave `idiv` out

`idiv` costs 20–40 cycles and, in `PuzzleRA`, pins `rax`/`rdx` while forcing the divisor
into `rcx`, which creates puzzle constraints and extra moves. `x / 2^k` and `x % 2^k`
now lower to shifts:

| Form | Unsigned | Signed |
|---|---|---|
| `x / 2^k` | `shr x, k` | `sar (x + ((x >> 63) & (2^k-1))), k` |
| `x % 2^k` | `and x, 2^k-1` | `x - ((x / 2^k) << k)` |

The sign bias keeps C semantics (truncation toward zero) for negative operands, which a
plain `sar` would get wrong. Two implementations: instruction selection in
`gen_binary` (AST backend, `-O1`) and an IR decomposition in `PuzzleRA.lower_expr`
(`-O2`, so the allocator never sees the `idiv` constraints). `k > 31` (divisors above
2³¹) still uses `idiv` for `%`; `x / 1` and `x % 1` fold to `x` and `0`.

## 3. Fewer instructions for small constants and for `reg + reg`

| Case | Before | After |
|---|---|---|
| `x * 2`, `* 3`, `* 5`, `* 9` | `imul` | `lea d, [x + x*2^k]` |
| `d = l + r` (three registers) | `mov d, l` + `add d, r` | `lea d, [l + r]` |

`emit_lea_index ()` refuses to encode an `rsp`/`r12` index (SIB index `100` means "no
index") and returns `false` so the caller falls back — `r12` is allocatable, and
emitting the wrong form silently dropped the addend.

## 4. Operator dispatch without `g_strcmp0`

`op == "+"` compiles to a `g_strcmp0` call in Vala. The condition-code helpers that run
once per comparison (`setcc`, `inverted_branch`, `direct_branch` in `codegen.vala`;
`cmp_cc`, `inverted_br` in `puzzle_ra.vala`) now dispatch on `op[0]` and `op.length`,
which removes 5–6 calls per emitted comparison.

## Measured

Division-heavy loop (`s += a[i]/8 + a[i]%8 + a[i]*3`, 20 M iterations,
`--target=windows`, best of 5):

| Compiler | `-O1` | `-O2` |
|---|---|---|
| before | 154.6 ms | 149.3 ms |
| after | 77.0 ms | **48.9 ms** |

Self-compile of `planc/src/*.vala` (200 k lines, `--target=planetos`):

| Level | before | after |
|---|---|---|
| `-O0` | 1.55 s wall / 5.56 s CPU | 1.05 s wall |
| `-O2` | 1.67 s wall / 7.89 s CPU | 1.37 s wall / 5.67 s CPU |

The generated code was checked against the `idiv` path for every operand in
`[-2000, 2000]`, for `int64` extremes (`INT64_MIN`, `INT64_MAX`, ±2⁴⁰) and for
`uint64` up to `UINT64_MAX`, at `-O0`, `-O1` and `-O2` (`planc/tests/valid/divmod_constants.vala`).

## Tests added

| Case | What it pins |
|---|---|
| `valid/divmod_constants.vala` (`.out`, `.code`, plus `-O1`/`-O2` runs) | reduced `/` and `%` match the `idiv` path for signed, unsigned and extreme values |
| `valid/deep_expr_chain.vala` (`.code`, plus `-O2` run) | a 300-operator chain compiles (it used to crash) |
| `invalid/expr_too_deep.vala` | 500 levels is a positioned diagnostic, not a stack overflow |

## Not done (deliberately)

- **Magic-number division** for non-power-of-two divisors needs `mulhi` (`rdx:rax`) plus
  signed correction; only power-of-two divisors were taken because they need no new
  register constraints.
- **`enum BinOp` in the AST**: 440 `op`/`sop` string comparisons remain across
  `codegen`/`opt`/`puzzle_ra`; converting them is mechanical but touches every
  expression site, so only the hottest helpers were switched to character dispatch.
- **A per-expression type cache** stays blocked on `non_null_vars` narrowing state
  (see [slice 51](slice-51-throughput.md)).
