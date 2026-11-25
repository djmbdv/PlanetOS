// Preemptive round-robin kernel task scheduler over PIT IRQ0 (100 Hz).

namespace Planet.Kernel {

    private const int MAX_TASKS      = 16;
    private const int TCB_SIZE       = 128;

    private const int XSAVE_STRIDE   = 1024;

    [AsmBody(@"
        mov $7, %eax
        xor %edx, %edx
        .byte 0x0f, 0xae, 0x27
        ret
    ")]
    public extern void xsave_to (int addr);

    [AsmBody(@"
        mov $7, %eax
        xor %edx, %edx
        .byte 0x0f, 0xae, 0x2f
        ret
    ")]
    public extern void xrstor_from (int addr);

    private static void init_fx_area (int tid) {
        int fx = KernelLayout.FXSAVE_AREA + tid * XSAVE_STRIDE;
        for (int i = 0; i < XSAVE_STRIDE; i += 8)
            mmio_write64 (fx + i, 0);
        mmio_write16 (fx + 0, 0x037F);  // x87 FCW default
        mmio_write32 (fx + 24, 0x1F80); // SSE MXCSR default
    }

    private const int TASK_FREE    = 0;
    private const int TASK_READY   = 1;
    private const int TASK_RUNNING = 2;
    private const int TASK_ZOMBIE  = 3;
    private const int TASK_BLOCKED = 4;

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
    // +112: stdio_in_fd (8B)
    // +120: stdio_out_fd (8B)

    public int sched_tick (int cur_rsp) {
        // Increment the global system tick counter
        int t = mmio_read64 (KernelLayout.TICK);
        mmio_write64 (KernelLayout.TICK, t + 1);

        if (mmio_read64 (KernelLayout.SCHED_ENABLED) == 0)
            return cur_rsp;

        int cur = mmio_read64 (KernelLayout.SCHED_CUR);
        int cur_tcb = KernelLayout.TCB_TABLE + cur * TCB_SIZE;
        mmio_write64 (cur_tcb + 8, cur_rsp);
        if (cur == 0) {
            mmio_write64 (cur_tcb + 104, Hal.get_tss_rsp0 ());
        }
        int tt = mmio_read64 (cur_tcb + 40);
        mmio_write64 (cur_tcb + 40, tt + 1);

        if (mmio_read64 (cur_tcb) == TASK_RUNNING)
            mmio_write64 (cur_tcb, TASK_READY);

        // A blocked task is resumed on its deadline; the waker side
        // (SYS_WAKE_ADDR) clears it earlier when the futex word changes.
        Sched.sweep_deadlines ();

        int next = cur;
        for (int off = 1; off <= MAX_TASKS; off++) {
            int cand = (cur + off) % MAX_TASKS;
            int ctcb = KernelLayout.TCB_TABLE + cand * TCB_SIZE;
            if (mmio_read64 (ctcb) == TASK_READY) {
                next = cand;
                break;
            }
        }

        if (next != cur) {
            xsave_to (KernelLayout.FXSAVE_AREA + cur * XSAVE_STRIDE);
        }

        int next_tcb = KernelLayout.TCB_TABLE + next * TCB_SIZE;
        mmio_write64 (next_tcb, TASK_RUNNING);
        mmio_write64 (KernelLayout.SCHED_CUR, next);
        int nrsp0 = mmio_read64 (next_tcb + 104);
        Hal.set_tss_rsp0 ((nrsp0 != 0) ? nrsp0 : KernelLayout.STACK_TOP);
        int ncr3 = mmio_read64 (next_tcb + 88);
        int target_cr3 = (ncr3 != 0) ? ncr3 : KernelLayout.PAGE_TABLES;
        if (vmm_read_cr3 () != target_cr3) {
            vmm_write_cr3 (target_cr3);
        }
        if (next != cur) {
            xrstor_from (KernelLayout.FXSAVE_AREA + next * XSAVE_STRIDE);
        }
        return mmio_read64 (next_tcb + 8);
    }

    [AsmBody(@"
        cld
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

    public sealed class Sched : Object {
        // Per-task errno (SYS_ERRNO) and futex wait bookkeeping. Kept out of
        // the TCB because its 128 bytes are fully allocated.
        private static int[] task_errno;
        private static int[] wait_word;
        private static int[] wait_deadline;

        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        public static void init () {
            task_errno = new int[MAX_TASKS];
            wait_word = new int[MAX_TASKS];
            wait_deadline = new int[MAX_TASKS];
            for (int i = 0; i < (MAX_TASKS * TCB_SIZE) / 8; i++) {
                mmio_write64 (KernelLayout.TCB_TABLE + i * 8, 0);
            }
            // Task 0 represents the main shell/userland task
            mmio_write64 (KernelLayout.TCB_TABLE + 0, TASK_RUNNING);
            mmio_write64 (KernelLayout.TCB_TABLE + 32, -1);
            mmio_write8 (KernelLayout.TCB_TABLE + 48 + 0, 's');
            mmio_write8 (KernelLayout.TCB_TABLE + 48 + 1, 'h');
            mmio_write8 (KernelLayout.TCB_TABLE + 48 + 2, 'e');
            mmio_write8 (KernelLayout.TCB_TABLE + 48 + 3, 'l');
            mmio_write8 (KernelLayout.TCB_TABLE + 48 + 4, 'l');
            mmio_write8 (KernelLayout.TCB_TABLE + 48 + 5, 0);
            mmio_write64 (KernelLayout.TCB_TABLE + 112, 0);
            mmio_write64 (KernelLayout.TCB_TABLE + 120, 1);

            mmio_write64 (KernelLayout.SCHED_CUR, 0);
            mmio_write64 (KernelLayout.SCHED_ENABLED, 1);
            Hal.set_idt_gate_dpl (32, addr_isr_sched_irq0 (), 0);
        }

        public static int current_tid () {
            if (mmio_read64 (KernelLayout.SCHED_ENABLED) == 0)
                return 0;
            return mmio_read64 (KernelLayout.SCHED_CUR);
        }

        // --- errno ----------------------------------------------------------

        public static void set_errno (int err) {
            if (task_errno == null)
                return;
            int cur = current_tid ();
            if (cur >= 0 && cur < MAX_TASKS)
                task_errno[cur] = err;
        }

        public static int errno_code () {
            if (task_errno == null)
                return 0;
            int cur = current_tid ();
            if (cur < 0 || cur >= MAX_TASKS)
                return 0;
            return task_errno[cur];
        }

        // --- futex-style blocking -------------------------------------------

        // Parks the current task until SYS_WAKE_ADDR matches `addr` or the
        // absolute tick deadline (0 = none) is reached by the timer.
        public static void block_on (int addr, int deadline_tick) {
            if (wait_word == null)
                return;
            int cur = current_tid ();
            if (cur <= 0 || cur >= MAX_TASKS)
                return;
            wait_word[cur] = addr;
            wait_deadline[cur] = deadline_tick;
            mmio_write64 (KernelLayout.TCB_TABLE + cur * TCB_SIZE, TASK_BLOCKED);
        }

        // Ends the park: called by the woken task once its wait returns.
        public static void unblock_self () {
            if (wait_word == null)
                return;
            int cur = current_tid ();
            if (cur <= 0 || cur >= MAX_TASKS)
                return;
            wait_word[cur] = 0;
            wait_deadline[cur] = 0;
        }

        // Called from the timer: resumes tasks whose deadline expired.
        public static void sweep_deadlines () {
            if (wait_deadline == null)
                return;
            int now = mmio_read64 (KernelLayout.TICK);
            for (int w = 1; w < MAX_TASKS; w++) {
                int wtcb = KernelLayout.TCB_TABLE + w * TCB_SIZE;
                if (mmio_read64 (wtcb) != TASK_BLOCKED)
                    continue;
                int dl = wait_deadline[w];
                if (dl != 0 && now >= dl) {
                    wait_deadline[w] = 0;
                    wait_word[w] = 0;
                    mmio_write64 (wtcb, TASK_READY);
                }
            }
        }

        // Wakes up to `count` tasks parked on `addr`; returns how many.
        public static int wake_word (int addr, int count) {            if (wait_word == null || addr == 0)
                return 0;
            int woken = 0;
            for (int t = 1; t < MAX_TASKS && woken < count; t++) {
                int tcb = KernelLayout.TCB_TABLE + t * TCB_SIZE;
                if (mmio_read64 (tcb) != TASK_BLOCKED || wait_word[t] != addr)
                    continue;
                wait_word[t] = 0;
                wait_deadline[t] = 0;
                mmio_write64 (tcb, TASK_READY);
                woken = woken + 1;
            }
            return woken;
        }

        public static int spawn_ready (int entry, int arg_sp, int stack_base, int name_ptr, int name_len) {
            int parent = current_tid ();
            for (int tid = 1; tid < MAX_TASKS; tid++) {
                int tcb = KernelLayout.TCB_TABLE + tid * TCB_SIZE;
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
                    init_fx_area (tid);
                    mmio_write64 (tcb + 0, TASK_READY);
                    return tid;
                }
            }
            return -1;
        }

        private static void write_thread_name (int stack_bottom) {
            mmio_write8 (stack_bottom + 0, 't');
            mmio_write8 (stack_bottom + 1, 'h');
            mmio_write8 (stack_bottom + 2, 'r');
            mmio_write8 (stack_bottom + 3, 'e');
            mmio_write8 (stack_bottom + 4, 'a');
            mmio_write8 (stack_bottom + 5, 'd');
        }

        public static int spawn_thread (int entry, int arg) {
            int stack_base = Pmm.alloc_contiguous (16);
            if (stack_base == 0)
                return -1;
            int arg_sp = stack_base + 16 * 4096 - 16;
            int ucr3 = current_cr3 ();
            int tid = -1;
            if (ucr3 != 0 && ucr3 != KernelLayout.PAGE_TABLES) {
                if (Vmm.map_user_range_checked (ucr3, stack_base, 16 * 4096) == 0) {
                    Vmm.map_supervisor_range (ucr3, stack_base, 16 * 4096);
                    for (int p = 0; p < 16; p++)
                        Pmm.free_frame (stack_base + p * 4096);
                    Vmm.unmap_user_range (ucr3, stack_base, 16 * 4096);
                    return -1;
                }
                // The name goes at the bottom of the stack, which is only
                // reachable once the range is mapped in this CR3. A frame freed
                // by an earlier reap is not mapped until this point.
                write_thread_name (stack_base);
                tid = spawn_user_ready (entry, arg_sp, stack_base, 16, ucr3, stack_base, 6);
                if (tid < 0) {
                    Vmm.unmap_user_range (ucr3, stack_base, 16 * 4096);
                    Vmm.map_supervisor_range (ucr3, stack_base, 16 * 4096);
                }
            } else {
                write_thread_name (stack_base);
                tid = spawn_ready (entry, arg_sp, stack_base, stack_base, 6);
            }
            if (tid < 0) {
                for (int p = 0; p < 16; p++)
                    Pmm.free_frame (stack_base + p * 4096);
                if (ucr3 != 0 && ucr3 != KernelLayout.PAGE_TABLES)
                    Vmm.unmap_user_range (ucr3, stack_base, 16 * 4096);
                return -1;
            }
            // Put `arg` into saved %rdi slot (offset +72 in 15-GPR frame)
            int frame_rsp = mmio_read64 (KernelLayout.TCB_TABLE + tid * TCB_SIZE + 8);
            mmio_write64 (frame_rsp + 72, arg);
            return tid;
        }

        public static int get_stdio_in () {
            int cur = current_tid ();
            return mmio_read64 (KernelLayout.TCB_TABLE + cur * TCB_SIZE + 112);
        }

        public static int get_stdio_out () {
            int cur = current_tid ();
            int fd = mmio_read64 (KernelLayout.TCB_TABLE + cur * TCB_SIZE + 120);
            return (fd == 0) ? 1 : fd;
        }

        public static void set_stdio (int in_fd, int out_fd) {
            int cur = current_tid ();
            int tcb = KernelLayout.TCB_TABLE + cur * TCB_SIZE;
            mmio_write64 (tcb + 112, in_fd);
            mmio_write64 (tcb + 120, out_fd);
        }

        public static void exit_current (int code) {
            int cur = mmio_read64 (KernelLayout.SCHED_CUR);
            int tcb = KernelLayout.TCB_TABLE + cur * TCB_SIZE;
            int ucr3 = mmio_read64 (tcb + 88);
            if (ucr3 != 0) {
                bool shared = false;
                for (int ot = 0; ot < MAX_TASKS; ot++) {
                    if (ot == cur)
                        continue;
                    int otcb = KernelLayout.TCB_TABLE + ot * TCB_SIZE;
                    if (mmio_read64 (otcb) != TASK_FREE && mmio_read64 (otcb + 88) == ucr3) {
                        shared = true;
                        break;
                    }
                }
                if (!shared)
                    Fb.release_for_cr3 (ucr3);
            }
            mmio_write64 (tcb + 24, code);
            release_fds (cur);
            mmio_write64 (tcb + 0, TASK_ZOMBIE);
            cpu_sti ();
            while (true) {
                cpu_hlt ();
            }
        }

        public static void set_current_exec_ctx (int cr3, int rsp0) {
            int cur = current_tid ();
            int tcb = KernelLayout.TCB_TABLE + cur * TCB_SIZE;
            mmio_write64 (tcb + 88, cr3);
            mmio_write64 (tcb + 104, rsp0);
        }

        public static int current_cr3 () {
            int cur = current_tid ();
            return mmio_read64 (KernelLayout.TCB_TABLE + cur * TCB_SIZE + 88);
        }

        public static int spawn_user_ready (int entry, int user_sp, int user_stack_base, int user_stack_pages, int user_cr3, int name_ptr, int name_len) {
            int kstack = Pmm.alloc_contiguous (4);
            if (kstack == 0)
                return -1;
            int ktop = kstack + 4 * 4096;
            int parent = current_tid ();
            for (int tid = 1; tid < MAX_TASKS; tid++) {
                int tcb = KernelLayout.TCB_TABLE + tid * TCB_SIZE;
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
                    int ptcb = KernelLayout.TCB_TABLE + parent * TCB_SIZE;
                    mmio_write64 (tcb + 112, mmio_read64 (ptcb + 112));
                    mmio_write64 (tcb + 120, mmio_read64 (ptcb + 120));
                    int nmax = (name_len < 31) ? name_len : 31;
                    for (int k = 0; k < nmax; k++) {
                        mmio_write8 (tcb + 48 + k, read_u8 (name_ptr + k));
                    }
                    mmio_write8 (tcb + 48 + nmax, 0);
                    init_fx_area (tid);
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
            mmio_write64 (KernelLayout.TCB_TABLE + tid * TCB_SIZE + 80, pages);
        }

        private static int reap_zombie (int tid) {
            int irq = cpu_irq_save ();
            int saved_cr3 = vmm_read_cr3 ();
            if (saved_cr3 != KernelLayout.PAGE_TABLES)
                vmm_write_cr3 (KernelLayout.PAGE_TABLES);
            int tcb = KernelLayout.TCB_TABLE + tid * TCB_SIZE;
            release_fds (tid);
            int code = mmio_read64 (tcb + 24);
            int sbase = mmio_read64 (tcb + 16);
            int spages = mmio_read64 (tcb + 80);
            int ucr3 = mmio_read64 (tcb + 88);
            int kbase = mmio_read64 (tcb + 96);
            if (spages <= 0)
                spages = 16;
            if (sbase != 0) {
                bool own_cr3 = (ucr3 != 0 && ucr3 == current_cr3 ());
                if (own_cr3)
                    Vmm.unmap_user_range (ucr3, sbase, spages * 4096);
                // Pmm writes into the frame it releases, so it must be reachable
                // from the active CR3 once the user mapping is gone.
                if (own_cr3) {
                    Vmm.map_supervisor_range (ucr3, sbase, spages * 4096);
                    Vmm.map_4k (sbase);
                }
                for (int p = 0; p < spages; p++) {
                    Pmm.free_frame (sbase + p * 4096);
                }
                if (own_cr3)
                    Vmm.unmap_user_range (ucr3, sbase, spages * 4096);
            }
            if (kbase != 0) {
                for (int p = 0; p < 4; p++) {
                    Pmm.free_frame (kbase + p * 4096);
                }
            }
            if (ucr3 != 0 && ucr3 != current_cr3 ()) {
                bool shared = false;
                for (int ot = 0; ot < MAX_TASKS; ot++) {
                    if (ot == tid)
                        continue;
                    int otcb = KernelLayout.TCB_TABLE + ot * TCB_SIZE;
                    if (mmio_read64 (otcb) != TASK_FREE && mmio_read64 (otcb + 88) == ucr3) {
                        shared = true;
                        break;
                    }
                }
                if (!shared) {
                    Fb.release_for_cr3 (ucr3);
                    VirtioGpu.release_task (tid);
                    release_allocs (ucr3);
                    Vmm.destroy_user_space (ucr3);
                }
            }
            mmio_write64 (tcb + 88, 0);
            mmio_write64 (tcb + 96, 0);
            mmio_write64 (tcb + 104, 0);
            mmio_write64 (tcb + 112, 0);
            mmio_write64 (tcb + 120, 1);
            mmio_write64 (tcb + 0, TASK_FREE);
            if (wait_word != null && tid >= 0 && tid < MAX_TASKS) {
                wait_word[tid] = 0;
                wait_deadline[tid] = 0;
                task_errno[tid] = 0;
            }
            if (saved_cr3 != KernelLayout.PAGE_TABLES)
                vmm_write_cr3 (saved_cr3);
            cpu_irq_restore (irq);
            return code;
        }

        public static int wait_tid (int tid) {
            if (tid <= 0 || tid >= MAX_TASKS)
                return -1;
            int tcb = KernelLayout.TCB_TABLE + tid * TCB_SIZE;
            if (mmio_read64 (tcb) == TASK_FREE)
                return -1;
            while (mmio_read64 (tcb) != TASK_ZOMBIE) {
                cpu_sti ();
                cpu_hlt ();
            }
            return reap_zombie (tid);
        }

        public static int try_wait_tid (int tid) {
            if (tid <= 0 || tid >= MAX_TASKS)
                return -1;
            int tcb = KernelLayout.TCB_TABLE + tid * TCB_SIZE;
            int st = mmio_read64 (tcb);
            if (st == TASK_FREE)
                return -1;
            if (st != TASK_ZOMBIE)
                return -2;
            return reap_zombie (tid);
        }

        public static int kill_tid (int tid) {
            if (tid <= 0 || tid >= MAX_TASKS || tid == current_tid ())
                return -1;
            int tcb = KernelLayout.TCB_TABLE + tid * TCB_SIZE;
            int st = mmio_read64 (tcb);
            if (st == TASK_FREE)
                return -1;
            if (st != TASK_ZOMBIE) {
                mmio_write64 (tcb + 24, 143);
                mmio_write64 (tcb + 0, TASK_ZOMBIE);
            }
            return reap_zombie (tid);
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
                int tcb = KernelLayout.TCB_TABLE + tid * TCB_SIZE;
                int st = mmio_read64 (tcb);
                if (st == TASK_FREE)
                    continue;
                pos = append_int (buf, pos, max_b, tid);
                pos = append_str (buf, pos, max_b, "   ");
                if (st == TASK_READY) pos = append_str (buf, pos, max_b, "READY   ");
                else if (st == TASK_RUNNING) pos = append_str (buf, pos, max_b, "RUNNING ");
                else if (st == TASK_BLOCKED) pos = append_str (buf, pos, max_b, "BLOCKED ");
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
