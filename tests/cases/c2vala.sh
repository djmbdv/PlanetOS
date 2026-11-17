# Translate C -> Vala -> ELF64 and execute it entirely inside PlanetOS!
c2vala arith.c -o arith.vala
planc arith.vala -o arith.elf
arith.elf
rm arith.vala
rm arith.elf
