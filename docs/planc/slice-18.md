# Slice 18 — Kernel IDT, PIC 8259, PIT 100 Hz Timer, and In-Kernel `async`/`Channel<T>`

Slice 18 adds the first hardware subsystems to the bare-metal PlanetOS kernel
and runs `async`/`yield` + `Channel<T>` coroutines directly over hardware
`IRQ0` timer interrupts in QEMU (`I5`, `I6`).

## 1. Kernel Hardware Abstraction ([kernel/cpu.vala](../../kernel/cpu.vala))

- **Memory / CPU primitives**: `mmio_write8`/`16`/`64`, `mmio_read64`,
  `cpu_sti`, `cpu_hlt`, `cpuid_vendor_raw`, and `Hal.print_cpu_vendor()`.
- **64-bit IDT**: populates all 256 64-bit Interrupt Gates at `0x105000` and
  loads `IDTR` via `lidt`.
- **8259 PIC + 8254 PIT**: remaps PIC IRQs to vectors `32..47`, unmasks
  `IRQ0`, programs PIT channel 0 to ~100 Hz (`0x2E9C`), and handles `IRQ0` via
  `isr_irq0` (`iretq` + EOI) incrementing `Hal.ticks()`.

## 2. In-Kernel `async` + `Channel<int>` ([kernel/main.vala](../../kernel/main.vala))

- `ticker_task` polls `Hal.ticks()` with `cpu_hlt()` + `yield` and sends
  ticks over `Channel<int>`.
- `logger_task` awaits `yield ch.recv()` and logs `irq0 tick=1..3` over COM1
  before exiting QEMU via `isa-debug-exit`.

## 3. Verification

- `freestanding_qemu` in [run.sh](../../planc/tests/run.sh) verifies:
  `PlanetOS v0.1 booted in x86-64 Long Mode (freestanding Vala + planc)`,
  `CPU: AuthenticAMD`, `irq0 tick=1..3`, and `kernel:ok`.
