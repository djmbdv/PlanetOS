# Kernel-backed environment variables: inherited by child processes and used by planc.
echo $OS
export FOO=bar
echo $FOO
unset FOO
c2vala arith.c -o arith.vala
planc arith.vala -o arith.elf
arith.elf
rm arith.vala
rm arith.elf
