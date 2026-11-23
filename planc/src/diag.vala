// Diagnostic collection with error recovery.
//
// planc parses and type-checks in one pass and used to abort at the first
// error. Like valac, it now keeps going: the parser resynchronizes at the next
// declaration boundary and codegen skips the function that failed, so a single
// compile reports every error it can find. Nothing is written when any
// diagnostic was produced.

namespace Planc {

    public sealed class Diag : Object {
        public string file = "";
        public int line = 0;
        public int column = 0;
        public string kind = "";
        public string message = "";
    }

    public sealed class Diagnostics : Object {

        // No static initializers: valac only runs them in a static block the
        // self-hosted compiler does not emit, so main() calls init () first.
        public static GenericArray<Diag> entries;
        public static bool recover;
        public static int limit;
        public static string current_file;
        private static int[] diag_lock;

        public static void init (bool do_recover, int max_errors) {
            entries = new GenericArray<Diag> ();
            recover = do_recover;
            limit = (max_errors > 0) ? max_errors : 1;
            current_file = "";
            diag_lock = new int[1];
        }

        public static int count () {
            if (entries == null)
                return 0;
            Host.spin_lock (diag_lock);
            int n = entries.length;
            Host.spin_unlock (diag_lock);
            return n;
        }

        public static bool is_full () {
            if (entries == null)
                return false;
            Host.spin_lock (diag_lock);
            bool full = entries.length >= limit;
            Host.spin_unlock (diag_lock);
            return full;
        }

        public static void add (string file, int line, int column, string kind, string message) {
            if (entries == null)
                return;
            Host.spin_lock (diag_lock);
            if (entries.length >= limit) {
                Host.spin_unlock (diag_lock);
                return;
            }
            var d = new Diag () {
                file = file,
                line = line,
                column = column,
                kind = kind,
                message = strip_position (message)
            };
            entries.add (d);
            Host.spin_unlock (diag_lock);
        }

        // Start of the " at L:C" suffix, or -1 when the message has none.
        private static int pos_at_start (string msg) {
            int at = -1;
            for (int i = msg.length - 4; i >= 0; i--) {
                if (msg[i] == ' ' && msg[i + 1] == 'a' && msg[i + 2] == 't' && msg[i + 3] == ' ') {
                    at = i + 4;
                    break;
                }
            }
            return at;
        }

        private static int parse_int (string msg, int from, int to) {
            int v = 0;
            for (int i = from; i < to; i++)
                v = v * 10 + (int) (msg[i] - '0');
            return v;
        }

        // Index of the ':' in "L:C", or -1 when the suffix is malformed.
        private static int pos_suffix_colon (string msg) {
            int start = pos_at_start (msg);
            if (start < 0)
                return -1;
            int colon = -1;
            for (int i = start; i < msg.length; i++) {
                if (msg[i] == ':') {
                    colon = i;
                    break;
                }
                if (msg[i] < '0' || msg[i] > '9')
                    return -1;
            }
            if (colon <= start || colon + 1 >= msg.length)
                return -1;
            for (int i = colon + 1; i < msg.length; i++) {
                if (msg[i] < '0' || msg[i] > '9')
                    return -1;
            }
            return colon;
        }

        // Line/column suffix of an error message ("... at 12:34"), 0 when the
        // message carries no position.
        public static int pos_line (string msg) {
            int colon = pos_suffix_colon (msg);
            if (colon < 0)
                return 0;
            return parse_int (msg, pos_at_start (msg), colon);
        }

        public static int pos_column (string msg) {
            int colon = pos_suffix_colon (msg);
            if (colon < 0)
                return 0;
            return parse_int (msg, colon + 1, msg.length);
        }

        // Error messages already end with "at L:C"; the reported position
        // carries that information, so drop the duplicate.
        private static string strip_position (string msg) {
            int start = pos_at_start (msg);
            if (start <= 4)
                return msg;
            if (pos_suffix_colon (msg) < 0)
                return msg;
            return msg.substring (0, start - 4);
        }

        public static void print_all () {
            if (entries == null)
                return;
            for (int i = 0; i < entries.length; i++) {
                var d = entries[i];
                string loc = (d.file != "")
                    ? @"$(d.file):$(d.line):$(d.column)"
                    : @"$(d.line):$(d.column)";
                Host.eprintln (@"planc: $loc: $(d.kind): $(d.message)");
            }
            if (entries.length >= limit)
                Host.eprintln (@"planc: too many errors, stopping after $(entries.length)");
        }

        public static int report () {
            print_all ();
            int n = count ();
            if (n > 0)
                Host.eprintln (@"planc: $n error(s)");
            return (n > 0) ? 1 : 0;
        }
    }
}
