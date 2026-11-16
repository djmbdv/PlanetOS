# Slice 26: Preemptive `IRQ0` Task Scheduler (`SYS_SPAWN` / `SYS_WAIT` / `SYS_PS`)

## Goal

Add preemptive round-robin multitasking over the 100 Hz PIT `IRQ0` timer interrupt, enabling background ELF execution (`exec <file> &`), task inspection (`ps`), and waiting/reaping (`wait <tid>`) from the PlanetOS shell.

## Changes

### 1. Preemptive scheduler (`kernel/sched.vala`)
- [`kernel/sched.vala`](../../kernel/sched.vala):
  - Added a 16-slot Task Control Block (TCB) table at `0x124000` (`state`, `saved_rsp`, `stack_base`, `exit_code`, `parent_tid`, `ticks`, `name`).
  - `isr_sched_irq0` replaces vector `32` (`IRQ0`) upon `Sched.init()`, saving/restoring all 15 general-purpose registers + `iretq` frame and switching stacks across `READY` tasks at 100 Hz.
  - `Sched.spawn_ready()` builds a synthetic `iretq` + 15-GPR frame (`CS=0x08`, `SS=0x10`, `RFLAGS=0x202`) on the new task's 64 KiB stack.
  - `Sched.exit_current()`, `Sched.wait_tid()`, and `Sched.list_tasks()` manage task termination (`ZOMBIE`), stack reclamation, and `ps` formatting.

### 2. Kernel & syscall integration
- [`kernel/elf_loader.vala`](../../kernel/elf_loader.vala):
  - Extracted `prepare_process()` shared by synchronous `exec_from_xfs()` and asynchronous `spawn_from_xfs()`.
- [`kernel/syscall.vala`](../../kernel/syscall.vala):
  - Added `SYS_SPAWN` (`16`), `SYS_WAIT` (`17`), and `SYS_PS` (`18`); `SYS_EXIT` (`11`) calls `Sched.exit_current()` when `Sched.current_tid() > 0`.
- [`kernel/main.vala`](../../kernel/main.vala):
  - Calls `Sched.init()` before transferring control to `shell.elf` (`tid=0`).

### 3. Shell & QEMU verification
- [`user/shell.vala`](../../user/shell.vala):
  - Added `ps`, `wait <tid>`, and background `exec <file> [args...] &`.
- [`user/worker.vala`](../../user/worker.vala):
  - Background test binary (`--image-base=0x900000`) that waits 4 `IRQ0` ticks and exits with code `7`.
- [`run-qemu.sh`](../../run-qemu.sh) & [`planc/tests/run.sh`](../../planc/tests/run.sh):
  - Embed `worker.elf` in XFS and verify `exec worker.elf &`, `ps`, concurrent `exec init.elf`, and `wait 1` (`exit=7`) in QEMU.
