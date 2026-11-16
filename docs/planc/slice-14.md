# Slice 14 — `signal`, `.connect()`, `.disconnect()`, and ARC Cleanup

Slice 14 completes Vala-compatible `signal` support on classes, including
inheritance, default handlers, lambda/closure connection, disconnection by ID,
and automatic destructor cleanup without leaks.

## 1. Compiler & Runtime Design

- **Per-instance storage**: each `SignalDecl` in a class reserves a hidden
  pointer field `#sig_<name>` (`sd.slot_index`) in the object layout,
  zero-initialized by `__planc_alloc` and inherited by subclasses.
- **Handler list (`SigNode`)**: `__planc_sig_connect` allocates a 32-byte
  payload node (`+16` next, `+24` unique atomic `id`, `+32` `#code`, `+40`
  `#env`), retains `#env` if non-null, and appends in FIFO order.
- **Disconnection & finalizers**: `__planc_sig_disconnect(slot_addr, id)` unlinks
  and unrefs the matching node + closure `#env`. Classes with signals always emit
  a finalizer calling `__planc_sig_free_list` for each signal slot.
- **Emission (`obj.sig(args)` / `sig(args)`)**: runs `sd.default_handler` if
  present, then iterates the linked list safely (caching `next` before each
  invocation) passing `(#env, sender, args...)`.

## 2. Verification

- [signals.vala](../../planc/tests/valid/signals.vala) +
  `check_leaks_signals` + [signal_wrong_arg.vala](../../planc/tests/invalid/signal_wrong_arg.vala).
- Verified with `172/172` passing cases under both Stage 1 and self-hosted `planc2`.
