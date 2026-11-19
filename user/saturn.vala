// Saturn: Geany-inspired GTK IDE & text editor for PlanetOS (100% pure Vala).

using GLib;
using Gee;
using Gio;
using Cairo;
using Planet;
using Gtk;

namespace SaturnIDE {

    private static string ch_str (uint8 c) {
        string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
        if (c < 32 || c >= 127)
            return "";
        return ascii.substring ((int) c - 32, 1);
    }

    /**
     * Custom Gtk.Widget providing a Geany-style monospace code editor with
     * line-number gutter, basic Vala/C syntax coloring, and cursor editing.
     */
    public class CodeView : Widget {
        public GenericArray<string> lines;
        public int cx = 0;
        public int cy = 0;
        public bool dirty = false;
        public string filename = "untitled.vala";
        public int line_h = 18;
        public int gutter_w = 46;
        public double font_size = 13.0;

        public signal void cursor_moved (int line, int col, int total_lines);
        public signal void modified_changed (bool is_dirty);
        public signal void save_requested ();

        public CodeView () {
            lines = new GenericArray<string> ();
            lines.add ("// Welcome to Saturn IDE (Geany-style)");
            lines.add ("using Planet;");
            lines.add ("");
            lines.add ("int main (string[] args) {");
            lines.add ("    print (\"Hello from Saturn!\\n\");");
            lines.add ("    return 0;");
            lines.add ("}");
            focused = true;
        }

        public bool load_file (string path) {
            filename = path;
            int fd = Sys.open (path);
            if (fd < 0) {
                lines = new GenericArray<string> ();
                lines.add ("");
                cx = 0; cy = 0; dirty = false;
                modified_changed (false);
                cursor_moved (1, 1, 1);
                return false;
            }
            int sz = Sys.file_size (fd);
            lines = new GenericArray<string> ();
            if (sz > 0) {
                var sb = new StringBuilder ();
                var buf = new uint8[1024];
                int total = 0;
                while (total < sz) {
                    int nr = Sys.read (fd, buf, 1024);
                    if (nr <= 0) break;
                    for (int i = 0; i < nr; i++) {
                        uint8 b = buf[i];
                        if (b == '\n') {
                            lines.add (sb.str);
                            sb = new StringBuilder ();
                        } else if (b == '\t') {
                            sb.append ("    ");
                        } else if (b >= 32 && b < 127) {
                            sb.append (ch_str (b));
                        }
                    }
                    total += nr;
                }
                if (sb.len > 0 || lines.length == 0)
                    lines.add (sb.str);
            } else {
                lines.add ("");
            }
            Sys.close (fd);
            cx = 0;
            cy = 0;
            dirty = false;
            modified_changed (false);
            cursor_moved (1, 1, lines.length);
            return true;
        }

        public int save_file (string path) {
            filename = path;
            int fd = Sys.create (path);
            if (fd < 0)
                return -1;
            int bytes = 0;
            var nl = new uint8[1];
            nl[0] = (uint8) '\n';
            for (int i = 0; i < lines.length; i++) {
                string ln = lines[i];
                if (ln.length > 0) {
                    var b = new uint8[ln.length];
                    for (int k = 0; k < ln.length; k++)
                        b[k] = (uint8) ln[k];
                    int w = Sys.write (fd, b, ln.length);
                    if (w > 0) bytes += w;
                }
                if (i + 1 < lines.length) {
                    Sys.write (fd, nl, 1);
                    bytes += 1;
                }
            }
            Sys.close (fd);
            dirty = false;
            modified_changed (false);
            return bytes;
        }

        public void goto_line (int line_idx) {
            if (line_idx < 0) line_idx = 0;
            if (line_idx >= lines.length) line_idx = lines.length - 1;
            cy = line_idx;
            if (cx > lines[cy].length) cx = lines[cy].length;
            cursor_moved (cy + 1, cx + 1, lines.length);
        }

        public override void measure (out int min_w, out int min_h) {
            int max_len = 40;
            for (int i = 0; i < lines.length; i++) {
                if (lines[i].length > max_len)
                    max_len = lines[i].length;
            }
            min_w = gutter_w + (max_len + 4) * 8;
            min_h = (lines.length + 2) * line_h;
            if (min_w < 360) min_w = 360;
            if (min_h < 200) min_h = 200;
        }

        private static bool is_comment_line (string s) {
            int i = 0;
            while (i < s.length && s[i] == ' ') i++;
            return (i + 1 < s.length && s[i] == '/' && s[i + 1] == '/');
        }

        private static bool has_keyword_prefix (string s) {
            int i = 0;
            while (i < s.length && s[i] == ' ') i++;
            string t = s.substring (i);
            return t.has_prefix ("using ") || t.has_prefix ("namespace ")
                || t.has_prefix ("public ") || t.has_prefix ("private ")
                || t.has_prefix ("class ") || t.has_prefix ("return ")
                || t.has_prefix ("if ") || t.has_prefix ("while ")
                || t.has_prefix ("for ") || t.has_prefix ("var ")
                || t.has_prefix ("int ") || t.has_prefix ("void ");
        }

        public override void draw (Context cr) {
            if (!visible || width <= 0 || height <= 0)
                return;
            // Editor background
            cr.set_source_rgb (1.0, 1.0, 1.0);
            cr.rectangle ((double) x, (double) y, (double) width, (double) height);
            cr.fill ();

            // Gutter background
            cr.set_source_rgb (0.94, 0.95, 0.96);
            cr.rectangle ((double) x, (double) y, (double) gutter_w, (double) height);
            cr.fill ();
            cr.set_source_rgb (0.84, 0.85, 0.88);
            cr.rectangle ((double) (x + gutter_w - 1), (double) y, 1.0, (double) height);
            cr.fill ();

            int i0 = (cr.clip_top () - y) / line_h;
            int i1 = (cr.clip_bottom () - y) / line_h;
            if (i0 < 0) i0 = 0;
            if (i1 >= lines.length) i1 = lines.length - 1;
            for (int i = i0; i <= i1; i++) {
                int ly = y + i * line_h;
                if (i == cy) {
                    cr.set_source_rgb (0.95, 0.97, 1.0);
                    cr.rectangle ((double) (x + gutter_w), (double) ly, (double) (width - gutter_w), (double) line_h);
                    cr.fill ();
                }
                cr.set_source_rgb ((i == cy) ? 0.20 : 0.55, (i == cy) ? 0.25 : 0.58, (i == cy) ? 0.35 : 0.62);
                string lnum = @"$(i + 1)";
                TextHelper.draw_mono (cr, lnum, x + 8, ly + 2, 12.0);

                string ln = lines[i];
                if (ln.length > 0) {
                    if (is_comment_line (ln))
                        cr.set_source_rgb (0.35, 0.55, 0.35);
                    else if (has_keyword_prefix (ln))
                        cr.set_source_rgb (0.12, 0.34, 0.68);
                    else
                        cr.set_source_rgb (0.14, 0.15, 0.18);
                    TextHelper.draw_mono (cr, ln, x + gutter_w + 8, ly + 2, font_size);
                }
                if (i == cy && focused) {
                    int cw = 0;
                    int ch = 0;
                    if (cx > 0)
                        TextHelper.measure_mono (lines[i].substring (0, cx), font_size, out cw, out ch);
                    cr.set_source_rgb (0.12, 0.38, 0.82);
                    cr.rectangle ((double) (x + gutter_w + 8 + cw), (double) (ly + 2), 2.0, (double) (line_h - 4));
                    cr.fill ();
                }
            }
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1 || !contains (mx, my))
                return false;
            focused = true;
            int row = (my - y) / line_h;
            if (row < 0) row = 0;
            if (row >= lines.length) row = lines.length - 1;
            cy = row;
            int col_px = mx - (x + gutter_w + 8);
            int best_cx = 0;
            if (col_px > 0) {
                int len = lines[cy].length;
                best_cx = col_px / 8;
                if (best_cx > len) best_cx = len;
            }
            cx = best_cx;
            cursor_moved (cy + 1, cx + 1, lines.length);
            return true;
        }

        private void mark_dirty () {
            if (!dirty) {
                dirty = true;
                modified_changed (true);
            }
            cursor_moved (cy + 1, cx + 1, lines.length);
        }

        public override bool on_key_press (int key) {
            if (!focused || !visible || !sensitive)
                return false;
            int mods = Sys.key_mods ();
            bool ctrl = (mods & Sys.MOD_CTRL) != 0;
            if (key == 19 || (ctrl && (key == 's' || key == 'S'))) {
                save_requested ();
                return true;
            }
            if (key == 0x81) {
                if (cy > 0) cy--;
                if (cx > lines[cy].length) cx = lines[cy].length;
                cursor_moved (cy + 1, cx + 1, lines.length);
                return true;
            }
            if (key == 0x82) {
                if (cy + 1 < lines.length) cy++;
                if (cx > lines[cy].length) cx = lines[cy].length;
                cursor_moved (cy + 1, cx + 1, lines.length);
                return true;
            }
            if (key == 0x83) {
                if (cx > 0) cx--;
                else if (cy > 0) { cy--; cx = lines[cy].length; }
                cursor_moved (cy + 1, cx + 1, lines.length);
                return true;
            }
            if (key == 0x84) {
                if (cx < lines[cy].length) cx++;
                else if (cy + 1 < lines.length) { cy++; cx = 0; }
                cursor_moved (cy + 1, cx + 1, lines.length);
                return true;
            }
            if (key == 0x85) { cx = 0; cursor_moved (cy + 1, cx + 1, lines.length); return true; }
            if (key == 0x86) { cx = lines[cy].length; cursor_moved (cy + 1, cx + 1, lines.length); return true; }
            if (key == '\n' || key == '\r') {
                string s = lines[cy];
                int indent = 0;
                while (indent < s.length && s[indent] == ' ') indent++;
                var sp = new StringBuilder ();
                for (int i = 0; i < indent; i++) sp.append (" ");
                lines[cy] = s.substring (0, cx);
                lines.add ("");
                for (int i = lines.length - 1; i > cy + 1; i--)
                    lines[i] = lines[i - 1];
                lines[cy + 1] = sp.str + s.substring (cx);
                cy++;
                cx = indent;
                mark_dirty ();
                return true;
            }
            if (key == 8 || key == 127) {
                if (cx > 0) {
                    string s = lines[cy];
                    lines[cy] = s.substring (0, cx - 1) + s.substring (cx);
                    cx--;
                    mark_dirty ();
                } else if (cy > 0) {
                    string cur = lines[cy];
                    int prev_len = lines[cy - 1].length;
                    lines[cy - 1] = lines[cy - 1] + cur;
                    lines.remove_index (cy);
                    cy--;
                    cx = prev_len;
                    mark_dirty ();
                }
                return true;
            }
            if (key == '\t') {
                string s = lines[cy];
                lines[cy] = s.substring (0, cx) + "    " + s.substring (cx);
                cx += 4;
                mark_dirty ();
                return true;
            }
            if (key >= 32 && key < 127) {
                string ch = ch_str ((uint8) key);
                if (ch.length > 0) {
                    string s = lines[cy];
                    lines[cy] = s.substring (0, cx) + ch + s.substring (cx);
                    cx++;
                    mark_dirty ();
                    return true;
                }
            }
            return false;
        }
    }

    private class SaturnState : Object {
        public CodeView editor;
        public Entry path_entry;
        public ListView files_lv;
        public ListView symbols_lv;
        public ScrolledWindow sc_editor;
        public Label status_lbl;
        public Label msg_lbl;
        public GenericArray<string> file_names = new GenericArray<string> ();
        public GenericArray<int> sym_lines = new GenericArray<int> ();
    }

    private static void refresh_symbols (SaturnState st) {
        var syms = new GenericArray<string> ();
        var icons = new GenericArray<string> ();
        st.sym_lines = new GenericArray<int> ();
        for (int i = 0; i < st.editor.lines.length; i++) {
            string ln = st.editor.lines[i];
            int k = 0;
            while (k < ln.length && ln[k] == ' ') k++;
            string t = ln.substring (k);
            if (t.has_prefix ("public class ") || t.has_prefix ("private class ")
                || t.has_prefix ("class ") || t.has_prefix ("int main")
                || t.has_prefix ("public void ") || t.has_prefix ("private void ")
                || t.has_prefix ("public bool ") || t.has_prefix ("private static ")) {
                int paren = t.index_of ("{");
                string label = (paren > 0) ? t.substring (0, paren) : t;
                syms.add (label);
                icons.add ("text-x-generic");
                st.sym_lines.add (i);
            }
        }
        st.symbols_lv.set_items (syms, icons);
    }

    private static void load_file_list (SaturnState st, string dir_path) {
        var items = new GenericArray<string> ();
        var icons = new GenericArray<string> ();
        st.file_names = new GenericArray<string> ();
        try {
            var dir = File.new_for_path (dir_path);
            var en = dir.enumerate_children ();
            if (en != null) {
                while (true) {
                    var info = en.next_file ();
                    if (info == null) break;
                    string nm = info.get_name ();
                    items.add (nm);
                    st.file_names.add (nm);
                    icons.add ((info.get_file_type () == FileType.DIRECTORY) ? "folder" : "text-x-generic");
                }
            }
        } catch (Error e) {
        }
        st.files_lv.set_items (items, icons);
    }

    int main (string[] args) {
        bool once = false;
        string open_path = "";
        for (int i = 1; i < args.length; i++) {
            if (args[i] == "--once" || args[i] == "--self-test")
                once = true;
            else
                open_path = args[i];
        }

        init (args);
        load_ttf ("LiberationSans-Regular.ttf");
        TextHelper.load_mono_ttf ("LiberationMono-Regular.ttf");

        var win = new GtkWindow (1280, 720);
        win.set_title ("Saturn IDE (Geany-style)");

        var root = new Box (Orientation.VERTICAL, 6);
        var toolbar = new Box (Orientation.HORIZONTAL, 8);
        var btn_new = new Button ("New");
        var btn_save = new Button ("Save");
        var btn_build = new Button ("Compile");
        var path_entry = new Entry ((open_path.length > 0) ? open_path : "hello.txt");
        toolbar.pack_start (btn_new);
        toolbar.pack_start (btn_save);
        toolbar.pack_start (btn_build);
        toolbar.pack_start (path_entry, true, true, 0);

        var hpaned = new Paned (Orientation.HORIZONTAL);
        hpaned.set_position (230);

        var side_nb = new Notebook ();
        var sc_files = new ScrolledWindow ();
        var files_lv = new ListView ();
        sc_files.set_child (files_lv);
        side_nb.append_page (sc_files, "Files");

        var sc_syms = new ScrolledWindow ();
        var symbols_lv = new ListView ();
        sc_syms.set_child (symbols_lv);
        side_nb.append_page (sc_syms, "Symbols");
        hpaned.set_start_child (side_nb);

        var vpaned = new Paned (Orientation.VERTICAL);
        vpaned.set_position (280);

        var ed_nb = new Notebook ();
        var sc_editor = new ScrolledWindow ();
        var editor = new CodeView ();
        sc_editor.set_child (editor);
        ed_nb.append_page (sc_editor, (open_path.length > 0) ? open_path : "Editor");
        vpaned.set_start_child (ed_nb);

        var msg_nb = new Notebook ();
        var msg_lbl = new Label ("Saturn IDE ready. Select a file on the left or edit here.");
        msg_nb.append_page (msg_lbl, "Compiler / Status");
        vpaned.set_end_child (msg_nb);

        hpaned.set_end_child (vpaned);

        var status_lbl = new Label ("Ln 1, Col 1 | 7 lines");

        var st = new SaturnState ();
        st.editor = editor;
        st.path_entry = path_entry;
        st.files_lv = files_lv;
        st.symbols_lv = symbols_lv;
        st.sc_editor = sc_editor;
        st.status_lbl = status_lbl;
        st.msg_lbl = msg_lbl;

        load_file_list (st, "/");
        if (open_path.length > 0)
            editor.load_file (open_path);
        refresh_symbols (st);

        editor.cursor_moved.connect ((sender, ln, col, total) => {
            string mod = editor.dirty ? " [Modified]" : "";
            status_lbl.set_text (@"Ln $ln, Col $col | $total lines | $(editor.filename)$mod");
            sc_editor.ensure_visible ((ln - 1) * editor.line_h, editor.line_h);
        });
        editor.modified_changed.connect ((sender, is_dirty) => {
            string mod = is_dirty ? " [Modified]" : "";
            status_lbl.set_text (@"Ln $(editor.cy + 1), Col $(editor.cx + 1) | $(editor.lines.length) lines | $(editor.filename)$mod");
        });
        editor.save_requested.connect ((sender) => {
            string target = path_entry.get_text ();
            if (target.length == 0) target = editor.filename;
            int w = editor.save_file (target);
            msg_lbl.set_text ((w >= 0) ? @"Saved $w bytes to $target" : @"Error saving $target");
            refresh_symbols (st);
        });

        btn_new.clicked.connect ((sender) => {
            editor.lines = new GenericArray<string> ();
            editor.lines.add ("");
            editor.cx = 0; editor.cy = 0; editor.dirty = false;
            editor.filename = "untitled.vala";
            path_entry.set_text ("untitled.vala");
            sc_editor.scroll_to (0, 0);
            refresh_symbols (st);
            msg_lbl.set_text ("Created new empty buffer.");
        });

        btn_save.clicked.connect ((sender) => {
            editor.save_requested ();
        });

        btn_build.clicked.connect ((sender) => {
            string target = path_entry.get_text ();
            if (target.length == 0) target = editor.filename;
            editor.save_file (target);
            if (target.has_suffix (".vala")) {
                string out_elf = "_saturn_out.elf";
                int rc = Sys.exec ("planc.elf", @"planc.elf --target=planetos $target -o $out_elf");
                msg_lbl.set_text (@"planc $target -> $out_elf (exit=$rc)");
            } else {
                msg_lbl.set_text (@"Saved $target (select a .vala file to compile with planc).");
            }
        });

        path_entry.activate.connect ((sender) => {
            string target = path_entry.get_text ();
            if (target.length > 0 && editor.load_file (target)) {
                sc_editor.scroll_to (0, 0);
                refresh_symbols (st);
                msg_lbl.set_text (@"Opened $target");
            }
        });

        files_lv.activate.connect ((sender, idx) => {
            if (idx >= 0 && idx < st.file_names.length) {
                string nm = st.file_names[idx];
                path_entry.set_text (nm);
                if (editor.load_file (nm)) {
                    sc_editor.scroll_to (0, 0);
                    refresh_symbols (st);
                    msg_lbl.set_text (@"Opened $nm");
                }
            }
        });

        symbols_lv.activate.connect ((sender, idx) => {
            if (idx >= 0 && idx < st.sym_lines.length) {
                editor.goto_line (st.sym_lines[idx]);
                editor.focused = true;
            }
        });

        root.pack_start (toolbar, false, false, 2);
        root.pack_start (hpaned, true, true, 0);
        root.pack_start (status_lbl, false, false, 2);

        win.set_child (root);
        win.run (once);
        print (@"saturn: file=$(editor.filename) lines=$(editor.lines.length) ok\n");
        return 0;
    }
}
