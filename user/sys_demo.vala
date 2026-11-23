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

    return fails;
}
