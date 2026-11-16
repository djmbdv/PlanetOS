# Slice 19 — Physical Memory Manager (PMM) and `int 0x80` Syscalls

Slice 19 adds a 4 KiB frame bitmap Physical Memory Manager (`Pmm`) and a
custom `int 0x80` (`DPL=3`) syscall dispatcher (`Syscalls`) to the freestanding
PlanetOS kernel (`I6`).

## 1. Physical Memory Manager ([kernel/pmm.vala](../../kernel/pmm.vala))

- [planetrt/boot_mb2.vala](../../planetrt/boot_mb2.vala) saves the Multiboot1
  info pointer (`EBX`) at `0x106040`.
- `Pmm.init()` reads `mem_upper` from Multiboot1 (capped at 64 MiB), marks
  `0x000000..0x600000` reserved (BIOS, page tables, IDT/bitmap, kernel), and
  manages free 4 KiB frames in a bitmap at `0x110000`.
- `Pmm.alloc_frame()` allocates and zeroes (`zero_page_4k`) a 4 KiB physical
  frame; `Pmm.free_frame(phys)` releases it back to the bitmap.

## 2. Syscalls ([kernel/syscall.vala](../../kernel/syscall.vala))

- Registers vector `0x80` in the 64-bit IDT with `DPL=3` (`0xEE`) via
  `Hal.set_idt_gate_dpl`.
- `isr_syscall` saves caller registers and dispatches to `syscall_dispatch`:
  - `1`: `SYS_CONSOLE_WRITE(buf, len)`
  - `2`: `SYS_TICKS()`
  - `3`: `SYS_ALLOC_PAGE()`
  - `4`: `SYS_FREE_PAGE(phys)`

## 3. Verification

- `freestanding_qemu` in [run.sh](../../planc/tests/run.sh) passes (`174/174`),
  verifying `pmm:free=14848`, `pmm:restored=1`, `irq0 tick=1..3`, `sys:ticks=3`,
  and `kernel:ok`.
