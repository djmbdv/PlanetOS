# Kernel-backed environment variables: inherited by child processes and used by planc.
mkdir test
mkdir test/env
cp arith.c test/env/arith.c
echo $OS
export FOO=bar
echo $FOO
unset FOO
c2vala test/env/arith.c -o test/env/arith.vala
planc test/env/arith.vala c2vala_sdk.vala -o test/env/arith.elf
test/env/arith.elf
