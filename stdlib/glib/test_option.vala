// Pure-Vala GLib.Test and GLib.OptionContext for PlanetOS.
using Planet;

namespace GLib {

    public delegate void TestFunc ();

    private class TestCase : Object {
        public string path;
        public TestFunc func;

        public TestCase (string p, TestFunc f) {
            path = p;
            func = f;
        }
    }

    private GenericArray<TestCase>? test_cases = null;

    /**
     * Lightweight unit-test harness and assertions (GLib.Test).
     */
    public class Test : Object {
        private static int total_checks = 0;
        private static int failed_checks = 0;
        private static string prefix = "test";

        public static void init (ref string[] args) {
            test_cases = new GenericArray<TestCase> ();
            total_checks = 0;
            failed_checks = 0;
            if (args.length > 0 && args[0].length > 0)
                prefix = PathUtils.get_basename (args[0]);
        }

        public static void add_func (string testpath, TestFunc func) {
            if (test_cases == null)
                test_cases = new GenericArray<TestCase> ();
            ((!) test_cases).add (new TestCase (testpath, func));
        }

        public static int run () {
            if (test_cases == null)
                return 0;
            var list = (!) test_cases;
            int ran = 0;
            for (int i = 0; i < list.length; i++) {
                var tc = list[i];
                int before_fail = failed_checks;
                tc.func ();
                ran++;
                if (failed_checks == before_fail)
                    print (@"ok $ran - $(tc.path)\n");
                else
                    print (@"not ok $ran - $(tc.path)\n");
            }
            print (@"$prefix:summary checks=$total_checks failures=$failed_checks\n");
            return (failed_checks == 0) ? 0 : 1;
        }

        public static void message (string msg) {
            print (@"# $msg\n");
        }

        public static void fail (string msg = "Test failed") {
            total_checks++;
            failed_checks++;
            print (@"FAIL: $msg\n");
        }

        public static void assert_true (bool expr, string msg = "assertion failed") {
            total_checks++;
            if (!expr) {
                failed_checks++;
                print (@"FAIL: $msg\n");
            }
        }

        public static void assert_false (bool expr, string msg = "assertion expected false") {
            assert_true (!expr, msg);
        }

        public static void assert_not_reached (string msg = "should not be reached") {
            fail (msg);
        }

        private static int cmp_str (string a, string b) {
            int n = (a.length < b.length) ? a.length : b.length;
            for (int i = 0; i < n; i++) {
                if (a[i] < b[i]) return -1;
                if (a[i] > b[i]) return 1;
            }
            if (a.length == b.length) return 0;
            return (a.length < b.length) ? -1 : 1;
        }

        public static void assert_cmpstr (string? s1, string op, string? s2) {
            total_checks++;
            string a = (s1 != null) ? (!) s1 : "";
            string b = (s2 != null) ? (!) s2 : "";
            bool ok = false;
            if (op == "==") ok = (s1 == s2);
            else if (op == "!=") ok = (s1 != s2);
            else {
                int c = cmp_str (a, b);
                if (op == "<") ok = (c < 0);
                else if (op == "<=") ok = (c <= 0);
                else if (op == ">") ok = (c > 0);
                else if (op == ">=") ok = (c >= 0);
            }
            if (!ok) {
                failed_checks++;
                print (@"FAIL: assert_cmpstr('$a' $op '$b')\n");
            }
        }

        public static void assert_cmpint (int64 n1, string op, int64 n2) {
            total_checks++;
            bool ok = false;
            if (op == "==") ok = (n1 == n2);
            else if (op == "!=") ok = (n1 != n2);
            else if (op == "<") ok = (n1 < n2);
            else if (op == "<=") ok = (n1 <= n2);
            else if (op == ">") ok = (n1 > n2);
            else if (op == ">=") ok = (n1 >= n2);
            if (!ok) {
                failed_checks++;
                print (@"FAIL: assert_cmpint($n1 $op $n2)\n");
            }
        }
    }

    public enum OptionArg {
        NONE,
        STRING,
        INT,
        DOUBLE,
        FILENAME,
        STRING_ARRAY
    }

    public enum OptionFlags {
        NONE = 0,
        HIDDEN = 1,
        IN_MAIN = 2,
        REVERSE = 4,
        NO_ARG = 8,
        FILENAME = 16,
        OPTIONAL_ARG = 32,
        NOALIAS = 64
    }

    public errordomain OptionError {
        UNKNOWN_OPTION,
        BAD_VALUE,
        FAILED
    }

    /**
     * Option entry descriptor (GLib.OptionEntry).
     */
    public class OptionEntry : Object {
        public string long_name;
        public char short_name;
        public OptionFlags flags;
        public OptionArg arg;
        public string? description;
        public string? arg_description;

        public bool bool_val = false;
        public string? str_val = null;
        public int int_val = 0;
        public double double_val = 0.0;
        public GenericArray<string> str_arr_val = new GenericArray<string> ();
        public bool was_set = false;
        // Set by OptionGroup so get_help() can print a heading per group.
        public string group_name = "";

        public OptionEntry (string long_name, char short_name = '\0', OptionFlags flags = OptionFlags.NONE,
                            OptionArg arg = OptionArg.NONE, string? description = null, string? arg_description = null) {
            this.long_name = long_name;
            this.short_name = short_name;
            this.flags = flags;
            this.arg = arg;
            this.description = description;
            this.arg_description = arg_description;
        }
    }

    /**
     * A named set of options (GLib.OptionGroup) that an OptionContext can add
     * as a unit; get_help() prints each group under its own heading.
     */
    public class OptionGroup : Object {
        private string name;
        private string? description;
        private string? help_text;
        private GenericArray<OptionEntry> entries = new GenericArray<OptionEntry> ();

        public OptionGroup (string name, string? description, string? help) {
            this.name = name;
            this.description = description;
            this.help_text = help;
        }

        public string get_name () {
            return name;
        }

        public string? get_description () {
            return description;
        }

        public string? get_help () {
            return help_text;
        }

        public void set_help (string? help) {
            help_text = help;
        }

        public void add_entry (OptionEntry entry) {
            entry.group_name = name;
            entries.add (entry);
        }

        public void add_entries (OptionEntry[] list) {
            for (int i = 0; i < list.length; i++)
                add_entry (list[i]);
        }

        public GenericArray<OptionEntry> get_entries () {
            return entries;
        }
    }

    /**
     * Command-line option parser (GLib.OptionContext).
     */
    public class OptionContext : Object {
        private string? parameter_string;
        private string? summary = null;
        private string? description = null;
        private bool help_enabled = true;
        private bool ignore_unknown = false;
        private GenericArray<OptionEntry> entries;
        private GenericArray<OptionGroup> groups;

        public OptionContext (string? parameter_string = null) {
            this.parameter_string = parameter_string;
            entries = new GenericArray<OptionEntry> ();
            groups = new GenericArray<OptionGroup> ();
        }

        public void add_group (OptionGroup group) {
            groups.add (group);
            var list = group.get_entries ();
            for (int i = 0; i < list.length; i++)
                entries.add (list[i]);
        }

        public void set_summary (string? s) { summary = s; }
        public string? get_summary () { return summary; }
        public void set_description (string? d) { description = d; }
        public string? get_description () { return description; }
        public void set_help_enabled (bool enabled) { help_enabled = enabled; }
        public bool get_help_enabled () { return help_enabled; }
        public void set_ignore_unknown_options (bool ignore) { ignore_unknown = ignore; }
        public bool get_ignore_unknown_options () { return ignore_unknown; }

        public void add_entry (OptionEntry entry) {
            entries.add (entry);
        }

        public void add_entries (OptionEntry[] list) {
            for (int i = 0; i < list.length; i++)
                entries.add (list[i]);
        }

        private OptionEntry? find_long (string name) {
            for (int i = 0; i < entries.length; i++) {
                if (entries[i].long_name == name)
                    return entries[i];
            }
            return null;
        }

        private OptionEntry? find_short (char ch) {
            if (ch == '\0')
                return null;
            for (int i = 0; i < entries.length; i++) {
                if (entries[i].short_name == ch)
                    return entries[i];
            }
            return null;
        }

        private void apply_value (OptionEntry e, string? raw) throws OptionError {
            e.was_set = true;
            if (e.arg == OptionArg.NONE) {
                bool rev = ((int) e.flags & (int) OptionFlags.REVERSE) != 0;
                e.bool_val = !rev;
                return;
            }
            if (raw == null)
                throw new OptionError.BAD_VALUE (@"Missing argument for --$(e.long_name)");
            string val = (!) raw;
            if (e.arg == OptionArg.STRING || e.arg == OptionArg.FILENAME) {
                e.str_val = val;
            } else if (e.arg == OptionArg.INT) {
                int parsed = 0;
                if (!parse_int (val, out parsed))
                    throw new OptionError.BAD_VALUE (@"Cannot parse integer value '$val' for --$(e.long_name)");
                e.int_val = parsed;
            } else if (e.arg == OptionArg.DOUBLE) {
                e.double_val = double.parse (val);
            } else if (e.arg == OptionArg.STRING_ARRAY) {
                e.str_arr_val.add (val);
            }
        }

        private static bool parse_int (string s, out int val) {
            val = 0;
            if (s.length == 0)
                return false;
            int i = 0;
            bool neg = false;
            if (s[0] == '-') {
                neg = true;
                i = 1;
            } else if (s[0] == '+') {
                i = 1;
            }
            if (i >= s.length)
                return false;
            int64 acc = 0;
            int64 limit = neg ? 2147483648L : 2147483647L;
            for (; i < s.length; i++) {
                uint8 c = s[i];
                if (c < '0' || c > '9')
                    return false;
                acc = acc * 10 + (int64) (c - '0');
                if (acc > limit)
                    return false;
            }
            val = neg ? (int) (-acc) : (int) acc;
            return true;
        }

        public bool parse (ref string[] args) throws OptionError {
            var remaining = new GenericArray<string> ();
            if (args.length > 0)
                remaining.add (args[0]);
            bool stop_opts = false;
            int i = 1;
            while (i < args.length) {
                string a = args[i];
                if (stop_opts || !a.has_prefix ("-") || a == "-") {
                    remaining.add (a);
                    i++;
                    continue;
                }
                if (a == "--") {
                    stop_opts = true;
                    i++;
                    continue;
                }
                if (help_enabled && (a == "--help" || a == "-h" || a == "-?")) {
                    print (get_help ());
                    i++;
                    continue;
                }
                if (a.has_prefix ("--")) {
                    string body = a.substring (2);
                    int eq = body.index_of_char ('=');
                    string name = (eq >= 0) ? body.substring (0, eq) : body;
                    string? inline_val = (eq >= 0) ? body.substring (eq + 1) : null;
                    var entry = find_long (name);
                    if (entry == null) {
                        if (ignore_unknown) {
                            remaining.add (a);
                            i++;
                            continue;
                        }
                        throw new OptionError.UNKNOWN_OPTION (@"Unknown option --$name");
                    }
                    var e = (!) entry;
                    if (e.arg == OptionArg.NONE) {
                        apply_value (e, null);
                        i++;
                    } else if (inline_val != null) {
                        apply_value (e, inline_val);
                        i++;
                    } else {
                        if (i + 1 >= args.length)
                            throw new OptionError.BAD_VALUE (@"Missing argument for --$name");
                        apply_value (e, args[i + 1]);
                        i += 2;
                    }
                } else {
                    char ch = (char) a[1];
                    var entry = find_short (ch);
                    if (entry == null) {
                        if (ignore_unknown) {
                            remaining.add (a);
                            i++;
                            continue;
                        }
                        throw new OptionError.UNKNOWN_OPTION (@"Unknown option -$ch");
                    }
                    var e = (!) entry;
                    if (e.arg == OptionArg.NONE) {
                        apply_value (e, null);
                        i++;
                    } else if (a.length > 2) {
                        apply_value (e, a.substring (2));
                        i++;
                    } else {
                        if (i + 1 >= args.length)
                            throw new OptionError.BAD_VALUE (@"Missing argument for -$ch");
                        apply_value (e, args[i + 1]);
                        i += 2;
                    }
                }
            }
            var out_args = new string[remaining.length];
            for (int k = 0; k < remaining.length; k++)
                out_args[k] = remaining[k];
            args = out_args;
            return true;
        }

        private static void append_entry (StringBuilder sb, OptionEntry e) {
            if (((int) e.flags & (int) OptionFlags.HIDDEN) != 0)
                return;
            sb.append ("  ");
            if (e.short_name != '\0') {
                sb.append ("-");
                sb.append_c (e.short_name);
                sb.append (", ");
            } else {
                sb.append ("    ");
            }
            sb.append (@"--$(e.long_name)");
            if (e.arg != OptionArg.NONE) {
                string ad = (e.arg_description != null) ? (!) e.arg_description : "VAL";
                sb.append (@"=$ad");
            }
            if (e.description != null) {
                string ed = (!) e.description;
                sb.append (@"  $ed");
            }
            sb.append ("\n");
        }

        public string get_help () {
            var sb = new StringBuilder ();
            sb.append ("Usage:\n  [OPTION...]");
            if (parameter_string != null && ((!) parameter_string).length > 0) {
                string ps = (!) parameter_string;
                sb.append (@" $ps");
            }
            sb.append ("\n\n");
            if (summary != null && ((!) summary).length > 0) {
                string sm = (!) summary;
                sb.append (@"$sm\n\n");
            }
            sb.append ("Options:\n");
            if (help_enabled)
                sb.append ("  -h, --help                Show help options\n");
            for (int i = 0; i < entries.length; i++) {
                if (entries[i].group_name.length == 0)
                    append_entry (sb, entries[i]);
            }
            for (int g = 0; g < groups.length; g++) {
                var group = groups[g];
                sb.append (@"\n$(group.get_name ()):\n");
                var gd = group.get_description ();
                if (gd != null && ((!) gd).length > 0) {
                    string gds = (!) gd;
                    sb.append (@"  $gds\n");
                }
                var list = group.get_entries ();
                for (int i = 0; i < list.length; i++)
                    append_entry (sb, list[i]);
            }
            if (description != null && ((!) description).length > 0) {
                string ds = (!) description;
                sb.append (@"\n$ds\n");
            }
            return sb.str;
        }
    }
}
