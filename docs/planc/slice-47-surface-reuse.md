# Slice 47: one framebuffer for the compositor self-test (fixes `graphics`)

## Symptom

`python tests/qemu.py` failed the `graphics` case only in the animated run:

```
planet> compositor --animate --self-test
compositor: pattern=frag_pattern.spv ok=1 samples=3600 uniforms=1
compositor: animate=1 period_ms=400
compositor: FAIL damage-surface-alloc
fault:vec=14 err=6 rip=8390942 cr2=0
```

Static and `--vulkan` modes reached `compositor:summary checks=75 failures=0`.

## Cause

`self_test_run ()` allocated **five** full-screen `ImageSurface`s, one per block
(rendering smoke test, damage merging, occlusion culling, damage tracking, GTK
widgets). At 1280×720 each one is `1280*720*4 = 3,686,400` bytes = **900 pages**,
and `SYS_ALLOC_PAGE` serves a multi-page block with `Pmm.alloc_contiguous`
([kernel/syscall.vala](/C:/Users/Lenovo/PlanetOS/kernel/syscall.vala)): a single
unbroken run of free frames.

- 8..16 MiB is reserved for the static userland ELF region
  ([kernel/pmm.vala](/C:/Users/Lenovo/PlanetOS/kernel/pmm.vala) `reserve_range (0x800000, 0x800000)`),
  so the first big free run starts at 16 MiB.
- `--animate` keeps the baked pattern surface alive, four surfaces had already
  been handed out, and the fifth 900-frame run no longer exists → the allocator
  returns 0.
- `ImageSurface` stores it in `buf_addr`, the self-test only checked
  `buf_addr != 0` on some blocks, and `new Context (surf2)` then wrote through
  address 0 → `#PF cr2=0`.

## Fix

Every block of the self-test starts with a full flush, so none of them needs its
own buffer: the surface from the rendering smoke test is now **the** framebuffer
for the whole test (`var surf4 = surf;` and friends). One 900-page block instead
of five, and the two blocks that never checked their allocation now do
(`occlusion-surface-alloc`, `gtk-surface-alloc`), so an allocator failure is a
named failing check instead of a page fault.

```vala
    // One 1280x720 surface is 900 contiguous frames and every block below starts
    // with a full flush, so the whole self-test shares this one: allocating five
    // of them (18 MiB) is more than the allocator can serve in --animate mode.
    var surf = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
```

## Verification

```
python tests/qemu.py        # 14/14 cases passed (graphics was 13/14 before)
```

## What is still missing: freeing a block

The obvious companion — `SYS_FREE_PAGES (addr, pages)` = 34, `Planet.Sys.free_pages`
and `ImageSurface.release ()` — was implemented and **reverted**, because it makes
things worse in a way that is not yet understood:

- With the release path in place, the very first surface write faults at
  `cr2 = 0x1000000` in *every* mode (`err=2`, write to a non-present page), and
  the address grows by one surface per process (`0x1000000`, `0x1384000`,
  `0x1708000` — free frames are never reused, so the allocator hands out
  successively higher runs).
- Reverting *only* `kernel/syscall.vala` (keeping the surface reuse) makes the
  case pass again, so the fault comes from the kernel side of that change, not
  from the allocator interface.
- Baseline (no changes at all) reproduces the original `FAIL damage-surface-alloc`,
  so the fault is not pre-existing behaviour.

The next step is to understand why a block that has been unmapped and reallocated
is not usable: `map_user_range ()` → `map_user_4k ()` → `ensure_pt_in_pd ()`
silently returns without mapping when it cannot split the PDE, so an unmapped
allocation is indistinguishable from a successful one. That should be diagnosed
(split failures reported, and the PMM restricted to mappable frames) before
freeing user memory is exposed again.
