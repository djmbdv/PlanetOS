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
        private bool dyn = false;

        public ModuleHandle (string name, bool is_dyn = false) {
            module_name = name;
            dyn = is_dyn;
        }

        public string get_name () {
            return module_name;
        }

        public bool is_static () {
            return !dyn;
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

        private static int le16 (uint8[] b, int off) {
            return ((int) b[off]) | (((int) b[off + 1]) << 8);
        }

        private static int le32 (uint8[] b, int off) {
            return ((int) b[off]) | (((int) b[off + 1]) << 8)
                | (((int) b[off + 2]) << 16) | (((int) b[off + 3]) << 24);
        }

        private static int le64 (uint8[] b, int off) {
            int lo = le32 (b, off);
            int hi = le32 (b, off + 4);
            return lo | (hi << 32);
        }

        private static ModuleHandle open_dlib (string path) throws ModuleError {
            if (module_index (path) >= 0)
                return new ModuleHandle (path, true);
            int fd = Sys.open (path);
            if (fd < 0) {
                last_error = @"dlib '$path' not found";
                throw new ModuleError.NOT_FOUND (last_error);
            }
            int sz = Sys.file_size (fd);
            if (sz < 64 || sz > 4194304) {
                Sys.close (fd);
                last_error = @"invalid dlib size for '$path'";
                throw new ModuleError.FAILED (last_error);
            }
            var buf = new uint8[sz];
            int got = 0;
            while (got < sz) {
                int rem = sz - got;
                if (rem > 65536) rem = 65536;
                var chunk = new uint8[rem];
                int r = Sys.read (fd, chunk, rem);
                if (r <= 0)
                    break;
                for (int i = 0; i < r; i++)
                    buf[got + i] = chunk[i];
                got = got + r;
            }
            Sys.close (fd);
            if (got < 64 || le32 (buf, 0) != 0x4E414C50 || le16 (buf, 6) != 1) {
                last_error = @"'$path' is not a valid PlanetOS .dlib";
                throw new ModuleError.FAILED (last_error);
            }
            int sec_count = le32 (buf, 24);
            int exp_count = le32 (buf, 28);
            int meta_off = le64 (buf, 40);
            if (sec_count <= 0 || 64 + sec_count * 32 > got) {
                last_error = @"corrupt section table in '$path'";
                throw new ModuleError.FAILED (last_error);
            }
            for (int i = 0; i < sec_count; i++) {
                int sh = 64 + i * 32;
                int vaddr = le64 (buf, sh + 0);
                int foff = le64 (buf, sh + 8);
                int fsz = le64 (buf, sh + 16);
                int msz = le64 (buf, sh + 24);
                if (msz <= 0)
                    continue;
                if (foff + fsz > got || Sys.map_user_at (vaddr, msz) < 0) {
                    last_error = @"failed to map .dlib section in '$path'";
                    throw new ModuleError.FAILED (last_error);
                }
                for (int b = 0; b < fsz; b++)
                    Unsafe.poke8 (vaddr + b, (int) buf[foff + b]);
                for (int b = fsz; b < msz; b++)
                    Unsafe.poke8 (vaddr + b, 0);
                // Sections 0 (.text) and 1 (.rodata) are read-only once populated.
                if (i < 2)
                    Sys.protect_user_ro (vaddr, msz);
            }
            register_static (path, "PlanetOS .dlib");
            int pos = meta_off;
            for (int i = 0; i < exp_count && pos + 12 <= got; i++) {
                int sym_addr = le64 (buf, pos);
                int nlen = le32 (buf, pos + 8);
                pos = pos + 12;
                if (nlen <= 0 || pos + nlen > got)
                    break;
                var nsl = new uint8[nlen];
                for (int k = 0; k < nlen; k++)
                    nsl[k] = buf[pos + k];
                string sname = __planc_host_bytes_to_str (nsl, nlen);
                register_symbol (path, sname, sym_addr);
                pos = pos + nlen;
            }
            return new ModuleHandle (path, true);
        }

        public static ModuleHandle open (string path, ModuleFlags flags = ModuleFlags.LAZY) throws ModuleError {
            if (path.has_suffix (".dlib"))
                return open_dlib (path);
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
