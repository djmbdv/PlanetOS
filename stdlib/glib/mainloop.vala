// Pure-Vala GLib MainContext & MainLoop.
using Planet;

namespace GLib {

    public delegate bool SourceFunc ();

    private class Source : Object {
        public uint32 id;
        public uint8 kind;      // 0 = idle, 1 = timeout, 2 = fd watch
        public uint32 interval; // ms
        public int due;       // ms
        public bool removed;
        public SourceFunc func;
        public int fd = -1;      // kind 2
        public uint32 condition = 0; // kind 2: 1 = readable, 2 = writable

        public Source (uint32 id, uint8 kind, uint32 interval, int due, SourceFunc func) {
            this.id = id;
            this.kind = kind;
            this.interval = interval;
            this.due = due;
            this.func = func;
        }
    }

    private MainContext? default_main_context;

    public class MainContext : Object {
        private GenericArray<Source> sources;
        private uint32 next_id = 0;
        private int iter_depth = 0;
        private int dead_count = 0;
        private int idle_cursor = 0;
        private int timeout_cursor = 0;
        // Reused buffer for SYS_POLL; the context supports 8 fd watches.
        private int[] pollbuf = new int[8];

        public MainContext () {
            sources = new GenericArray<Source> ();
        }

        public static MainContext default_ () {
            var ctx = default_main_context;
            if (ctx == null) {
                var created = new MainContext ();
                default_main_context = created;
                return created;
            } else {
                return ctx;
            }
        }

        private void compact () {
            if (dead_count == 0)
                return;
            int write_i = 0;
            for (int i = 0; i < sources.length; i++) {
                if (!sources[i].removed) {
                    sources[write_i] = sources[i];
                    write_i++;
                }
            }
            sources.length = write_i;
            dead_count = 0;
            if (idle_cursor >= sources.length)
                idle_cursor = 0;
            if (timeout_cursor >= sources.length)
                timeout_cursor = 0;
        }

        public bool has_sources () {
            for (int i = 0; i < sources.length; i++) {
                if (!sources[i].removed)
                    return true;
            }
            return false;
        }

        public bool pending () {
            int now = Sys.ticks () * 10;
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed)
                    continue;
                if (s.kind == 0 || now >= s.due)
                    return true;
            }
            return false;
        }

        // Runs one ready source: idle sources first (round-robin), then due timeouts.
        // Returns false when nothing was ready; may_block yields the CPU once.
        public bool iteration (bool may_block) {
            int n = sources.length;
            if (n > 0) {
                int start = (idle_cursor < n) ? idle_cursor : 0;
                for (int k = 0; k < n; k++) {
                    int idx = (start + k) % n;
                    Source s = sources[idx];
                    if (s.removed || s.kind != 0)
                        continue;
                    idle_cursor = (idx + 1) % n;
                    iter_depth++;
                    bool keep = s.func ();
                    iter_depth--;
                    if (!keep && !s.removed) {
                        s.removed = true;
                        dead_count++;
                    }
                    if (iter_depth == 0 && dead_count > 0)
                        compact ();
                    return true;
                }
            }
            int now = Sys.ticks () * 10;
            int tn = sources.length;
            if (tn > 0) {
                int tstart = (timeout_cursor < tn) ? timeout_cursor : 0;
                for (int k = 0; k < tn; k++) {
                    int idx = (tstart + k) % tn;
                    Source s = sources[idx];
                    if (s.removed || s.kind != 1 || now < s.due)
                        continue;
                    timeout_cursor = (idx + 1) % tn;
                    s.due = now + (int) s.interval;
                    iter_depth++;
                    bool keep = s.func ();
                    iter_depth--;
                    if (!keep && !s.removed) {
                        s.removed = true;
                        dead_count++;
                    }
                    if (iter_depth == 0 && dead_count > 0)
                        compact ();
                    return true;
                }
            }
            if (iter_depth == 0 && dead_count > 0)
                compact ();
            if (!may_block)
                return false;
            // Block on the fd watches (if any) up to the next timeout instead
            // of waking on every tick.
            int next_ms = -1;
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed || s.kind != 1)
                    continue;
                int d = s.due - now;
                if (d < 1)
                    d = 1;
                if (next_ms < 0 || d < next_ms)
                    next_ms = d;
            }
            int nfd = 0;
            for (int i = 0; i < sources.length && nfd < pollbuf.length; i++) {
                Source s = sources[i];
                if (s.removed || s.kind != 2)
                    continue;
                pollbuf[nfd] = s.fd;
                nfd++;
            }
            if (nfd > 0) {
                int tmo = (next_ms < 0) ? 1000 : next_ms;
                if (tmo > 1000)
                    tmo = 1000;
                int mask = Sys.poll (pollbuf, tmo);
                if (mask > 0) {
                    // Dispatch the first ready watch.
                    int seen = 0;
                    for (int i = 0; i < sources.length; i++) {
                        Source s = sources[i];
                        if (s.removed || s.kind != 2)
                            continue;
                        bool ready = ((mask >> seen) & 1) == 1;
                        seen++;
                        if (!ready)
                            continue;
                        iter_depth++;
                        bool keep = s.func ();
                        iter_depth--;
                        if (!keep && !s.removed) {
                            s.removed = true;
                            dead_count++;
                        }
                        return true;
                    }
                }
                return false;
            }
            Sys.sleep_ms ((next_ms < 0) ? 10 : next_ms);
            return false;
        }

        public uint32 add_idle (SourceFunc func) {
            next_id = next_id + 1;
            sources.add (new Source (next_id, 0, 0, 0, func));
            return next_id;
        }

        public uint32 add_timeout (uint32 interval_ms, SourceFunc func) {
            next_id = next_id + 1;
            uint32 interval = (interval_ms == 0) ? 1 : interval_ms;
            sources.add (new Source (next_id, 1, interval, Sys.ticks () * 10 + (int) interval, func));
            return next_id;
        }

        // Watches `fd` through SYS_POLL; condition 1 = readable, 2 = writable.
        // Up to 8 watches per context.
        public uint32 add_watch (int fd, uint32 condition, SourceFunc func) {
            next_id = next_id + 1;
            var s = new Source (next_id, 2, 0, 0, func);
            s.fd = fd;
            s.condition = condition;
            sources.add (s);
            return next_id;
        }

        public bool remove (uint32 id) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.id == id && !s.removed) {
                    if (iter_depth == 0) {
                        sources.remove_index (i);
                        if (idle_cursor >= sources.length)
                            idle_cursor = 0;
                        if (timeout_cursor >= sources.length)
                            timeout_cursor = 0;
                    } else {
                        s.removed = true;
                        dead_count++;
                    }
                    return true;
                }
            }
            return false;
        }

        public bool exists (uint32 id) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.id == id && !s.removed)
                    return true;
            }
            return false;
        }
    }

    public uint32 idle_add (SourceFunc func) {
        return MainContext.default_ ().add_idle (func);
    }

    public uint32 timeout_add (uint32 interval_ms, SourceFunc func) {
        return MainContext.default_ ().add_timeout (interval_ms, func);
    }

    public uint32 io_add_watch (int fd, uint32 condition, SourceFunc func) {
        return MainContext.default_ ().add_watch (fd, condition, func);
    }

    public bool source_remove (uint32 id) {
        return MainContext.default_ ().remove (id);
    }

    public bool source_exists (uint32 id) {
        return MainContext.default_ ().exists (id);
    }

    public class MainLoop : Object {
        private MainContext context;
        private bool running = false;

        public MainLoop (MainContext? ctx = null) {
            context = (ctx != null) ? ctx : MainContext.default_ ();
        }

        public MainContext get_context () {
            return context;
        }

        public bool is_running () {
            return running;
        }

        public void quit () {
            running = false;
        }

        // Runs until quit() is called. If every source removes itself the loop
        // also stops instead of blocking forever.
        public void run () {
            if (running)
                return;
            running = true;
            while (running) {
                bool did = context.iteration (true);
                if (!did && !context.has_sources ())
                    break;
            }
            running = false;
        }
    }
}
