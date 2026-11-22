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
        public int32 cx = 0;
        public int32 cy = 0;
        public bool dirty = false;
        public string filename = "untitled.vala";
        public string cut_buf = "";
        public bool has_cut = false;
        public int16 line_h = 18;
        public int16 gutter_w = 46;
        public float font_size = 13.0f;

        // Line range touched since the last repaint, plus the caret/bookkeeping
        // the window needs to turn an edit into one damage rectangle instead of
        // a full-window repaint.
        private int dmg_line0 = -1;
        private int dmg_line1 = -1;
        private int dmg_caret = -1;
        private int dmg_count = -1;
        // Bumped on every content change; the measure cache watches it.
        private int content_seq = 0;
        private int cache_seq = -1;
        private int cache_max_len = 40;

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
            grab_focus ();
            dmg_count = lines.length;
        }

        private static string sanitize_line (string s) {
            string clean = Str.replace (s, "\r", "");
            return Str.replace (clean, "\t", "    ");
        }

        public bool load_file (string path) {
            filename = path;
            string raw = "";
            bool ok = FileUtils.get_contents (path, out raw);
            lines = new GenericArray<string> ();
            if (!ok) {
                lines.add ("");
                cx = 0; cy = 0; dirty = false;
                dmg_line0 = -1;
                dmg_line1 = -1;
                dmg_caret = 0;
                dmg_count = lines.length;
                modified_changed (false);
                cursor_moved (1, 1, 1);
                damage_all ();
                return false;
            }
            if (raw.length > 0) {
                GenericArray<string> parts = Str.split (raw, "\n");
                for (int i = 0; i < parts.length; i++)
                    lines.add (sanitize_line (parts[i]));
            }
            if (lines.length == 0)
                lines.add ("");
            cx = 0;
            cy = 0;
            dirty = false;
            dmg_line0 = -1;
            dmg_line1 = -1;
            dmg_caret = 0;
            dmg_count = lines.length;
            modified_changed (false);
            cursor_moved (1, 1, lines.length);
            damage_all ();
            return true;
        }

        public int save_file (string path) {
            filename = path;
            string payload = Str.joinv ("\n", lines);
            if (!FileUtils.set_contents (path, payload))
                return -1;
            dirty = false;
            modified_changed (false);
            return payload.length;
        }

        public void goto_line (int line_idx) {
            if (line_idx < 0) line_idx = 0;
            if (line_idx >= lines.length) line_idx = lines.length - 1;
            cy = line_idx;
            if (cx > lines[cy].length) cx = lines[cy].length;
            notify_cursor ();
        }

        public override void measure (out int min_w, out int min_h) {
            // The scroll view re-measures on every repaint, so the width scan is
            // cached and only redone when the buffer actually changed.
            if (cache_seq != content_seq) {
                int max_len = 40;
                for (int i = 0; i < lines.length; i++) {
                    if (lines[i].length > max_len)
                        max_len = lines[i].length;
                }
                cache_max_len = max_len;
                cache_seq = content_seq;
            }
            min_w = gutter_w + (cache_max_len + 4) * 8;
            min_h = (lines.length + 2) * line_h;
            if (min_w < 360) min_w = 360;
            if (min_h < 200) min_h = 200;
        }

        private static bool is_comment_line (string s) {
            int i = 0;
            while (i < s.length && s[i] == ' ') i++;
            return (i + 1 < s.length && s[i] == '/' && s[i + 1] == '/');
        }

        // Prefix compare at an offset: no substring, so classifying a line for
        // colouring allocates nothing.
        private static bool at_prefix (string s, int start, string p) {
            if (start < 0 || start + p.length > s.length)
                return false;
            for (int k = 0; k < p.length; k++) {
                if (s[start + k] != p[k])
                    return false;
            }
            return true;
        }

        private static bool has_keyword_prefix (string s) {
            int i = 0;
            while (i < s.length && s[i] == ' ') i++;
            return at_prefix (s, i, "using ") || at_prefix (s, i, "namespace ")
                || at_prefix (s, i, "public ") || at_prefix (s, i, "private ")
                || at_prefix (s, i, "class ") || at_prefix (s, i, "struct ")
                || at_prefix (s, i, "enum ") || at_prefix (s, i, "errordomain ")
                || at_prefix (s, i, "return ") || at_prefix (s, i, "if ")
                || at_prefix (s, i, "else ") || at_prefix (s, i, "else{")
                || (i + 4 == s.length && at_prefix (s, i, "else"))
                || at_prefix (s, i, "while ")
                || at_prefix (s, i, "for ") || at_prefix (s, i, "var ")
                || at_prefix (s, i, "int ") || at_prefix (s, i, "bool ")
                || at_prefix (s, i, "string ") || at_prefix (s, i, "double ")
                || at_prefix (s, i, "void ") || at_prefix (s, i, "try ")
                || at_prefix (s, i, "try{") || at_prefix (s, i, "catch ")
                || at_prefix (s, i, "catch(") || at_prefix (s, i, "throw ");
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
                    // Mono advance instead of measuring the prefix: the caret is
                    // painted on every repaint and a prefix measure walks the
                    // whole glyph run again.
                    int cw = (cx > 0) ? TextHelper.mono_advance (font_size) * cx : 0;
                    cr.set_source_rgb (0.12, 0.38, 0.82);
                    cr.rectangle ((double) (x + gutter_w + 8 + cw), (double) (ly + 2), 2.0, (double) (line_h - 4));
                    cr.fill ();
                }
            }
        }

        public override bool on_pointer_press (int mx, int my, int button) {
            if (!visible || !sensitive || button != 1 || !contains (mx, my))
                return false;
            grab_focus ();
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
            notify_cursor ();
            return true;
        }

        private void mark_dirty () {
            if (!dirty) {
                dirty = true;
                modified_changed (true);
            }
            content_seq = content_seq + 1;
            notify_cursor ();
        }

        private void damage_line (int ln) {
            if (ln < 0 || ln >= lines.length)
                return;
            if (dmg_line0 < 0 || ln < dmg_line0) dmg_line0 = ln;
            if (dmg_line1 < 0 || ln > dmg_line1) dmg_line1 = ln;
        }

        // Inserting or deleting a line renumbers everything below the caret, so
        // the damage has to reach the bottom of the viewport and not just the
        // edited row (which may well be the last line in the buffer).
        private void damage_from_line (int ln) {
            if (ln < 0) ln = 0;
            if (ln >= lines.length) ln = lines.length - 1;
            if (dmg_line0 < 0 || ln < dmg_line0) dmg_line0 = ln;
            int rows = (height + line_h - 1) / line_h;
            int last = ln + rows;
            if (dmg_line1 < 0 || last > dmg_line1) dmg_line1 = last;
        }

        private void notify_cursor () {
            if (dmg_caret >= 0 && dmg_caret != cy)
                damage_line (dmg_caret);
            if (dmg_count >= 0 && dmg_count != lines.length)
                damage_from_line (cy);
            dmg_caret = cy;
            dmg_count = lines.length;
            damage_line (cy);
            cursor_moved (cy + 1, cx + 1, lines.length);
        }

        // Whole-editor repaint: used when the buffer is replaced rather than edited.
        public void damage_all () {
            content_seq = content_seq + 1;
            damage_self ();
        }

        // The line range is this widget's damage; hand it to the shared
        // accumulator so the window can publish it with the rest of the tree.
        // The editor has no hover state, so entering it must not repaint the
        // whole viewport (the base widget damages itself on a hover change).
        public override bool on_pointer_motion (int mx, int my) {
            return false;
        }

        public override void gather_damage () {
            if (dmg_line0 >= 0) {
                int y0 = y + dmg_line0 * line_h;
                int y1 = y + (dmg_line1 + 1) * line_h;
                if (y0 < y) y0 = y;
                if (y1 > y + height) y1 = y + height;
                if (y1 > y0)
                    damage_box (x, y0, width, y1 - y0);
                dmg_line0 = -1;
                dmg_line1 = -1;
            }
        }

        public override bool take_damage (out int dx, out int dy, out int dw, out int dh) {
            gather_damage ();
            return base.take_damage (out dx, out dy, out dw, out dh);
        }

        private void insert_line_at (int idx, string text) {
            if (idx < 0) idx = 0;
            if (idx > lines.length) idx = lines.length;
            lines.add ("");
            for (int i = lines.length - 1; i > idx; i--)
                lines[i] = lines[i - 1];
            lines[idx] = text;
        }

        public bool find_next (string query) {
            if (query.length == 0 || lines.length == 0)
                return false;
            int start = cx + 1;
            if (start < lines[cy].length) {
                int hit = lines[cy].substring (start).index_of (query);
                if (hit >= 0) {
                    cx = start + hit;
                    notify_cursor ();
                    return true;
                }
            }
            for (int off = 1; off <= lines.length; off++) {
                int r = (cy + off) % lines.length;
                int hit = lines[r].index_of (query);
                if (hit >= 0) {
                    cy = r;
                    cx = hit;
                    notify_cursor ();
                    return true;
                }
            }
            return false;
        }

        private int page_lines () {
            return 20;
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
            if (key == 11 || (ctrl && (key == 'k' || key == 'K'))) {
                cut_buf = lines[cy];
                has_cut = true;
                if (lines.length > 1) {
                    lines.remove_index (cy);
                    if (cy >= lines.length) cy = lines.length - 1;
                } else {
                    lines[0] = "";
                }
                if (cx > lines[cy].length) cx = lines[cy].length;
                mark_dirty ();
                return true;
            }
            if (key == 21 || (ctrl && (key == 'u' || key == 'U'))) {
                if (has_cut) {
                    insert_line_at (cy + 1, cut_buf);
                    cy++;
                    cx = 0;
                    mark_dirty ();
                }
                return true;
            }
            if (key == 4 || (ctrl && (key == 'd' || key == 'D'))) {
                insert_line_at (cy + 1, lines[cy]);
                cy++;
                if (cx > lines[cy].length) cx = lines[cy].length;
                mark_dirty ();
                return true;
            }
            if (key == 0x81) {
                if (cy > 0) cy--;
                if (cx > lines[cy].length) cx = lines[cy].length;
                notify_cursor ();
                return true;
            }
            if (key == 0x82) {
                if (cy + 1 < lines.length) cy++;
                if (cx > lines[cy].length) cx = lines[cy].length;
                notify_cursor ();
                return true;
            }
            if (key == 0x83) {
                if (cx > 0) cx--;
                else if (cy > 0) { cy--; cx = lines[cy].length; }
                notify_cursor ();
                return true;
            }
            if (key == 0x84) {
                if (cx < lines[cy].length) cx++;
                else if (cy + 1 < lines.length) { cy++; cx = 0; }
                notify_cursor ();
                return true;
            }
            if (key == 0x85) { cx = 0; notify_cursor (); return true; }
            if (key == 0x86) { cx = lines[cy].length; notify_cursor (); return true; }
            if (key == 0x87 || key == 0xFF55) {
                cy -= page_lines ();
                if (cy < 0) cy = 0;
                if (cx > lines[cy].length) cx = lines[cy].length;
                notify_cursor ();
                return true;
            }
            if (key == 0x88 || key == 0xFF56) {
                cy += page_lines ();
                if (cy >= lines.length) cy = lines.length - 1;
                if (cx > lines[cy].length) cx = lines[cy].length;
                notify_cursor ();
                return true;
            }
            if (key == '\n' || key == '\r') {
                string s = lines[cy];
                int indent = 0;
                while (indent < s.length && s[indent] == ' ') indent++;
                var sp = new StringBuilder ();
                for (int i = 0; i < indent; i++) sp.append (" ");
                lines[cy] = s.substring (0, cx);
                insert_line_at (cy + 1, sp.str + s.substring (cx));
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
            if (!ctrl && key >= 32 && key < 127) {
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

    /**
     * Headless checks for the interactive path: an edit must damage one line,
     * an inserted line must damage down to the viewport bottom, and a window
     * attached to a shared block must publish exactly the rectangle it painted.
     */
    private static int saturn_self_test () {
        int checks = 0;
        int fails = 0;
        int dx = 0;
        int dy = 0;
        int dw = 0;
        int dh = 0;

        var surf = new ImageSurface (Format.ARGB32, 420, 320);
        var cr = new Context (surf);
        // Verify blit_alpha_mask SIMD + tail pixel-exact blending.
        cr.set_source_rgb (0.0, 0.0, 0.0);
        cr.rectangle (0, 0, 16, 4);
        cr.fill ();
        cr.set_source_rgba (1.0, 0.5, 0.25, 1.0);
        uint8[] mask = { 0, 128, 255, 64, 192, 0 };
        cr.blit_alpha_mask (mask, 6, 1, 2, 1);
        checks++;
        int row1 = surf.buf_addr + 1 * surf.width * 4;
        int p0 = Sys.peek32 (row1 + 2 * 4) & 0xFFFFFF;
        int p1 = Sys.peek32 (row1 + 3 * 4) & 0xFFFFFF;
        int p2 = Sys.peek32 (row1 + 4 * 4) & 0xFFFFFF;
        int p3 = Sys.peek32 (row1 + 5 * 4) & 0xFFFFFF;
        int p4 = Sys.peek32 (row1 + 6 * 4) & 0xFFFFFF;
        int p5 = Sys.peek32 (row1 + 7 * 4) & 0xFFFFFF;
        if (p0 != 0x000000 || p2 != 0xFF7F3F || p5 != 0x000000
                || p1 == 0 || p1 == 0xFF7F3F || p3 == 0 || p4 == 0)
            fails++;
        // Check green channel of p1 (a=128 over 0, sg=128 -> ~64, must not be ~255).
        int p1_g = (p1 >> 8) & 0xFF;
        checks++;
        if (p1_g < 60 || p1_g > 68)
            fails++;

        var ed = new CodeView ();
        ed.allocate (0, 0, 420, 320);
        ed.draw (cr);

        ed.on_key_press ('a');
        checks++;
        if (!ed.take_damage (out dx, out dy, out dw, out dh) || dh != ed.line_h || dy != 0)
            fails++;

        ed.on_key_press ('\n');
        checks++;
        if (!ed.take_damage (out dx, out dy, out dw, out dh) || dh <= ed.line_h)
            fails++;

        ed.on_key_press (0x81);
        checks++;
        if (!ed.take_damage (out dx, out dy, out dw, out dh) || dh != 2 * ed.line_h)
            fails++;

        // Keys must reach the focused editor, not the first scrollable sibling
        // that reacts to arrows: the side panel used to scroll instead of the
        // caret moving between lines.
        var items = new GenericArray<string> ();
        for (int i = 0; i < 30; i++)
            items.add (@"row $i");
        var side_lv = new ListView ();
        side_lv.set_items (items);
        var side_sc = new ScrolledWindow ();
        side_sc.set_child (side_lv);
        var ed_sc = new ScrolledWindow ();
        var ed2 = new CodeView ();
        ed_sc.set_child (ed2);
        var hbox = new Box (Orientation.HORIZONTAL, 0);
        hbox.pack_start (side_sc, true, true);
        hbox.pack_start (ed_sc, true, true);
        hbox.allocate (0, 0, 500, 300);
        int side_before = side_sc.scroll_y;
        int line_before = ed2.cy;
        checks++;
        if (!hbox.handle_key (0x82))
            fails++;
        checks++;
        if (ed2.cy != line_before + 1 || side_sc.scroll_y != side_before)
            fails++;
        checks++;
        if (!hbox.handle_key (0x81) || ed2.cy != line_before)
            fails++;

        // Focus is exclusive: the list takes the arrows while it owns focus and
        // the editor takes them back when it is focused again.
        side_lv.grab_focus ();
        int ed_line = ed2.cy;
        hbox.handle_key (0x82);
        checks++;
        if (side_lv.get_selected () < 0 || ed2.cy != ed_line)
            fails++;
        ed2.grab_focus ();
        int lv_sel = side_lv.get_selected ();
        int ed_before2 = ed2.cy;
        hbox.handle_key (0x82);
        checks++;
        if (ed2.cy != ed_before2 + 1 || side_lv.get_selected () != lv_sel)
            fails++;
        checks++;
        if (!ed2.has_focus () || side_lv.has_focus ())
            fails++;

        // PageUp / PageDown move the focused editor's caret by a page without
        // falling through to the side panel's ScrolledWindow.
        for (int i = 0; i < 40; i++)
            ed2.lines.add (@"line $i");
        hbox.allocate (0, 0, 500, 300);
        int side_pg = side_sc.scroll_y;
        int cy0 = ed2.cy;
        checks++;
        if (!hbox.handle_key (0x88) || ed2.cy <= cy0 || side_sc.scroll_y != side_pg)
            fails++;
        int cy1 = ed2.cy;
        checks++;
        if (!hbox.handle_key (0x87) || ed2.cy >= cy1 || side_sc.scroll_y != side_pg)
            fails++;
        checks++;
        if (!hbox.handle_key (0xFF56) || ed2.cy <= cy0)
            fails++;
        checks++;
        if (!hbox.handle_key (0xFF55) || ed2.cy != cy0)
            fails++;

        // Client publish path: a block laid out exactly as the compositor does.
        int w = 200;
        int h = 150;
        int pages = SharedSurface.pages_for (w, h);
        int shm = Sys.alloc_pages (pages);
        if (shm > 0) {
            Sys.poke32 (shm + SharedSurface.OFF_MAGIC, SharedSurface.MAGIC);
            Sys.poke32 (shm + SharedSurface.OFF_WIDTH, w);
            Sys.poke32 (shm + SharedSurface.OFF_HEIGHT, h);
            Sys.poke32 (shm + SharedSurface.OFF_SEQ, 0);
            Sys.setenv ("PLANET_WIN_SHM", @"$shm");
            Sys.setenv ("PLANET_WIN_W", @"$w");
            Sys.setenv ("PLANET_WIN_H", @"$h");

            var win = new GtkWindow (w, h);
            win.set_child (ed);
            win.show_all ();
            checks++;
            if (Sys.peek32 (shm + SharedSurface.OFF_SEQ) != 1
                    || Sys.peek32 (shm + SharedSurface.OFF_DW) != w
                    || Sys.peek32 (shm + SharedSurface.OFF_DH) != h)
                fails++;

            win.redraw_area (5, 7, 11, 13);
            checks++;
            if (Sys.peek32 (shm + SharedSurface.OFF_SEQ) != 2
                    || Sys.peek32 (shm + SharedSurface.OFF_DX) != 5
                    || Sys.peek32 (shm + SharedSurface.OFF_DY) != 7
                    || Sys.peek32 (shm + SharedSurface.OFF_DW) != 11
                    || Sys.peek32 (shm + SharedSurface.OFF_DH) != 13)
                fails++;

            checks++;
            int px = Sys.peek32 (shm + SharedSurface.pixel_offset () + (2 * w + 2) * 4);
            if (((px >> 24) & 0xFF) != 255)
                fails++;

            Sys.unsetenv ("PLANET_WIN_SHM");
            for (int p = 0; p < pages; p++)
                Sys.free_page (shm + p * 4096);
        } else {
            checks++;
            fails++;
        }

        print (@"saturn:summary checks=$checks failures=$fails\n");
        return (fails == 0) ? 0 : 1;
    }

    private static void run_find (SaturnState st, Entry find_entry) {        string q = find_entry.get_text ();
        if (q.length == 0) {
            st.msg_lbl.set_text ("Enter text to find.");
            return;
        }
        if (st.editor.find_next (q)) {
            st.editor.grab_focus ();
            st.msg_lbl.set_text (@"Found '$q' at Ln $(st.editor.cy + 1), Col $(st.editor.cx + 1)");
        } else {
            st.msg_lbl.set_text (@"Not found: '$q'");
        }
    }

    int main (string[] args) {
        bool once = false;
        bool self_test = false;
        string open_path = "";
        for (int i = 1; i < args.length; i++) {
            if (args[i] == "--self-test")
                self_test = true;
            else if (args[i] == "--once")
                once = true;
            else
                open_path = args[i];
        }

        init (args);
        load_ttf ("LiberationSans-Regular.ttf");
        TextHelper.load_mono_ttf ("LiberationMono-Regular.ttf");
        if (self_test)
            return saturn_self_test ();

        var win = new GtkWindow (1280, 720);
        win.set_title ("Saturn IDE (Geany-style)");

        var root = new Box (Orientation.VERTICAL, 6);
        var toolbar = new Box (Orientation.HORIZONTAL, 8);
        var btn_new = new Button ("New");
        var btn_save = new Button ("Save");
        var btn_build = new Button ("Compile");
        var path_entry = new Entry ((open_path.length > 0) ? open_path : "hello.txt");
        var find_entry = new Entry ("");
        find_entry.set_placeholder_text ("Find...");
        var btn_find = new Button ("Find");
        toolbar.pack_start (btn_new);
        toolbar.pack_start (btn_save);
        toolbar.pack_start (btn_build);
        toolbar.pack_start (path_entry, true, true, 0);
        toolbar.pack_start (find_entry);
        toolbar.pack_start (btn_find);

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
            editor.damage_all ();
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
                try {
                    string so = "";
                    string se = "";
                    int ws = 0;
                    string[] argv = { "planc.elf", "--target=planetos", target, "-o", out_elf };
                    Process.spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null, out so, out se, out ws);
                    int rc = Process.if_exited (ws) ? Process.exit_status (ws) : -1;
                    msg_lbl.set_text (@"planc $target -> $out_elf (exit=$rc)");
                } catch (SpawnError e) {
                    msg_lbl.set_text (@"planc $target failed: $(e.message)");
                }
            } else {
                msg_lbl.set_text (@"Saved $target (select a .vala file to compile with planc).");
            }
        });

        btn_find.clicked.connect ((sender) => {
            run_find (st, find_entry);
        });

        find_entry.activate.connect ((sender) => {
            run_find (st, find_entry);
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
                editor.grab_focus ();
            }
        });

        root.pack_start (toolbar, false, true, 2);
        root.pack_start (hpaned, true, true, 0);
        root.pack_start (status_lbl, false, true, 2);

        win.set_child (root);
        if (!once)
            print (@"saturn: opened $(editor.filename) (Esc=quit, Ctrl+S=save)\n");
        win.run (once);
        print (@"saturn: file=$(editor.filename) lines=$(editor.lines.length) ok\n");
        return 0;
    }
}
