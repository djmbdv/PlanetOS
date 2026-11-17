# Hardware #PF isolation: a userland null-page read must fault (exit 142) without crashing the kernel or shell.
echo '[AsmBody("xor %rax, %rax; mov (%rax), %rax; ret")] extern int boom(); int main() { return boom(); }' > boom.vala
exec planc.elf --target=planetos boom.vala -o boom.elf
exec boom.elf
echo shell:alive=1
rm boom.vala
rm boom.elf
