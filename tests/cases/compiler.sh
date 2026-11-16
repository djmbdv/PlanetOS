# planc.elf running inside PlanetOS, compiling and executing from XFS.
exec planc.elf --target=planetos utf8.vala -o utf8.elf
utf8.elf
exec planc.elf --target=planetos class_basic.vala -o cls.elf
cls.elf
rm utf8.elf
rm cls.elf
