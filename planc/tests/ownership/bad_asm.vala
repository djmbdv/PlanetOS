int main () {
    return 0;
}

[AsmBody(@"
    xor %rax, %rax
    ret
")]
private extern int untrusted_asm ();