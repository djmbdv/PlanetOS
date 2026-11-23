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
| Device namespace (`/dev`) | [kernel/vfs.vala](../kernel/vfs.vala) | **missing**: `SYS_OPEN` resolves only XFS/RAMFS |
| Handles with ownership, generation and rights | [kernel/syscall.vala](../kernel/syscall.vala) | implemented (A1.1/A1.2): 64 slots, `index \| generation << 8`, per-operation rights |
| Capability grant | `SYS_MAP_USER_AT`, [kernel/syscall.vala](../kernel/syscall.vala) | **missing**: maps any physical frame above 6 MiB |
| Safe user copies with page-fault recovery (KR-07) | [kernel/syscall.vala](../kernel/syscall.vala) | **missing** |
| Interrupt-driven completion | `kernel/ata.vala`, `kernel/virtio_gpu.vala` | **missing**: PIO and bounded spin loops |
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

### 4.2 Memory grants

- `SYS_GRANT(handle, offset, len, prot)` maps only frames owned by the resource
  named by the handle.
- Each process owns a pre-mapped **I/O arena**: a fixed virtual window granted at
  `exec`. Grants carve windows inside it. The fast path does not edit page
  tables; the mapping cost is paid once.
- `SYS_MAP_USER_AT` and `SYS_MAP_USER_RO_AT` are not capabilities and must be
  removed from the public ABI once `SharedSurface` and the `.dlib` loader
  ([stdlib/gmodule_compat.vala](../stdlib/gmodule_compat.vala)) use `SYS_GRANT`.
  Until then they are an open isolation hole: they map `vaddr == paddr` for any
  physical frame above 6 MiB, with `RW|USER` or read-only, without checking
  ownership.

### 4.3 User copies

- Validate the range against the caller's PML4, not only against a fixed
  `USER_LIMIT`.
- Copy through a recoverable path: a page fault inside a registered copy point
  returns an error and the task survives (KR-07). Today a bad pointer kills the
  task in the middle of the operation.
- Ring descriptors are read through a kernel copy, never dereferenced in place,
  so a racing producer cannot change a validated descriptor (no TOCTOU).

### 4.4 Raw escapes

`Sys.poke8/poke32/peek32/call_ptr*` ([stdlib/planet_sys.vala](../stdlib/planet_sys.vala))
are public today and defeat any type-based security claim. Move them to an
internal unsafe module available only to the runtime and to the dlib loader.

## 5. Contract A: byte devices

### 5.1 Shape

```vala
// Gio has no Pollable interface today; both types are part of this phase.
public interface Pollable : Object {
    public abstract bool ready (uint32 condition) throws IOError; // POLL.IN / POLL.OUT
}

public class DeviceInputStream : Gio.InputStream, Pollable {
    public DeviceInputStream (Sys.Handle handle, Sys.Rights rights);
}
```

`Gio.File` for `/dev/<name>` returns these streams. No new stream base class is
needed: `FilterInputStream`, `BufferedInputStream` and `DataInputStream` already
exist ([stdlib/gio/streams.vala](../stdlib/gio/streams.vala)).

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
| **A2** | `SYS_GRANT`, I/O arena, migrate `SharedSurface` | Mapping an unowned frame fails; the compositor still attaches a client surface |
| **A3** | PML4 validation and recoverable user copies (KR-07) | An invalid user pointer returns an error and the calling task survives |
| **A4** | Raw escapes out of the public API | `poke`/`peek`/`call_ptr` are absent from the public stdlib surface |
| **B1** | `devfs` and `Gio.File` for `/dev` | `open("/dev/serial0")` returns a stream and `cat` works through it |
| **B2** | Filter chains and line discipline in userland | A line-discipline case passes; `SYS_READ_KEY` still works |
| **C1** | Ring ABI, validation, `SYS_RING_KICK` | A malformed descriptor is rejected without touching the device |
| **C2** | IRQ-driven block I/O (virtio-blk) | No spin loop in the block path; throughput case passes |
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
  network echo.
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
