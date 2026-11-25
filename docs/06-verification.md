# 06 — Verification

## 1. Principles

1. **Every requirement has an executable verification** (VE-06). A requirement without a test is an intention.
2. **Most of it is verified without an emulator.** The `host` profile exists for that (VE-01).
3. **Tests do not depend on the external toolchain.** `valac` may be used as an oracle during development, never as a dependency of the delivered system.
4. **A failure reproduced in `host` is fixed in `host`.**

## 2. Bootstrap fixed point

It is the central verification of the compiler (I4, TC-09, VE-03).

```
planc-0   = valac + host C compiler               →  development binary
planc-1   = planc-0 compiles planc                →  first native
planc-2   = planc-1 compiles planc                →  second native
planc-3   = planc-2 compiles planc                →  third
```

Criteria:

| # | Criterion | Check |
|---|---|---|
| B1 | `planc-1` compiles `planc` without errors | exit code |
| B2 | `sha256(planc-2) == sha256(planc-3)` | binary comparison |
| B3 | `planc-1`, `planc-2` and `planc-3` produce the conformance suite green | running the suite with each of them |
| B4 | The `planc-1` binary does not reference host symbols outside the `host` profile | symbol audit |

If B2 fails, there is non-determinism in the compiler: dictionary iteration order, embedded addresses, timestamps or absolute paths. It is a compiler failure, not a test failure, and it blocks delivery.

A second, stricter fixed point is added once the system boots:

| # | Criterion |
|---|---|
| B5 | `planc` compiles `planc` **running inside PlanetOS** and produces the same binary as `planc-1` |

B5 is not necessary for the correctness of the system; it is the proof that the toolchain is self-sufficient.

## 3. Validation experiments

Each experiment answers a `[V]` assumption or a representation decision. They have no assigned duration: they have a closure criterion. The live record is in [`docs/experiments/`](experiments/README.md).

| ID | Question | Status | Result |
|---|---|---|---|
| **E-01** | Which constructs does `valac` actually accept? | **measured** | [E01-dialect.md](experiments/E01-dialect.md) |
| **E-02** | Monomorphized or erased generics? | **measured** (absorbed into E-01 §3) | erased with `GType` + boxing |
| **E-03** | What shape does a delegate have? | **measured** (absorbed into E-01 §4) | `fn` + `(target, destroy_notify)` pair |
| **E-04** | How is `async` lowered? | **measured** | [E04-async.md](experiments/E04-async.md) — tied to GIO |
| **E-05** | Does `finally` exist? How is `lock` closed on error? | **measured** (in E-01 §2) | it exists; it is lowered to a label, with no unwinding |
| **E-06** | Which `[CCode]` attributes are there in the vapis? | **measured** | [E06-vapis.md](experiments/E06-vapis.md) |
| **E-07** | Is the differential oracle reproducible? | pending | requires `planc` to compare |
| **E-08** | Useful DWARF without CFI? | **measured** | [E08-dwarf.md](experiments/E08-dwarf.md) — yes, with frame pointer |

Reproducible harness, without root:

```sh
experiments/oracle/install.sh
. experiments/oracle/env.sh
experiments/e01-dialect/run.sh
experiments/e01-dialect/run_executables.sh
```

Each result is archived together with the command that produces it. An experiment whose numbers cannot be reproduced does not count as a measurement.

## 4. Verification in QEMU

```bash
#!/bin/sh
# tests/qemu.sh <image> [seconds]
set -u
IMAGE="${1:?missing image}"
LIMIT="${2:-60}"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

CODE=0
timeout "$LIMIT" qemu-system-x86_64 \
    -cdrom "$IMAGE" \
    -display none \
    -serial "file:$LOG" \
    -m 1G -smp "${SMP:-1}" \
    -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 || CODE=$?

echo "--- serial ---"
cat "$LOG"

if [ "$CODE" -eq 124 ]; then
    echo "FAIL: no output within ${LIMIT}s (possible hang or panic without exit)" >&2
    exit 125
fi

# isa-debug-exit returns (code << 1) | 1
STATUS=$(( (CODE - 1) / 2 ))
exit "$STATUS"
```

The kernel writes to port `0xf4` with `(code << 1) | 1` to terminate. Code 0 means success; any other code identifies the test that failed.

### 4.1 Implemented harness (`tests/qemu.py`)

The repository ships a working subset of the above. `tests/qemu.py` builds the
system once through the launchers (`run-qemu.sh --build-only`,
`run-qemu.ps1 -BuildOnly`), then boots the kernel headless for every case in
`tests/cases/`, types the case script into the shell over COM1 and checks the
serial output against `<case>.expect`.

| Case | What it proves |
|---|---|
| `system` | the kernel contract behind the process API: the errno table, `readdir`, the kernel log, `Cond`, `poll`, `sleep`, `wait`; handle guards (`fdguard`, `rights`, `stale`) and recoverable user copies (`guard`); threads and the pool (`thread`, `pool`); devfs plus `Gio` polling (`dev`); frame ownership and grants (`memguard`); the validated descriptor ring (`ring`); and four virtio-blk reads, each completed by an MSI-X interrupt (`blk:irq=4/4`, `blk:late=0`, `blk=ok`) |
| `fault` | a page fault in a user task is reported with tid, vector, error code, rip and cr2; the task exits 142 and the shell keeps running (`shell:alive=1`) |
| `debug` | the kernel logger: level filter, per-category toggles, `dmesg` empty after a clear, PS/2 mouse resync counters, and the boot records (window verified, mouse on IRQ12, GPU fallback) |
| `env` | `env`/`getenv` round-trip between parent and child plus the compiler demo values (`gcd=21`, `collatz(6)=8`) |
| `time` | `date` prints UTC and `uptime` prints wall time and the tick count |
| `c2vala` | the C-to-Vala translator runs in the guest: it writes `test/c2vala/arith.vala`, `planc` compiles it and the binary reports `gcd=21` and `collatz(1..6)` |
| `jsmn` | the translated jsmn parser tokenizes the JSON sample: 12 tokens with the expected type, start, end and size |
| `gpu` | the virtio-gpu probe reports the device as absent instead of faulting when QEMU has no such device |
| `calendar` | the calendar panel is built with the environment time zone and three places, and the compositor summary reports zero failures |
| `directories` | `mkdir`/`cd`/`pwd`, `ls -l`, path-relative `write`/`cat`/`mv`/`rm`, empty-directory deletion |
| `gio` | the Gio layer runs twice in one boot at 51/51 |
| `exec` | bare, case-insensitive and `exec` command resolution |
| `errors` | the unlink/mkdir/cat error paths run inside `test/errors` (a RAMFS tree that disappears at the next boot), so the shared XFS root is untouched and later cases still see `hello.txt`; the syscall guard rejects bad pointers (`sysguard:ok=1`) |
| `compiler` | `planc.elf` compiles and runs programs inside the guest |
| `objects` | `gobject_demo` and `gmodule_demo` report 19/19 and 14/14 |
| `mainloop` | `mainloop_demo` reports 17/17 (idle before timeouts, source removal, `Application.run`) |
| `graphics` | `cairo_demo`/`spv_demo` draw an 800×600 framebuffer (the 469-page surface proves the raised allocation limit), the shared SPIR-V module reports `words=169 insns=44 rgb=(56,188,247)`, `vk_demo --once` paints a GSK `ShaderNode` from `frag_pattern.spv`, the compositor self-test passes 108/108 in three modes (static, --vulkan, --animate: damage merge, occlusion, modifiers, per-pixel pattern, push constants, shared surface header, two-rectangle publish and the shared input ring) and the Vulkan refusal is reported |
| `saturn` | `saturn --self-test` proves the interactive contract: one keystroke damages one editor line, Enter damages down to the viewport bottom, an arrow key damages the two caret rows, arrow keys reach the focused editor instead of scrolling the side panel, focus is exclusive between the list and the editor, and the window publishes exactly the rectangles it repainted into a shared surface |
| `compositor-ext` | `compositor --ext saturn.elf --keys abcd --frames 400` boots a real client through the production path: the compositor allocates the block and spawns `saturn.elf`, the client attaches it, receives the typed keys through the input ring, and publishes three rectangles (initial frame, edited line, status label) totalling less than two full frames — with no `_comp_*` file in `/tmp` and the desktop pass skipped for rectangles covered by the window (`bg>0`) |
| `pango` | `pango_demo` reports 44/44: metrics, wrapping, ellipsize, alignment, colour attribute runs, `clip()` and text drawing |

Assertions: `text` (substring, in order), `=text` (whole line), `!text`
(absent) and `~regex`.

The launcher is part of the contract: `tools/mkdisk.py` consumes every guest
binary, so a unit without its own build rule silently reuses the member that is
already in `disk.img` and the case passes against old code. Compare the artifact
timestamp with the source before believing a measurement (R-39 in
[07](07-risks-and-decisions.md)).

```sh
python tests/qemu.py                # build + every case in parallel
python tests/qemu.py --no-build     # reuse the last build
python tests/qemu.py --case gio     # one case
python tests/qemu.py -j 4           # cap parallel QEMU workers
python tests/qemu.py --accel tcg    # force TCG instead of auto KVM
```

To keep runs fast, `tests/qemu.py` passes `-snapshot` (with `file.locking=off`
on the IDE image) so cases run in parallel across `--jobs`/`-j` workers,
auto-enables `-accel kvm` on Linux when `/dev/kvm` is accessible (`--accel auto`,
falling back to `tcg` for frame-budget-sensitive cases such as `compositor-ext`),
uses a `0.005` s character typing `--delay`, and reads COM1 output in 4 KiB
chunks with a `threading.Condition` instead of 100 ms polling.

Host-side differential tests for the C -> Vala translator live in [tools/c2vala_tests/run.py](tools/c2vala_tests/run.py) (gcc vs valac on the same source; needs MSYS2, not QEMU). The native translator has to be built first: `tools/c2vala/build_host.sh` for this host (`.exe` on Windows) or `tools/c2vala/build.sh` for the guest (ELF, planc). A case directory with `refuse.txt` must be refused with that message, one with `report.txt` must print those lines under `--report`, and one with `planc_only.txt` is skipped unless planc compiles the generated code:

```sh
python tools/c2vala_tests/run.py --translator vala   # native, 5 passed (unions need planc)
python tools/c2vala_tests/run.py --translator py     # python, 6 passed
```

Tests that require QEMU, and only those:

| Test | What it proves |
|---|---|
| Boot up to `init` | KR-01, KR-02 |
| Atomic counter with N threads | KR-04 |
| Out-of-range write by a process | KR-07, US-02 |
| Injection of each CPU exception | KR-05 |
| Controlled panic and dump | KR-06 |
| Round trip of SIMD registers between threads | KR-09 |
| Simulated power cut over `pfs` | file system coherence |
| Complete guest suite | VE-05 |

The tests for allocator, containers, strings, signals, coroutines, errors and formatting do **not** require QEMU: they run on `host`.

## 5. Suites

| Suite | Location | Requirement |
|---|---|---|
| Language conformance | `dialecto/conformidad/` | VL-01 … VL-11, TC-10 |
| Language negatives | `dialecto/conformidad/negativos/` | TC-07, VL-11 |
| Runtime on `host` | `planetrt/tests/` | RT-01 … RT-09 |
| Type layout | `planc/tests/layout/` | VL-02, VL-05 |
| ABI and calls | `planc/tests/abi/` | §3 of [01](01-architecture.md#3-own-abi) |
| Linker and relocations | `planc/tests/enlace/` | TC-03, TC-05 |
| DWARF | `planc/tests/dwarf/` | TC-06 |
| Kernel in QEMU | `tests/kernel/` | KR-01 … KR-09 |
| Guest | `tests/guest/` | US-01 … US-07 |
| Shell | `tests/shell/` | US-04 |
| I/O data path | `tests/io/` | IO-01 to IO-06, KR-07 |

### 5.1 Language conformance

Each case is a program with an expected output, or a program that **must** fail with a specific diagnostic:

```
conformidad/
├── clases/
│   ├── herencia.vala            expected output
│   ├── interfaces.vala
│   ├── propiedades.vala
│   └── constructores.vala
├── genericos/
├── cierres/
├── async/
├── errores/
├── senales/
└── negativos/
    ├── ccode_cheader.vala       must fail with TC-07
    └── varargs.vala             must fail with VL-11
```

### 5.2 Symbol audit

Mandatory job (VE-02). For each binary of the system:

```bash
nm -u "$binary" | awk '{print $2}' > undefined.txt
comm -23 <(sort undefined.txt) <(sort allowed.txt) | tee forbidden.txt
test ! -s forbidden.txt
```

`allowed.txt` is generated from the symbols exported by `planetrt` for the corresponding profile. Any symbol outside that list is a failure, not a warning.

Additional checks on ELF:

| Check | Requirement |
|---|---|
| `readelf -d` without `DT_NEEDED` | US-01, I2 |
| No `PT_INTERP` | US-01 |
| No `.eh_frame` or `.plt` section | I1 |
| Sections with coherent permissions and no RWX | KR-03 |
| `e_entry` inside the executable segment | TC-03 |

## 6. Differential oracle

While the compiler matures, the semantics are contrasted against `valac` **on the host**:

```
same .vala
    ├─ planc  → native → runs → output A
    └─ valac  → C → cc   → runs → output B
                                    A must be equal to B
```

Oracle scope:

| Is compared | Is not compared |
|---|---|
| Result of expressions, arithmetic, conversions | Type layout |
| Constructor initialization order | Symbol names |
| Signal emission order | Performance |
| Error propagation and release | In-memory representation |
| Number and string formatting | — |

This use of `valac` is for **verification**, not for building: it does not appear in any artifact of the system and can be removed once the conformance suite is dense enough (E-07).

## 7. Fuzzing and robustness

| Target | Technique | Failure signal |
|---|---|---|
| Lexer and parser | random input and mutation of valid cases | crash, infinite loop, diagnostic without position |
| Semantic analysis | valid programs with type mutations | accepting what must be rejected |
| Register allocation | generated programs with many live variables | different result with and without optimization |
| Linker | objects with duplicated, missing and extremely distant symbols | linking something incorrect instead of failing |
| ELF loader | malformed binaries | kernel panic instead of a process error |

## 8. CI matrix

| Job | Command | Requirements it covers |
|---|---|---|
| `conformidad` | `planc test --suite=conformidad` | TC-08, TC-10, VL-* |
| `negativos` | `planc test --suite=negativos` | TC-07, VL-11 |
| `runtime-host` | `planc test --perfil=host` | RT-01 … RT-09, VE-01 |
| `layout-abi` | `planc test --suite=layout --suite=abi` | VL-02, VL-05, ABI |
| `enlace` | `planc test --suite=enlace` | TC-03, TC-05 |
| `dwarf` | `planc test --suite=dwarf` | TC-06 |
| `symbol-audit` | `tests/auditar-simbolos.sh` | I2, KR-02, RT-01, VE-02 |
| `bootstrap` | `tests/bootstrap.sh` | I4, TC-09, VE-03 |
| `boot` | `tests/qemu.sh iso/planetos.iso` | KR-01, VE-04 |
| `guest` | `tests/qemu.sh iso/planetos-tests.iso` | US-*, VE-05 |
| `io` | `planc test --suite=io` plus the QEMU cases of [08 §9](08-io-data-path.md#9-verification) | IO-01 to IO-06, KR-07 |
| `reproducible` | two builds, compare `sha256` | TC-05 |
| `fuzz` | `planc fuzz --semilla=<n>` | §7 |

## 9. Milestones by capability

Milestones are defined by what the system **can do**, not by when. Each one is reachable only if the previous one is verified.

| Milestone | Demonstrable capability | Requirements it closes |
|---|---|---|
| **M1** | `planc` compiles programs without classes or signals and runs them on `host` | TC-01, TC-02, TC-08 |
| **M2** | `planc` compiles classes, properties and signals; the fixed point converges | VL-01 … VL-06, I4, TC-09 |
| **M3** | `planc` compiles `async`, `throws` and `[AsmBody]`; useful DWARF | VL-07 … VL-09, TC-04, TC-06 |
| **M4** | The kernel boots, manages memory and runs threads | KR-01 … KR-06, KR-08 |
| **M5** | A user process in Vala runs without libc | US-01, US-02, US-06, I2 |
| **M6** | Interactive shell with pipelines and redirection | US-03, US-04, US-07 |
| **M7** | Persistent file system and SDK usable by third parties | US-05, coherence of `pfs` |
| **M8** | A process cannot name another's handle; `/dev/serial0` works through a `Gio` filter chain; one block ring completes by IRQ | IO-01 to IO-06, KR-07 |

M5 is the milestone that validates the whole thesis: **a process written in Vala, compiled by a compiler written in Vala, running without libc on a kernel written in Vala**.

## 10. What verification does not cover

Honesty about the limits:

| Not covered | Consequence |
|---|---|
| Behavior on physical hardware other than the emulated one | A driver failure may not show up in CI |
| Concurrency under sustained real load | Stress tests are bounded |
| Security against malicious code | There is no multi-user threat model. Process isolation (IO-01 to IO-03) is required even with a single user; a process that was granted a ring is trusted to speak its protocol |
| Compatibility with existing Vala programs | It is not a requirement (I3) |
| Formal correctness of the compiler | It is verified by conformance and oracle, not by proof |
