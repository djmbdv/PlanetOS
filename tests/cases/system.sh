# Kernel/userland integration surface: errno survives a failed open, GLib.Dir
# enumerates the root, g_log lands in the kernel ring, Mutex/Cond park and wake
# a real thread, SYS_POLL reports a file as readable, SYS_SLEEP_MS waits for
# the timer, a handle opened by one task is denied to another, an operation
# without its right is refused, a closed handle value is stale, and an
# unmapped user pointer is refused without killing the task, and GLib.Thread
# runs as a real kernel task, ThreadPool drains its queue on workers, and /dev
# exposes console, serial0 and null as byte handles, and a block a task owns cannot be granted unless owned nor freed under a live grant, and a descriptor ring rejects a descriptor that points outside its own block.
sys_demo
