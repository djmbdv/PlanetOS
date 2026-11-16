# E-04 — `async` and `yield` in Vala 0.56

- **Risk it attacks:** R-05 (incomplete `async` lowering), R-20 (primitive missing in `planetrt`)
- **Assumption it answers:** V-03

## 1. Main finding: `async` depends on GIO

```
$ valac async.vala
error: gio-2.0 package required for async methods
```

It is not an optional dependency: `valac` implements `async` on top of `GTask`, `GAsyncResult` and `GMainContext`. The generated C contains:

```c
GTask* _async_result;
GAsyncResult* _res_;
GObject* _source_object_;

_data_->_async_result = g_task_new (NULL, NULL, _callback_, _user_data_);
g_task_set_task_data (_data_->_async_result, _data_, contar_data_free);
g_task_return_pointer (_data_->_async_result, _data_, NULL);
g_main_context_iteration (g_task_get_context (_data_->_async_result), TRUE);
```

PlanetOS does not have GIO. Therefore:

> **Vala's `async` is not reusable as an API reference. Only its *shape* of lowering serves as a reference.**

It is a design constraint, not a problem to solve: `planc` defines its own model of awaitables over coroutines and the `planetrt` event loop.

## 2. Shape of the lowering (this is reused)

Source:

```vala
async int contar(int hasta) {
    int total = 0;
    for (int i = 0; i < hasta; i++) {
        if (i % 2 == 0) { yield; }
        total += i;
    }
    return total;
}
```

### 2.1 The state goes to the heap, always

```c
struct _ContarData {
    int _state_;
    GObject* _source_object_;
    GAsyncResult* _res_;
    GTask* _async_result;
    gint hasta;      // parameter
    gint result;     // return value
    gint total;      // local that survives the yield
    gint i;          // loop variable
    gboolean _tmp0_; // for-loop temporary
    gint _tmp1_;     // for-loop temporary
};
```

**All** locals go to the heap, not only those that cross a `yield`. Even internal temporaries (`_tmp0_`, `_tmp1_`) that do not appear in the source.

### 2.2 Reentry from the top with `goto`, not dispatch by state

```c
static gboolean contar_co (ContarData* _data_) {
    switch (_data_->_state_) {
        case 0: goto _state_0;
        case 1: goto _state_1;
        default: g_assert_not_reached ();
    }
    _state_0:
    _data_->total = 0;
    … loop …
                if ((_data_->i % 2) == 0) {
                    _data_->_state_ = 1;
                    return FALSE;      // suspend
                    _state_1:
                    ;
                }
    …
    return TRUE;                        // finish
}
```

The function is **re-invoked from the beginning** and jumps to the resumption point with `goto`. There is no function per state. `return FALSE` suspends; `return TRUE` signals completion.

This shape transfers directly to SSA IR: the `switch` over `_state_` is a switch of blocks, and the labels are jump targets.

### 2.3 The `for` is rewritten with a flag

```c
_data_->i = 0;
_data_->_tmp0_ = TRUE;
while (TRUE) {
    if (!_data_->_tmp0_) { _data_->_tmp1_ = _data_->i; _data_->i = _data_->_tmp1_ + 1; }
    _data_->_tmp0_ = FALSE;
    if (!(_data_->i < _data_->hasta)) break;
    …
}
```

The `_tmp0_` flag avoids incrementing on resumption. It is the subtlest part of the whole lowering: a `continue` or a `yield` inside the body must not execute the increment twice.

## 3. Consequences for `planc`

| Vala decision | `planc` decision | Reason |
|---|---|---|
| State always on the heap | State on the heap by default; on the stack if escape analysis proves it does not escape | Without `GTask` there is no reason to always allocate; but correctness rules and the analysis only optimizes |
| `GTask`/`GAsyncResult` | `Planet.Corrutinas.Tarea` | There is no GIO |
| Reentry with `goto` | Reentry with a `switch` over the block index, in the IR | The IR is SSA; jumps are edges |
| Loop with a flag | Same | The measured semantics is replicated |
| Awaiter in `GMainContext` | Awaiter in `Planet.Eventos.Principal` | Same concept, our own implementation |

Derived requirement: `planc` **must** emit the loop control flag in the lowering of `for` inside an `async` method. Without it, a `continue` after a `yield` produces an infinite loop or a skipped index.

## 4. Conclusion

- **Passes**, with a major constraint: the `async` model is our own.
- **V-03 answered:** `yield` does exist, and its lowering is reentry with `goto` and full state on the heap.
- **Changes to the plan:** [02 §8.1](../02-compiler.md#81-async) must state that Vala's API is not reused; only the shape. And the loop flag must be added as an explicit requirement of the lowering.
