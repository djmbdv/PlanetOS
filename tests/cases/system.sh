# Kernel/userland integration surface: errno survives a failed open, GLib.Dir
# enumerates the root, g_log lands in the kernel ring, Mutex/Cond park and wake
# a real thread, SYS_POLL reports a file as readable, SYS_SLEEP_MS waits for
# the timer, and a handle opened by one task is denied to another.
sys_demo
