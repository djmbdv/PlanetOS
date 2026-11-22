// PlanetOS compositor -- an Openbox-style window manager with Gala-inspired
// visuals, written in 100% Vala.
//
// There is no Mutter, no X11 and no Wayland here. Window management is a pure
// Vala model (Win/Compositor) and the screen is painted through Gdk + Cairo
// into the framebuffer. The fragment stage is fed by the SPIR-V module
// (frag.spv) through Module: the same IR a Vulkan backend will upload once
// an ICD exists (docs/planc/slice-38.md, decision D-13).
//
// Usage:
//   compositor.elf                 interactive session (framebuffer)
//   compositor.elf --self-test     headless model + render smoke test
//   compositor.elf --no-shader     ignore frag.spv, use the built-in accent
//   compositor.elf --shader FILE   load another SPIR-V fragment module

using GLib;
using Planet;
using Pango;
using PangoCairo;
using Spv;
using Cairo;
using Gdk;
using Gtk;
using Gsk;
using Wm;

namespace Wm {
    public const int SCREEN_W = 1280;
    public const int SCREEN_H = 720;
    public const int TOP_H = 26;
    public const int DOCK_H = 34;
    public const int TITLE_H = 26;
    public const int BORDER = 1;
    public const int SHADOW = 2;
    public const int BTN = 16;
    public const int BTN_GAP = 4;
    public const int DOCK_X0 = 10;
    public const int DOCK_BTN_W = 132;
    public const int DOCK_BTN_GAP = 6;
    public const int MOVE_STEP = 8;
    public const int WORK_H = 540; // SCREEN_H - TOP_H - DOCK_H

    public const int ACT_NONE = 0;
    public const int ACT_FOCUS = 1;
    public const int ACT_DRAG = 2;
    public const int ACT_CLOSE = 3;
    public const int ACT_MAXIMIZE = 4;
    public const int ACT_DOCK = 5;

    public const int BACKEND_CAIRO = 0;
    public const int BACKEND_VULKAN = 1;

    public const int LAYOUT_NORMAL = 0;
    public const int LAYOUT_MAX = 1;
    public const int LAYOUT_LEFT = 2;
    public const int LAYOUT_RIGHT = 3;

    public const int DMG_RECTS = 32;
    public const int PAT_STEP = 8;

    public enum Kind { TERMINAL, CLOCK, SHADER, NOTES, GTK, FILES, EXT }

    public static string resolve_gui_binary (string nm) {
        if (nm == "gtk_demo" || nm == "gtk_demo.elf") return "gtk_demo.elf";
        if (nm == "pcm4" || nm == "pcm4.elf") return "pcm4.elf";
        if (nm == "cairo_demo" || nm == "cairo_demo.elf") return "cairo_demo.elf";
        if (nm == "spv_demo" || nm == "spv_demo.elf") return "spv_demo.elf";
        if (nm == "vk_demo" || nm == "vk_demo.elf") return "vk_demo.elf";
        if (nm == "pango_demo" || nm == "pango_demo.elf") return "pango_demo.elf";
        if (nm == "compositor" || nm == "compositor.elf") return "compositor.elf";
        if (nm == "saturn" || nm == "saturn.elf") return "saturn.elf";
        return "";
    }

    public class GtkCompState : Object {
        public int clicks = 0;
    }

    public class VteTerminal : Object {
        public GenericArray<string> lines;
        public GenericArray<string> history;
        public int hist_idx = -1;
        public string draft_input = "";
        public string input = "";
        public string cwd = "/";
        public bool active = false;
        public bool want_pcm4 = false;
        public string want_gui_exec = "";
        public string want_gui_title = "";
        public int scroll_off = 0;
        public int child_tid = -1;
        public int child_out_fd = -1;
        public string out_file = "";
        public int out_read_pos = 0;
        private string partial_line = "";
        private int vte_seq = 0;

        public VteTerminal () {
            lines = new GenericArray<string> ();
            history = new GenericArray<string> ();
            lines.add ("PlanetOS VTE v0.2 (shell.elf integrated, type 'help')");
        }

        public bool busy () {
            return child_tid > 0;
        }

        public bool on_scroll (int dy) {
            if (dy == 0 || lines.length <= 0)
                return false;
            int prev = scroll_off;
            scroll_off = scroll_off - dy * 2;
            if (scroll_off < 0)
                scroll_off = 0;
            int max_off = (lines.length > 4) ? (lines.length - 4) : 0;
            if (scroll_off > max_off)
                scroll_off = max_off;
            return scroll_off != prev;
        }

        private void push_line (string s) {
            // Wrap long lines cleanly at 64 chars so output stays inside VTE bounds.
            if (s.length <= 64) {
                lines.add (s);
            } else {
                int pos = 0;
                while (pos < s.length) {
                    int take = s.length - pos;
                    if (take > 64) take = 64;
                    lines.add (s.substring (pos, take));
                    pos = pos + take;
                }
            }
            while (lines.length > 256)
                lines.remove_index (0);
            scroll_off = 0;
        }

        private static string bytes_to_str (uint8[] buf, int off, int len) {
            var sb = new StringBuilder ("");
            for (int i = 0; i < len; i++) {
                uint8 c = buf[off + i];
                if (c >= 32 && c < 127)
                    sb.append_c ((char) c);
            }
            return sb.str;
        }

        private static string trim_str (string s) {
            int a = 0;
            int b = s.length;
            while (a < b && s[a] == ' ') a++;
            while (b > a && s[b - 1] == ' ') b--;
            return s.substring (a, b - a);
        }

        private string resolve_path (string p) {
            if (p.length == 0 || p == ".")
                return cwd;
            if (p == "..") {
                if (cwd == "/") return "/";
                int last = -1;
                for (int i = cwd.length - 1; i >= 0; i--) {
                    if (cwd[i] == '/') { last = i; break; }
                }
                return (last <= 0) ? "/" : cwd.substring (0, last);
            }
            if (p.has_prefix ("/"))
                return p;
            return (cwd == "/") ? ("/" + p) : (cwd + "/" + p);
        }

        private void feed_output_bytes (uint8[] buf, int count) {
            for (int i = 0; i < count; i++) {
                uint8 c = buf[i];
                if (c == '\n') {
                    push_line (partial_line);
                    partial_line = "";
                } else if (c == '\r') {
                    partial_line = "";
                } else if (c >= 32 && c < 127) {
                    string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                    partial_line = partial_line + ascii.substring ((int) c - 32, 1);
                    if (partial_line.length >= 64) {
                        push_line (partial_line);
                        partial_line = "";
                    }
                }
            }
        }

        private void drain_out_file () {
            if (out_file.length == 0)
                return;
            int fd = Sys.open (out_file);
            if (fd < 0)
                return;
            int sz = Sys.file_size (fd);
            if (sz > out_read_pos) {
                Sys.seek (fd, out_read_pos);
                var buf = new uint8[1024];
                while (out_read_pos < sz) {
                    int nr = Sys.read (fd, buf, 1024);
                    if (nr <= 0)
                        break;
                    feed_output_bytes (buf, nr);
                    out_read_pos = out_read_pos + nr;
                }
            }
            Sys.close (fd);
        }

        public void cancel_proc () {
            if (child_tid > 0) {
                Sys.kill (child_tid);
                child_tid = -1;
            }
            if (child_out_fd >= 0) {
                Sys.close (child_out_fd);
                child_out_fd = -1;
            }
            if (out_file.length > 0) {
                Sys.unlink (out_file);
                out_file = "";
            }
            out_read_pos = 0;
        }

        public bool poll_proc () {
            if (child_tid <= 0)
                return false;
            int prev_len = lines.length;
            int prev_part = partial_line.length;
            drain_out_file ();
            int rc = Sys.wait_nb (child_tid);
            if (rc != -2) {
                if (child_out_fd >= 0) {
                    Sys.close (child_out_fd);
                    child_out_fd = -1;
                }
                drain_out_file ();
                if (partial_line.length > 0) {
                    push_line (partial_line);
                    partial_line = "";
                }
                if (rc != 0)
                    push_line (@"[exit=$rc]");
                child_tid = -1;
                if (out_file.length > 0) {
                    Sys.unlink (out_file);
                    out_file = "";
                }
                out_read_pos = 0;
                return true;
            }
            return (lines.length != prev_len || partial_line.length != prev_part);
        }

        private void spawn_shell_cmd (string cmd) {
            vte_seq = vte_seq + 1;
            Sys.mkdir ("/tmp");
            out_file = @"/tmp/_vte_$(vte_seq).txt";
            out_read_pos = 0;
            partial_line = "";
            int out_fd = Sys.create (out_file);
            if (out_fd < 0) {
                push_line ("vte: cannot allocate output buffer");
                out_file = "";
                return;
            }
            Sys.setenv ("PLANET_CWD", cwd);
            Sys.sys (19, 0, out_fd, 0);
            child_tid = Sys.spawn ("vte_sh.elf", @"vte_sh.elf -c $cmd");
            Sys.sys (19, 0, 1, 0);
            if (child_tid < 0) {
                Sys.close (out_fd);
                Sys.unlink (out_file);
                out_file = "";
                push_line (@"vte: failed to spawn shell for '$cmd'");
            } else {
                child_out_fd = out_fd;
            }
        }


        private void run_cmd (string raw) {
            string cmd = trim_str (raw);
            push_line (@"planet:$cwd> $cmd");
            if (cmd == "")
                return;
            if (history.length == 0 || history[history.length - 1] != cmd) {
                history.add (cmd);
                if (history.length > 32)
                    history.remove_index (0);
            }
            hist_idx = -1;
            draft_input = "";

            if (cmd == "clear") {
                lines.length = 0;
                scroll_off = 0;
                return;
            }
            if (cmd == "help") {
                push_line ("vte: builtins: help clear cd pwd history pcm4");
                push_line ("vte: shell.elf -c runs ls cat echo wc exec .elf/.plan pipes");
                return;
            }
            if (cmd == "history") {
                for (int i = 0; i < history.length; i++)
                    push_line (@"  $(i + 1): $(history[i])");
                return;
            }
            if (cmd == "pcm4" || cmd == "files") {
                want_pcm4 = true;
                push_line ("opening pcm4 window...");
                return;
            }
            if (cmd == "pwd") {
                push_line (cwd);
                return;
            }
            if (cmd == "cd" || cmd.has_prefix ("cd ")) {
                string arg = (cmd.length > 3) ? trim_str (cmd.substring (3, cmd.length - 3)) : "/";
                string target = resolve_path (arg);
                if (target == "/") {
                    cwd = "/";
                } else {
                    string rel = target.has_prefix ("/") ? target.substring (1, target.length - 1) : target;
                    if (Sys.stat (rel) == 2)
                        cwd = target;
                    else
                        push_line (@"cd: not a directory: $arg");
                }
                return;
            }
            if (cmd.has_prefix ("exec ")) {
                string rest = trim_str (cmd.substring (5, cmd.length - 5));
                string gui_bin = resolve_gui_binary (rest);
                if (gui_bin.length > 0) {
                    if (gui_bin == "pcm4.elf")
                        want_pcm4 = true;
                    else {
                        want_gui_exec = gui_bin;
                        want_gui_title = gui_bin;
                    }
                    push_line (@"launching $gui_bin in compositor...");
                    return;
                }
            } else {
                string gui_bin = resolve_gui_binary (cmd);
                if (gui_bin.length > 0) {
                    if (gui_bin == "pcm4.elf")
                        want_pcm4 = true;
                    else {
                        want_gui_exec = gui_bin;
                        want_gui_title = gui_bin;
                    }
                    push_line (@"launching $gui_bin in compositor...");
                    return;
                }
            }
            spawn_shell_cmd (cmd);
        }

        private void autocomplete () {
            if (input.length == 0)
                return;
            int sp = -1;
            for (int i = input.length - 1; i >= 0; i--) {
                if (input[i] == ' ') { sp = i; break; }
            }
            string pref = (sp >= 0) ? input.substring (sp + 1, input.length - sp - 1) : input;
            string head = (sp >= 0) ? input.substring (0, sp + 1) : "";
            string fs_dir = (cwd == "/") ? "/" : cwd.substring (1, cwd.length - 1);
            var buf = new uint8[4096];
            int n = Sys.readdir_path (fs_dir.length == 0 ? "/" : fs_dir, buf, 4096);
            if (n <= 0)
                return;
            var matches = new GenericArray<string> ();
            int start = 0;
            for (int i = 0; i <= n; i++) {
                if (i == n || buf[i] == 0 || buf[i] == '\n') {
                    if (i > start) {
                        string nm = bytes_to_str (buf, start, i - start);
                        if (pref.length == 0 || nm.has_prefix (pref))
                            matches.add (nm);
                    }
                    start = i + 1;
                }
            }
            if (matches.length == 1) {
                input = head + matches[0];
            } else if (matches.length > 1) {
                string line = "";
                for (int i = 0; i < matches.length; i++) {
                    if (line.length + matches[i].length + 1 > 58) {
                        push_line (line);
                        line = matches[i];
                    } else {
                        line = (line.length > 0) ? (line + " " + matches[i]) : matches[i];
                    }
                }
                if (line.length > 0)
                    push_line (line);
            }
        }

        public bool on_key_press (int key) {
            if (!active)
                return false;
            if (key == 3) { // Ctrl+C
                if (child_tid > 0) {
                    Sys.kill (child_tid);
                    child_tid = -1;
                    if (out_file.length > 0) {
                        Sys.unlink (out_file);
                        out_file = "";
                    }
                    push_line ("^C");
                } else {
                    input = "";
                }
                return true;
            }
            if (key == 0x81) { // Up arrow -> history prev
                if (history.length > 0) {
                    if (hist_idx < 0) {
                        draft_input = input;
                        hist_idx = history.length - 1;
                    } else if (hist_idx > 0) {
                        hist_idx = hist_idx - 1;
                    }
                    input = history[hist_idx];
                }
                return true;
            }
            if (key == 0x82) { // Down arrow -> history next
                if (hist_idx >= 0) {
                    if (hist_idx + 1 < history.length) {
                        hist_idx = hist_idx + 1;
                        input = history[hist_idx];
                    } else {
                        hist_idx = -1;
                        input = draft_input;
                    }
                }
                return true;
            }
            if (key == 9) { // Tab -> autocomplete
                if (input.length > 0) {
                    autocomplete ();
                    return true;
                }
                return false;
            }
            if (key == '\n' || key == '\r') {
                if (child_tid > 0)
                    return true;
                string cmd = input.substring (0, input.length);
                input = "";
                run_cmd (cmd);
                return true;
            }
            if (key == 8 || key == 127) {
                if (input.length > 0)
                    input = input.substring (0, input.length - 1);
                return true;
            }
            if (key >= 32 && key < 127) {
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                input = input + ascii.substring (key - 32, 1);
                return true;
            }
            return false;
        }

        public void draw (Context cr, int cx, int cy, int cw, int ch, bool focused, double ar, double ag, double ab) {
            // Obsidian Orbit (#0F1419)
            cr.set_source_rgb (0.059, 0.078, 0.098);
            cr.rectangle (cx, cy, cw, ch);
            cr.fill ();
            int row_h = 18;
            int max_rows = (ch - 12) / row_h;
            if (max_rows < 2) max_rows = 2;
            int hist_rows = max_rows - 1;
            int end = lines.length - scroll_off;
            if (end < 0) end = 0;
            int start = (end > hist_rows) ? (end - hist_rows) : 0;
            int y = cy + 8;
            // Lunar White (#F0F4F8)
            cr.set_source_rgb (0.941, 0.957, 0.973);
            for (int i = start; i < end; i++) {
                TextHelper.draw_mono (cr, lines[i], cx + 10, y, 14.0);
                y += row_h;
            }
            cr.set_source_rgb (ar, ag, ab);
            string prompt = (child_tid > 0)
                ? (@"[$cwd running... ^C to stop]")
                : (@"planet:$cwd> " + input + (focused ? "_" : ""));
            TextHelper.draw_mono (cr, prompt, cx + 10, y, 14.0);
        }
    }

    class Pcm4CompState : Object {
        public string cwd = "/";
        public string selected = "";
        public string clip_path = "";
        public string want_gui_exec = "";
        public string want_gui_title = "";
        public int want_gui_w = 560;
        public int want_gui_h = 380;
        public GenericArray<string> names = new GenericArray<string> ();
        public Entry? path_entry = null;
        public ListView? lv = null;
        public Label? status = null;
        public Label? preview = null;
        public Notebook? nb = null;

        public string child_path (string nm) {
            if (cwd == "/" || cwd.length == 0)
                return "/" + nm;
            return cwd.has_suffix ("/") ? (cwd + nm) : (cwd + "/" + nm);
        }

        public void refresh (string dir_path) {
            string target = (dir_path.length == 0) ? "/" : dir_path;
            string fs_dir = (target == "/") ? "/" : (target.has_prefix ("/") ? target.substring (1, target.length - 1) : target);
            var buf = new uint8[4096];
            int n = Sys.readdir_path (fs_dir.length == 0 ? "/" : fs_dir, buf, 4096);
            if (n < 0) {
                if (status != null)
                    status.set_text (@"Error: cannot open $target");
                return;
            }
            var items = new GenericArray<string> ();
            var icons = new GenericArray<string> ();
            var next_names = new GenericArray<string> ();
            int start = 0;
            for (int i = 0; i <= n; i++) {
                if (i == n || buf[i] == 0 || buf[i] == '\n') {
                    if (i > start) {
                        var slice = new uint8[i - start];
                        for (int k = 0; k < i - start; k++)
                            slice[k] = buf[start + k];
                        string nm = __planc_host_bytes_to_str (slice, i - start);
                        next_names.add (nm);
                        string fp = (fs_dir == "/") ? nm : (fs_dir + "/" + nm);
                        int kind = Sys.stat (fp);
                        if (kind == 2) {
                            items.add (nm + "/");
                            icons.add ("folder");
                        } else {
                            items.add (nm);
                            if (nm.has_suffix (".elf") || nm.has_suffix (".plan") || nm.has_suffix (".desktop"))
                                icons.add ("application-x-executable");
                            else if (nm.has_suffix (".txt") || nm.has_suffix (".vala") || nm.has_suffix (".c"))
                                icons.add ("text-x-generic");
                            else
                                icons.add ("document-properties");
                        }
                    }
                    start = i + 1;
                }
            }
            cwd = target;
            names = next_names;
            selected = (names.length > 0) ? names[0] : "";
            if (lv != null)
                lv.set_items (items, icons);
            if (path_entry != null)
                path_entry.set_text (cwd);
            if (status != null)
                status.set_text (@"$cwd: $(names.length) items");
        }

        private static bool is_gui_app (string nm) {
            return resolve_gui_binary (nm).length > 0;
        }

        private void run_cli_capture (string fp, string label_nm) {
            Sys.mkdir ("/tmp");
            int out_fd = Sys.create ("/tmp/_pcm4_out.txt");
            if (out_fd < 0) {
                if (status != null)
                    status.set_text (@"Cannot create output buffer for $label_nm");
                return;
            }
            Sys.sys (19, 0, out_fd, 0);
            int tid = Sys.spawn (fp, "");
            int rc = (tid >= 0) ? Sys.wait (tid) : -1;
            Sys.sys (19, 0, 1, 0);
            Sys.close (out_fd);

            string txt = @"[$label_nm exit=$rc]\n";
            int rfd = Sys.open ("/tmp/_pcm4_out.txt");
            if (rfd >= 0) {
                var obuf = new uint8[480];
                int nr = Sys.read (rfd, obuf, 479);
                Sys.close (rfd);
                if (nr > 0) {
                    var slice = new uint8[nr];
                    for (int i = 0; i < nr; i++)
                        slice[i] = obuf[i];
                    txt = txt + __planc_host_bytes_to_str (slice, nr);
                }
            }
            Sys.unlink ("/tmp/_pcm4_out.txt");
            if (preview != null)
                preview.set_text (txt);
            if (nb != null)
                nb.set_current_page (1);
            if (status != null)
                status.set_text (@"Finished $label_nm (exit=$rc)");
        }

        public void open_entry (string nm) {
            if (nm.length == 0)
                return;
            string p = child_path (nm);
            string fp = p.has_prefix ("/") ? p.substring (1, p.length - 1) : p;
            int kind = Sys.stat (fp);
            if (kind == 2) {
                refresh (p);
                return;
            }
            if (nm.has_suffix (".desktop")) {
                var kf = new KeyFile ();
                try {
                    if (kf.load_from_file (fp)) {
                        string exec_nm = kf.get_string ("Desktop Entry", "Exec");
                        string app_nm = kf.get_string ("Desktop Entry", "Name");
                        if (app_nm.length == 0)
                            app_nm = nm;
                        bool term_app = kf.get_boolean ("Desktop Entry", "Terminal");
                        if (exec_nm.length > 0) {
                            if (term_app) {
                                run_cli_capture (exec_nm, app_nm);
                            } else {
                                want_gui_exec = exec_nm;
                                want_gui_title = app_nm;
                                want_gui_w = 560;
                                want_gui_h = 380;
                            }
                            return;
                        }
                    }
                } catch (KeyFileError ke) {
                    if (status != null)
                        status.set_text (@"Desktop error: $(ke.message)");
                    return;
                }
            }
            if (nm.has_suffix (".elf") || nm.has_suffix (".plan")) {
                if (is_gui_app (nm)) {
                    want_gui_exec = fp;
                    want_gui_title = nm;
                    want_gui_w = (nm == "saturn.elf") ? 720 : 560;
                    want_gui_h = (nm == "saturn.elf") ? 460 : 380;
                    if (status != null)
                        status.set_text (@"Opening window: $nm");
                } else {
                    run_cli_capture (fp, nm);
                }
                return;
            }
            int fd = Sys.open (fp);
            if (fd >= 0) {
                var buf = new uint8[320];
                int nr = Sys.read (fd, buf, 319);
                Sys.close (fd);
                if (nr > 0) {
                    var slice = new uint8[nr];
                    for (int i = 0; i < nr; i++)
                        slice[i] = buf[i];
                    if (preview != null)
                        preview.set_text (__planc_host_bytes_to_str (slice, nr));
                    if (nb != null)
                        nb.set_current_page (1);
                    if (status != null)
                        status.set_text (@"Opened $nm ($nr B)");
                }
            }
        }
    }

}
