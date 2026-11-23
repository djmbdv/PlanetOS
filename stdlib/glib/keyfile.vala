// Pure-Vala GLib.KeyFile INI parser and writer.
using Planet;

namespace GLib {

    public enum KeyFileFlags {
        NONE,
        KEEP_COMMENTS,
        KEEP_TRANSLATIONS
    }

    public errordomain KeyFileError {
        NOT_FOUND,
        GROUP_NOT_FOUND,
        KEY_NOT_FOUND,
        PARSE
    }

    private class KfEntry : Object {
        public string key;
        public string val;

        public KfEntry (string k, string v) {
            key = k;
            val = v;
        }
    }

    private class KfGroup : Object {
        public string name;
        public GenericArray<KfEntry> entries;
        private GLib.HashTable<string, int> index =
            new GLib.HashTable<string, int> (GLib.str_hash, GLib.str_equal);

        public KfGroup (string n) {
            name = n;
            entries = new GenericArray<KfEntry> ();
        }

        private void rebuild_index () {
            index = new GLib.HashTable<string, int> (GLib.str_hash, GLib.str_equal);
            for (int i = 0; i < entries.length; i++)
                index.insert (entries[i].key, i);
        }

        public int find_entry (string key) {
            if (index.size () != entries.length)
                rebuild_index ();
            int i = -1;
            string orig = "";
            if (!index.lookup_extended (key, out orig, out i))
                return -1;
            return i;
        }

        public void append (KfEntry entry) {
            index.insert (entry.key, entries.length);
            entries.add (entry);
        }

        public void remove_entry (int i) {
            entries.remove_index (i);
            rebuild_index ();
        }
    }

    public class KeyFile : Object {
        private GenericArray<KfGroup> groups;
        private GLib.HashTable<string, int> group_index =
            new GLib.HashTable<string, int> (GLib.str_hash, GLib.str_equal);

        public KeyFile () {
            groups = new GenericArray<KfGroup> ();
        }

        private void rebuild_group_index () {
            group_index = new GLib.HashTable<string, int> (GLib.str_hash, GLib.str_equal);
            for (int i = 0; i < groups.length; i++)
                group_index.insert (groups[i].name, i);
        }

        private int find_group (string group_name) {
            if (group_index.size () != groups.length)
                rebuild_group_index ();
            int i = -1;
            string orig = "";
            if (!group_index.lookup_extended (group_name, out orig, out i))
                return -1;
            return i;
        }

        private KfGroup ensure_group (string group_name) {
            int gi = find_group (group_name);
            if (gi >= 0)
                return groups[gi];
            var g = new KfGroup (group_name);
            group_index.insert (group_name, groups.length);
            groups.add (g);
            return g;
        }

        public bool load_from_data (string data, int length = -1, KeyFileFlags flags = KeyFileFlags.NONE) throws KeyFileError {
            groups = new GenericArray<KfGroup> ();
            int total = (length >= 0 && length < data.length) ? length : data.length;
            string cur_group = "";
            int pos = 0;
            while (pos < total) {
                int nl = data.index_of ("\n", pos);
                int end = (nl >= 0 && nl < total) ? nl : total;
                string raw = data.substring (pos, end - pos);
                pos = (nl >= 0) ? (nl + 1) : total;
                string line = Str.strip (raw);
                if (line.length == 0 || line[0] == '#' || line[0] == ';')
                    continue;
                if (line[0] == '[') {
                    int rb = line.index_of ("]", 1);
                    if (rb < 0)
                        throw new KeyFileError.PARSE ("Malformed group header");
                    cur_group = Str.strip (line.substring (1, rb - 1));
                    ensure_group (cur_group);
                    continue;
                }
                int eq = line.index_of ("=", 0);
                if (eq <= 0)
                    throw new KeyFileError.PARSE ("Expected key=value");
                if (cur_group == "")
                    throw new KeyFileError.PARSE ("Key outside group");
                string k = Str.strip (line.substring (0, eq));
                if (k.length == 0)
                    throw new KeyFileError.PARSE ("Empty key name");
                string v = Str.strip (line.substring (eq + 1));
                set_string (cur_group, k, v);
            }
            return true;
        }

        public bool load_from_file (string file, KeyFileFlags flags = KeyFileFlags.NONE) throws KeyFileError {
            string content = "";
            if (!FileUtils.get_contents (file, out content))
                throw new KeyFileError.NOT_FOUND ("Cannot read key file");
            return load_from_data (content, content.length, flags);
        }

        public string to_data (out int length) {
            var sb = new StringBuilder ();
            for (int i = 0; i < groups.length; i++) {
                var g = groups[i];
                if (i > 0)
                    sb.append ("\n");
                sb.append (@"[$(g.name)]\n");
                for (int j = 0; j < g.entries.length; j++) {
                    var e = g.entries[j];
                    sb.append (@"$(e.key)=$(e.val)\n");
                }
            }
            string res = sb.str;
            length = res.length;
            return res;
        }

        public bool save_to_file (string filename) {
            int len = 0;
            string data = to_data (out len);
            return FileUtils.set_contents (filename, data);
        }

        public bool has_group (string group_name) {
            return find_group (group_name) >= 0;
        }

        public bool has_key (string group_name, string key) throws KeyFileError {
            int gi = find_group (group_name);
            if (gi < 0)
                throw new KeyFileError.GROUP_NOT_FOUND ("Group not found");
            return groups[gi].find_entry (key) >= 0;
        }

        public GenericArray<string> get_groups () {
            var res = new GenericArray<string> ();
            for (int i = 0; i < groups.length; i++)
                res.add (groups[i].name);
            return res;
        }

        public GenericArray<string> get_keys (string group_name) throws KeyFileError {
            int gi = find_group (group_name);
            if (gi < 0)
                throw new KeyFileError.GROUP_NOT_FOUND ("Group not found");
            var res = new GenericArray<string> ();
            var g = groups[gi];
            for (int i = 0; i < g.entries.length; i++)
                res.add (g.entries[i].key);
            return res;
        }

        public string get_string (string group_name, string key) throws KeyFileError {
            int gi = find_group (group_name);
            if (gi < 0)
                throw new KeyFileError.GROUP_NOT_FOUND ("Group not found");
            int ei = groups[gi].find_entry (key);
            if (ei < 0)
                throw new KeyFileError.KEY_NOT_FOUND ("Key not found");
            return groups[gi].entries[ei].val;
        }

        public void set_string (string group_name, string key, string value) {
            var g = ensure_group (group_name);
            int ei = g.find_entry (key);
            if (ei >= 0) {
                g.entries[ei].val = value;
                return;
            }
            g.append (new KfEntry (key, value));
        }

        public int get_integer (string group_name, string key) throws KeyFileError {
            string s = Str.strip (get_string (group_name, key));
            if (s.length == 0)
                throw new KeyFileError.PARSE ("Invalid integer value");
            int i = (s[0] == '+' || s[0] == '-') ? 1 : 0;
            if (i >= s.length)
                throw new KeyFileError.PARSE ("Invalid integer value");
            for (; i < s.length; i++) {
                uint8 c = (uint8) s[i];
                if (c < '0' || c > '9')
                    throw new KeyFileError.PARSE ("Invalid integer value");
            }
            return int.parse (s);
        }

        public void set_integer (string group_name, string key, int value) {
            set_string (group_name, key, @"$value");
        }

        public bool get_boolean (string group_name, string key) throws KeyFileError {
            string s = get_string (group_name, key);
            if (s == "true" || s == "1")
                return true;
            if (s == "false" || s == "0")
                return false;
            throw new KeyFileError.PARSE ("Invalid boolean value");
        }

        public void set_boolean (string group_name, string key, bool value) {
            set_string (group_name, key, value ? "true" : "false");
        }

        public bool remove_key (string group_name, string key) throws KeyFileError {
            int gi = find_group (group_name);
            if (gi < 0)
                throw new KeyFileError.GROUP_NOT_FOUND ("Group not found");
            int ei = groups[gi].find_entry (key);
            if (ei < 0)
                throw new KeyFileError.KEY_NOT_FOUND ("Key not found");
            groups[gi].remove_entry (ei);
            return true;
        }

        public bool remove_group (string group_name) throws KeyFileError {
            int gi = find_group (group_name);
            if (gi < 0)
                throw new KeyFileError.GROUP_NOT_FOUND ("Group not found");
            groups.remove_index (gi);
            rebuild_group_index ();
            return true;
        }
    }

}
