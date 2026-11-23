// Pure-Vala Gio ListStore, SimpleAction, AppInfo, and Application.
using GLib;
using Planet;

namespace Gio {

    public class ListStore<G> : Object {
        private GenericArray<G> items;
        private G zero_val;

        public signal void items_changed (int position, int removed, int added);

        public ListStore () {
            items = new GenericArray<G> ();
        }

        public int get_n_items () {
            return items.length;
        }

        public G get_item (int position) {
            if (position < 0 || position >= items.length)
                return zero_val;
            return items[position];
        }

        public void append (G item) {
            int pos = items.length;
            items.add (item);
            items_changed (pos, 0, 1);
        }

        public void insert (int position, G item) {
            int n = items.length;
            if (position < 0) position = 0;
            if (position >= n) {
                append (item);
                return;
            }
            items.add (items[n - 1]);
            for (int i = n - 1; i > position; i--)
                items[i] = items[i - 1];
            items[position] = item;
            items_changed (position, 0, 1);
        }

        public void remove (int position) {
            if (position < 0 || position >= items.length)
                return;
            items.remove_index (position);
            items_changed (position, 1, 0);
        }

        public void remove_all () {
            int n = items.length;
            if (n == 0)
                return;
            items = new GenericArray<G> ();
            items_changed (0, n, 0);
        }

        public bool find (G item, out int position) {
            position = -1;
            for (int i = 0; i < items.length; i++) {
                if (items[i] == item) {
                    position = i;
                    return true;
                }
            }
            return false;
        }

        public void splice (int position, int removals, G[] additions) {
            int n = items.length;
            if (position < 0)
                position = 0;
            if (position > n)
                position = n;
            int rem = removals;
            if (rem < 0)
                rem = 0;
            if (position + rem > n)
                rem = n - position;
            for (int i = 0; i < rem; i++)
                items.remove_index (position);
            for (int i = 0; i < additions.length; i++)
                insert_raw (position + i, additions[i]);
            if (rem > 0 || additions.length > 0)
                items_changed (position, rem, additions.length);
        }

        private void insert_raw (int position, G item) {
            int n = items.length;
            if (position >= n) {
                items.add (item);
                return;
            }
            items.add (items[n - 1]);
            for (int i = n - 1; i > position; i--)
                items[i] = items[i - 1];
            items[position] = item;
        }
    }

    public class SimpleAction : Object {
        private string action_name;
        private VariantType? param_type = null;
        private bool enabled = true;
        private Variant? state_val = null;
        private bool stateful = false;

        public signal void activate (Variant? parameter);
        public signal void change_state (Variant? value);

        public SimpleAction (string name, VariantType? parameter_type = null) {
            action_name = name;
            param_type = parameter_type;
        }

        public SimpleAction.stateful (string name, VariantType? parameter_type, Variant state) {
            action_name = name;
            param_type = parameter_type;
            state_val = state;
            stateful = true;
        }

        public string get_name () {
            return action_name;
        }

        public VariantType? get_parameter_type () {
            return param_type;
        }

        public VariantType? get_state_type () {
            return (state_val != null) ? state_val.get_type () : null;
        }

        public bool get_enabled () {
            return enabled;
        }

        public void set_enabled (bool e) {
            enabled = e;
        }

        public Variant? get_state () {
            return state_val;
        }

        public void set_state (Variant value) {
            if (stateful) {
                state_val = value;
                change_state (value);
            }
        }

        public void activate_action (Variant? parameter = null) {
            if (!enabled)
                return;
            if (param_type != null && (parameter == null || !parameter.is_of_type (param_type)))
                return;
            activate (parameter);
        }
    }

    public class SimpleActionGroup : Object {
        private GenericArray<SimpleAction> actions;

        public SimpleActionGroup () {
            actions = new GenericArray<SimpleAction> ();
        }

        public void add_action (SimpleAction action) {
            for (int i = 0; i < actions.length; i++) {
                if (actions[i].get_name () == action.get_name ()) {
                    actions[i] = action;
                    return;
                }
            }
            actions.add (action);
        }

        public void remove_action (string name) {
            for (int i = 0; i < actions.length; i++) {
                if (actions[i].get_name () == name) {
                    actions.remove_index (i);
                    return;
                }
            }
        }

        public SimpleAction? lookup_action (string name) {
            for (int i = 0; i < actions.length; i++) {
                if (actions[i].get_name () == name)
                    return actions[i];
            }
            return null;
        }

        public void activate_action (string name, Variant? parameter = null) {
            var a = lookup_action (name);
            if (a != null)
                a.activate_action (parameter);
        }
    }

    public class AppInfo : Object {
        private string cmd;
        private string app_name;

        private AppInfo (string commandline, string name) {
            cmd = commandline;
            app_name = name;
        }

        public static AppInfo create_from_commandline (string commandline, string? application_name = null) {
            string nm = (application_name != null && application_name.length > 0) ? application_name : commandline;
            return new AppInfo (commandline, nm);
        }

        public static AppInfo? get_default_for_type (string content_type) {
            if (content_type == "application/x-executable")
                return new AppInfo ("exec", "PlanetOS Runner");
            if (content_type.has_prefix ("text/"))
                return new AppInfo ("wc.elf", "Text Inspector");
            return null;
        }

        public string get_name () {
            return app_name;
        }

        public string get_commandline () {
            return cmd;
        }

        public bool launch (GenericArray<File>? files = null) {
            try {
                if (cmd == "exec" && files != null && files.length > 0) {
                    string target = files[0].get_path ();
                    if (target.has_prefix ("/"))
                        target = target.substring (1);
                    string[] argv = { target };
                    int pid = 0;
                    return Process.spawn_async (null, argv, null, SpawnFlags.SEARCH_PATH, null, out pid);
                }
                var base_argv = Process.split_command_line (cmd);
                int extra = (files != null) ? files.length : 0;
                var argv = new string[base_argv.length + extra];
                for (int i = 0; i < base_argv.length; i++)
                    argv[i] = base_argv[i];
                if (files != null) {
                    for (int i = 0; i < files.length; i++)
                        argv[base_argv.length + i] = files[i].get_path ();
                }
                int pid = 0;
                return Process.spawn_async (null, argv, null, SpawnFlags.SEARCH_PATH, null, out pid);
            } catch (SpawnError e) {
                return false;
            }
        }
    }

    public class Application : Object {
        private string? app_id;
        private ApplicationFlags flags;
        private int hold_count = 0;
        private MainLoop? loop = null;
        private SimpleActionGroup action_group = new SimpleActionGroup ();

        public signal void activate ();

        public Application (string? application_id = null, ApplicationFlags flags = ApplicationFlags.FLAGS_NONE) {
            this.app_id = application_id;
            this.flags = flags;
        }

        public void add_action (SimpleAction action) {
            action_group.add_action (action);
        }

        public SimpleAction? lookup_action (string name) {
            return action_group.lookup_action (name);
        }

        public void activate_action (string name, Variant? parameter = null) {
            action_group.activate_action (name, parameter);
        }

        public string? get_application_id () {
            return (app_id != null) ? app_id.substring (0) : null;
        }

        public ApplicationFlags get_flags () {
            return flags;
        }

        public void hold () {
            hold_count = hold_count + 1;
        }

        public void release () {
            if (hold_count > 0)
                hold_count = hold_count - 1;
            if (hold_count == 0) {
                var current = loop;
                if (current != null)
                    current.quit ();
            }
        }

        public virtual int run (string[]? args = null) {
            activate ();
            if (hold_count <= 0)
                return 0;
            loop = new MainLoop ();
            loop.run ();
            loop = null;
            return 0;
        }
    }
}
