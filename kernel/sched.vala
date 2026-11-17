// Preemptive round-robin kernel task scheduler over PIT IRQ0 (100 Hz).

namespace Planet.Kernel {

    private const int SCHED_CUR_ADDR = 0x123FF0;
    private const int SCHED_EN_ADDR  = 0x123FF8;
    private const int TCB_BASE       = 0x124000;
    private const int MAX_TASKS      = 16;
    private const int TCB_SIZE       = 128;

    private const int TASK_FREE    = 0;
    private const int TASK_READY   = 1;
    private const int TASK_RUNNING = 2;
    private const int TASK_ZOMBIE  = 3;

    // TCB layout (128 bytes):
    // +0:  state (8B)
    // +8:  saved_rsp (8B)
    // +16: stack_base (8B)
    // +24: exit_code (8B)
    // +32: parent_tid (8B)
    // +40: ticks (8B)
    // +48: name[32]
    // +80: stack_pages (8B)
    // +88: cr3 (8B)
    // +96: kstack_base (8B)
    // +104: rsp0 (8B)

    public int sched_tick (int cur_rsp) {
        // Increment global system tick counter (0x106000)
        int t = mmio_read64 (0x106000);
        mmio_write64 (0x106000, t + 1);

        if (mmio_read64 (SCHED_EN_ADDR) == 0)
            return cur_rsp;

        int cur = mmio_read64 (SCHED_CUR_ADDR);
        int cur_tcb = TCB_BASE + cur * TCB_SIZE;
        mmio_write64 (cur_tcb + 8, cur_rsp);
        if (cur == 0) {
            mmio_write64 (cur_tcb + 104, Hal.get_tss_rsp0 ());
        }
        int tt = mmio_read64 (cur_tcb + 40);
        mmio_write64 (cur_tcb + 40, tt + 1);

        if (mmio_read64 (cur_tcb) == TASK_RUNNING)
            mmio_write64 (cur_tcb, TASK_READY);

        int next = cur;
        for (int off = 1; off <= MAX_TASKS; off++) {
            int cand = (cur + off) % MAX_TASKS;
            int ctcb = TCB_BASE + cand * TCB_SIZE;
            if (mmio_read64 (ctcb) == TASK_READY) {
                next = cand;
                break;
            }
        }

        int next_tcb = TCB_BASE + next * TCB_SIZE;
        mmio_write64 (next_tcb, TASK_RUNNING);
        mmio_write64 (SCHED_CUR_ADDR, next);
        int nrsp0 = mmio_read64 (next_tcb + 104);
        Hal.set_tss_rsp0 ((nrsp0 != 0) ? nrsp0 : 0x200000);
        int ncr3 = mmio_read64 (next_tcb + 88);
        int target_cr3 = (ncr3 != 0) ? ncr3 : Vmm.KERNEL_CR3;
        if (vmm_read_cr3 () != target_cr3) {
            vmm_write_cr3 (target_cr3);
        }
        return mmio_read64 (next_tcb + 8);
    }

    [AsmBody(@"
        push %rax
        push %rbx
        push %rcx
        push %rdx
        push %rsi
        push %rdi
        push %rbp
        push %r8
        push %r9
        push %r10
        push %r11
        push %r12
        push %r13
        push %r14
        push %r15
        mov %rsp, %rdi
        call sched_tick
        mov %rax, %rsp
        mov $0x20, %al
        out %al, $0x20
        pop %r15
        pop %r14
        pop %r13
        pop %r12
        pop %r11
        pop %r10
        pop %r9
        pop %r8
        pop %rbp
        pop %rdi
        pop %rsi
        pop %rdx
        pop %rcx
        pop %rbx
        pop %rax
        iretq
    ")]
    public extern void isr_sched_irq0 ();

    [AsmBody(@"
        lea isr_sched_irq0(%rip), %rax
        ret
    ")]
    public extern int addr_isr_sched_irq0 ();

    public class Sched : Object {
        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        public static void init () {
            for (int i = 0; i < (MAX_TASKS * TCB_SIZE) / 8; i++) {
                mmio_write64 (TCB_BASE + i * 8, 0);
            }
            // Task 0 represents the main shell/userland task
            mmio_write64 (TCB_BASE + 0, TASK_RUNNING);
            mmio_write64 (TCB_BASE + 32, -1);
            mmio_write8 (TCB_BASE + 48 + 0, 's');
            mmio_write8 (TCB_BASE + 48 + 1, 'h');
            mmio_write8 (TCB_BASE + 48 + 2, 'e');
            mmio_write8 (TCB_BASE + 48 + 3, 'l');
            mmio_write8 (TCB_BASE + 48 + 4, 'l');
            mmio_write8 (TCB_BASE + 48 + 5, 0);

            mmio_write64 (SCHED_CUR_ADDR, 0);
            mmio_write64 (SCHED_EN_ADDR, 1);
            Hal.set_idt_gate_dpl (32, addr_isr_sched_irq0 (), 0);
        }

        public static int current_tid () {
            if (mmio_read64 (SCHED_EN_ADDR) == 0)
                return 0;
            return mmio_read64 (SCHED_CUR_ADDR);
        }

        public static int spawn_ready (int entry, int arg_sp, int stack_base, int name_ptr, int name_len) {
            int parent = current_tid ();
            for (int tid = 1; tid < MAX_TASKS; tid++) {
                int tcb = TCB_BASE + tid * TCB_SIZE;
                if (mmio_read64 (tcb) == TASK_FREE) {
                    // Build synthetic iretq + 15-GPR frame below arg_sp
                    mmio_write64 (arg_sp - 8,  0x10);   // SS
                    mmio_write64 (arg_sp - 16, arg_sp); // RSP
                    mmio_write64 (arg_sp - 24, 0x202);  // RFLAGS (IF=1)
                    mmio_write64 (arg_sp - 32, 0x08);   // CS
                    mmio_write64 (arg_sp - 40, entry);  // RIP
                    for (int g = 1; g <= 15; g++) {
                        mmio_write64 (arg_sp - 40 - g * 8, 0);
                    }
                    int frame_rsp = arg_sp - 160;

                    mmio_write64 (tcb + 8, frame_rsp);
                    mmio_write64 (tcb + 16, stack_base);
                    mmio_write64 (tcb + 24, 0);
                    mmio_write64 (tcb + 32, parent);
                    mmio_write64 (tcb + 40, 0);
                    mmio_write64 (tcb + 80, 16);
                    mmio_write64 (tcb + 88, 0);
                    mmio_write64 (tcb + 96, 0);
                    mmio_write64 (tcb + 104, 0);
                    int nmax = (name_len < 31) ? name_len : 31;
                    for (int k = 0; k < nmax; k++) {
                        mmio_write8 (tcb + 48 + k, read_u8 (name_ptr + k));
                    }
                    mmio_write8 (tcb + 48 + nmax, 0);
                    mmio_write64 (tcb + 0, TASK_READY);
                    return tid;
                }
            }
            return -1;
        }

        public static int spawn_thread (int entry, int arg) {
            int stack_base = Pmm.alloc_contiguous (16);
            if (stack_base == 0)
                return -1;
            int arg_sp = stack_base + 16 * 4096 - 16;
            // Temporarily write "thread" name on stack_base+0..6
            mmio_write8 (stack_base + 0, 't');
            mmio_write8 (stack_base + 1, 'h');
            mmio_write8 (stack_base + 2, 'r');
            mmio_write8 (stack_base + 3, 'e');
            mmio_write8 (stack_base + 4, 'a');
            mmio_write8 (stack_base + 5, 'd');
            int tid = spawn_ready (entry, arg_sp, stack_base, stack_base, 6);
            if (tid < 0) {
                for (int p = 0; p < 16; p++)
                    Pmm.free_frame (stack_base + p * 4096);
                return -1;
            }
            // Put `arg` into saved %rdi slot (offset +72 in 15-GPR frame)
            int frame_rsp = mmio_read64 (TCB_BASE + tid * TCB_SIZE + 8);
            mmio_write64 (frame_rsp + 72, arg);
            return tid;
        }

        public static void exit_current (int code) {
            int cur = mmio_read64 (SCHED_CUR_ADDR);
            int tcb = TCB_BASE + cur * TCB_SIZE;
            mmio_write64 (tcb + 24, code);
            mmio_write64 (tcb + 0, TASK_ZOMBIE);
            cpu_sti ();
            while (true) {
                cpu_hlt ();
            }
        }

        public static void set_current_exec_ctx (int cr3, int rsp0) {
            int cur = current_tid ();
            int tcb = TCB_BASE + cur * TCB_SIZE;
            mmio_write64 (tcb + 88, cr3);
            mmio_write64 (tcb + 104, rsp0);
        }

        public static int current_cr3 () {
            int cur = current_tid ();
            return mmio_read64 (TCB_BASE + cur * TCB_SIZE + 88);
        }

        public static int spawn_user_ready (int entry, int user_sp, int user_stack_base, int user_stack_pages, int user_cr3, int name_ptr, int name_len) {
            int kstack = Pmm.alloc_contiguous (4);
            if (kstack == 0)
                return -1;
            int ktop = kstack + 4 * 4096;
            int parent = current_tid ();
            for (int tid = 1; tid < MAX_TASKS; tid++) {
                int tcb = TCB_BASE + tid * TCB_SIZE;
                if (mmio_read64 (tcb) == TASK_FREE) {
                    // Synthetic Ring-3 iretq + 15-GPR frame on kernel stack
                    mmio_write64 (ktop - 8,  0x1B);     // User SS (RPL=3)
                    mmio_write64 (ktop - 16, user_sp);  // User RSP
                    mmio_write64 (ktop - 24, 0x202);    // RFLAGS (IF=1)
                    mmio_write64 (ktop - 32, 0x23);     // User CS (RPL=3)
                    mmio_write64 (ktop - 40, entry);    // User RIP
                    for (int g = 1; g <= 15; g++) {
                        mmio_write64 (ktop - 40 - g * 8, 0);
                    }
                    int frame_rsp = ktop - 160;
                    mmio_write64 (tcb + 8, frame_rsp);
                    mmio_write64 (tcb + 16, user_stack_base);
                    mmio_write64 (tcb + 24, 0);
                    mmio_write64 (tcb + 32, parent);
                    mmio_write64 (tcb + 40, 0);
                    mmio_write64 (tcb + 80, user_stack_pages);
                    mmio_write64 (tcb + 88, user_cr3);
                    mmio_write64 (tcb + 96, kstack);
                    mmio_write64 (tcb + 104, ktop);
                    int nmax = (name_len < 31) ? name_len : 31;
                    for (int k = 0; k < nmax; k++) {
                        mmio_write8 (tcb + 48 + k, read_u8 (name_ptr + k));
                    }
                    mmio_write8 (tcb + 48 + nmax, 0);
                    mmio_write64 (tcb + 0, TASK_READY);
                    return tid;
                }
            }
            for (int p = 0; p < 4; p++)
                Pmm.free_frame (kstack + p * 4096);
            return -1;
        }

        public static void set_stack_pages (int tid, int pages) {
            if (tid <= 0 || tid >= MAX_TASKS)
                return;
            mmio_write64 (TCB_BASE + tid * TCB_SIZE + 80, pages);
        }

        public static int wait_tid (int tid) {
            if (tid <= 0 || tid >= MAX_TASKS)
                return -1;
            int tcb = TCB_BASE + tid * TCB_SIZE;
            if (mmio_read64 (tcb) == TASK_FREE)
                return -1;
            while (mmio_read64 (tcb) != TASK_ZOMBIE) {
                cpu_sti ();
                cpu_hlt ();
            }
            int code = mmio_read64 (tcb + 24);
            int sbase = mmio_read64 (tcb + 16);
            int spages = mmio_read64 (tcb + 80);
            int ucr3 = mmio_read64 (tcb + 88);
            int kbase = mmio_read64 (tcb + 96);
            if (spages <= 0)
                spages = 16;
            if (sbase != 0) {
                Vmm.map_4k (sbase);
                for (int p = 0; p < spages; p++) {
                    Pmm.free_frame (sbase + p * 4096);
                }
            }
            if (kbase != 0) {
                for (int p = 0; p < 4; p++) {
                    Pmm.free_frame (kbase + p * 4096);
                }
            }
            if (ucr3 != 0) {
                Vmm.destroy_user_space (ucr3);
            }
            mmio_write64 (tcb + 88, 0);
            mmio_write64 (tcb + 96, 0);
            mmio_write64 (tcb + 104, 0);
            mmio_write64 (tcb + 0, TASK_FREE);
            return code;
        }

        private static int append_str (int buf, int pos, int max_b, string s) {
            for (int i = 0; i < s.length && pos < max_b; i++) {
                mmio_write8 (buf + pos, (int) s[i]);
                pos = pos + 1;
            }
            return pos;
        }

        private static int append_int (int buf, int pos, int max_b, int v) {
            if (v == 0) {
                if (pos < max_b) {
                    mmio_write8 (buf + pos, '0');
                    pos = pos + 1;
                }
                return pos;
            }
            int tmp = v;
            int digits = 0;
            int rev = 0;
            while (tmp > 0) {
                rev = rev * 10 + (tmp % 10);
                tmp = tmp / 10;
                digits = digits + 1;
            }
            for (int d = 0; d < digits && pos < max_b; d++) {
                mmio_write8 (buf + pos, '0' + (rev % 10));
                rev = rev / 10;
                pos = pos + 1;
            }
            return pos;
        }

        public static int list_tasks (int buf, int max_b) {
            if (max_b <= 0)
                return 0;
            int pos = append_str (buf, 0, max_b, "TID STATE   TICKS NAME\n");
            for (int tid = 0; tid < MAX_TASKS; tid++) {
                int tcb = TCB_BASE + tid * TCB_SIZE;
                int st = mmio_read64 (tcb);
                if (st == TASK_FREE)
                    continue;
                pos = append_int (buf, pos, max_b, tid);
                pos = append_str (buf, pos, max_b, "   ");
                if (st == TASK_READY) pos = append_str (buf, pos, max_b, "READY   ");
                else if (st == TASK_RUNNING) pos = append_str (buf, pos, max_b, "RUNNING ");
                else pos = append_str (buf, pos, max_b, "ZOMBIE  ");
                pos = append_int (buf, pos, max_b, mmio_read64 (tcb + 40));
                pos = append_str (buf, pos, max_b, "     ");
                for (int k = 0; k < 31 && pos < max_b; k++) {
                    int ch = read_u8 (tcb + 48 + k);
                    if (ch == 0)
                        break;
                    mmio_write8 (buf + pos, ch);
                    pos = pos + 1;
                }
                if (pos < max_b) {
                    mmio_write8 (buf + pos, '\n');
                    pos = pos + 1;
                }
            }
            return pos;
        }
    }
}
