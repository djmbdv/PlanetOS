# 08 - I/O data path

Status: **design, not implemented.** The prerequisites in section 4 are open.
This document is normative for the driver and hardware layer roadmap; it does
not change any invariant of the project.

## 1. Decision

PlanetOS keeps a monolithic kernel. The kernel keeps MMIO, DMA submission,
interrupts, physical memory and the doorbell registers. It stops being the
place where protocol logic lives.

Two I/O contracts are defined, and only two:

| Contract | Devices | Userland side | Kernel side |
|---|---|---|---|
| **A. Byte devices** | serial, TTY/console, raw keyboard, audio control | `Gio.InputStream` / `OutputStream` subclasses and filter chains (STREAMS-style composition) | one handle, readiness, blocking wait |
| **B. Framed/queue devices** | block, network, GPU, audio data | shared descriptor ring, buffers, protocol stack (LibOS) | ring validation, doorbell, IRQ completion, buffer ownership |

Neither contract is a microkernel. The physical driver and the doorbell stay in
ring 0. **Objects do not cross the kernel/user boundary; handles do.**

## 2. What the repository has today

| Capability | Where | State |
|---|---|---|
| Pure-Vala `Gio` streams (`Filter`, `Buffered`, `Data`, `File`, `Memory`) | [stdlib/gio/streams.vala](../stdlib/gio/streams.vala) | implemented |
| `MainContext` with idle, timeout and fd watch | [stdlib/glib/mainloop.vala](../stdlib/glib/mainloop.vala) | implemented, 8 watches, 15 fds per poll |
| Futex-like wait/wake on a user word | `SYS_WAIT_ADDR` / `SYS_WAKE_ADDR`, [kernel/syscall.vala](../kernel/syscall.vala) | implemented |
| Zero-copy shared surface, app <-> compositor | [stdlib/gdk/window.vala](../stdlib/gdk/window.vala) | implemented, built on an unsafe map |
| Device namespace (`/dev`) | [kernel/vfs.vala](../kernel/vfs.vala) | implemented (B1): `/dev/console`, `/dev/serial0`, `/dev/null` resolve to `KIND_DEV` handles that carry no seek right |
| Handles with ownership, generation and rights | [kernel/syscall.vala](../kernel/syscall.vala) | implemented (A1.1/A1.2): 64 slots, `index \| generation << 8`, per-operation rights |
| `Pollable`, `FileDescriptorBased`, `IOStream`, cancellable source | [stdlib/gio/types.vala](../stdlib/gio/types.vala), [stdlib/gio/streams.vala](../stdlib/gio/streams.vala) | implemented: `PollableInputStream`/`PollableOutputStream` on the file and device streams, `SimpleIOStream`, `Cancellable.create_source` |
| Capability grant | `SYS_MAP_USER_AT`, [kernel/syscall.vala](../kernel/syscall.vala) | **missing**: maps any physical frame above 6 MiB |
| Safe user copies with page-fault recovery (KR-07) | [kernel/syscall.vala](../kernel/syscall.vala) | implemented (A3): PML4 walk with read/write rights, guarded copy that recovers from a fault |
| Frame ownership and grants | [kernel/syscall.vala](../kernel/syscall.vala) | implemented (A2): `SYS_ALLOC_PAGE` records the owner, `SYS_GRANT`/`SYS_GRANT_SHARE` hand out a capability, `SYS_FREE_PAGE` and `SYS_MAP_USER_AT` check it |
| Interrupt-driven completion | `kernel/ata.vala`, `kernel/virtio_gpu.vala` | **missing**: PIO and bounded spin loops |
| VirtIO-BLK queue and request path | [kernel/virtio_blk.vala](../kernel/virtio_blk.vala) | implemented (C2): queue 0 over the modern transport, 3-descriptor chain (header/data/status), MSI-X delivery verified, completion word the task parks on |
| Local APIC | [kernel/cpu.vala](../kernel/cpu.vala) | implemented (C2): enabled through `IA32_APIC_BASE` with x2APIC off, SIVR/TPR set, `lapic_id` and `lapic_eoi` drive MSI-X delivery |
| IOMMU | QEMU command line, [run-qemu.ps1](../run-qemu.ps1) | absent |
| Protocol stacks | - | absent |

Consequence: Contracts A and B are both **blocked on section 4**, not on the
stream classes or the rings. The stream hierarchy already exists; the handles
and the grants do not.

## 3. Non-goals

- GObject instances, vtables or signals crossing the ring/CR3 boundary.
- Userland MMIO or DMA programming while there is no IOMMU (see D-15).
- Compiler-proved ownership transfer. `planc` is ARC with `owned`/`unowned`
  reference semantics, not linear types; exclusivity is enforced at run time.
- A kernel-side STREAMS framework with `M_DATA`/`M_PROTO`/`M_FLUSH` messages.
- A reincarnation server for ring-0 drivers.
- Replacing `Gio` byte streams with message streams for every device.

## 4. Prerequisite: handles and grants (Phase A)

### 4.1 Handle

A handle is a per-process opaque value. It is never an address.

Slot layout, as implemented (32 bytes per slot, 64 slots):

| Offset | Field | Width |
|---|---|---|
| +0 | `kind` | 8 bits |
| +0 | `rights` | 8 bits |
| +0 | `generation` | 16 bits |
| +0 | `owner` (task id) | 32 bits |
| +8 | object id (inode or RAMFS slot) | 64 bits |
| +16 | size | 64 bits |
| +24 | position | 64 bits |

Rights: `READ`, `WRITE`, `SEEK`, `POLL`, `CLOSE`. `open` grants
`READ|WRITE|SEEK|POLL|CLOSE`; `create` grants `WRITE|SEEK|POLL|CLOSE`, so a
write-only handle cannot read.

The value exposed to userland is `index | generation << 8`, never a table
offset. `fd_check` returns three states: usable, invalid (forged, stale or
foreign) and missing rights, mapped to `EBADF` and `EACCES` respectively. When a
slot is released its generation survives, so a stale value cannot be revived by
the next allocation in the same index. The owner field is the per-process
namespace: a table per process would be an optimisation, not a correctness
requirement, until handle counts grow.

Rules:

- Every syscall that names a resource takes a handle, not an integer index.
- 0, 1 and 2 are aliases resolved per process; they are not entries in a global
  table ([kernel/syscall.vala](../kernel/syscall.vala)).
- Closing requires `CLOSE`; granting requires `GRANT`.
- A handle is meaningless in another process: the lookup is done in the caller's
  table. Forgery yields `E_BAD_HANDLE`, never a kernel dereference.
- Transfer between processes is explicit (a planned `SYS_HANDLE_SEND`, or a
  channel). There is no ambient file-descriptor namespace.

### 4.2 Memory grants (implemented, A2)

`SYS_GRANT(start, len)` turns a block the task allocated with `SYS_ALLOC_PAGE`
into a handle (`KIND_GRANT`, no seek/poll rights). The kernel keeps a table of
owned blocks, so:

- `SYS_FREE_PAGE` refuses frames the caller does not own (`EACCES`) and any
  frame a live grant still covers.
- `SYS_MAP_USER_AT` refuses a range that belongs to another task, unless a
  grant covering it lists the caller in its ACL (`SYS_GRANT_SHARE`). Image
  segments nobody owns (the `.dlib` loader) stay mappable.
- A task's death returns its blocks to the Pmm; handles die with their owner.

The compositor grants each shared surface and shares it with the client task
before `spawn`, so the address in `PLANET_WIN_SHM` is a hint and the capability
is what actually authorizes the mapping.

Still open from the original design: a dedicated pre-mapped **I/O arena** per
process (`exec`-time grant window) so the fast path never edits page tables, and
an explicit `SYS_HANDLE_SEND` so a handle can travel over a channel instead of
being shared by task id.

### 4.3 User copies (implemented, A3)

- `user_range_ok` walks the caller's PML4/PDPT/PD/PT and requires the present
  and user bits at every level; a write also requires `RW`. Kernel callers
  (CR3 0) keep the low-window bound check, because their buffers are not user
  maps.
- `SYS_READ` and `SYS_WRITE` stage data through `KernelLayout.IO_SCRATCH`, a
  16 KiB buffer in the low window that every user CR3 maps as supervisor pages.
  `copy_guarded` records its frame; a kernel-mode page fault inside it is
  recovered by `copy_recover`, which returns 1 and lets the syscall fail with
  `EINVAL` instead of killing the task.
- Paths (A3.1, implemented): `copy_path` validates and copies into the staging
  buffer (offset 0 and `MAX_PATH` for rename), and the VFS reads kernel memory.
  Covered: open, create, unlink, rename, mkdir, readdir, stat, stat_ex, exec and
  spawn.
- `SYS_READDIR` and `SYS_STAT_EX` also stage their output through the scratch
  and return it with `copy_guarded`, so their user buffers are written through
  the same recoverable path.
- Still validated but not staged: `SYS_PS`, `SYS_GETENV`, `SYS_KLOG_READ`,
  `SYS_MOUSE_READ` and `SYS_FB_INFO` write short results directly to user
  memory (A3.2).
- Ring descriptors will be read through a kernel copy, never dereferenced in
  place (Phase C).

### 4.4 Raw escapes

`Sys.poke8/poke32/peek32/call_ptr*` ([stdlib/planet_sys.vala](../stdlib/planet_sys.vala))
are public today and defeat any type-based security claim. Move them to an
internal unsafe module available only to the runtime and to the dlib loader.

## 5. Contract A: byte devices

### 5.1 Shape

```vala
// Implemented in stdlib/gio/types.vala. `create_source` returns a Source that
// the MainContext can watch, so a device stream plugs into the same event loop
// as any other source.
public interface PollableInputStream : Object {
    public abstract bool is_readable ();
    public abstract Source create_source (Cancellable? cancellable = null);
}

public interface PollableOutputStream : Object {
    public abstract bool is_writable ();
    public abstract Source create_source (Cancellable? cancellable = null);
}

public interface FileDescriptorBased : Object {
    public abstract int get_fd ();
}
```

`Gio.File` for `/dev/<name>` returns these streams: `read ()` gives a
`FileInputStream` that is `PollableInputStream` and `FileDescriptorBased`,
`append_to ()` gives the matching `FileOutputStream`, and `SimpleIOStream`
pairs them into one `IOStream`. No new stream base class is needed:
`FilterInputStream`, `BufferedInputStream` and `DataInputStream` already exist
([stdlib/gio/streams.vala](../stdlib/gio/streams.vala)).

### 5.2 Composition

The userland pipeline is a chain of Vala objects, not kernel modules:

```
/dev/serial0 -> DeviceInputStream -> LineDiscipline -> BufferedInputStream -> parser
```

- Composition is static and type-checked: constructors, not `I_PUSH`.
- `Gio` streams are synchronous; there is no `read_async`. A pipeline inside
  `MainContext` must run each stage as a coroutine (`async`/`yield`, VL-08) that
  yields on readiness. A blocking `read` inside the loop stalls every source.
- One syscall per underlying read or write, amortized by buffering. Filters copy
  through each stage; this is accepted for byte devices.

### 5.3 Limits

- No message boundaries and no control messages. Byte streams model a TTY, not a
  packet protocol.
- Flow control is per stage (`canput`/`backenable` have no equivalent). Use
  coroutines and bounded queues between stages.
- Line discipline and terminal echo move to userland **last**. `SYS_READ_KEY`
  currently decodes scancodes and folds stdin, serial and the virtio console
  ([kernel/syscall.vala](../kernel/syscall.vala)); it stays until `/dev/console`
  covers the shell and the boot/panic console.

## 6. Contract B: framed devices

### 6.1 Ring

One granted page for the header, followed by a descriptor array.

Header (little-endian):

| Offset | Size | Field | Writer |
|---|---|---|---|
| 0x00 | 4 | magic `PLNR` | static |
| 0x04 | 4 | version (`1`) | static |
| 0x08 | 4 | entries (power of two) | static |
| 0x0C | 4 | entry size (`32`) | static |
| 0x10 | 4 | head | device/consumer |
| 0x14 | 4 | tail | producer (user) |
| 0x18 | 4 | seq | kernel on completion |
| 0x1C | 4 | wake word | kernel on completion |
| 0x20 | 4 | doorbell epoch | kernel |
| 0x24 | 4 | status / error bits | kernel |

Descriptor (32 bytes):

| Offset | Size | Field |
|---|---|---|
| 0x00 | 8 | address (in the process I/O arena) |
| 0x08 | 4 | length |
| 0x0C | 4 | flags (`READ`, `WRITE`, `FENCE`, `MORE`) |
| 0x10 | 4 | buffer lease id |
| 0x14 | 4 | status (filled on completion) |
| 0x18 | 8 | reserved |

Ordering: the producer writes descriptors, executes a full fence, then
increments `tail`. The consumer reads `tail` with acquire semantics. `seq` is
published with release. Single producer and single consumer per ring.

**Implemented in C1** (`kernel/syscall.vala`): the header above, descriptors
with `address`/`length`/`flags`/`lease`/`status` (reserved words untouched), and
status values `1 READY`, `2 DONE`, `3 ERROR`. `SYS_RING_ATTACH(grant, entries)`
accepts a `KIND_RING` handle only when the magic, the version, the entry count
and the entry size match and the whole ring fits inside the grant.
`SYS_RING_KICK` consumes `head..tail`, validates each `READY` descriptor
(flags must be a known combination, `0 < length <= 16 KiB`, and the whole
`[address, address+length)` range inside the ring block), and only then runs it:
C1's stand-in operation fills the buffer with `0xA5` when `WRITE` is set. A
rejected descriptor gets `ERROR`, the syscall returns `EINVAL` and the device is
never touched. `seq` is incremented and `SYS_WAKE_ADDR` is applied to it, so a
completion can be awaited without polling. Leases are not implemented yet.

### 6.2 Validation and doorbell

`SYS_RING_KICK(handle, count)` is the only doorbell path:

1. Snapshot `tail`; copy up to `count` descriptors to kernel memory.
2. Reject the batch unless every descriptor address and length lie inside a
   window granted to the calling process.
3. Reject flags not allowed by the handle rights.
4. Reject a lease id that the caller does not hold, or a buffer not in
   `DEVICE` state.
5. Reject overlap with kernel-owned frames or with another process window.
6. Only then publish the descriptors to the device and ring its doorbell.

A rejected batch returns an error and increments a per-ring counter; it never
programs the device. The kernel is the only writer of the device's avail index
and of the MMIO doorbell. Userland never maps a BAR.

### 6.3 Completion

The kernel IRQ handler records the used index, increments `seq`, writes the wake
word and calls the internal equivalent of `SYS_WAKE_ADDR`. Userland waits with
`SYS_WAIT_ADDR` and consumes the completions. There is no userland interrupt
handler.

### 6.4 Ownership

A buffer lease has three states: `APP`, `DEVICE`, `FREE`.

- `kick` moves every referenced lease from `APP` to `DEVICE`.
- Completion moves it back to `APP`.
- `close` or cancellation moves `DEVICE` leases to `FREE` only after the device
  has acknowledged the reset; otherwise the ring is quarantined.
- A buffer in `DEVICE` state cannot be written by the application. This is a
  runtime check in the allocator and in the copy path, not a compiler proof.

### 6.5 Safety without an IOMMU

Until D-15 closes, userland never programs DMA. The kernel validates every
descriptor and owns the doorbell. This keeps the security property of the
exokernel design (secure binding) while keeping the driver in ring 0, so the
monolithic kernel and the discarded-microkernel decision are preserved.

## 7. Event integration

- `SYS_POLL` becomes **readiness per handle**. Today it reports "the fd slot is
  occupied" for `fd >= 3`, treats 0/1/2 as special cases, and caps the call at 15
  fds ([kernel/syscall.vala](../kernel/syscall.vala)).
- `MainContext` grows beyond its fixed 8-watch buffer
  ([stdlib/glib/mainloop.vala](../stdlib/glib/mainloop.vala)) and watches handles,
  not raw file descriptors.
- Timeouts and cancellation use `Cancellable` plus the wake word. No blocking
  read inside the loop.

## 8. Roadmap and exit criteria

| Phase | Work | Exit criterion |
|---|---|---|
| **A1** | Handle ownership, generation, rights, aliases 0/1/2 | **Done for ownership, generation and rights**: the `system` case proves cross-task denial (`EBADF`), missing-right refusal (`EACCES`) and stale-value refusal (`EBADF`); 19/19 QEMU cases green. A dedicated per-process table remains an optional optimisation |
| **A2** | `SYS_GRANT`, I/O arena, migrate `SharedSurface` | **Done for grants**: `SYS_GRANT` returns a handle over a block the task owns, `SYS_GRANT_SHARE` puts a task id in its ACL, `SYS_FREE_PAGE` refuses a non-owner and any range a live grant covers, and `SYS_MAP_USER_AT` refuses another task's block. `system` proves it (`memguard=ok`). The compositor grants its surface and shares it with the client before `spawn`, so zero-copy keeps working (`graphics`, `compositor-ext`). A dedicated I/O arena remains optional |
| **A3** | PML4 validation and recoverable user copies (KR-07) | **Done**: an unmapped pointer to `SYS_READ` and to `SYS_WRITE` returns `EINVAL` and the task keeps running (`guard=ok`). **A3.1 also done**: paths, `readdir` and `stat_ex` stage through the scratch, and `copy_guarded` moves 8 bytes per iteration. 20/20 QEMU cases green |
| **A4** | Raw escapes out of the public API | `poke`/`peek`/`call_ptr` are absent from the public stdlib surface |
| **B1** | `devfs` and `Gio.File` for `/dev` | **Done for the namespace**: `gio_demo` opens `/dev/console`, checks `PollableInputStream`/`FileDescriptorBased`/`PollableOutputStream`/`is_writable` and closes the pair as one `IOStream` (`dev=ok` in `system`). Remaining: `cat` through `/dev/serial0` and a readiness-driven read |
| **B2** | Filter chains and line discipline in userland | A line-discipline case passes; `SYS_READ_KEY` still works |
| **C1** | Ring ABI, validation, `SYS_RING_KICK` | **Done for the ABI and the validator**: `SYS_RING_ATTACH` binds a `KIND_RING` handle to a granted block whose header matches the documented layout, and `SYS_RING_KICK` validates every ready descriptor against that block (op, length, range) before running it, marking `RING_ST_ERROR` and returning `EINVAL` when one is malformed. `system` proves it (`ring=ok`): a valid echo completes, an out-of-block descriptor is rejected untouched. Remaining: a real device op (virtio-blk in C2) and the completion path through `wait_addr` on the ring sequence |
| **C2** | IRQ-driven block I/O (virtio-blk) | **Done**: `kernel/virtio_blk.vala` finds the device, negotiates `VIRTIO_F_VERSION_1`, sets up queue 0, reads four sectors through it (`blk=ok`, magic verified on sector 0) and takes every completion from an MSI-X interrupt (`blk:irq=4/4`, `blk:late=0`, 40/40 reads over 10 boots, ~50 in a row with no fallback). The capability is parsed with the table offset/BIR dword, table entry 0 carries this LAPIC and vector 64, the enable bit is read back before `msix_config`/`queue_msix_vector` are set to 0, and INTx is disabled as the spec requires. `Hal.lapic_init` disables x2APIC (QEMU `-cpu max` starts with it on, which makes the LAPIC registers MSR-only), sets SIVR and TPR, and the handler acks with `lapic_eoi`. Two earlier failures were the waiter's own doing: a two-tick park that outran the interrupt, and a used-ring read on every wake that could beat the message by a few milliseconds. The used ring is now read only when the one-second watchdog expires, so a slow message can only lose to a timeout |
| **C3** | `virtio-net` and a minimal LibOS stack | ARP/ICMP echo over the ring |
| **D** | Buffer leases and revocation | Cancelling a request quarantines the ring and frees no DEVICE buffer |
| **E** | IOMMU + userland drivers + reincarnation | Deferred; see D-15 |

A1-A4 are serial. B and C run in parallel after A1-A3. D depends on C1. E is a
separate project.

## 9. Verification

- **Host profile** (VE-01): handle rights, descriptor validation, ring parser,
  lease state machine. Pure logic, no QEMU.
- **QEMU**: handle denial across processes, unowned grant rejection, invalid
  pointer recovery, poll readiness, malformed descriptor, block throughput,
  network echo. The `system` case carries the current evidence: `fdguard`,
  `rights` and `stale` for handles, `guard` for user copies, `memguard` for
  grants, `ring` for the descriptor validator, and `blk:irq=4/4` with
  `blk:late=0` for four virtio-blk reads completed by MSI-X. Network echo
  arrives with C3.
- **Symbol audit** (VE-02): no device code in the standard library; no host
  symbol in the target.
- `SharedSurface` stays covered by the existing compositor cases.

## 10. Relationship to the classical designs

| Design | Taken | Not taken |
|---|---|---|
| **STREAMS** (Ritchie, V8) | Userland filter composition, push/pop as constructors, one handle per source | Kernel modules, `M_*` control messages, execution on the IRQ path |
| **Amoeba** (Tanenbaum) | Capabilities as kernel-enforced handles with rights | Single address space, RPC-only objects, no local driver |
| **Exokernel / LibOS** (Engler, Kaashoek) | Secure binding of frames, rings and interrupts; protocol stacks in userland | Unprivileged MMIO/DMA without an IOMMU |
| **MINIX 3** | Supervisor that can restart a driver | Restarting ring-0 drivers; deferred to Phase E |
| **Singularity / Oberon** | One language and one library for kernel and userland | Language-based isolation: `planc` has ARC, raw pointers and `[AsmBody]`, not linear types and not a verifier |

## 11. Open decisions and requirements

- **D-14**: byte streams plus kernel-validated rings, as defined here.
- **D-15**: IOMMU and userland drivers; closed only with a driver that crashes
  without corrupting the kernel.
- **IO-01** to **IO-06** in [00-requirements.md](00-requirements.md).
- **KR-07** (recoverable user accesses) and **US-02** (isolated address space)
  are prerequisites, not consequences, of this document.
