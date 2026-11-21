# Translate C -> Vala -> ELF64 and execute it entirely inside PlanetOS, with
# all generated files under test/c2vala.
mkdir test
mkdir test/c2vala
cp arith.c test/c2vala/arith.c
c2vala test/c2vala/arith.c -o test/c2vala/arith.vala
planc test/c2vala/arith.vala -o test/c2vala/arith.elf
test/c2vala/arith.elf
