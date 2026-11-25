// Pure-Vala GLib MainContext & MainLoop.
using Planet;

namespace GLib {

    public delegate bool SourceFunc ();
    public delegate void ChildWatchFunc (int pid, int status);

    // GLib priority values. Lower numbers run first.
    public const int PRIORITY_HIGH = -100;
    public const int PRIORITY_DEFAULT = 0;
    public const int PRIORITY_HIGH_IDLE = 100;
    public const int PRIORITY_DEFAULT_IDLE = 200;
    public const int PRIORITY_LOW = 300;

    public class Source : Object {
        public const uint8 KIND_IDLE = 0;
        public const uint8 KIND_TIMEOUT = 1;
        public const uint8 KIND_WATCH = 2;
        public const uint8 KIND_CUSTOM = 3;

        public uint32 id;
        public uint8 kind;
        public int priority;
        public uint32 interval; // ms
        public int due;         // ms
        public bool removed;
        public bool destroyed;
        public SourceFunc? func;
        public SourceFunc? check_func;
        public int fd = -1;
        public uint32 condition = 0; // 1 = readable, 2 = writable
        public MainContext? context;

        public Source (uint32 id, uint8 kind, uint32 interval, int due, SourceFunc? func) {
            this.id = id;
            this.kind = kind;
            this.interval = interval;
            this.due = due;
            this.func = func;
            this.priority = (kind == KIND_IDLE) ? PRIORITY_DEFAULT_IDLE : PRIORITY_DEFAULT;
        }

        public uint32 get_id () {
            return id;
        }

        public void set_priority (int value) {
            priority = value;
        }

        public int get_priority () {
            return priority;
        }

        public bool is_destroyed () {
            return destroyed;
        }

        public void set_callback (SourceFunc? callback) {
            func = callback;
        }

        public MainContext get_context () {
            return context ?? MainContext.default_ ();
        }

        public uint32 attach (MainContext? ctx = null) {
            var target = ctx ?? MainContext.default_ ();
            target.attach_source (this);
            return id;
        }

        public void destroy () {
            if (destroyed)
                return;
            destroyed = true;
            removed = true;
            var ctx = context;
            if (ctx != null)
                ctx.remove (id);
        }
    }

    private MainContext? default_main_context;
    private GenericArray<MainContext>? thread_defaults = null;

    private static void ensure_thread_defaults () {
        if (thread_defaults == null)
            thread_defaults = new GenericArray<MainContext> ();
    }

    private class ChildWatchSource : Object {
        public int pid;
        public ChildWatchFunc func;
        public ChildWatchSource (int pid, ChildWatchFunc func) {
            this.pid = pid;
            this.func = func;
        }

        public bool tick () {
            int status = Sys.wait_nb (pid);
            if (status == -2)
                return true;
            if (status < 0)
                return false;
            func (pid, status);
            return false;
        }
    }

    public class MainContext : Object {
        private GenericArray<Source> sources;
        private uint32 next_id = 0;
        private int iter_depth = 0;
        private int dead_count = 0;
        // Reused buffer for SYS_POLL; it grows to the number of watches.
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
        }

        private void ensure_pollbuf (int needed) {
            if (needed <= pollbuf.length)
                return;
            int cap = pollbuf.length;
            while (cap < needed)
                cap = cap * 2;
            pollbuf = new int[cap];
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
                if (s.removed || s.destroyed)
                    continue;
                if (s.kind == Source.KIND_IDLE
                    || (s.kind == Source.KIND_TIMEOUT && now >= s.due)
                    || (s.kind == Source.KIND_CUSTOM && s.check_func != null && s.check_func ()))
                    return true;
            }
            return false;
        }

        private bool source_ready (Source s, int now) {
            if (s.removed || s.destroyed)
                return false;
            if (s.kind == Source.KIND_IDLE)
                return true;
            if (s.kind == Source.KIND_TIMEOUT)
                return now >= s.due;
            if (s.kind == Source.KIND_CUSTOM)
                return s.check_func != null && s.check_func ();
            return false;
        }

        private void run_source (Source s, int now) {
            if (s.kind == Source.KIND_TIMEOUT) {
                uint32 interval = (s.interval == 0) ? 1 : s.interval;
                s.due = now + (int) interval;
            }
            iter_depth++;
            bool keep = true;
            var callback = s.func;
            if (callback != null)
                keep = callback ();
            iter_depth--;
            if (!keep && !s.removed) {
                s.removed = true;
                s.destroyed = true;
                dead_count++;
            }
            if (iter_depth == 0 && dead_count > 0)
                compact ();
        }

        // Runs the highest-priority ready source. Timeouts and fd watches use
        // PRIORITY_DEFAULT, idle sources PRIORITY_DEFAULT_IDLE, so a permanently
        // ready idle callback can no longer starve timers.
        public bool iteration (bool may_block) {
            int now = Sys.ticks () * 10;
            int best = -1;
            int best_prio = 0;
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (!source_ready (s, now))
                    continue;
                if (best < 0 || s.priority < best_prio) {
                    best = i;
                    best_prio = s.priority;
                }
            }
            if (best >= 0) {
                run_source (sources[best], now);
                return true;
            }
            if (iter_depth == 0 && dead_count > 0)
                compact ();
            if (!may_block)
                return false;

            int next_ms = -1;
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed || s.destroyed || s.kind != Source.KIND_TIMEOUT)
                    continue;
                int d = s.due - now;
                if (d < 1)
                    d = 1;
                if (next_ms < 0 || d < next_ms)
                    next_ms = d;
            }
            int nfd = 0;
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed || s.destroyed || s.kind != Source.KIND_WATCH)
                    continue;
                if ((s.condition & 1) == 0)
                    continue;
                nfd++;
            }
            if (nfd > 0) {
                ensure_pollbuf (nfd);
                int w = 0;
                for (int i = 0; i < sources.length; i++) {
                    Source s = sources[i];
                    if (s.removed || s.destroyed || s.kind != Source.KIND_WATCH)
                        continue;
                    if ((s.condition & 1) == 0)
                        continue;
                    pollbuf[w] = s.fd;
                    w++;
                }
                int tmo = (next_ms < 0) ? 1000 : next_ms;
                if (tmo > 1000)
                    tmo = 1000;
                int mask = Sys.poll_n (pollbuf, nfd, tmo);
                if (mask > 0) {
                    int seen = 0;
                    for (int i = 0; i < sources.length; i++) {
                        Source s = sources[i];
                        if (s.removed || s.destroyed || s.kind != Source.KIND_WATCH)
                            continue;
                        if ((s.condition & 1) == 0)
                            continue;
                        bool ready = ((mask >> seen) & 1) == 1;
                        seen++;
                        if (!ready)
                            continue;
                        run_source (s, now);
                        return true;
                    }
                }
                return false;
            }
            Sys.sleep_ms ((next_ms < 0) ? 10 : next_ms);
            return false;
        }

        private uint32 next_source_id () {
            next_id = next_id + 1;
            if (next_id == 0)
                next_id = 1;
            return next_id;
        }

        public uint32 attach_source (Source source) {
            if (source.id == 0)
                source.id = next_source_id ();
            source.context = this;
            source.removed = false;
            source.destroyed = false;
            sources.add (source);
            return source.id;
        }

        public uint32 add_idle (SourceFunc func) {
            var s = new Source (next_source_id (), Source.KIND_IDLE, 0, 0, func);
            return attach_source (s);
        }

        public uint32 add_timeout (uint32 interval_ms, SourceFunc func) {
            uint32 interval = (interval_ms == 0) ? 1 : interval_ms;
            var s = new Source (next_source_id (), Source.KIND_TIMEOUT, interval,
                                Sys.ticks () * 10 + (int) interval, func);
            return attach_source (s);
        }

        // Watches `fd` through SYS_POLL. `condition` bit 1 means readable;
        // SYS_POLL currently reports readability only.
        public uint32 add_watch (int fd, uint32 condition, SourceFunc func) {
            var s = new Source (next_source_id (), Source.KIND_WATCH, 0, 0, func);
            s.fd = fd;
            s.condition = condition;
            return attach_source (s);
        }

        public bool remove (uint32 id) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.id == id && !s.removed) {
                    if (iter_depth == 0) {
                        sources.remove_index (i);
                    } else {
                        s.removed = true;
                        s.destroyed = true;
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

        public Source? find_source_by_id (uint32 id) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.id == id && !s.removed)
                    return s;
            }
            return null;
        }

        // Runs `func` on this context. The loop is single-threaded, so this is
        // an idle callback with a dedicated source.
        public uint32 invoke (SourceFunc func) {
            return add_idle (func);
        }

        public static MainContext get_thread_default () {
            ensure_thread_defaults ();
            var stack = thread_defaults;
            if (stack != null && ((!) stack).length > 0) {
                var top = ((!) stack)[((!) stack).length - 1];
                return top;
            }
            return default_ ();
        }

        public void push_thread_default () {
            ensure_thread_defaults ();
            ((!) thread_defaults).add (this);
        }

        public void pop_thread_default () {
            ensure_thread_defaults ();
            var stack = thread_defaults;
            if (stack != null && ((!) stack).length > 0)
                ((!) stack).remove_index (((!) stack).length - 1);
        }
    }

    public uint32 idle_add (SourceFunc func) {
        return MainContext.get_thread_default ().add_idle (func);
    }

    public uint32 timeout_add (uint32 interval_ms, SourceFunc func) {
        return MainContext.get_thread_default ().add_timeout (interval_ms, func);
    }

    public uint32 io_add_watch (int fd, uint32 condition, SourceFunc func) {
        return MainContext.get_thread_default ().add_watch (fd, condition, func);
    }

    // Reaps a child by polling SYS_WAIT_NB. `func` runs once when the child
    // exits; it never blocks the main loop.
    public uint32 child_watch_add (int pid, ChildWatchFunc func) {
        if (pid <= 0)
            return 0;
        var watch = new ChildWatchSource (pid, func);
        return timeout_add (50, watch.tick);
    }

    public bool source_remove (uint32 id) {
        return MainContext.get_thread_default ().remove (id);
    }

    public bool source_exists (uint32 id) {
        return MainContext.get_thread_default ().exists (id);
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
