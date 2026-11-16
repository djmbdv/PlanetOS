# Slice 41: C → Vala feasibility probe

## Goal

Answer "how feasible is a C → Vala translator?" with measurements instead of
opinions. The probe parses real C, classifies every construct in three tiers
and reports what a translator would actually have to handle:

* **tier 0** — translates directly: functions, scalars, arrays, arithmetic,
  `if`/`while`/`for`/`do`, calls, casts, `sizeof`.
* **tier 1** — mechanical rewrite: pointers, structs, enums, typedefs,
  `switch`, initializer lists.
* **tier 2** — blocks a faithful translation: unions, bitfields, varargs,
  function pointers, `goto`/labels, VLAs, `_Atomic`, `setjmp`/`longjmp`,
  SIMD intrinsics.

The headline number is not "how many lines" but **how many functions have no
tier-2 construct**, plus the **libc call histogram**, which is the shopping
list for a runtime shim.

## How the probe works (`tools/c_coverage.py`)

1. Preprocess with a real preprocessor (`gcc -E -nostdinc`) against a **fake
   libc** shipped inside the tool (`stdio.h`, `stdlib.h`, `string.h`,
   `stdint.h`, `stdarg.h`, `math.h`, `time.h`, … plus `xmmintrin.h`/
   `emmintrin.h`/`immintrin.h` declaring `__m128`/`__m128i`/`__m256`). Real
   system headers drag in GCC extensions that pycparser rejects, and with
   `-nostdinc` the parse depends only on the project's own code.
2. Unknown headers are **auto-stubbed** (empty file, retry loop, up to 40) so a
   missing `linux/module.h` does not abort the run; the stub list is reported
   per file, because "5 missing project headers" is itself a finding.
3. `#line` markers are used for **provenance filtering**: lines coming from the
   fake/stub headers are excluded from every count. Without it, `libc_calls.c`
   reported 105 pointers instead of 13 and 7 varargs from `printf` prototypes
   alone.
4. `pycparser` builds the AST; two visitors count blockers/features per
   function and per file, and collect call targets.

Usage:

```sh
python tools/c_coverage.py tools/corpus            # deterministic fixtures
python tools/c_coverage.py path/to/corpus --json /tmp/cov.json
python tools/c_coverage.py lib.c -D SOME_IMPL -I include -I third_party
```

## Bugs the fixtures caught (why `tools/corpus/` exists)

Eight hand-written C files with known answers; the probe was wrong four times
before they went green:

| Fixture | Functions | Clean | Blockers |
|---|---|---|---|
| `clean_math.c` | 3 | 3 | — |
| `pointers.c` | 3 | 3 | — |
| `structs_enums.c` | 2 | 2 | — |
| `libc_calls.c` | 2 | 2 | — |
| `callbacks.c` | 3 | 1 | function pointers ×3 |
| `gotos_vla.c` | 2 | 0 | goto, label, VLA |
| `unions_bitfields.c` | 1 | 0 | union ×2, bitfield ×3 |
| `varargs.c` | 1 | 0 | varargs |
| **total** | **17** | **11 (64.7 %)** | 4/8 units without blockers |

Defects found and fixed: the fake headers were not self-contained (`size_t`
undefined when a unit included `stdlib.h` without `stddef.h`), function
pointers behind a `typedef` were invisible, prototype `...` counted as a
blocker, and a `->` member access crashed the name helper.

## Real corpus

Public single-file libraries and two Linux drivers, fetched into `%TEMP%`
(never committed):

| Unit | Kind | Functions | Clean | Main blockers |
|---|---|---|---|---|
| `stb_image.h` (`-D STB_IMAGE_IMPLEMENTATION`) | image decoder | 210 | 204 (97 %) | SIMD intrinsics |
| `cJSON.c` | JSON library | 113 | 105 (93 %) | `goto` 43, labels 10, function pointers 5 |
| `jsmn.h` | JSON tokenizer | 6 | 5 (83 %) | `goto`/label (error path) |
| **combined** | | **329** | **314 (95.4 %)** | |
| `miniz.c` | compression | — | — | not self-contained: includes 5 project headers |
| `ledtrig-heartbeat.c` | kernel driver | — | — | needs the kernel header tree |
| `charlcd.c` | kernel driver | — | — | needs the kernel header tree |

Blockers across the library corpus: **SIMD intrinsics 564**, `goto` 44,
function pointers 24, labels 11, VLAs 8. Tier-1 load: pointers 2360, casts
1464, calls 1686, structs 32, switches 18.

libc surface (the shim a tier-1 translator needs): **170 call sites over 22
functions**, dominated by `free` (59), `memcpy` (22), `memset` (20),
`strncmp`/`strcmp` (14), `fclose`/`fopen`/`fread`/`fseek`/`ftell` (16),
`strlen` (6), `sprintf` (6), `strcpy` (5), `fabs`/`sqrt`/`pow` (9),
`strtol`/`strtod` (5), `tolower` (4), `malloc`/`realloc` (3), `abs` (1).

## Reading the numbers

* **~95 % of library functions have no structural blocker.** The blockers are
  concentrated: SIMD kernels (`stbi__idct_simd`), `goto`-based cleanup paths
  (cJSON), and callback/vtable code. A translator can ship without them and
  refuse those functions by name.
* **The dominant cost is tier 1, not tier 2**: 2360 pointer nodes and 1464
  casts in 329 functions. That is mechanical but pervasive — it is where the
  work is.
* **Libraries are self-contained; drivers are not.** Both kernel drivers fail
  before parsing because `u32`, `struct file_operations` and `module_*` come
  from headers that cannot be stubbed meaningfully. Drivers also rely on
  struct-of-function-pointers vtable dispatch (tier 2).
* **Macro expansion hides complexity.** Because the probe runs *after* `cpp`,
  macro-heavy code looks simple. That means these numbers are an **upper bound**
  on translatability: they measure syntax difficulty, not ownership/aliasing
  difficulty, which is the real risk for a GC'd target like Vala.

## Recommendation

Proceed with a **tier-0 + tier-1 translator** fed by a preprocessor, targeting
in this order: pure functions → typed pointers → a ~22-function libc shim →
per-function refusal report. Leave SIMD, `goto` cleanup paths, function
pointers and unions out of scope with an explicit diagnostic, and validate
with differential tests against gcc (same input, same stdout).

## Known limitations (of the probe, not of a translator)

- No type inference: pointer arithmetic, aliasing and lifetime are invisible.
- `goto`/labels are counted per function, not per control-flow graph, so some
  of those functions are trivially rewritable.
- Preprocessed input means macro complexity and conditional compilation are
  not measured.
- Auto-stubbing can make a unit *parse* while its types are wrong; the
  `stubs=N` column is the warning sign.
- The fake libc covers C89/C99 basics only; POSIX and platform APIs appear as
  ordinary external calls.
