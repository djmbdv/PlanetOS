# planc, slice 10: self-hosted bootstrap (I4)

Slice 10 closes invariant **I4**: `planc` compiles `planc`, and the fixed point
is verified — stage *N* and stage *N+1* are byte-identical. It also delivers
the `Host` abstraction that lets the same compiler sources build under valac
(stage 0) and as native code (stages ≥ 1), a dedicated
definite-assignment pre-pass, and a chain of codegen fixes that only surfaced
when the compiler started compiling itself.

Requirements demonstrated: **I1**, **I2**, **I3**, **I4**, **TC-02**, **TC-05**,
**VL-12**, **VL-13**, **KR-03**.

---

## 1. The `Host` abstraction

The compiler sources in `planc/src/*.vala` must build in two worlds:

- **stage 0** — under `valac`/GLib, using the oracle toolchain;
- **stage ≥ 1** — compiled by `planc` itself to a static ELF64 with no libc.

Every OS-facing operation therefore goes through `Host.*` wrappers with two
adapters:

| Adapter | File | Backed by |
|---|---|---|
| `planc/stage0/host_stage0.vala` | GLib host (read/write files, argv, exit, stdout, stderr) | valac + libc |
| `planc/src/host_native.vala` | `extern __planc_host_*` intrinsics resolved by codegen against the runtime | planc runtime only |

No `src/*.vala` file calls GLib directly; `main.vala` and codegen use the
`Host.*` surface.

## 2. Bootstrap pipeline (`planc/bootstrap.sh`)

```sh
stage 1: valac (stage0 adapter)      -> planc1   # GLib-hosted, same sources
stage 2: planc1 (native adapter)     -> planc2   # static ELF64, own runtime
ELF invariants of planc2: ET_EXEC, exactly 3 PT_LOAD (R|X, R, RW),
                          no RWX segment, empty `nm -u`
stage 3: planc2                      -> planc3
fixed point: sha256(planc2) == sha256(planc3)      # PASS
stage 4: full regression under planc2              # 157/157
```

planc2 and planc3 are byte-identical: the compiler is at a fixed point of its
own sources. From here on, any change to the compiler is validated twice —
once under valac (planc1) and once under the self-hosted binary (planc2) —
which is what caught the bugs below.

## 3. Definite-assignment pre-pass

The dialect now allows a local of non-nullable `class`/`interface`/`error`
type to be declared without an initializer and assigned later
(`Expr atom;` … `atom = ...;`) — the compiler's own sources rely on it. The
soundness authority is a new dedicated pre-pass in `codegen.vala`
(`da_reset`, `da_needs_tracking`, `da_state_copy/restore`, `da_scope_exit`,
`da_use`, `da_assign`, `da_stmt`, `da_expr`, `stmt_list_exits`), run at the
top of `prepare_function`. Flow merges use intersection: an assignment only
counts if it happens on *all* paths (if/else join; `while`/`for`/`foreach`
restore the pre-state because the body may run zero times; `switch` merges
non-exiting cases with the pre-state when there is no `default`; `try`/`catch`
is conservative — catches run with the pre-state; `finally` persists). A
variable still unassigned at scope end, or read while unassigned, is a
positioned semantic error; the invalid test `uninit_non_null_class.vala`
still fails. The two former hard rejections in `prepare_stmt` and
`gen_statement` were removed; the generation side zeroes the slot (null),
which is safe because the pre-pass guarantees no read of the null.

## 4. Null-check narrowing unified between phases

Prepare and generation must agree on which keys are known non-null where.
The generation side still used the half-written `match_null_cmp` (only plain
`x != null`); all its call sites (`if`, `while`, `?:`) now use the same
list-based `collect_non_null_when` mechanism as the prepare side, feeding
`add_all_non_null`. `match_null_cmp` has no remaining call sites.

## 5. Strictness fixes required to self-compile

planc1 is stricter than valac in places; the compiler's own sources had to be
tightened so planc1 could compile them:

- `ExprVisitor` delegate parameter is now `Expr?`; `collect_expr_free_vars`
  takes `Expr?` with a null guard;
- narrowing locals hoisted where planc cannot narrow through member access
  (`fn.params[i].default_value` → `dv`);
- explicit null checks after `program.find_class` / `find_struct` /
  `find_delegate` / `resolve_call_target` / `find_prop_setter` where the
  result feeds a non-null parameter;
- receiver null guards in `gen_builtin_method_call` (`int_to_string`,
  `has_prefix`/`has_suffix`, `substring`).

## 6. Codegen bugs the bootstrap caught

- **Closure environment size (fixed-point breaker):** `gen LambdaExpr`
  allocated `8 * ncap` bytes for the capture environment, but the layout is
  an 8-byte header, ARC refcount at `+8`, captures at `+16 + 8*ci` — the
  allocation now covers the header: `16 + 8*ncap`.
- **`this` loaded from the wrong slot (segfault compiling
  `delegates_and_lambdas.vala`):** `lookup()` returns the *locals-table
  index*, but `load_this_slot()` passed it directly to `load_local` as a
  *physical slot*. The two coincide only by accident; in synthesized lambda
  functions the generation side allocated `err_prop_slot` before the capture
  block while the prepare side allocated it after, so index 2 pointed at the
  (uninitialized) error slot while the `this` capture lived at slot 3 — the
  generated closure passed `this = nil` into instance calls. Fixed by mapping
  the index through `local_slots[ts]` and moving the gen-side
  `err_prop_slot` allocation after the capture block so prepare and gen share
  one slot layout.

## 7. Verification

- `./planc/tests/run.sh` — 157/157 under planc1 (valac build).
- `./planc/bootstrap.sh` — stages 1–3 pass, ELF invariants hold,
  `sha256(planc2) == sha256(planc3)`, and the full suite is 157/157 under the
  self-hosted planc2 (including the leak-check variants).
- planc2/planc3: static ELF64, three `PT_LOAD` segments (R|X, R, RW — never
  RWX), empty `nm -u`, no libc/POSIX symbols in the compilation chain (**I1**,
  **I2**, **I3**).
