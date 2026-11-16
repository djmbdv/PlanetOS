int helper_add(int a, int b) {
    return a + b;
}

[AsmBody(@"
    # %rdi = a, %rsi = b -> return (a + b) * 3 + 1
    call helper_add
    lea (%rax,%rax,2), %rax
    add $1, %rax
    ret
")]
private static extern int asm_calc(int a, int b);

[AsmBody(@"
    # sum 1..%rdi using local labels and loop
    xor %rax, %rax
    xor %rcx, %rcx
.L_loop:
    inc %rcx
    cmp %rdi, %rcx
    jg .L_done
    add %rcx, %rax
    jmp .L_loop
.L_done:
    ret
")]
private static extern int asm_sum_to(int n);

[AsmBody(@"
    push %rbx
    xor %eax, %eax
    cpuid
    pop %rbx
    ret
")]
private static extern int asm_cpuid_max();

[AsmBody(@"
    rdtsc
    shl $32, %rdx
    or %rdx, %rax
    ret
")]
private static extern int asm_rdtsc();

class Hal : Object {
    [AsmBody(@"
        mov %rdi, %rax
        shl $3, %rax
        sub $2, %rax
        ret
    ")]
    public static extern int scale8_minus2(int x);
}

void main() {
    var r1 = asm_calc(4, 5);
    var r2 = asm_sum_to(10);
    var r3 = Hal.scale8_minus2(7);
    var cmax = asm_cpuid_max();
    var t0 = asm_rdtsc();
    print(@"r1=$r1 r2=$r2 r3=$r3 cpuid_ok=$(cmax > 0) tsc_ok=$(t0 != 0)\n");
}
