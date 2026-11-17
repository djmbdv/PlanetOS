// GTK-compatible widget toolkit demo for PlanetOS (Window, Box, Label, Entry, Button + libschrift TTF).
using Planet;
using Gtk;

class GtkDemoState : Object {
    public int clicks = 0;
}

int main (string[] args) {
    bool once = false;
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--once")
            once = true;
    }

    init (args);
    bool ttf_ok = load_ttf ("Ubuntu-Regular.ttf");
    print (@"gtk_demo: ttf=$(ttf_ok ? 1 : 0)\n");

    var win = new GtkWindow (800, 600);
    win.set_title ("PlanetOS GTK + TrueType Demo (7)");

    var vbox = new Box (Orientation.VERTICAL, 14);
    var title_lbl = new Label ("PlanetOS GUI Toolkit (GTK + libschrift 7)");
    title_lbl.font_size = 22.0;

    var entry = new Entry ("Hello PlanetOS 7");
    entry.placeholder = "Type here...";

    var status_lbl = new Label ("Clicks: 0");
    var state = new GtkDemoState ();

    var hbox = new Box (Orientation.HORIZONTAL, 12);
    var btn_inc = new Button ("Increment (+1)");
    btn_inc.clicked.connect ((sender) => {
        state.clicks = state.clicks + 1;
        status_lbl.set_text (@"Clicks: $(state.clicks) | $(entry.get_text ())");
    });

    var btn_quit = new Button ("Quit");
    btn_quit.clicked.connect ((sender) => {
        main_quit ();
    });

    hbox.pack_start (btn_inc);
    hbox.pack_start (btn_quit);

    vbox.pack_start (title_lbl);
    vbox.pack_start (entry);
    vbox.pack_start (hbox);
    vbox.pack_start (status_lbl);

    win.add (vbox);
    win.run (once);
    print ("gtk_demo: done\n");
    return 0;
}
