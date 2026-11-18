// Pure-Vala GLib MainContext & MainLoop.
using Planet;

namespace GLib {

    public delegate bool SourceFunc ();

    private class Source : Object {
        public uint32 id;
        public int kind;      // 0 = idle, 1 = timeout
        public uint32 interval; // ms
        public int due;       // ms
        public bool removed;
        public SourceFunc func;

        public Source (uint32 id, int kind, uint32 interval, int due, SourceFunc func) {
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
            for (int i = sources.length - 1; i >= 0; i--) {
                if (sources[i].removed)
                    sources.remove_index (i);
            }
            dead_count = 0;
            if (idle_cursor >= sources.length)
                idle_cursor = 0;
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
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.removed || s.kind != 1 || now < s.due)
                    continue;
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
            if (iter_depth == 0 && dead_count > 0)
                compact ();
            if (may_block)
                Sys.yield_cpu ();
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

        public bool remove (uint32 id) {
            for (int i = 0; i < sources.length; i++) {
                Source s = sources[i];
                if (s.id == id && !s.removed) {
                    if (iter_depth == 0) {
                        sources.remove_index (i);
                        if (idle_cursor >= sources.length)
                            idle_cursor = 0;
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
                bool did = context.iteration (false);
                if (!did) {
                    if (!context.has_sources ())
                        break;
                    Sys.yield_cpu ();
                }
            }
            running = false;
        }
    }
}
