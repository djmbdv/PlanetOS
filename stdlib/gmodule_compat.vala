// Pure-Vala GModule compatibility layer for PlanetOS (zero C, zero .vapi).
//
// PlanetOS links statically: there is no dynamic linker, no PT_INTERP and no
// dlopen (docs/05). Module.open() therefore reports NOT_SUPPORTED instead of
// pretending to load a shared object.
//
// For statically linked "plugins" the layer offers an extension: modules are
// registered by name and their symbols as (name, int address) pairs, so code
// can use the GModule shape without a dynamic loader.

using Planet;

namespace GModule {

    public enum ModuleFlags {
        LAZY,
        LOCAL,
        SHLIB
    }

    public errordomain ModuleError {
        FAILED,
        NOT_SUPPORTED,
        NOT_FOUND
    }

    private GenericArray<string> module_names;
    private GenericArray<string> module_descriptions;
    private GenericArray<string> symbol_modules;
    private GenericArray<string> symbol_names;
    private GenericArray<int> symbol_addresses;
    private string last_error = "";

    private void ensure_registry () {
        if (module_names == null)
            module_names = new GenericArray<string> ();
        if (module_descriptions == null)
            module_descriptions = new GenericArray<string> ();
        if (symbol_modules == null)
            symbol_modules = new GenericArray<string> ();
        if (symbol_names == null)
            symbol_names = new GenericArray<string> ();
        if (symbol_addresses == null)
            symbol_addresses = new GenericArray<int> ();
    }

    private int module_index (string name) {
        ensure_registry ();
        for (int i = 0; i < module_names.length; i++) {
            if (module_names[i] == name)
                return i;
        }
        return -1;
    }

    public class ModuleHandle : Object {
        private string module_name;

        public ModuleHandle (string name) {
            module_name = name;
        }

        public string get_name () {
            return module_name;
        }

        public bool is_static () {
            return true;
        }

        public bool has_symbol (string symbol) {
            return Module.symbol_address (module_name, symbol) >= 0;
        }

        public int get_symbol (string symbol) {
            return Module.symbol_address (module_name, symbol);
        }
    }

    public class Module : Object {
        // There is no dynamic loader on PlanetOS.
        public static bool supported () {
            return false;
        }

        public static string error () {
            return last_error;
        }

        public static ModuleHandle open (string path, ModuleFlags flags = ModuleFlags.LAZY) throws ModuleError {
            last_error = "PlanetOS has no dynamic linker; register modules statically";
            throw new ModuleError.NOT_SUPPORTED (last_error);
        }

        // --- PlanetOS extension: statically linked modules -----------------

        public static bool register_static (string name, string description = "") {
            if (name.length == 0 || module_index (name) >= 0)
                return false;
            ensure_registry ();
            module_names.add (name);
            module_descriptions.add (description);
            return true;
        }

        public static bool is_registered (string name) {
            return module_index (name) >= 0;
        }

        public static int module_count () {
            ensure_registry ();
            return module_names.length;
        }

        public static string module_description (string name) {
            int index = module_index (name);
            if (index < 0)
                return "";
            return module_descriptions[index];
        }

        public static ModuleHandle open_static (string name) throws ModuleError {
            if (module_index (name) < 0) {
                last_error = @"module '$name' is not registered";
                throw new ModuleError.NOT_FOUND (last_error);
            }
            return new ModuleHandle (name);
        }

        public static bool register_symbol (string module, string symbol, int address) {
            if (module_index (module) < 0 || symbol.length == 0 || address < 0)
                return false;
            ensure_registry ();
            for (int i = 0; i < symbol_modules.length; i++) {
                if (symbol_modules[i] == module && symbol_names[i] == symbol) {
                    symbol_addresses[i] = address;
                    return true;
                }
            }
            symbol_modules.add (module);
            symbol_names.add (symbol);
            symbol_addresses.add (address);
            return true;
        }

        public static int symbol_address (string module, string symbol) {
            ensure_registry ();
            for (int i = 0; i < symbol_modules.length; i++) {
                if (symbol_modules[i] == module && symbol_names[i] == symbol)
                    return symbol_addresses[i];
            }
            return -1;
        }
    }
}
