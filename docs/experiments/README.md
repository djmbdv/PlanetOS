# Experiments

Record of what has been **measured**, with the harness that measures it. An experiment without a reproducible command is not an experiment.

## 1. Rules

1. Each experiment is a directory in [`experiments/`](../../experiments) with its script.
2. The result is documented here, with the real output, not the expected one.
3. A plan assumption only becomes "answered" when it has a linked measurement.
4. If the measurement contradicts the plan, **the plan is corrected**, not the measurement.

## 2. Environment

The oracle (`valac`) is installed without root from the system packages:

```sh
experiments/oracle/install.sh     # downloads the .deb packages and extracts them into a local prefix
. experiments/oracle/env.sh        # PATH, PKG_CONFIG_PATH, LD_LIBRARY_PATH
```

Measured versions: `Vala 0.56.18`, GLib `2.88.0`, GCC `15.2`, QEMU `10.2.1`, x86_64.

`valac` is a **development oracle only**. It is not part of the delivered toolchain ([02 §15](../02-compiler.md#15-bootstrap)).

## 3. Registry

| ID | Topic | Status | Result in one line |
|---|---|---|---|
| [E-01](E01-dialect.md) | Real dialect of Vala 0.56 | **measured** | 39 cases, 29 compile; the 10 rejections are language rules or environment dependencies |
| [E-01 §3](E01-dialect.md#3-generics-erasure--boxing-not-monomorphization) | Generics (was E-02) | **measured** | type erasure + boxing; monomorphization is our deviation |
| [E-01 §4](E01-dialect.md#4-delegates-function-pointer--target-destroy_notify-not-a-struct) | Delegates (was E-03) | **measured** | `fn` + a separate `(target, destroy_notify)` pair, not a struct |
| [E-01 §5](E01-dialect.md#5-object-initialization-order-measured) | Construction order (was E-05) | **measured** | defaults → `construct` properties → `construct` block → body |
| [E-04](E04-async.md) | `async`/`yield` | **measured** | tied to GIO; the shape is reused, not the API |
| [E-06](E06-vapis.md) | `[CCode]` in vapis | **measured** | `cheader_filename` ×752 forces deferred rejection |
| [E-08](E08-dwarf.md) | DWARF without CFI | **measured** | GDB works with a frame pointer and without `.eh_frame` |

Pending, which require `planc` to be truly measured:

| ID | Topic | Why it cannot be measured with `valac` |
|---|---|---|
| E-02 | Bootstrap fixed point | needs a compiler of our own |
| E-07 | Binary reproducibility | measures `planc`, not `valac` |
| V-08 | Circular dependencies between units | needs the semantics implementation |

## 4. Corrections applied to the plan

| # | Correction | Document |
|---|---|---|
| 1 | Initialization order: `construct` goes **before** the body | [02 §3.3](../02-compiler.md#33-semantics) |
| 2 | Monomorphization marked as a conscious deviation, with a reason | [02 §4.1](../02-compiler.md#41-generics) |
| 3 | Delegate = fat pointer `{fn, environment}`, not `{fn, env, destructor}` | [02 §6](../02-compiler.md#6-closures) |
| 4 | Signals: `valac` already generates a static marshaller; libffi was not necessary | [02 §7](../02-compiler.md#7-signals) |
| 5 | `async` does not reuse Vala's API (GIO) and requires a loop control flag | [02 §8.1](../02-compiler.md#81-async) |
| 6 | `[Inline]` and `[NoAtomico]` are our own extensions, not Vala attributes | [02 §2.1](../02-compiler.md#21-accepted) |
| 7 | Measured restrictions: `switch`, `lock`, `main`, arrays, generic constraints | [02 §2.1](../02-compiler.md#21-accepted) |
| 8 | VL-11 is justified by the absence of a C ABI, not by the language | [00 §2](../00-requirements.md#2-language-requirements-vl) |
| 9 | Rejection of foreign attributes deferred to the point of use | [02 §2.2](../02-compiler.md#22-rejected-with-a-diagnostic-tc-07) |
