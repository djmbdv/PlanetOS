// GTK-compatible widget toolkit demo for PlanetOS (Window, Box, Label, Entry, Button + libschrift TTF).
using Planet;
using GLib;
using Gtk;

class GtkDemoState : Object {
    public int clicks = 0;
}

int main (string[] args) {
    var opt_ctx = new GLib.OptionContext ();
    var opt_once = new GLib.OptionEntry ("once", '\0', GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Render once and exit");
    opt_ctx.add_entry (opt_once);
    opt_ctx.set_ignore_unknown_options (true);
    try {
        opt_ctx.parse (ref args);
    } catch (OptionError e) {
    }
    bool once = opt_once.bool_val;

    init (args);
    bool ttf_ok = load_ttf ("LiberationSans-Regular.ttf");
    TextHelper.load_mono_ttf ("LiberationMono-Regular.ttf");
    print (@"gtk_demo: ttf=$(ttf_ok ? 1 : 0)\n");

    var win = new GtkWindow (1280, 720);
    win.set_title ("PlanetOS GTK + TrueType Demo (7)");

    var vbox = new Box (Orientation.VERTICAL, 14);
    var title_lbl = new Label ("");
    title_lbl.set_markup ("<b>PlanetOS GUI Toolkit (GTK + libschrift 7)</b>");
    title_lbl.font_size = 22.0;

    var entry = new Entry ("Hello PlanetOS 7");
    entry.placeholder = "Type here...";

    var chk = new CheckButton ("Enable progress bar", true);
    var pbar = new ProgressBar ();
    pbar.set_text ("0%");

    var ctrl_frame = new Frame ("Interactive Controls");
    var ctrl_row = new Box (Orientation.HORIZONTAL, 12);
    var sw = new Switch (true);
    var slider = new Scale (0.0, 100.0, 5.0);
    slider.set_value (25.0);
    slider.value_changed.connect ((sender, val) => {
        int pct = (int) val;
        pbar.set_fraction (val / 100.0);
        pbar.set_text (@"$pct%");
    });
    sw.toggled.connect ((sender) => {
        chk.set_active (sw.get_active ());
    });
    ctrl_row.pack_start (sw);
    ctrl_row.pack_start (slider);
    ctrl_frame.set_child (ctrl_row);

    var state = new GtkDemoState ();
    var status_lbl = new Label (@"Clicks: $(state.clicks)");

    var hbox = new Box (Orientation.HORIZONTAL, 12);
    var btn_inc = new Button ("Increment (+1)");
    btn_inc.clicked.connect ((sender) => {
        state.clicks = state.clicks + 1;
        status_lbl.set_text (@"Clicks: $(state.clicks) | $(entry.get_text ())");
        if (chk.get_active ()) {
            int pct = (state.clicks * 10) % 110;
            if (pct > 100) pct = 100;
            pbar.set_fraction ((double) pct / 100.0);
            pbar.set_text (@"$pct%");
        }
    });

    var btn_quit = new Button ("Quit");
    btn_quit.clicked.connect ((sender) => {
        main_quit ();
    });

    hbox.pack_start (btn_inc);
    hbox.pack_start (btn_quit);

    vbox.pack_start (title_lbl);
    vbox.pack_start (entry);
    vbox.pack_start (chk);
    vbox.pack_start (ctrl_frame);
    vbox.pack_start (pbar);
    vbox.pack_start (new Separator ());
    vbox.pack_start (hbox);
    vbox.pack_start (status_lbl);

    // Fase 2 widgets: Image, ListBox, ListView, ScrolledWindow, Paned, Notebook
    var nb = new Notebook ();
    nb.append_page (vbox, "Controls");

    var paned = new Paned (Orientation.HORIZONTAL);
    paned.set_position (200);
    var sidebar = new ListBox ();
    var r_home = new Box (Orientation.HORIZONTAL, 6);
    r_home.pack_start (new Image.from_icon_name ("folder", 18));
    r_home.pack_start (new Label ("/ (XFS)"));
    sidebar.append (r_home);
    paned.set_start_child (sidebar);

    var sc = new ScrolledWindow ();
    var lv = new ListView ();
    var items = new GenericArray<string> ();
    items.add ("hello.txt");
    items.add ("gtk_demo.elf");
    var icons = new GenericArray<string> ();
    icons.add ("text-x-generic");
    icons.add ("application-x-executable");
    lv.set_items (items, icons);

    var store_lv = new ListView ();
    var model = new Gio.ListStore<string> ();
    store_lv.set_model (model);
    model.append ("row-a");
    model.append ("row-b");
    status_lbl.set_opacity (0.9);
    print (@"gtk_demo: model_count=$(store_lv.get_count ())\n");

    sc.set_child (lv);
    paned.set_end_child (sc);
    nb.append_page (paned, "Files");

    win.add (nb);
    win.run (once);
    print ("gtk_demo: done\n");
    return 0;
}
