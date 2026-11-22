// Minimal pcm4 file manager for PlanetOS (Fase 3: Gio + Gtk).
using Planet;
using GLib;
using Gio;
using Gtk;

class Pcm4State : Object {
    public string cwd = "/";
    public string selected_name = "";
    public string clip_path = "";
    public bool clip_cut = false;
    public int item_count = 0;
    public GenericArray<string> names = new GenericArray<string> ();
    public GenericArray<bool> is_dirs = new GenericArray<bool> ();
    public Entry? path_entry = null;
    public ListView? list_view = null;
    public Label? status_lbl = null;
    public Label? preview_lbl = null;
    public Notebook? nb = null;
}

string join_child_path (string dir, string name) {
    if (dir == "/" || dir.length == 0)
        return "/" + name;
    if (dir.has_suffix ("/"))
        return dir + name;
    return dir + "/" + name;
}

void set_status (Pcm4State st, string msg) {
    if (st.status_lbl != null)
        st.status_lbl.set_text (msg);
}

void load_dir (Pcm4State st, string dir_path) {
    string target = (dir_path.length == 0) ? "/" : dir_path;
    var items = new GenericArray<string> ();
    var icons = new GenericArray<string> ();
    var names = new GenericArray<string> ();
    var dirs = new GenericArray<bool> ();

    try {
        var dir_file = File.new_for_path (target);
        var en = dir_file.enumerate_children ();
        while (true) {
            var info = en.next_file ();
            if (info == null)
                break;
            string nm = info.get_name ();
            bool is_dir = (info.get_file_type () == FileType.DIRECTORY);
            names.add (nm);
            dirs.add (is_dir);
            if (is_dir) {
                items.add (nm + "/");
                icons.add ("folder");
            } else {
                items.add (@"$nm ($(info.get_size ()) B)");
                string ctype = info.get_content_type ();
                if (ctype == "application/x-executable")
                    icons.add ("application-x-executable");
                else if (ctype == "text/plain" || ctype == "text/x-vala")
                    icons.add ("text-x-generic");
                else
                    icons.add ("document-properties");
            }
        }
        en.close ();
    } catch (IOError e) {
        set_status (st, @"Error reading $target: $(e.message)");
        return;
    }

    st.cwd = target;
    st.names = names;
    st.is_dirs = dirs;
    st.item_count = names.length;
    st.selected_name = (names.length > 0) ? names[0] : "";
    if (st.list_view != null)
        st.list_view.set_items (items, icons);
    if (st.path_entry != null)
        st.path_entry.set_text (st.cwd);
    set_status (st, @"$(st.cwd): $(st.item_count) items");
}

bool is_gui_elf (string nm) {
    return nm == "gtk_demo.elf" || nm == "pcm4.elf" || nm == "cairo_demo.elf"
        || nm == "spv_demo.elf" || nm == "vk_demo.elf" || nm == "pango_demo.elf"
        || nm == "compositor.elf";
}

void run_cli_capture_argv (Pcm4State st, string[] argv, string label_nm) {
    int out_fd = Sys.create ("_pcm4_out.txt");
    if (out_fd < 0) {
        set_status (st, @"Cannot capture output for $label_nm");
        return;
    }
    Sys.sys (19, 0, out_fd, 0);
    int tid = -1;
    try {
        Process.spawn_async (null, argv, null, SpawnFlags.SEARCH_PATH, null, out tid);
    } catch (SpawnError se) {
        Sys.sys (19, 0, 1, 0);
        Sys.close (out_fd);
        Sys.unlink ("_pcm4_out.txt");
        set_status (st, @"Cannot run $label_nm: $(se.message)");
        return;
    }
    int rc = (tid >= 0) ? Sys.wait (tid) : -1;
    Sys.sys (19, 0, 1, 0);
    Sys.close (out_fd);

    string captured = "";
    FileUtils.get_contents ("_pcm4_out.txt", out captured);
    Sys.unlink ("_pcm4_out.txt");
    string snippet = (captured.length > 480) ? captured.substring (0, 480) + "..." : captured;
    if (st.preview_lbl != null)
        st.preview_lbl.set_text (@"[$label_nm exit=$rc]\n$snippet");
    if (st.nb != null)
        st.nb.set_current_page (1);
    set_status (st, @"Finished $label_nm (exit=$rc)");
}

void run_cli_capture (Pcm4State st, string fp, string label_nm) {
    string[] argv = { fp };
    run_cli_capture_argv (st, argv, label_nm);
}

void open_item (Pcm4State st, string name) {
    if (name.length == 0)
        return;
    string full = join_child_path (st.cwd, name);
    var f = File.new_for_path (full);
    try {
        var info = f.query_info ();
        if (info.get_file_type () == FileType.DIRECTORY) {
            load_dir (st, full);
            return;
        }
        if (name.has_suffix (".desktop")) {
            var kf = new KeyFile ();
            try {
                if (kf.load_from_file (full)) {
                    string exec_nm = kf.get_string ("Desktop Entry", "Exec");
                    string app_nm = kf.get_string ("Desktop Entry", "Name");
                    if (app_nm.length == 0)
                        app_nm = name;
                    bool is_term = kf.get_boolean ("Desktop Entry", "Terminal");
                    if (exec_nm.length > 0) {
                        try {
                            if (is_term) {
                                var argv = Process.split_command_line (exec_nm);
                                run_cli_capture_argv (st, argv, app_nm);
                            } else {
                                Process.spawn_command_line_async (exec_nm);
                                set_status (st, @"Launched $app_nm");
                            }
                        } catch (SpawnError se) {
                            set_status (st, @"Launch error: $(se.message)");
                        }
                        return;
                    }
                }
            } catch (KeyFileError ke) {
                set_status (st, @"Desktop entry error: $(ke.message)");
                return;
            }
        }
        string ctype = info.get_content_type ();
        if (ctype == "application/x-executable" || name.has_suffix (".plan")) {
            string fp = full.has_prefix ("/") ? full.substring (1, full.length - 1) : full;
            if (!is_gui_elf (name)) {
                run_cli_capture (st, fp, name);
                return;
            }
            var app = AppInfo.get_default_for_type (ctype);
            if (app != null) {
                var files = new GenericArray<File> ();
                files.add (f);
                app.launch (files);
                set_status (st, @"Launched $name");
                return;
            }
        }
        string contents = "";
        if (FileUtils.get_contents (full, out contents)) {
            string snippet = (contents.length > 240) ? contents.substring (0, 240) + "..." : contents;
            if (st.preview_lbl != null)
                st.preview_lbl.set_text (snippet);
            if (st.nb != null)
                st.nb.set_current_page (1);
            set_status (st, @"Opened $name ($(contents.length) bytes)");
        } else {
            set_status (st, @"Cannot read $name");
        }
    } catch (IOError e) {
        set_status (st, @"Open error: $(e.message)");
    }
}

int main (string[] args) {
    bool once = false;
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--once")
            once = true;
    }

    init (args);
    load_ttf ("LiberationSans-Regular.ttf");
    TextHelper.load_mono_ttf ("LiberationMono-Regular.ttf");

    var st = new Pcm4State ();

    var win = new GtkWindow (1280, 720);
    win.set_title ("pcm4 - PlanetOS File Manager");

    var root = new Box (Orientation.VERTICAL, 8);
    var toolbar = new Box (Orientation.HORIZONTAL, 6);

    var btn_up = new Button ("Up");
    var btn_ref = new Button ("Refresh");
    var btn_copy = new Button ("Copy");
    var btn_cut = new Button ("Cut");
    var btn_paste = new Button ("Paste");
    var btn_del = new Button ("Delete");
    var btn_mkdir = new Button ("Mkdir");
    var entry = new Entry ("/");
    entry.placeholder = "Path...";

    toolbar.pack_start (btn_up);
    toolbar.pack_start (btn_ref);
    toolbar.pack_start (btn_copy);
    toolbar.pack_start (btn_cut);
    toolbar.pack_start (btn_paste);
    toolbar.pack_start (btn_del);
    toolbar.pack_start (btn_mkdir);
    toolbar.pack_start (entry);

    var paned = new Paned (Orientation.HORIZONTAL);
    paned.set_position (180);
    paned.set_size_request (1200, 540);

    var sidebar = new ListBox ();
    var row_root = new Box (Orientation.HORIZONTAL, 6);
    row_root.pack_start (new Image.from_icon_name ("folder", 18));
    row_root.pack_start (new Label ("/ (XFS)"));
    sidebar.append (row_root);

    var row_hello = new Box (Orientation.HORIZONTAL, 6);
    row_hello.pack_start (new Image.from_icon_name ("text-x-generic", 18));
    row_hello.pack_start (new Label ("hello.txt"));
    sidebar.append (row_hello);
    paned.set_start_child (sidebar);

    var nb = new Notebook ();
    var sc_files = new ScrolledWindow ();
    var lv = new ListView ();
    lv.focused = true;
    sc_files.set_child (lv);
    nb.append_page (sc_files, "Files");

    var sc_prev = new ScrolledWindow ();
    var preview_lbl = new Label ("Select a text file to preview.");
    sc_prev.set_child (preview_lbl);
    nb.append_page (sc_prev, "Preview");

    paned.set_end_child (nb);

    var status_lbl = new Label ("Ready");

    st.path_entry = entry;
    st.list_view = lv;
    st.status_lbl = status_lbl;
    st.preview_lbl = preview_lbl;
    st.nb = nb;

    btn_up.clicked.connect ((sender) => {
        var cur = File.new_for_path (st.cwd);
        var par = cur.get_parent ();
        load_dir (st, (par != null) ? par.get_path () : "/");
    });

    btn_ref.clicked.connect ((sender) => {
        load_dir (st, st.cwd);
    });

    entry.activate.connect ((sender) => {
        load_dir (st, entry.get_text ());
    });

    lv.selection_changed.connect ((sender, idx) => {
        if (idx >= 0 && idx < st.names.length) {
            st.selected_name = st.names[idx];
            set_status (st, @"Selected: $(st.selected_name)");
        }
    });

    lv.activate.connect ((sender, idx) => {
        if (idx >= 0 && idx < st.names.length)
            open_item (st, st.names[idx]);
    });

    sidebar.row_activated.connect ((sender, row) => {
        if (row == null)
            return;
        int idx = row.get_index ();
        if (idx == 0)
            load_dir (st, "/");
        else if (idx == 1)
            open_item (st, "hello.txt");
    });

    btn_copy.clicked.connect ((sender) => {
        if (st.selected_name.length == 0)
            return;
        st.clip_path = join_child_path (st.cwd, st.selected_name);
        st.clip_cut = false;
        set_status (st, @"Copied: $(st.selected_name)");
    });

    btn_cut.clicked.connect ((sender) => {
        if (st.selected_name.length == 0)
            return;
        st.clip_path = join_child_path (st.cwd, st.selected_name);
        st.clip_cut = true;
        set_status (st, @"Cut: $(st.selected_name)");
    });

    btn_paste.clicked.connect ((sender) => {
        if (st.clip_path.length == 0) {
            set_status (st, "Clipboard empty");
            return;
        }
        var src = File.new_for_path (st.clip_path);
        string base_nm = src.get_basename ();
        string dst_name = st.clip_cut ? base_nm : ("copy_" + base_nm);
        var dst = File.new_for_path (join_child_path (st.cwd, dst_name));
        try {
            if (st.clip_cut) {
                src.move (dst, FileCopyFlags.OVERWRITE);
                st.clip_path = "";
                st.clip_cut = false;
            } else {
                src.copy (dst, FileCopyFlags.OVERWRITE);
            }
            load_dir (st, st.cwd);
            set_status (st, @"Pasted $dst_name");
        } catch (IOError e) {
            set_status (st, @"Paste failed: $(e.message)");
        }
    });

    btn_del.clicked.connect ((sender) => {
        if (st.selected_name.length == 0)
            return;
        string target = join_child_path (st.cwd, st.selected_name);
        try {
            File.new_for_path (target).delete ();
            load_dir (st, st.cwd);
            set_status (st, @"Deleted $target");
        } catch (IOError e) {
            set_status (st, @"Delete failed: $(e.message)");
        }
    });

    btn_mkdir.clicked.connect ((sender) => {
        string dir_path = join_child_path (st.cwd, "new_folder");
        try {
            File.new_for_path (dir_path).make_directory ();
            load_dir (st, st.cwd);
            set_status (st, @"Created $dir_path");
        } catch (IOError e) {
            set_status (st, @"Mkdir failed: $(e.message)");
        }
    });

    root.pack_start (toolbar);
    root.pack_start (paned);
    root.pack_start (status_lbl);
    win.set_child (root);

    load_dir (st, "/");
    print (@"pcm4: dir=$(st.cwd) items=$(st.item_count) ok\n");

    win.run (once);
    return 0;
}
