# Kernel/userland integration surface: errno survives a failed open, GLib.Dir
# enumerates the root, g_log lands in the kernel ring, Mutex/Cond park and wake
# a real thread, SYS_POLL reports a file as readable and SYS_SLEEP_MS waits for
# the timer.
sys_demo
