# Slice 53 - `GLib.Thread` as a kernel task

Status: **implemented.** `GLib.Thread` used to lower to a synchronous call on
`--target=planetos`: `__planc_thread_spawn` did `call rax` and `join` returned
immediately. A "thread" was the caller, and `ThreadPool` built on it would have
blocked in its constructor with an empty queue.

## 1. Lowering

| Runtime function | PlanetOS target | Host target |
|---|---|---|
| `__planc_thread_spawn(fn, arg)` | `SYS_THREAD_SPAWN` (27): entry in `rdi`, arg in `rsi`, tid in `rax` | `clone` as before |
| `__planc_thread_join(ctrl)` | `SYS_WAIT` (17) with the tid in `rdi` | waits on the control block |

The spawn result is therefore the tid, and the value `Thread._handle` stores is
that tid. The task runs in the caller's CR3, so `Thread` shares the heap and
statics exactly as a Vala thread should.

## 2. Exit

A kernel task has no return address: returning from the entry would pop garbage
from the user stack. The trampoline calls the body and then `SYS_EXIT`:

```vala
private void _c_glib_thread_trampoline (int slot) {
    _ThreadSlots.trampoline (slot);
#if PLANC
    Sys.sys (11, 0, 0, 0);
#endif
}
```

`#if PLANC` keeps the host build (valac) free of `Planet.Sys`.

## 3. Two bugs this exposed

Both were latent because no earlier code both created and reaped a thread.

| Bug | Symptom | Fix |
|---|---|---|
| `spawn_thread` wrote the task name at `stack_base` before mapping the range | Kernel write fault on the second spawn, when `Pmm` reused a frame that `reap_zombie` had just unmapped | `write_thread_name` runs after `map_user_range_checked` |
| `reap_zombie` unmapped the thread stack from the active CR3 and then freed the frames | `Pmm.free_frame` writes free-list metadata into the frame, which was no longer mapped | `Vmm.map_supervisor_range` (PTE `0x03`) around the release, then unmap |

## 4. Verification

`sys_demo` check 12 spawns a `Thread`, records `Sys.tid()` from the body and
asserts that it differs from the main tid:

```
thread=ok
```

`sys_demo` check 13 also creates a `ThreadPool` with two workers, pushes three
jobs and waits for the queue to drain:

```
pool=ok
```

`ThreadPool` is backed by real workers and its queue parses in the guest. Two
traps found while writing that check:

- The unqualified `Mutex` is the `planc` coroutine intrinsic, not `GLib.Mutex`.
  Naming it pulls the async runtime, and a program that imports `glib.dlib`
  then fails to link (`R-34` in [07](../07-risks-and-decisions.md)). The test
  uses `RecMutex`.
- `GLib.Mutex` cannot be named as a qualified type in that compilation unit
  (`unknown type 'GLib'`), so the workaround is the vapi-free `RecMutex`.

The full QEMU suite is 20/20.
