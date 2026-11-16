// Background worker task for preemptive multitasking test (--target=planetos --image-base=0x900000).

namespace UserWorker {

    [AsmBody(@"
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        int $0x80
        ret
    ")]
    public extern int sys (int num, int a0, int a1, int a2);

    int main () {
        int start = sys (2, 0, 0, 0);
        int cur = start;
        while (cur - start < 4) {
            sys (10, 0, 0, 0);
            cur = sys (2, 0, 0, 0);
        }
        print (@"worker: completed after $(cur - start) ticks\n");
        return 7;
    }
}
