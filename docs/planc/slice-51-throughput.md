# Slice 51 — compiler throughput

`planc` self-compiles in one process, so its own sources are the natural
benchmark: compiling ~200 000 lines of Vala with the compiler it just built. Three
quadratic algorithms dominated that time; all three are fixed here.

Measured with `time` (user CPU) on ten self-compiles, baseline = `git HEAD` at the
time of this slice, comparing each compiler against its own sources (`-O0`):

| Compiler | user CPU / 10 runs | per compile |
|---|---|---|
| baseline | 20.7 s | 2.07 s |
| this slice | 15.4 s | 1.54 s |

≈ **26 % less CPU** per compile, with larger sources (the new features add code).

## The three fixes

| Symptom | Cause | Fix |
|---|---|---|
| Whole compile spent in string interning | `Emitter.add_string` linearly scanned every string already added, for every literal and every runtime message: O(n²) over ~10⁴ strings | a `StrIndexMap` from text to `offset + 1` (offsets can be 0), so a lookup is O(1) |
| Relocation dominated the link step | each `call rel32` patch scanned **all** symbols by name: O(calls × symbols) | one name→index map built before the patch loop |
| `may_be_string` cost O(program) per `+` | for every `VarRef`/index/member/call it scanned **all** functions, all their parameters and all globals to answer “does any string exist in this program?” | the answer is a property of the program, computed once (`program_has_string_slots`) |

Two measured experiments that were **rejected** and reverted:

- caching `class_field_offset_slots` and `find_class_method` in hash maps changed
  nothing measurable (1623 → 1642 ms, inside noise), so the extra state and its
  invalidation risk were removed;
- `--phase=` instrumentation was only used to attribute the remaining time
  (parse ≈ 23 %, codegen ≈ 48 %, emit+relocate ≈ 29 %) and is not shipped.

## Where the remaining time goes

Per phase, on the self-host build:

| Phase | Share |
|---|---|
| lex, parse, type collection, monomorphization | ≈ 23 % |
| codegen (three AST traversals per function: definite assignment, `prepare_stmt`, `gen_statement`) | ≈ 48 % |
| `to_array` copies, relocation passes, ELF sections and file write | ≈ 29 % |

The next honest win would be a per-expression type cache, but `expr_type_full`
depends on the narrowing state (`non_null_vars`), so a cache must be keyed by that
state; a naive cache is unsound. That is deliberate future work, not a quick fix.

## Notes for future work

- `Program.find_global`, `find_delegate` and `find_const` are still linear scans.
  They are called once per declaration, and the corpus has few globals, delegates
  and constants, so they did not show up; a `StrIndexMap` each would be the fix if
  that changes.
- Anything added to the compiler must also compile with `valac` (stage 0), which is
  why the perf work is written against the existing dialect rather than new
  constructs.
