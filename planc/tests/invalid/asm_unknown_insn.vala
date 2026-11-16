[AsmBody(@"
    bogus_mnemonic %rax, %rbx
    ret
")]
private static extern void bad_asm();

void main() {
    bad_asm();
}
