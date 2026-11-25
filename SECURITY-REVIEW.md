# Security review — `planc` memory safety (2026-11-25)

Scope: the memory-safety hardening of the `planc` runtime and the
`--strict-ownership` checks (commits `259f215` … `17da1cf`). Files reviewed:
`planc/src/emitter.vala` (emitted allocator/refcount runtime),
`planc/src/codegen.vala` (ownership, borrows, arrays, `?.`, asm confinement),
`stdlib/glib/arena.vala`, `stdlib/glib/simd.vala`,
`stdlib/planet_math_kernels.vala`, `stdlib/planet_unsafe.vala`.

All three findings are **fixed and verified** in `17da1cf`.

## Findings

| # | Severity | File | Lines | Vulnerability | Confidence | Status |
|---|----------|------|-------|---------------|------------|--------|
| 1 | 🟠 HIGH | planc/src/codegen.vala | 11120-11135 (assignment codegen), 4855-4870 (strict rebind check) | Assigning to an `unowned` slot released the previous value and took ownership of the new one, like an owning slot. `u = b;` dropped the owner `a` from refcount 1 to 0 and freed a live object; the scope-exit `unref` of `a` then hit the freed block (use-after-free / double free). The strict rebind check did not catch it because a `VarRef` is never classified as a temporary. | 9/10 | Fixed |
| 2 | 🟡 MEDIUM | planc/src/codegen.vala | 2885-2930 | `is_storage_location` accepted every `MemberAccessExpr`/`IndexExpr`/`DerefExpr`, so `unowned T x = make ().field` took the borrow-root path instead of the temporary path: the receiver is released at the end of the statement and could not be tracked (no root local), leaving a dangling borrow with no diagnostic. | 8/10 | Fixed |
| 3 | 🟡 MEDIUM | planc/src/emitter.vala | 2130-2140 | The `0xFFFFFFFE` (destructor running) rejection in `__planc_ref` was emitted only with `--debug-memory`. A release build could resurrect an object that `l_free_self` frees as soon as the destructor returns; the resurrected reference then reads/writes freed memory or decrements a recycled block. | 8/10 | Fixed |

## Fixes

1. Borrow slots (`unowned` local or `unowned` parameter) only store the address:
   no `unref` of the old target, no ownership taken for the new value. When the
   new value is a temporary its single reference is kept, so the borrow leaks
   instead of dangling (and `--strict-ownership` rejects the assignment).
   This also fixed the self-hosted `planc.elf` panic.
2. `set_borrow_from_expr` requires the borrow root to resolve to a local before
   treating a field/index/deref as a storage location; otherwise the expression
   is handled as a temporary borrow (rejected under `--strict-ownership`,
   promoted to an owned local otherwise).
3. The `0xFFFFFFFE` check is emitted in every build.

## Verification

* `planc/tests/run.sh`: 281 cases, 280 pass. The only failure is the
  pre-existing `struct_union_delegate_arrays`.
* New regression tests: `valid/unowned_rebind`, `valid/unowned_field_temp`,
  `ownership/{bad_unowned_temp,bad_unowned_temp_string,bad_unowned_rebind,
  bad_unowned_stale,bad_ref_borrow,ok_unowned_local}`,
  `debugmem/uaf_write`.
* `bad_unowned_rebind.vala` without `--strict-ownership`: used to abort with
  `planc: panic: memory error (double free or corrupted block)` (exit 134),
  now exits normally.
* `dying_ref.vala` in a release build is now rejected instead of resurrecting
  the object.
* Self-hosted compiler in QEMU: `planc.elf --target=planetos utf8.vala -o t1.elf`
  and `t1.elf` print `chars=5 valid=1` / `cp0=0xF1 cp1=0x20AC cp2=0x1F680`;
  `class_basic.vala` → `t2.elf` prints `ops=24`.
* Runtime audit: `sys_demo.elf` all checks ok, `gio_demo.elf` 126 checks / 0
  failures, full PlanetOS build clean.

## Examined and not reported

* `Arena.get_int`/`set_int` `index * 4` overflow: degrades to a bounds panic
  (bounds checks are on by default) and only becomes an out-of-bounds access
  under the explicit `--no-bounds-check` opt-out.
* `ArenaHandle.valid` does not check `offset + length <= size`; it exposes only
  uninitialized bytes of the arena's own buffer, which the normal `alloc`/`get`
  path already returns.
* `Planet.math_vec4_*` raw-address wrappers have the same capability as the
  explicitly unsafe `Planet.Unsafe.poke32`.

## Follow-up

The remaining known limits of the dialect are documented in
[docs/planc/memory-safety.md](planc/memory-safety.md): `--strict-ownership` is
opt-in, and borrow tracking is per-local (a borrow taken through a field of a
local is invalidated when that local is reassigned, not when the field itself is
reassigned through another path).
