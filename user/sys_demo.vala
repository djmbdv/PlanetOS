// Exercises the kernel/userland integration surface added in this slice:
// errno from failed syscalls, GLib.Dir over SYS_READDIR, g_log into the kernel
// ring, futex-backed Mutex/Cond across a real thread, SYS_POLL readiness and
// SYS_SLEEP_MS. Exits with the number of failed checks.
using GLib;
using Planet;

private int shared_word = 0;
private RecMutex demo_mutex = new RecMutex ();
private Cond demo_cond = new Cond ();

private int probe_fd = -1;
private int probe_rc = -2;
private int probe_err = 0;

private int thread_seen_tid = -1;
private int thread_ran = 0;

// RecMutex, not the unqualified `Mutex`: that name is the planc coroutine
// intrinsic, which pulls the async runtime.
private RecMutex pool_mutex = new RecMutex ();
private int pool_sum = 0;

private void pool_job (int data) {
    pool_mutex.@lock ();
    pool_sum = pool_sum + data;
    pool_mutex.unlock ();
}

private uint8[]? demo_thread_body () {
    thread_seen_tid = Sys.tid ();
    thread_ran = 1;
    return null;
}

[AsmBody(@"
    lea fd_probe_worker(%rip), %rax
    ret
")]
private extern int addr_fd_probe ();

public void fd_probe_worker (int arg) {
    var buf = new uint8[1];
    probe_rc = Sys.read (probe_fd, buf, 1);
    probe_err = Sys.errno_code ();
    Sys.sys (11, 0, 0, 0);
}

private uint8[]? demo_worker () {
    demo_mutex.@lock ();
    shared_word = 42;
    demo_cond.signal ();
    demo_mutex.unlock ();
    return null;
}

int main (string[] args) {
    int fails = 0;

    // 1. errno survives a failed open (SYS_ERRNO)
    var f = FileStream.open ("/no_such_file", "r");
    int e = Sys.errno_code ();
    if (f == null && e == Sys.ENOENT)
        print ("errno=ok\n");
    else {
        print ("errno=FAIL\n");
        fails++;
    }

    // 2. GLib.Dir reads the root directory
    var d = Dir.open ("/");
    int n = 0;
    if (d != null) {
        string? name = d.read_name ();
        while (name != null) {
            n++;
            name = d.read_name ();
        }
    }
    if (n >= 5)
        print ("dir=ok\n");
    else {
        print ("dir=FAIL\n");
        fails++;
    }

    // 3. g_log reaches the kernel ring
    log_error ("sysdemo", "boom");
    var rec = new uint8[8 * 64];
    int got = Sys.klog_read (rec, 8);
    bool found = false;
    for (int i = 0; i < got; i++) {
        int len = (int) ((uint32) rec[i * 64 + 8] | ((uint32) rec[i * 64 + 9] << 8)
                         | ((uint32) rec[i * 64 + 10] << 16) | ((uint32) rec[i * 64 + 11] << 24));
        var sb = new StringBuilder ();
        for (int k = 0; k < len && k < 40; k++)
            sb.append_c ((char) rec[i * 64 + 24 + k]);
        if (sb.str.contains ("boom"))
            found = true;
    }
    if (found)
        print ("klog=ok\n");
    else {
        print ("klog=FAIL\n");
        fails++;
    }

    // 4. Mutex/Cond park and wake a real thread instead of polling
    var t = new Thread ("demo-worker", demo_worker);
    demo_mutex.@lock ();
    while (shared_word != 42)
        demo_cond.wait (demo_mutex);
    demo_mutex.unlock ();
    t.join ();
    if (shared_word == 42)
        print ("cond=ok\n");
    else {
        print ("cond=FAIL\n");
        fails++;
    }

    // 5. SYS_POLL reports a regular file as readable
    int fd = Sys.open ("/hello.txt");
    var fds = new int[1];
    fds[0] = fd;
    int mask = Sys.poll (fds, 0);
    if (fd >= 3 && (mask & 1) == 1)
        print ("poll=ok\n");
    else {
        print ("poll=FAIL\n");
        fails++;
    }
    if (fd >= 3)
        Sys.close (fd);

    // 6. SYS_SLEEP_MS actually waits for the timer
    int t0 = Sys.ticks ();
    Sys.sleep_ms (40);
    int t1 = Sys.ticks ();
    if (t1 > t0)
        print ("sleep=ok\n");
    else {
        print ("sleep=FAIL\n");
        fails++;
    }

    // 7. SYS_WAIT_ADDR parks the task and the timer wakes it on the deadline
    var word = new int[1];
    word[0] = 7;
    int t2 = Sys.ticks ();
    int wr = Sys.wait_addr (word, 7, 30);
    int t3 = Sys.ticks ();
    if (wr < 0 && Sys.errno_code () == Sys.ETIMEDOUT && t3 > t2)
        print ("wait=ok\n");
    else {
        print ("wait=FAIL\n");
        fails++;
    }

    // 8. A handle belongs to the task that opened it: another task is denied
    int owned_fd = Sys.open ("/hello.txt");
    probe_fd = owned_fd;
    probe_rc = -2;
    probe_err = 0;
    int probe_tid = Sys.sys (27, addr_fd_probe (), 0, 0);
    if (probe_tid > 0)
        Sys.wait (probe_tid);
    if (owned_fd >= 3 && probe_rc == -1 && probe_err == Sys.EBADF)
        print ("fdguard=ok\n");
    else {
        print ("fdguard=FAIL\n");
        fails++;
    }
    if (owned_fd >= 3)
        Sys.close (owned_fd);

    // 9. Rights are per operation: a handle created for writing cannot read.
    int wfd = Sys.create ("/rights_probe.txt");
    var rbuf = new uint8[1];
    int rr = (wfd >= 3) ? Sys.read (wfd, rbuf, 1) : -9;
    int rerr = Sys.errno_code ();
    if (wfd >= 3 && rr == -1 && rerr == Sys.EACCES)
        print ("rights=ok\n");
    else {
        print ("rights=FAIL\n");
        fails++;
    }
    if (wfd >= 3) {
        Sys.close (wfd);
        Sys.unlink ("/rights_probe.txt");
    }

    // 10. A value from a closed handle is stale and never resolves again.
    int sfd = Sys.open ("/hello.txt");
    if (sfd >= 3)
        Sys.close (sfd);
    int sr = (sfd >= 3) ? Sys.read (sfd, rbuf, 1) : -9;
    int serr = Sys.errno_code ();
    if (sfd >= 3 && sr == -1 && serr == Sys.EBADF)
        print ("stale=ok\n");
    else {
        print ("stale=FAIL\n");
        fails++;
    }

    // 11. An unmapped user pointer is refused by the page-table check, and the
    // task keeps running afterwards.
    int gfd = Sys.open ("/hello.txt");
    var gbuf = new uint8[1];
    int bad = Sys.sys (7, gfd, 0x00F00000, 16);
    int bad_err = Sys.errno_code ();
    int badw = Sys.sys (15, gfd, 0x00F00000, 16);
    int badw_err = Sys.errno_code ();
    int after = (gfd >= 3) ? Sys.read (gfd, gbuf, 1) : -1;
    if (gfd >= 3 && bad == -1 && bad_err == Sys.EINVAL
        && badw == -1 && badw_err == Sys.EINVAL && after > 0)
        print ("guard=ok\n");
    else {
        print ("guard=FAIL\n");
        fails++;
    }
    if (gfd >= 3)
        Sys.close (gfd);

    // 12. GLib.Thread runs as a real kernel task on PlanetOS.
    int main_tid = Sys.tid ();
    thread_seen_tid = -1;
    thread_ran = 0;
    var rt = new Thread ("real-thread", demo_thread_body);
    rt.join ();
    if (thread_ran == 1 && thread_seen_tid > 0 && thread_seen_tid != main_tid)
        print ("thread=ok\n");
    else {
        print ("thread=FAIL\n");
        fails++;
    }

    // 13. ThreadPool drains its queue on real workers.
    pool_sum = 0;
    var pool = new ThreadPool (pool_job, 2, false);
    pool.push (1);
    pool.push (2);
    pool.push (3);
    int spins = 0;
    while (pool.unprocessed () > 0 && spins < 400) {
        Sys.sleep_ms (5);
        spins++;
    }
    int pending_left = (int) pool.unprocessed ();
    pool.stop ();
    if (pool_sum == 6 && pending_left == 0)
        print ("pool=ok\n");
    else {
        print ("pool=FAIL\n");
        fails++;
    }

    // 14. /dev is a virtual device namespace with byte handles.
    int dev_kind = Sys.stat ("/dev/console");
    int dev_fd = Sys.open ("/dev/console");
    int dev_w = (dev_fd >= 3) ? Sys.write_str (dev_fd, "[dev]\n", 6) : -1;
    int dev_size = (dev_fd >= 3) ? Sys.file_size (dev_fd) : -1;
    int dev_seek = (dev_fd >= 3) ? Sys.seek (dev_fd, 0) : 0;
    var dev_list = new uint8[64];
    int dev_n = Sys.readdir_path ("/dev", dev_list, 64);
    int dev_null = Sys.open ("/dev/null");
    int dev_null_w = (dev_null >= 3) ? Sys.write_str (dev_null, "x", 1) : -1;
    if (dev_kind == 1 && dev_fd >= 3 && dev_w == 6 && dev_size == 0
        && dev_seek == -1 && dev_n > 0 && dev_null_w == 1)
        print ("dev=ok\n");
    else {
        print ("dev=FAIL\n");
        fails++;
    }
    if (dev_fd >= 3) Sys.close (dev_fd);
    if (dev_null >= 3) Sys.close (dev_null);

    // 15. A2: a grant is a capability over frames the task owns (IO-02).
    int mem_block = Sys.alloc_pages (1);
    // A range nobody allocated cannot be granted, even though the address is a
    // valid user address: ownership is checked, not the address.
    int mem_foreign = Sys.grant (0x20000000, 4096);
    int mem_foreign_err = Sys.errno_code ();
    int mem_grant = (mem_block > 0) ? Sys.grant (mem_block, 4096) : -1;
    int mem_grant_err = Sys.errno_code ();
    // While the capability is live the frames cannot be freed underneath it.
    int mem_free_live = (mem_block > 0) ? Sys.free_page (mem_block) : 0;
    int mem_free_live_err = Sys.errno_code ();
    int mem_map_own = (mem_block > 0) ? Sys.map_user_at (mem_block, 4096) : -1;
    if (mem_grant > 0)
        Sys.close (mem_grant);
    // With the grant gone the owner can release the block.
    int mem_free_after = (mem_block > 0) ? Sys.free_page (mem_block) : -1;
    bool mem_ok = mem_block > 0 && mem_foreign == -1
                  && mem_foreign_err == Sys.EACCES
                  && mem_grant >= 3
                  && mem_free_live == -1
                  && mem_free_live_err == Sys.EACCES
                  && mem_map_own == 0
                  && mem_free_after == 0;
    if (mem_ok)
        print ("memguard=ok\n");
    else {
        print (@"memdbg tid=$(Sys.tid()) block=$mem_block foreign=$mem_foreign/$mem_foreign_err grant=$mem_grant/$mem_grant_err live=$mem_free_live/$mem_free_live_err map=$mem_map_own after=$mem_free_after\n");
        print ("memguard=FAIL\n");
        fails++;
    }

    // 16. B: a descriptor ring the kernel validates before it touches anything.
    int ring_block = Sys.alloc_pages (1);
    Sys.poke32 (ring_block + 0, 0x524E4C50); // magic "PLNR"
    Sys.poke32 (ring_block + 4, 1);          // version
    Sys.poke32 (ring_block + 8, 2);          // entries
    Sys.poke32 (ring_block + 12, 32);        // entry size
    int ring_grant = (ring_block > 0) ? Sys.grant (ring_block, 4096) : -1;
    int ring_h = (ring_grant > 0) ? Sys.ring_attach (ring_grant, 2) : -1;
    int ring_err = Sys.errno_code ();
    int ring_buf = ring_block + 2048;
    int ring_d0 = ring_block + 64;
    int ring_d1 = ring_block + 96;
    // Descriptor 0: the device writes 8 bytes inside the ring block.
    Sys.poke32 (ring_d0 + 0, ring_buf);
    Sys.poke32 (ring_d0 + 4, 0);
    Sys.poke32 (ring_d0 + 8, 8);
    Sys.poke32 (ring_d0 + 12, 2); // WRITE
    Sys.poke32 (ring_d0 + 20, 1); // READY
    // Descriptor 1: points outside the ring, so it must be rejected.
    Sys.poke32 (ring_d1 + 0, 0x20000000);
    Sys.poke32 (ring_d1 + 4, 0);
    Sys.poke32 (ring_d1 + 8, 8);
    Sys.poke32 (ring_d1 + 12, 2);
    Sys.poke32 (ring_d1 + 20, 1);
    Sys.poke32 (ring_block + 20, 1); // tail: one descriptor published
    int ring_k1 = (ring_h > 0) ? Sys.ring_kick (ring_h) : -1;
    int ring_st0 = Sys.peek32 (ring_d0 + 20);
    int ring_fill = Sys.peek32 (ring_buf);
    Sys.poke32 (ring_block + 20, 2);
    int ring_k2 = (ring_h > 0) ? Sys.ring_kick (ring_h) : 0;
    int ring_st1 = Sys.peek32 (ring_d1 + 20);
    if (ring_h > 0)
        Sys.close (ring_h);
    if (ring_grant > 0)
        Sys.close (ring_grant);
    if (ring_block > 0)
        Sys.free_page (ring_block);
    bool ring_ok = ring_block > 0 && ring_h > 0
                   && ring_k1 == 1 && ring_st0 == 2 && ring_fill == 0xA5A5A5A5
                   && ring_k2 == -1 && ring_st1 == 3;
    if (ring_ok)
        print ("ring=ok\n");
    else {
        print (@"ringdbg err=$ring_err block=$ring_block grant=$ring_grant h=$ring_h k1=$ring_k1 st0=$ring_st0 fill=$ring_fill k2=$ring_k2 st1=$ring_st1\n");
        print ("ring=FAIL\n");
        fails++;
    }

    return fails;
}
