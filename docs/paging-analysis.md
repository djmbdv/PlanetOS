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

`kernel/pmm.vala`: `BITMAP_ADDR = 0x110000`, `RESERVED_END = 0x600000`,
`MB_INFO_PTR = 0x106040`. `kernel/syscall.vala` uses `FD_TABLE_ADDR` and
`0x106210` as a scratch buffer. The kernel image is loaded at `0x100000`, and its
page tables live at `0x100000`/`0x101000`/`0x102000`/`0x103000`.

So the kernel image, its BSS and these fixed structures share the first 6 MiB with
no linker script and no runtime assertion that `end_of_kernel <= 0x110000`. Any
growth in `.text`/`.data`/`.bss` moves the kernel's own end and silently
overlaps the bitmap or the fd table. This is the most likely explanation for
"adding one branch broke the mapping path": the *only* difference between the
working and the failing build was ~15 lines of kernel code, and the symptom was
not a compile error but memory corruption during allocation.

Correct approach: give the kernel a linker script (or a fixed layout documented
in one place) with `_kernel_end` exported, place the bitmap/fd table/scratch
buffers in `.bss` (symbols, not literals), and assert at boot that the region
between `_kernel_end` and the first PMM frame is large enough. Squeezing
structures into absolute addresses is only safe when something verifies them
(see Intel SDM Vol. 3A 4.5 for the mapping rules; nothing there protects you from
your own layout).

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

Do defects 1 and 3 first: they are small, they are bugs in their own right, and
they turn silent corruption into an assertion or an error code. Then, as a slice
of its own, implement the user VA window (defect 2), which makes freeing memory
trivial (defect 5) because a block no longer has to be contiguous.

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
