// user/gmodule_demo.vala -- exercises the pure-Vala GModule layer.
//
// Run from the PlanetOS shell:  gmodule_demo
// PlanetOS is statically linked, so Module.open() must report NOT_SUPPORTED;
// the static registry extension is checked separately.

using GModule;

namespace GModuleDemo {
    private int checks = 0;
    private int failures = 0;

    private void check (string what, bool ok) {
        checks = checks + 1;
        if (ok) {
            print (@"gmodule:check $what ok\n");
        } else {
            failures = failures + 1;
            print (@"gmodule:check $what FAIL\n");
        }
    }

    int main (string[] args) {
        check ("not-supported", !Module.supported ());

        try {
            Module.open ("libdemo.so");
            check ("open-refused", false);
        } catch (ModuleError e) {
            check ("open-refused", true);
        }

        check ("register", Module.register_static ("net", "network stack"));
        check ("register-duplicate", !Module.register_static ("net"));
        check ("registered", Module.is_registered ("net"));
        check ("count", Module.module_count () == 1);
        check ("description", Module.module_description ("net") == "network stack");

        try {
            var handle = Module.open_static ("net");
            check ("open-static-name", handle.get_name () == "net");
            check ("symbol-missing", handle.get_symbol ("init") < 0);
        } catch (ModuleError e) {
            check ("open-static-name", false);
        }

        check ("symbol-register", Module.register_symbol ("net", "init", 0x1234));
        check ("symbol-unknown-module", !Module.register_symbol ("nope", "init", 1));

        try {
            var handle = Module.open_static ("net");
            check ("symbol-found", handle.has_symbol ("init"));
            check ("symbol-address", handle.get_symbol ("init") == 0x1234);
        } catch (ModuleError e) {
            check ("symbol-found", false);
        }

        try {
            Module.open_static ("missing");
            check ("open-missing", false);
        } catch (ModuleError e) {
            check ("open-missing", true);
        }

        print (@"gmodule:summary checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
    }
}
