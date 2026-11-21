# planc.elf running inside PlanetOS, compiling and executing from a test folder.
mkdir test
mkdir test/compiler
cp utf8.vala test/compiler/utf8.vala
cp class_basic.vala test/compiler/class_basic.vala
exec planc.elf --target=planetos test/compiler/utf8.vala -o test/compiler/utf8.elf
test/compiler/utf8.elf
exec planc.elf --target=planetos test/compiler/class_basic.vala -o test/compiler/cls.elf
test/compiler/cls.elf
