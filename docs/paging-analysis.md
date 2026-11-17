# Paging and frame allocation: analysis (2026-11-17)

Context: the `graphics` case only failed in `--animate` on this build, and when
`SYS_FREE_PAGES` (34) was added the failure moved to the *first* surface write at
`cr2 = 0x1000000` in every mode. Reverting only that kernel branch restored the
baseline behaviour. This note records what the code actually does, what is wrong
with it, and what the correct design is. Sources are listed at the end.

## What the kernel does today

1. `planetrt/boot_mb2.vala` identity-maps 1 GiB with 512 x 2 MiB PDEs
   (`0x83` = present | writable | PS) in the PD at `0x102000`.
2. `Vmm.init ()` unmaps page 0 so a NULL dereference faults, which forces PDE 0 to
   be split into a 4 KiB PT.
3. `Vmm.create_user_space ()` allocates a new PML4/PDPT/PD and **clones all 512
   PDEs of the kernel PD**, clearing the user bit on 2 MiB entries and cloning any
   already-split PT. The process therefore sees the whole physical memory,
   identity-mapped.
4. `SYS_ALLOC_PAGE (n)` takes `Pmm.alloc_contiguous (n)` (one unbroken run of
   free frames) and maps it with `Vmm.map_user_range (ucr3, phys, n * 4096)`,
   paying identity addresses (virtual == physical).
5. `Vmm.map_user_4k ()` -> `ensure_pt_in_pd ()` splits a 2 MiB PDE into a fresh
   PT when needed, filling the 512 entries with identity mappings, then writes the
   single PTE for the target page.

## Defects (in severity order)

### 1. Kernel data structures at hard-coded absolute addresses

The window is real, but the first reading of this defect was wrong: the kernel
image is **not** at `0x100000`. `planc --freestanding` links it at `0x400000`
(multiboot header at `0x4000F0`), and the produced image is file-backed
`0x4000e8..0x4292c2` with `.bss` reaching `0x46b348`. Everything the kernel keeps
at a fixed address lives *below* the image, hand-partitioned into
`0x100000..0x127000`:

| region | base | size | owner |
| --- | --- | --- | --- |
| page tables (PML4/PDPT/PD/PD3) | `0x100000` | `0x4000` | boot asm, `Fb`, `Vmm` |
| GDT, GDTR, TSS (+`rsp0`) | `0x104000` | `0x200` | boot asm, `Hal` |
| IDT | `0x105000` | `0x1000` | `Hal` |
| tick, IDTR, cpuid scratch | `0x106000` | `0x40` | `Hal`, IRQ0 handler |
| multiboot pointer | `0x106040` | `0x8` | boot asm, `Pmm` |
| keyboard ring + cursors | `0x106100` | `0x50` | `Keyboard` |
| nested exec slots | `0x106200` | `0x100` | `ElfLoader` |
| mouse ring | `0x106300` | `0x100` | `Mouse` |
| mouse cursors | `0x106400` | `0x10` | `Mouse` |
| syscall scratch | `0x106800` | `0x10` | `SYS_READ_KEY` |
| fd table | `0x107000` | `0x200` | `syscall.vala` |
| PMM bitmap | `0x110000` | `0x800` | `Pmm` |
| RAMFS table | `0x120000` | `0x2000` | `Ramfs` |
| scheduler variables | `0x123FF0` | `0x10` | `Sched` |
| TCBs (16 x 128 B) | `0x124000` | `0x800` | `Sched` |
| FXSAVE areas (16 x 512 B) | `0x125000` | `0x2000` | `Sched` |

So growth of `.text`/`.data`/`.bss` moves away from the window: the image starts
`0x400000 - 0x127000` ≈ 2.8 MiB above it, and the boot stack (`rsp = 0x200000`,
growing down) is the only thing between them. The earlier probe in `81ed103`
reported the opposite ("the image is file-backed up to 0x42b280, which covers the
fixed structures") because it assumed a single contiguous span from `0x100000`;
that conclusion is withdrawn here.

What *is* wrong is that the partition existed only as magic numbers spread over
ten files, with nothing checking it. Two overlaps were live in the tree:

- `syscall.vala` used `0x106210` as the one-byte scratch buffer for
  `SYS_READ_KEY`. That address is inside the first 32-byte nested-exec slot
  (`0x106200 + (exec_depth - 1) * 32`), so reading stdin while a file was open on
  fd 0 overwrote the saved `rsp`/`cr3`/`rsp0` of the outermost `SYS_EXEC` and the
  return path restored a garbage stack.
- nested `SYS_EXEC` had no depth limit, and the slots only span 8 levels before
  they reach the mouse ring at `0x106300`.

Both are fixed, and the window is now declared once:

- `kernel/layout.vala` holds the region table above (base, size, bounds of the
  window, boot stack, PMM range and image base). Every module references
  `KernelLayout.*` instead of its own literals, so the partition cannot drift
  between files.
- `KernelLayout.verify ()` walks the regions in address order at boot and the
  kernel refuses to run on a broken table, printing `layout:ok=1` (or
  `layout:fail=<code>` and halting).
- `ElfLoader.exec_from_xfs ()` refuses to nest past `EXEC_MAX_DEPTH` (8),
  releasing the child stack and address space instead of writing past the slots.
- `tools/check_layout.py` is a build gate, not a report: it parses
  `kernel/layout.vala`, checks ordering/disjointness/window bounds, checks that
  the produced image (PT_LOAD `vaddr + memsz`, so `.bss` counts) does not touch
  the window or the boot stack, and checks that the addresses which only exist as
  literals inside asm bodies (boot page tables, multiboot pointer, PS/2 rings,
  TSS `rsp0`) still match their constants. `run-qemu.ps1` fails the build on a
  non-zero exit.

What is still not possible is the ideal form of the fix: putting the buffers in
`.bss` as symbols. `planc` has no arrays and no static class fields, so a byte
buffer cannot be declared at all — only scalar globals reach `.bss`. Until the
compiler grows fixed-size static buffers (or a linker script plus exported
`_kernel_end`), an enumerated, verified window is the strongest guarantee
available; the checks are what make it safe rather than lucky.


### 2. User space is the kernel identity map

`create_user_space ()` clones the supervisor identity map instead of building a
user address space. Consequences:

- Every frame in the machine is addressable by ring 3 wherever the PDE was
  cloned with `& ~0x04` removed... except that `ensure_pt_in_pd` fills a split
  PT with `| 0x07` (present | writable | **user**) entries covering the whole
  2 MiB region. From the moment one page in that region is mapped for a process,
  the other 511 pages of the same 2 MiB are user-writable too, including frames
  that belong to the kernel or to another process.
- There is no way to tell "this frame is not mine" from the page tables, so a
  use-after-free or an off-by-one in userland is a silent cross-process write
  instead of a `#PF`.

Correct approach (as every production kernel does): a dedicated user VA window.
Keep the identity map supervisor-only for the kernel, and map user buffers at
virtual addresses from a bump allocator (e.g. `0x40000000+`), one PTE per 4 KiB
frame, `present | writable | user`, `NX` where appropriate. On free, clear the
PTE and return the frame. Intel SDM Vol. 3A 4.6 (page-protection facilities) and
4.10 (caching/TLB) apply.

### 3. Silent mapping failures

`ensure_pt_in_pd ()` returns `false` when the PDE is not present or when
`Pmm.alloc_frame ()` fails, and `map_user_4k ()` / `map_user_range ()` simply
return. `SYS_ALLOC_PAGE` returns the physical address either way, so userland
cannot distinguish "mapped" from "not mapped" and the first write faults with
`err=2` at the start of the buffer - exactly the symptom seen with
`SYS_FREE_PAGES` in the tree.

Correct approach: mapping must be all-or-nothing. `map_user_range ()` returns
the number of pages mapped (or a bool); `SYS_ALLOC_PAGE` frees the block and
returns 0/-ENOMEM when mapping fails. A `#PF` must never be the error path of an
allocator.

### 4. No TLB maintenance for other address spaces

`map_user_4k ()`/`unmap_user_4k ()` only call `invlpg` when
`vmm_read_cr3 () == cr3`. That is correct while the process is running, but the
kernel also writes PTEs of a process that is not current (e.g. while scheduling);
those entries stay in the TLB of the CPU that ran it. With a single CPU and a
CR3 reload on every switch this is hidden, but `mov cr3` is not a substitute for
`invlpg` semantics on all microarchitectures (Intel SDM Vol. 3A 4.10.4 "Invalidating
Translations"; 4.10.4.1 says global pages survive CR3 loads).

Correct approach: reload CR3 with the "flush all non-global" behaviour after
batch updates (already done in `map_mmio_2m`), and per-page `invlpg` only when the
target is current.

### 5. Fragmentation from the reserved window

`Pmm` caps at 64 MiB (`MAX_BYTES`) and reserves 8..16 MiB for the static userland
ELF. A 900-frame (3.6 MiB) contiguous request therefore has to start at 16 MiB,
which is why the first surface lives exactly at `0x1000000` in every run.
`alloc_contiguous` also returns 0 with no diagnostic when no run fits.

Correct approach: allocate user buffers from *non-contiguous* frames and map them
into a contiguous user VA range (defect 2's design removes the need for
contiguity entirely); if contiguity is kept, reserve the region up front instead
of relying on what is left after fragmentation, and report failures.

## Recommendation

Defect 1 is now declared and enforced (region table, boot check, build gate) and
defect 3 turns silent mapping failures into `0` returns; what remains of defect 1
is the compiler work needed to place the buffers in `.bss` instead of a window.
The next slice should be defect 2, the user VA window, which also makes freeing
memory trivial (defect 5) because a block no longer has to be contiguous.

The `-animate` failure that slice 47 fixed by reusing one framebuffer was a
symptom of defect 5 only; the five surfaces were fine in principle.

## Sources

- Intel 64 and IA-32 Architectures Software Developer's Manual, Vol. 3A:
  chapter 4 "Paging" (4.5 4-level paging and entry formats, 4.6 protection,
  4.10 TLB and `INVLPG`, 4.10.4.1 global pages).
- AMD64 Architecture Programmer's Manual, Vol. 2, chapter 5 "Page Translation and
  Protection Mechanisms" (same PDE/PTE semantics, `PS` bit, user bit).
- OS/Dev wiki, "Page Frame Allocation" and "Paging" articles (frame allocator
  strategies, why kernels keep a supervisor-only identity map and map user
  memory elsewhere). `https://wiki.osdev.org/Setting_Up_Paging` answered 403 to
  this environment, so the references are by article name.
- Linux: `Documentation/x86/x86_64/mm.rst` documents the split between the
  direct map, `vmalloc` and user space per address-space layout; it is the
  canonical example of defect 2's fix.
