// Pluto: native nano-style terminal text editor for PlanetOS (100% pure Vala).

using GLib;
using Planet;

namespace PlutoEditor {

    private const int SCREEN_ROWS = 25;
    private const int SCREEN_COLS = 80;
    private const int VIEW_ROWS = 21; // 1 header + 21 text + 1 status + 2 help

    private class Pluto : Object {
        public GenericArray<string> lines;
        public string filename = "untitled.txt";
        public int cx = 0;
        public int cy = 0;
        public int row_off = 0;
        public int col_off = 0;
        public bool dirty = false;
        public string status = "New Buffer";
        private string cut_buf = "";

        public Pluto () {
            lines = new GenericArray<string> ();
            lines.add ("");
        }

        private static string ch_str (uint8 c) {
            string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
            if (c < 32 || c >= 127)
                return "";
            return ascii.substring ((int) c - 32, 1);
        }

        public bool open_file (string path) {
            filename = path;
            int fd = Sys.open (path);
            if (fd < 0) {
                lines = new GenericArray<string> ();
                lines.add ("");
                status = @"[ New File: $path ]";
                dirty = false;
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
                    if (nr <= 0)
                        break;
                    for (int i = 0; i < nr; i++) {
                        uint8 b = buf[i];
                        if (b == '\n') {
                            lines.add (sb.str);
                            sb = new StringBuilder ();
                        } else if (b != '\r' && b >= 32 && b < 127) {
                            sb.append (ch_str (b));
                        } else if (b == '\t') {
                            sb.append ("    ");
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
            row_off = 0;
            col_off = 0;
            dirty = false;
            status = @"[ Read $(lines.length) lines ]";
            return true;
        }

        public bool save_file () {
            int fd = Sys.create (filename);
            if (fd < 0) {
                status = @"[ Error writing $filename ]";
                return false;
            }
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
            status = @"[ Wrote $bytes bytes to $filename ]";
            return true;
        }

        private void clamp_cursor () {
            if (cy < 0) cy = 0;
            if (cy >= lines.length) cy = lines.length - 1;
            int ln_len = lines[cy].length;
            if (cx < 0) cx = 0;
            if (cx > ln_len) cx = ln_len;
            if (cy < row_off) row_off = cy;
            if (cy >= row_off + VIEW_ROWS) row_off = cy - VIEW_ROWS + 1;
            if (cx < col_off) col_off = cx;
            if (cx >= col_off + SCREEN_COLS) col_off = cx - SCREEN_COLS + 1;
        }

        public void insert_char (uint8 c) {
            string s = lines[cy];
            string ch = ch_str (c);
            if (ch.length == 0)
                return;
            lines[cy] = s.substring (0, cx) + ch + s.substring (cx);
            cx++;
            dirty = true;
        }

        private static void insert_at (GenericArray<string> arr, int idx, string val) {
            arr.add ("");
            for (int i = arr.length - 1; i > idx; i--)
                arr[i] = arr[i - 1];
            arr[idx] = val;
        }

        public void insert_newline () {
            string s = lines[cy];
            string left = s.substring (0, cx);
            string right = s.substring (cx);
            lines[cy] = left;
            insert_at (lines, cy + 1, right);
            cy++;
            cx = 0;
            dirty = true;
        }

        public void backspace () {
            if (cx > 0) {
                string s = lines[cy];
                lines[cy] = s.substring (0, cx - 1) + s.substring (cx);
                cx--;
                dirty = true;
            } else if (cy > 0) {
                string cur = lines[cy];
                int prev_len = lines[cy - 1].length;
                lines[cy - 1] = lines[cy - 1] + cur;
                lines.remove_index (cy);
                cy--;
                cx = prev_len;
                dirty = true;
            }
        }

        public void cut_line () {
            cut_buf = lines[cy];
            if (lines.length > 1) {
                lines.remove_index (cy);
                if (cy >= lines.length)
                    cy = lines.length - 1;
            } else {
                lines[0] = "";
            }
            cx = 0;
            dirty = true;
            status = "[ Cut line ]";
        }

        public void uncut_line () {
            if (cut_buf.length == 0)
                return;
            insert_at (lines, cy, cut_buf);
            cy++;
            cx = 0;
            dirty = true;
            status = "[ Uncut line ]";
        }

        public void find_next (string query) {
            if (query.length == 0)
                return;
            for (int off = 0; off < lines.length; off++) {
                int r = (cy + off) % lines.length;
                int start = (off == 0) ? (cx + 1) : 0;
                if (start <= lines[r].length) {
                    int idx = lines[r].index_of (query, start);
                    if (idx >= 0) {
                        cy = r;
                        cx = idx;
                        status = @"[ Found '$query' at $(r + 1):$(idx + 1) ]";
                        return;
                    }
                }
            }
            status = @"[ '$query' not found ]";
        }

        private string prompt_input (string label) {
            var sb = new StringBuilder ();
            while (true) {
                print (@"\x1b[23;1H\x1b[7m$label: $(sb.str)\x1b[K\x1b[0m");
                int k = Sys.read_key ();
                while (k < 0) {
                    Sys.yield_cpu ();
                    k = Sys.read_key ();
                }
                if (k == 27 || k == 3) // Esc or Ctrl+C
                    return "";
                if (k == '\n' || k == '\r')
                    return sb.str;
                if ((k == 8 || k == 127) && sb.len > 0) {
                    string cur = sb.str;
                    sb = new StringBuilder ();
                    sb.append (cur.substring (0, cur.length - 1));
                } else if (k >= 32 && k < 127) {
                    sb.append (ch_str ((uint8) k));
                }
            }
        }

        private static string pad_right (string s, int w) {
            if (s.length >= w)
                return s.substring (0, w);
            var sb = new StringBuilder ();
            sb.append (s);
            for (int i = s.length; i < w; i++)
                sb.append (" ");
            return sb.str;
        }

        public void render () {
            clamp_cursor ();
            var out_sb = new StringBuilder ();
            string mod_str = dirty ? " [Modified]" : "";
            string hdr = pad_right (@"  Pluto 1.0          File: $filename$mod_str", SCREEN_COLS);
            out_sb.append (@"\x1b[1;1H\x1b[7m$hdr\x1b[0m");

            for (int r = 0; r < VIEW_ROWS; r++) {
                int li = row_off + r;
                out_sb.append (@"\x1b[$(r + 2);1H");
                if (li < lines.length) {
                    string ln = lines[li];
                    if (col_off < ln.length) {
                        string vis = ln.substring (col_off);
                        if (vis.length > SCREEN_COLS)
                            vis = vis.substring (0, SCREEN_COLS);
                        out_sb.append (vis);
                    }
                } else {
                    out_sb.append ("~");
                }
                out_sb.append ("\x1b[K");
            }

            string st_left = @" $status";
            string st_right = @"Ln $(cy + 1)/$(lines.length), Col $(cx + 1) ";
            int gap = SCREEN_COLS - st_left.length - st_right.length;
            var st_sb = new StringBuilder ();
            st_sb.append (st_left);
            for (int i = 0; i < gap; i++)
                st_sb.append (" ");
            st_sb.append (st_right);
            out_sb.append (@"\x1b[23;1H\x1b[7m$(pad_right (st_sb.str, SCREEN_COLS))\x1b[0m");
            out_sb.append ("\x1b[24;1H^O Write Out   ^W Where Is    ^K Cut Line    ^U Uncut Line\x1b[K");
            out_sb.append ("\x1b[25;1H^X Exit        ^G Help        Arrows Move   Home/End Line\x1b[K");

            int scr_r = (cy - row_off) + 2;
            int scr_c = (cx - col_off) + 1;
            out_sb.append (@"\x1b[$scr_r;$(scr_c)H");
            print (out_sb.str);
        }

        public void run () {
            print ("\x1b[2J\x1b[H");
            render ();
            while (true) {
                int k = Sys.read_key ();
                if (k < 0) {
                    Sys.yield_cpu ();
                    continue;
                }
                int mods = Sys.key_mods ();
                bool ctrl = (mods & Sys.MOD_CTRL) != 0;

                if (k == 24 || (ctrl && (k == 'x' || k == 'X'))) { // Ctrl+X
                    if (dirty) {
                        string ans = prompt_input ("Save modified buffer? (y/n)");
                        if (ans == "y" || ans == "Y")
                            save_file ();
                    }
                    break;
                }
                if (k == 15 || (ctrl && (k == 'o' || k == 'O'))) { // Ctrl+O
                    string target = prompt_input (@"File Name to Write [$filename]");
                    if (target.length > 0)
                        filename = target;
                    save_file ();
                    render ();
                    continue;
                }
                if (k == 11 || (ctrl && (k == 'k' || k == 'K'))) { // Ctrl+K
                    cut_line ();
                    render ();
                    continue;
                }
                if (k == 21 || (ctrl && (k == 'u' || k == 'U'))) { // Ctrl+U
                    uncut_line ();
                    render ();
                    continue;
                }
                if (k == 23 || (ctrl && (k == 'w' || k == 'W'))) { // Ctrl+W
                    string q = prompt_input ("Search");
                    if (q.length > 0)
                        find_next (q);
                    render ();
                    continue;
                }
                if (k == 7 || (ctrl && (k == 'g' || k == 'G'))) { // Ctrl+G
                    status = "^O Save  ^X Exit  ^K Cut  ^U Uncut  ^W Find  Esc Quit";
                    render ();
                    continue;
                }
                if (k == 27 && !dirty) {
                    break;
                }

                if (k == 0x81) { cy--; }
                else if (k == 0x82) { cy++; }
                else if (k == 0x83) {
                    if (cx > 0) cx--;
                    else if (cy > 0) { cy--; cx = lines[cy].length; }
                } else if (k == 0x84) {
                    if (cx < lines[cy].length) cx++;
                    else if (cy + 1 < lines.length) { cy++; cx = 0; }
                } else if (k == 0x85) { cx = 0; }
                else if (k == 0x86) { cx = lines[cy].length; }
                else if (k == '\n' || k == '\r') { insert_newline (); }
                else if (k == 8 || k == 127) { backspace (); }
                else if (k == '\t') {
                    for (int t = 0; t < 4; t++)
                        insert_char (' ');
                } else if (k >= 32 && k < 127) {
                    insert_char ((uint8) k);
                }
                render ();
            }
            print ("\x1b[2J\x1b[H");
        }
    }

    int main (string[] args) {
        bool once = false;
        string path = "";
        for (int i = 1; i < args.length; i++) {
            if (args[i] == "--once" || args[i] == "--self-test")
                once = true;
            else
                path = args[i];
        }
        var ed = new Pluto ();
        if (path.length > 0)
            ed.open_file (path);
        if (once) {
            ed.insert_char ('P');
            ed.insert_char ('l');
            ed.insert_char ('u');
            ed.insert_char ('t');
            ed.insert_char ('o');
            print (@"pluto: lines=$(ed.lines.length) ok\n");
            return 0;
        }
        ed.run ();
        return 0;
    }
}
