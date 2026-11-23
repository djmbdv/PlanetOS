// user/mainloop_demo.vala -- exercises the GLib main loop on PlanetOS.
//
// Run from the PlanetOS shell:  mainloop_demo
// Checks idle/timeout ordering, source removal and Application.run().

using GLib;
using Gio;

namespace MainLoopDemo {
    private int checks = 0;
    private int failures = 0;
    private int idle_runs = 0;
    private int timeout_runs = 0;
    private int order = 0;
    private int app_ticks = 0;
    private int priority_runs = 0;
    private int invoked = 0;
    private int alt_runs = 0;

    private void check (string what, bool ok) {
        checks = checks + 1;
        if (ok) {
            print (@"mainloop:check $what ok\n");
        } else {
            failures = failures + 1;
            print (@"mainloop:check $what FAIL\n");
        }
    }

    int main (string[] args) {
        var ctx = MainContext.default_ ();
        check ("context", ctx == MainContext.default_ ());
        check ("empty", !ctx.pending () && !ctx.has_sources ());

        var loop = new MainLoop (ctx);
        check ("loop-context", loop.get_context () == ctx);
        check ("not-running", !loop.is_running ());

        uint32 idle_id = idle_add (() => {
            idle_runs = idle_runs + 1;
            order = 1;
            return false;
        });
        uint32 timeout_id = timeout_add (20, () => {
            timeout_runs = timeout_runs + 1;
            if (order == 0)
                order = -1;
            if (timeout_runs >= 3) {
                loop.quit ();
                return false;
            }
            return true;
        });
        check ("ids", idle_id > 0 && timeout_id > 0 && idle_id != timeout_id);
        check ("pending", ctx.pending ());

        loop.run ();

        check ("idle-once", idle_runs == 1);
        check ("timeout-three", timeout_runs == 3);
        check ("idle-before-timeout", order == 1);
        check ("stopped", !loop.is_running ());
        check ("all-sources-done", !ctx.has_sources ());

        uint32 ghost = timeout_add (10, () => {
            return false;
        });
        check ("source-exists", source_exists (ghost));
        check ("source-remove", source_remove (ghost));
        check ("source-removed", !source_exists (ghost));
        check ("source-remove-twice", !source_remove (ghost));

        // Source priorities: a permanently-ready idle source must not hide a
        // timeout. The high-priority idle runs three times, then the timer quits.
        var high = new Source (0, Source.KIND_IDLE, 0, 0, () => {
            priority_runs = priority_runs + 1;
            return priority_runs < 3;
        });
        high.set_priority (PRIORITY_HIGH);
        uint32 high_id = high.attach (ctx);
        check ("source-attach", high_id > 0 && ctx.find_source_by_id (high_id) == high);
        timeout_add (10, () => {
            loop.quit ();
            return false;
        });
        loop.run ();
        check ("priority-runs", priority_runs == 3);

        var doomed = new Source (0, Source.KIND_IDLE, 0, 0, () => false);
        uint32 doomed_id = doomed.attach (ctx);
        check ("source-destroy", doomed_id > 0);
        doomed.destroy ();
        check ("source-destroyed", doomed.is_destroyed () && !ctx.exists (doomed_id));

        // Per-context invoke and push_thread_default.
        ctx.invoke (() => {
            invoked = invoked + 1;
            return false;
        });
        while (ctx.pending ())
            ctx.iteration (false);
        check ("invoke", invoked == 1);

        var alt = new MainContext ();
        alt.push_thread_default ();
        uint32 alt_id = idle_add (() => {
            alt_runs = alt_runs + 1;
            return false;
        });
        alt.pop_thread_default ();
        check ("thread-default-attached", alt_id > 0 && alt.pending ());
        while (alt.pending ())
            alt.iteration (false);
        check ("thread-default-run", alt_runs == 1);

        var priv = new Private ();
        priv.set (42);
        check ("private", priv.get () == 42 && priv.replace (7) == 42 && priv.get () == 7);

        var app = new Application ("org.planetos.MainLoopDemo", ApplicationFlags.FLAGS_NONE);
        app.hold ();
        timeout_add (10, () => {
            app_ticks = app_ticks + 1;
            app.release ();
            return false;
        });
        check ("app-run", app.run (args) == 0);
        check ("app-loop-driven", app_ticks == 1);

        print (@"mainloop:summary checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
    }
}
