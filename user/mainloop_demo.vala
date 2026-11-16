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
