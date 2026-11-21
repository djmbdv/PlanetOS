# Hardware #PF isolation: a userland null-page read must fault (exit 142) without
# crashing the kernel or shell. Source and binary live in test/fault.
mkdir test
mkdir test/fault
echo '[AsmBody("xor %rax, %rax; mov (%rax), %rax; ret")] extern int boom(); int main() { return boom(); }' > test/fault/boom.vala
exec planc.elf --target=planetos test/fault/boom.vala -o test/fault/boom.elf
exec test/fault/boom.elf
echo shell:alive=1
