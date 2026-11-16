# Slice 16 — DWARF v4 Debug Info (`.debug_line`, `.debug_abbrev`, `.debug_info`)

Slice 16 emits standard DWARF v4 debugging sections in every generated ELF64
executable so both host tools (`gdb`, `readelf`, `addr2line`) and a future
self-hosted PlanetOS debugger (`plandbg`) or kernel panic backtracer can resolve
addresses to source lines, functions, frame bases, and local/parameter slots
without `libc` or `libdwarf`.

## 1. Implementation

- [dwarf.vala](../../planc/src/dwarf.vala):
  - `Dwarf.build` encodes `.debug_line` (DWARF v4 line-number program with
    `DW_LNE_set_address`, `DW_LNS_advance_pc`, `DW_LNS_advance_line`,
    `DW_LNS_copy`, `DW_LNE_end_sequence`), `.debug_abbrev`, and `.debug_info`
    (`DW_TAG_compile_unit`, `DW_TAG_base_type`, `DW_TAG_subprogram` with
    `DW_OP_reg6` `rbp` frame base, `DW_TAG_formal_parameter` and
    `DW_TAG_variable` with `DW_OP_fbreg` offsets).
- [codegen.vala](../../planc/src/codegen.vala): records `DebugLineEntry` per
  statement in `gen_statement` and `DebugFunc` / `DebugVar` per function in
  `generate_function`.
- [elf.vala](../../planc/src/elf.vala) & [main.vala](../../planc/src/main.vala):
  appends `.debug_line`, `.debug_abbrev`, and `.debug_info` as non-`ALLOC`
  sections after `.shstrtab`, keeping the 3 `PT_LOAD` segments unchanged.

## 2. Verification

- `dwarf_info` in [run.sh](../../planc/tests/run.sh) verifies `.debug_line` and
  `.debug_info` (`DW_TAG_subprogram`) via `readelf`.
- 3-stage self-hosted fixed-point bootstrap (`./planc/bootstrap.sh`):
  `sha256(planc2) == sha256(planc3)` (`830e78e3d1da4dcb9be6976a3a6f2e4e66a53b1849e75599a10e92ea5904537c`, `1671432 bytes`),
  `173 cases, 173 pass, 0 fail`.
