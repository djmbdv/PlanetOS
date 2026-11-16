# Slice 42: C → Vala translator (tier 0/1) with differential tests

## Goal

Turn the numbers from slice 41 into code: a translator that handles the
**tier-0 + tier-1** subset, refuses the rest with a diagnostic, and is verified
by **differential testing** — the same source compiled by gcc and translated to
Vala must print identical output. The first real case is `jsmn`, as agreed.

## Translator (`tools/c2vala.py`)

Pipeline: reuse the probe's preprocessor (`gcc -E -nostdinc` + fake libc +
auto-stubbed headers), parse with pycparser, translate, emit Vala.

**Type mapping**

| C | Vala |
|---|---|
| `int`, `char`, `short`, `long`, `unsigned …`, `size_t`, `int32_t`… | same kind (`uint`, `uchar`, `size_t`, `int32`…) |
| `_Bool` | `bool` |
| `typedef enum {…} T` | `public enum T` with **constant-folded** values (`1 << 0` → `1`) |
| `typedef struct {…} T` | `public class T` (reference semantics) |
| `T *` (object-ish) | `T?` — nullable reference |
| `T *` used as `x[i]` / `&x[i]`, or forwarded to such a parameter | `T[]` |
| `char *` | `string` (indexing yields `char`) |

**Explicit rewrites** (each one is a documented, testable rule):

- `token->field` → `((T) token).field` — Vala has no `!` non-null assertion;
  an explicit cast is the documented way to dereference a nullable reference.
- `&tokens[i]` → `tokens[i]` (array elements are already references).
- Uninitialized struct local → `new T ()`; struct array → allocated element by
  element (`new T[n]` leaves nulls).
- `a = b = c;` → two statements (Vala has no chained assignment).
- `goto L` where `L` labels a statement after the enclosing loop → a boolean
  flag, `break` out of the switch, and a guarded `break` at the end of the loop
  body. Any other `goto` shape is refused.
- `printf` → `stdout.printf`, `fprintf(f, …)` → `f.printf(…)`, `strlen`/
  `strcmp`/`strncmp` → `c_strlen`/`c_strcmp`/`c_strncmp` from
  [tools/c2vala_rt.vala](c2vala_rt.vala).
- Integer promotions: every binary operand pair is promoted to the common C
  kind and cast explicitly (`(size_t) parser.pos < len`), because Vala rejects
  mixed integer comparisons.

**Refusals** (exit status 2 with `file:line: reason`): unions, bitfields,
function pointers, varargs, VLAs, initializer lists, `sizeof` of aggregates,
pointer arithmetic other than indexing, switch fallthrough with statements,
global variables, unknown functions.

## Differential harness (`tools/c2vala_tests/run.py`)

For each case directory: `gcc -std=c99` the sources and run them, translate to
Vala, `valac --pkg=glib-2.0` the result plus the runtime shim, run it, and
compare stdout byte for byte. A case with `refuse.txt` must be refused with that
message instead.

```
== case arith
   PASS (7 lines of output match)
== case jsmn
   PASS (14 lines of output match)
== case refused_union
   PASS (refused: unions are not supported)
== case structs
   PASS (5 lines of output match)

4 passed, 0 failed
```

The `jsmn` case downloads `jsmn.h` (MIT, third-party) on demand and is
gitignored, so the repository carries no vendored code.

## jsmn, end to end

`jsmn.h` + an unmodified-style C driver: `jsmn_init`, `jsmn_parse` over a JSON
document, dump every token, then a second parse of a truncated document to hit
the `JSMN_ERROR_PART` path. 14 lines of output, identical from gcc and from the
translated Vala.

The interesting parts of the generated code:

```vala
jsmntok_t? jsmn_alloc_token (jsmn_parser? parser, jsmntok_t[] tokens, size_t num_tokens) {
jsmntok_t? tok = null;
if (((size_t) ((jsmn_parser) parser).toknext >= num_tokens)) {
return null;
}
tok = tokens[(int) ((jsmn_parser) parser).toknext++];
((jsmntok_t) tok).end = -1;
...
```

```vala
int jsmn_parse_primitive (jsmn_parser? parser, string js, size_t len, jsmntok_t[] tokens, size_t num_tokens) {
    bool c2v_goto_found = false;
    ...
            case ':':
            case '\t':
            ...
                c2v_goto_found = true;
                break;
    ...
    if (c2v_goto_found) {
        break;
    }
}
```

Two decisions worth recording:

- **Array vs single reference is a whole-program question.** `tokens` is
  indexed in `jsmn_parse` but only forwarded in `jsmn_parse_primitive`;
  typing each function in isolation made the signatures disagree. The
  translator runs a fixpoint over the call graph (indexed locally *or* passed to
  an array parameter) so every signature agrees.
- **`goto found`** is the only control-flow construct Vala cannot express, and
  jsmn uses it to break out of a `switch` inside a `for`. The flag+break
  rewrite is narrow on purpose: any other shape is refused rather than
  approximated.

## Verification

```
python tools/c2vala_tests/run.py     # 4 passed, 0 failed
python tools/c_coverage.py tools/corpus   # probe fixtures still green (17 funcs, 11 clean)
```

## Known limitations

- The translator is a *front end*: no ownership analysis, so `free`/`malloc`
  are not translated at all (a C heap does not map to Vala references).
- Pointers are only supported as arrays or single object references; pointer
  arithmetic (`p + 1`, subtracting pointers) is refused.
- Structs become classes: value semantics (`a = b` copies in C, aliases here)
  are **not** preserved. jsmn only passes them by pointer, so it is unaffected,
  but code that relies on struct copies would silently change meaning — the
  reason struct-by-value parameters are refused rather than mistranslated.
- No `const` propagation, no `static` storage classes, one translation unit at
  a time (each input file is translated as its own TU).
- Generated code is deliberately mechanical, not idiomatic: casts everywhere,
  `c_*` shims instead of Vala string APIs.
