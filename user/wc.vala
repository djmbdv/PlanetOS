// Real-world style Vala program using pure-Vala GLib & Gee compatibility layer (no C, no .vapi).

using GLib;
using Gee;

int main (string[] args) {
    if (args.length < 2) {
        printerr ("usage: wc.elf <file>\n");
        return 1;
    }
    string path = args[1];
    if (!FileUtils.test (path, FileTest.EXISTS)) {
        printerr (@"wc: cannot open '$path'\n");
        return 1;
    }
    string text = "";
    if (!FileUtils.get_contents (path, out text)) {
        printerr (@"wc: read failed '$path'\n");
        return 1;
    }

    int lines = 0;
    int words = 0;
    bool in_word = false;
    for (int i = 0; i < text.length; i++) {
        uint8 c = text[i];
        if (c == '\n')
            lines = lines + 1;
        bool is_ws = (c == ' ' || c == '\t' || c == '\r' || c == '\n');
        if (is_ws) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            words = words + 1;
        }
    }

    var sb = new StringBuilder ();
    sb.append (@"$path: lines=$lines words=$words bytes=$(text.length) chars=$(text.char_count())");
    if (text.contains ("PlanetOS"))
        sb.append (" [has PlanetOS]");

    var list = new ArrayList<string> ();
    list.add (sb.str);
    print (@"$(list.get(0))\n");
    return 0;
}
