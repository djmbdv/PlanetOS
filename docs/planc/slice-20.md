# Slice 20 — PS/2 Keyboard (`IRQ1`) and ATA PIO LBA28 Disk Drivers

Slice 20 adds the PS/2 keyboard (`IRQ1`) and primary ATA PIO LBA28 disk drivers
to the PlanetOS kernel, verified end-to-end in QEMU with an IDE disk image.

## 1. PS/2 Keyboard ([kernel/keyboard.vala](../../kernel/keyboard.vala))

- Unmasks `IRQ1` on the 8259 PIC ([kernel/cpu.vala](../../kernel/cpu.vala)) and
  installs `isr_irq1` on IDT vector `33`.
- Reads scan codes from port `0x60` into a 64-byte ring buffer at `0x106100`
  and exposes `Keyboard.poll_scancode()` and `Keyboard.scancode_to_ascii()`.

## 2. ATA PIO LBA28 Disk ([kernel/ata.vala](../../kernel/ata.vala))

- Drives the primary IDE controller (`0x1F0..0x1F7`) with `Ata.identify()`,
  `Ata.read_sector(lba, buf)`, and `Ata.write_sector(lba, buf)` + `CACHE FLUSH`.

## 3. Verification

- `freestanding_qemu` in [run.sh](../../planc/tests/run.sh) attaches a 64 KiB
  raw IDE disk (`-drive ...,if=ide`) and verifies `kb:ok=1`, `ata:ok=1`
  (writing and reading back `"PLNT"` on sector 1 using a PMM-allocated frame),
  `pmm:restored=1`, `irq0 tick=1..3`, `sys:ticks=3`, and `kernel:ok`
  (`174 cases, 174 pass, 0 fail`).
