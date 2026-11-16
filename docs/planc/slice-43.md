# Slice 43: a memory model for the C → Vala translator, and `--report`

## Goal

Slice 42 refused every function that touched the heap, which is most real C.
This slice gives the translator a **memory model**: `malloc`/`calloc` become
GC-owned Vala arrays, `free` becomes a no-op, and anything the model cannot
express (pointer arithmetic, `realloc`, allocating an aggregate) is still
refused with a diagnostic instead of being mistranslated. It also adds
`--report`, so a translation unit where only *some* functions are in scope is
still useful: the translator emits what it can, stubs the rest as comments, and
prints a per-function verdict.

## The model

| C | Vala | Why |
|---|---|---|
| `T *p = malloc (n * sizeof (T));` | `T[] p = new T[n];` | a Vala array is a length-carrying, GC-owned block |
| `T *p = calloc (n, sizeof (T));` | `T[] p = new T[n];` | `new T[n]` is already zeroed |
| `char *b = malloc (n);` | `uchar[] b = new uchar[n];` | mutable byte buffer; `char *` stays `string` only when it is read-only text |
| `p = malloc (n * sizeof (T));` after `T *p;` | declaration becomes `T[] p = new T[0];`, assignment `p = new T[n];` | the count is not known where the declaration is emitted |
| `free (p);` | `// free (p): the GC owns the array` | the GC frees it; keeping the call visible in the output documents the difference |
| `return p;` where `p` is a malloc'd buffer | the function's return type becomes an array | return types are resolved before bodies are emitted |

`sizeof` is folded away instead of becoming `sizeof (T)`: the count in
`malloc (n * sizeof (int))` comes from the multiplier, and
`calloc (n, sizeof (int))` from the second argument, so the generated array size
is a plain C integer expression (`new int[n]`).

`tools/c2vala_tests/cases/malloc_arrays/main.c` exercises all of it — a buffer
built inside a callee and returned, a `const int *` parameter that is only read,
a mutable `char` buffer, and `free` calls:

```vala
int[] make_table (int n) {
int[] t = new int[n];
...
return t;
}

int sum_all (int[] t, int n) { ... }

int main (string[] args) {
int[] table = new int[0];
uchar[] buf = new uchar[0];
table = make_table (n);
stdout.printf ("sum=%d\n", sum_all (table, n));
...
// free (table): the GC owns the array
buf = new uchar[8];
```

### What the model deliberately does not do

- **No heap emulation.** There is no `sizeof`-sized byte arena behind the array
  and no `memcpy` over it; a buffer is a `T[]` and only indexing is allowed.
  Pointer arithmetic (`p + 1`, `p - q`) is still refused, as in slice 42.
- **No `realloc`.** Resizing in place has no Vala equivalent that preserves C
  aliasing; it is refused rather than turned into copy-and-reallocate.
- **No allocated aggregates.** `malloc (sizeof (T))` where `T` is a struct is
  refused: classes are references, so `T[]` would change the meaning of
  `p->field`.
- **String/buffer helpers stay refused.** `memcpy`, `memmove`, `memset`,
  `strcpy`, `strncpy`, `strcat` are reported as "not supported yet" — a
  `string` in Vala is immutable and a `uchar[]` is not the same thing as
  `void *`.

## `--report`

Plain mode is all-or-nothing: one refusal aborts the whole file with exit
status 2. With `--report` the translator keeps going, writes a comment stub for
each function it could not translate, and prints a verdict per function in
source order:

```
$ python tools/c2vala.py tools/c2vala_tests/cases/partial/main.c -o /tmp/p.vala --report
c2vala: wrote /tmp/p.vala (12 lines)
c2vala report: 2 function(s)
  ok       square
  refused  sum_ints  main.c:52: varargs are not supported
  1 translated, 1 refused
```

Exit codes: **0** everything translated, **2** a refusal happened before any
per-function decision could be made (a type at file scope, a parse error),
**3** partial success — the output is valid Vala but incomplete.

The stub keeps the reason next to the hole it left, so a reader of the generated
file does not have to re-run the translator to find out what is missing:

```vala
// c2vala refused sum_ints: main.c:52: varargs are not supported
```

## Harness

`tools/c2vala_tests/run.py` gained a third case kind. A case directory with
`report.txt` runs the translator with `--report` and asserts that every line of
`report.txt` appears in its stdout (substring match, so line numbers and paths
can be omitted); it does not compile or compare output. The other two kinds are
unchanged: differential (gcc vs valac, byte-identical stdout) and `refuse.txt`
(must be refused with that message).

```
== case arith
   PASS (7 lines of output match)
== case jsmn
   PASS (14 lines of output match)
== case malloc_arrays
   PASS (3 lines of output match)
== case partial
   PASS (report matches 5 expectations)
== case refused_union
   PASS (refused: unions are not supported)
== case structs
   PASS (5 lines of output match)

6 passed, 0 failed
```

## Verification

```
python tools/c2vala_tests/run.py     # 6 passed, 0 failed
python tools/c_coverage.py tools/corpus   # probe fixtures still green (17 funcs, 11 clean)
```

## Known limitations

Everything from slice 42 still holds (structs are classes, no `const`
propagation, one translation unit at a time, mechanical output), plus:

- Ownership is inferred, not analysed: a pointer that is sometimes a single
  object and sometimes a buffer is decided by the whole-program array fixpoint,
  not by dataflow.
- `free` being a no-op means a program that relies on `free` to bound memory
  will use more memory after translation; nothing is leaked, but nothing is
  reclaimed early either.
- `--report` re-checks nothing: a function that translates can still be
  semantically wrong if it depends on a refused neighbour's C-level behaviour.
