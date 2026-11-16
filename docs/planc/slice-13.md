# Slice 13 — `async` / `yield` Coroutines and M:N Parallel Scheduler

Slice 13 implements Vala-compatible `async` / `yield` / `.begin()` coroutines
with heap-allocated state machines (`VL-08`) and an M:N cooperative + parallel
runtime scheduler (`Async.run()` and `Async.run_parallel(n)`) without `libc` or
GIO (`I1`, `I2`).

## 1. Language Surface

- **`async` modifier** on top-level functions and class methods (`async void`,
  `async T`, `async T throws Err`, `virtual`/`override`/`static`). Rejected on
  `main`, constructors, destructors, `extern`, `[AsmBody]`, properties, fields,
  and `signal`s, as well as `ref`/`out` parameters on `async` functions.
- **`yield;` and `yield <expr>`**:
  - `yield;` suspends the current coroutine and re-enqueues it at the tail of
    the run queue.
  - `yield child_async(...)` or `yield task_handle` awaits a child `AsyncTask`,
    suspending only if the child has not yet completed, propagating returned
    values (including IEEE-754 `float`/`double` via `xmm0`) and `throws` errors.
  - `for` loops containing `yield` / `continue` resume directly at the suspension
    point inside the loop body without re-executing or duplicating the `for` step
    (`VL-08`).
- **`.begin(...)` and direct spawn**: calling `fn(args)` or `fn.begin(args)` (or
  `obj.method.begin(args)`) spawns an `AsyncTask` handle, enqueues it, and
  returns the ARC-managed handle.
- **Scheduler entry points**:
  - `Async.run()`: runs all queued tasks cooperatively on the calling thread.
  - `Async.run_parallel(int workers)`: spawns `workers - 1` OS worker threads
    via Linux `SYS_clone` (`CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|CLONE_CHILD_CLEARTID`),
    coordinates sleeping workers with `SYS_futex`, joins all worker threads, and
    unmaps their 64 KiB stacks via `SYS_munmap` before returning.

## 2. Heap State Machine & Thread-Safe Allocator

- **Heap frame redirection**: `__async_resume_<fn>(AsyncTask* task)` stores
  `task` in `[rbp - 8]` and sets `Emitter.async_task_rbp_offset = -8`, routing
  all local variables, error slots, and expression temps into `[task + 80 + 8*slot]`.
  Every `AsyncTask` is allocated via `__planc_alloc(64 + 8*slots, 0)` and
  managed by atomic ARC (`lock inc` / `lock dec` + `task_lock` spinlock).
- **Thread-safe `__planc_alloc` / `__planc_unref`**: slab carving and size-class
  free-list operations are serialized by a spinlock at `alloc_bss_offset + 96`.

## 3. Verification

- `planc/tests/valid/async_goroutines.vala` (and `check_leaks_async_goroutines`):
  covers cooperative `yield;`, `yield child()`, `async double`, `for` + `yield`
  + `continue`, class method `.begin()`, `throws`/`try`/`catch` across `yield`,
  `Async.run()`, and `Async.run_parallel(2)` with zero leaks.
- `planc/tests/invalid/async_yield_outside.vala`: verifies `yield` outside
  `async` is rejected at compile time.
- 3-stage self-hosted fixed-point bootstrap (`./planc/bootstrap.sh`):
  `sha256(planc2) == sha256(planc3)` (`f0a3829a3d6ed7e5711a7f55f2f344dc7ade8fe9c28abe3300e4add7d342195d`),
  and `166/166` passing test cases under `planc2`.
