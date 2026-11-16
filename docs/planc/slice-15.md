# Slice 15 — `Channel<T>` and `Mutex` Synchronization Primitives

Slice 15 adds Go-style typed message channels (`Channel<T>`) and spinlock
mutexes (`Mutex`) on top of the Slice 13 M:N `async` scheduler.

## 1. `Channel<T>`

- `new Channel<T>()` creates an ARC-managed channel with an internal spinlock,
  FIFO message queue, and FIFO suspended `AsyncTask` waiter queue.
- `ch.send(T val)` retains reference-counted values, appends to the message
  queue, and wakes the next waiting task via `__planc_async_enqueue` if any.
- `yield ch.recv()` calls `__planc_chan_try_recv(ch, current_task)`: if a value
  is available it returns immediately without allocating a child `AsyncTask`; if
  empty (and open), the current task suspends until woken by `send` or `close`.
- `ch.close()` marks the channel closed and wakes all suspended readers.

## 2. `Mutex`

- `new Mutex()`, `m.lock()`, `m.unlock()` provide an ARC-managed atomic
  spinlock (`xchg` + `pause`) for shared state under `Async.run_parallel(n)`.

## 3. Verification

- [channels_and_mutex.vala](../../planc/tests/valid/channels_and_mutex.vala) +
  `check_leaks_channels_and_mutex` +
  [channel_type_mismatch.vala](../../planc/tests/invalid/channel_type_mismatch.vala).
- 3-stage self-hosted fixed-point bootstrap (`./planc/bootstrap.sh`):
  `sha256(planc2) == sha256(planc3)` (`ef24188e82be1742da78b7101b1002ad1af2ec64606a05d55bcbd72528bdbf27`),
  `172/172` cases passing under `planc2`.
