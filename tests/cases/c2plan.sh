# Translate C -> Plan -> ELF64 and execute it entirely inside PlanetOS, with
# all generated files under test/c2plan. The translator emits c_init_stdio (),
# so the build needs c2plan_rt.plan; it is packed with planet_sys.vala and the
# GLib layer into c2plan_sdk.plan (tools/make_sdk.py) because the guest shell
# line buffer is 480 bytes.
mkdir test
mkdir test/c2plan
cp arith.c test/c2plan/arith.c
c2plan test/c2plan/arith.c -o test/c2plan/arith.plan
planc test/c2plan/arith.plan c2plan_sdk.plan -o test/c2plan/arith.elf
test/c2plan/arith.elf
