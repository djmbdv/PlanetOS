# planc, slice 11: IEEE-754 `float` & `double` on x86-64-v3

Slice 11 adds native IEEE-754 `float` (binary32) and `double` (binary64) types,
operators, casts, runtime formatting/parsing, and the `xmm0`–`xmm7` floating-point
calling convention on x86-64-v3, while preserving self-hosted fixed-point
determinism (`sha256(planc2) == sha256(planc3)`).

Requirements demonstrated: **I1**, **I2**, **I3**, **I4**, **TC-05**, **VL-14**.

---

## 1. Lexing and deterministic literal parsing (`Ieee754`)

- `Lexer` (`planc/src/lexer.vala`) scans decimal floating-point literals with
  optional fractional part, `_` separators, scientific exponent (`e`/`E[+-]?d+`),
  and `f`/`F` (32-bit `float`) or `d`/`D` (64-bit `double`) suffixes, while
  preserving `1.to_string()` as `INTEGER` + `DOT` + `IDENTIFIER`.
- `Ieee754.parse_bits` (`planc/src/ast.vala`) converts decimal strings to exact
  IEEE-754 binary32/binary64 bit patterns using pure base-$2^{28}$ integer limb
  arithmetic and round-to-nearest-ties-to-even — zero `libc`/`strtod` dependency,
  bit-identical across Stage 0 (`valac`) and self-hosted stages (`planc1`/`planc2`).

## 2. Type system & conversions

- Added `ValaType.FLOAT` (`float`) and `ValaType.DOUBLE` (`double`).
- Implicit widening: `int` → `float`/`double`, `float` → `double` (in assignments,
  returns, arguments, ternary `?:`, and binary expressions).
- Explicit casts: `(int)`/`(int8..uint64)` truncation (`cvttsd2si` / `cvttss2si`),
  `(float)`, and `(double)`.
- Arithmetic (`+`, `-`, `*`, `/`, unary `-`, compound `+=`/`-=`/`*=`/`/=`) and
  IEEE-754 NaN-safe comparisons (`<`, `<=`, `>`, `>=`, `==`, `!=` via `ucomisd`/
  `ucomiss` + parity checks). Bitwise/modulo operators and `switch` on `float`/
  `double` are rejected (`VL-14`).
- Static constants & builtins: `{float,double}.{MIN,MAX,NAN,INFINITY}`,
  `{float,double}.parse(s)`, `.to_string()`, and `@"..."` string interpolation.

## 3. x86-64-v3 / SSE2 ABI & runtime

- **Calling convention (`docs/01-architecture.md`):** floating-point value
  parameters use `xmm0`–`xmm7` independently of GPR parameters (`rdi`–`r9`), with
  overflow args passed on the stack; floating-point return values travel in
  `xmm0` (unified across `generate_function` and all 4 call sites via
  `plan_call_abi` / `pop_call_regs`).
- **Runtime (`planc/src/emitter.vala`):** `__planc_double_to_str` and
  `__planc_str_to_double` handle `NaN`, `inf`/`-inf`, `0`, fixed decimal, and
  scientific notation without `libc`.

## 4. Verification

- `./planc/tests/run.sh`: **160 cases, 160 pass, 0 fail** (adds `float_double`,
  `check_leaks_float_double`, and `float_bitwise`).
- `./planc/bootstrap.sh`:
  - `planc2` & `planc3`: `f705ff13a40dc71ea78b31e8d20c2b1ccae88006fa47a1b701f8d439e3725b67` (`1251176` bytes).
  - ELF invariants: `ET_EXEC`, 3 `PT_LOAD` segments (`R E`, `R`, `RW`), zero `RWX`, empty `nm -u`.
  - Full suite under self-hosted `planc2`: **160 cases, 160 pass, 0 fail**.
