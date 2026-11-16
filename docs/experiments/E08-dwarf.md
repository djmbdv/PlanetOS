# E-08 — Debugging without CFI

- **Requirement it attacks:** TC-06 (useful DWARF)
- **Question:** can GDB reconstruct the stack and show variables without `.eh_frame`?

## 1. Why it matters

`.eh_frame` exists for run-time unwinding (exceptions, `backtrace()`). `planc` has no unwinding: `throws` is lowered to an output parameter, not to `longjmp`. Emitting CFI would be work without a consumer.

The alternative is to keep the **frame pointer** (`rbp`) and let GDB use `.debug_frame`/the frame pointer.

## 2. Measurement

```sh
gcc -g -O0 -fno-omit-frame-pointer \
    -fno-asynchronous-unwind-tables -fno-unwind-tables \
    p.c -o p
```

Checks:

| Check | Result |
|---|---|
| `.eh_frame` in our own object (`.o`) | **absent** |
| Undefined unwinding symbols (`_Unwind_*`, `__gcc_personality_*`) | **none** (`nm -u` empty) |
| GDB reconstructs the frame chain | yes: `#0 producto`, `#1 compuesto`, `#2 main` |
| GDB shows arguments | yes: `a = 3`, `b = 4` |
| GDB shows locals | yes: `p = 7` |

Real output:

```
Breakpoint 1, producto (a=3, b=4) at p.c:2
#0  producto (a=3, b=4) at p.c:2
#1  0x0000555555555197 in compuesto (a=3, b=4) at p.c:3
#2  0x00005555555551bb in main () at p.c:4
a = 3
b = 4
p = 7
```

## 3. Conclusion

- **Passes.** The combination "frame pointer + DWARF without CFI" is enough for debugging.
- `.debug_frame` appears because `gcc -g` emits it on its own; it is not necessary if `rbp` is kept, but it is cheap and helps.
- **Decision confirmed:** `planc` does not emit `.eh_frame`. In `debug` it keeps `rbp` as the frame pointer even when there are free registers. In `release` it can dispense with it.
- **Change to the plan:** [02 §13](../02-compiler.md#13-dwarf) already said so; it is now verified by measurement instead of assumption.
