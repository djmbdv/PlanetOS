# 09 - Gio.Planet (`gio-planet-1.0`)

Status: **Phases 1–3 initial implemented** ([stdlib/gio/planet.vala](../stdlib/gio/planet.vala), [net.vala](../stdlib/gio/net.vala), [converter.vala](../stdlib/gio/converter.vala), [subprocess.vala](../stdlib/gio/subprocess.vala), [user/mercury.vala](../user/mercury.vala)).
This document specifies the PlanetOS-native `Gio.Planet` API (the counterpart to `gio-unix-2.0`) and the hybrid userland-service + zero-copy ring architecture defined in [08-io-data-path.md](08-io-data-path.md).

## 1. Naming and scope

PlanetOS has no POSIX, no `AF_UNIX`, and no Linux-style `-d` daemon naming (`netd`, `blkd`, `devd`).
System services in userland use PlanetOS-native names (following `pluto`, `saturn`, `compositor`):

- **`mercury`** — Network service (`virtio-net` + ARP/ICMP/UDP/TCP over shared rings and grants).
- **`atlas`** — Block/storage service (`virtio-blk` / XFS / RAMFS cache over shared rings and grants).
- **`iris`** — Device namespace & readiness broker (`/dev` discovery and handle routing).

The Vala API lives in namespace `Gio` (package **`gio-planet-1.0`**, [stdlib/gio/planet.vala](../stdlib/gio/planet.vala)) so it integrates directly with `GLib`, `Gio.InputStream`/`OutputStream`, `PollableInputStream`/`PollableOutputStream`, `FileDescriptorBased`, and `Cancellable`.

## 2. API mapping (`gio-unix-2.0` -> `Gio.Planet`)

| `gio-unix-2.0` | `Gio.Planet` (`gio-planet-1.0`) | Backing PlanetOS primitive |
|---|---|---|
| `UnixInputStream` / `UnixOutputStream` | `PlanetInputStream` / `PlanetOutputStream` | Per-process handle (`KIND_DEV`, `KIND_FILE`, etc.) implementing `PollableInputStream`, `PollableOutputStream`, `FileDescriptorBased` |
| `UnixFDMessage` / `UnixFDList` | `PlanetCapMessage` *(planned)* | Explicit handle + grant transfer (`SYS_GRANT_SHARE` / `SYS_HANDLE_SEND`) |
| `UnixSocketAddress` / `UnixConnection` | `PlanetServiceAddress` / `PlanetConnection` *(planned)* | Control-plane connection to `mercury` / `atlas` / `compositor` |
| *(no Unix equivalent)* | `PlanetGrant` | Page-owned memory capability (`SYS_ALLOC_PAGE` + `SYS_GRANT` + `SYS_GRANT_SHARE` + `SYS_FREE_PAGE`) |
| *(no Unix equivalent)* | `PlanetRing` | `PLNR` descriptor ring (`SYS_RING_ATTACH` + `SYS_RING_KICK` + `SYS_WAIT_ADDR` on `seq`) |
| *(no Unix equivalent)* | `PlanetRingSource` *(planned)* | `GLib.Source` that inspects `head`/`tail`/`seq` with 0 syscalls before parking |

## 3. Hybrid architecture (Control Plane vs Data Plane)

Combining a shared userland service (for global state such as IP/ARP tables or block caches) with zero-copy rings and `planc` coroutines avoids double-copying payloads over IPC:

```text
  [ App (Gio.Planet + GLib.MainContext) ]
       │                      ▲
       │ Control (IPC/async)  │ Data: Zero-Copy (PlanetGrant + PlanetRing)
       ▼                      │
  [ Service: mercury / atlas (async/yield coroutines + Channel<T>) ]
       │                      ▲
       │ SYS_RING_KICK (batch)│ MSI-X -> SYS_WAKE_ADDR (seq)
       ▼                      │
  [ Kernel Ring 0: descriptor validation + doorbell + IRQ ]
```

1. **Control plane (low frequency, userland service):**
   - `mercury` or `atlas` owns global protocol state (ARP table, IP config, port bindings, mount/cache policy).
   - Opening a session grants the client a shared `PlanetGrant` / `PlanetIoArena` window via `SYS_GRANT_SHARE`.
2. **Data plane (high frequency, zero-copy):**
   - Payloads stay in the granted `PlanetIoArena` pages; neither the service nor the kernel copies data across user/service boundaries.
   - Only 32-byte `PLNR` descriptors and lease indices move.
3. **Concurrency (`async`/`yield` + `GLib.MainContext`):**
   - Inside `mercury` and `atlas`, `planc` `async`/`yield` coroutines and `Channel<T>` multiplex batches without OS thread context switches per packet.
   - Inside GUI/CLI apps, `Gio.Planet` exposes `GLib.Source` and `Pollable*Stream` so `GLib.MainContext` stays non-blocking.

## 4. Performance invariants

1. **Zero-syscall `prepare()`/`check()`:** `PlanetRing` reads `seq` and `head != tail` directly from the shared header; `SYS_WAIT_ADDR` / `SYS_POLL` is called only when the ring is empty.
2. **Batched doorbells:** Multiple descriptors are queued before a single `SYS_RING_KICK` call, amortizing `int 0x80` overhead.
3. **Pre-mapped `PlanetIoArena`:** Pages are allocated and granted once at session setup; the hot path rotates `APP` / `DEVICE` / `FREE` buffer leases without editing page tables (`SYS_MAP_USER_AT` / `SYS_FREE_PAGE`).
4. **Zero-copy Contract B views:** Network/block streams expose slices `(grant, offset, length)` over lease buffers; byte-copying `BufferedInputStream` chains remain reserved for low-bandwidth Contract A devices (`/dev/serial0`, `/dev/console`).

## 5. Implementation plan

- **Phase 1 (done):** `PlanetInputStream`, `PlanetOutputStream`, `PlanetGrant` (including bounded `read_bytes`/`write_bytes`/`get_u8`/`put_u8`), `PlanetRing` (`DEV_ECHO`/`DEV_BLK`/`DEV_NET`), and `PlanetBlockDevice` (`virtio-blk`).
- **Phase 2 (done):** `MainContext` `KIND_CUSTOM` 0-syscall ring/socket watch, `SYS_POLL` for `KIND_RING*`, `PlanetIoArena` lease state machine (`FREE`/`APP`/`DEVICE` + quarantine), `Gio.Converter` (`LineDisciplineConverter`), `Gio.Subprocess`, `Gio.Socket`, `Gio.SocketService`, `Gio.ThreadedSocketService`, `Gio.Resolver`, `Gio.NetworkService`.
- **Phase 3 (in progress):** `user/mercury.vala` (`virtio-net` + ARP/ICMP echo green in QEMU). Next: `SYS_HANDLE_SEND`, cross-process `PlanetConnection` IPC over `mercury`/`atlas`, UDP/TCP/DNS in `mercury`, and kernel-side Phase D lease enforcement.
