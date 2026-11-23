# Translate C -> Vala -> ELF64 and execute it entirely inside PlanetOS, with
# all generated files under test/c2vala. The translator emits c_init_stdio (),
# so the build needs c2vala_rt.vala; it is packed with planet_sys.vala and the
# GLib layer into c2vala_sdk.vala (tools/make_sdk.py) because the guest shell
# line buffer is 480 bytes.
mkdir test
mkdir test/c2vala
cp arith.c test/c2vala/arith.c
c2vala test/c2vala/arith.c -o test/c2vala/arith.vala
planc test/c2vala/arith.vala c2vala_sdk.vala -o test/c2vala/arith.elf
test/c2vala/arith.elf
