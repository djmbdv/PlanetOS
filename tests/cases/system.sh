# Kernel/userland integration surface: errno survives a failed open, GLib.Dir
# enumerates the root, g_log lands in the kernel ring, Mutex/Cond park and wake
# a real thread, SYS_POLL reports a file as readable, SYS_SLEEP_MS waits for
# the timer, a handle opened by one task is denied to another, an operation
# without its right is refused and a closed handle value is stale.
sys_demo
