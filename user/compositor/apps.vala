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

    public class GtkCompState : Object {
        public int clicks = 0;
    }

    public class VteTerminal : Object {
        public GenericArray<string> lines;
        public string input = "";
        public bool active = false;
        public bool want_pcm4 = false;

        public VteTerminal () {
            lines = new GenericArray<string> ();
            lines.add ("PlanetOS VTE v0.1 (click & type 'help')");
        }

        private void push_line (string s) {
            lines.add (s);
            if (lines.length > 64)
                lines.remove_index (0);
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

        private void run_cmd (string raw) {
            string cmd = trim_str (raw);
            push_line ("planet> " + cmd);
            if (cmd == "")
                return;
            if (cmd == "help") {
                push_line ("cmds: help ls cat ticks uname echo clear pcm4");
            } else if (cmd == "pcm4" || cmd == "files") {
                want_pcm4 = true;
                push_line ("opening pcm4 window...");
            } else if (cmd == "clear") {
                lines.length = 0;
            } else if (cmd == "uname") {
                push_line ("PlanetOS x86_64 Long Mode (Ring 3 + VTE)");
            } else if (cmd == "ticks") {
                push_line (@"ticks: $(Sys.ticks ())");
            } else if (cmd.has_prefix ("echo ")) {
                push_line (cmd.substring (5, cmd.length - 5));
            } else if (cmd == "ls") {
                var buf = new uint8[2048];
                int n = Sys.readdir_path ("/", buf, 2048);
                if (n <= 0) {
                    push_line ("(empty)");
                    return;
                }
                string cur = "";
                int start = 0;
                for (int i = 0; i <= n; i++) {
                    if (i == n || buf[i] == 0 || buf[i] == '\n') {
                        if (i > start) {
                            string name = bytes_to_str (buf, start, i - start);
                            if (cur.length + name.length + 1 > 40) {
                                push_line (cur);
                                cur = name;
                            } else {
                                cur = (cur.length > 0) ? (cur + " " + name) : name;
                            }
                        }
                        start = i + 1;
                    }
                }
                if (cur.length > 0)
                    push_line (cur);
            } else if (cmd.has_prefix ("cat ")) {
                string path = trim_str (cmd.substring (4, cmd.length - 4));
                int fd = Sys.open (path);
                if (fd < 0) {
                    push_line (@"cat: not found: $path");
                } else {
                    var fbuf = new uint8[512];
                    int nr = Sys.read (fd, fbuf, 511);
                    Sys.close (fd);
                    if (nr > 0) {
                        int st = 0;
                        for (int i = 0; i <= nr; i++) {
                            if (i == nr || fbuf[i] == '\n') {
                                if (i > st)
                                    push_line (bytes_to_str (fbuf, st, i - st));
                                st = i + 1;
                            }
                        }
                    }
                }
            } else {
                push_line (@"unknown: $cmd");
            }
        }

        public bool on_key_press (int key) {
            if (!active)
                return false;
            if (key == '\n' || key == '\r') {
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
            cr.set_source_rgb (0.051, 0.063, 0.090);
            cr.rectangle (cx, cy, cw, ch);
            cr.fill ();
            int row_h = 18;
            int max_rows = (ch - 12) / row_h;
            if (max_rows < 2) max_rows = 2;
            int hist_rows = max_rows - 1;
            int start = (lines.length > hist_rows) ? (lines.length - hist_rows) : 0;
            int y = cy + 8;
            cr.set_source_rgb (0.78, 0.83, 0.90);
            for (int i = start; i < lines.length; i++) {
                TextHelper.draw_mono (cr, lines[i], cx + 10, y, 14.0);
                y += row_h;
            }
            cr.set_source_rgb (ar, ag, ab);
            string prompt = "planet> " + input + (focused ? "_" : "");
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
                            if (nm.has_suffix (".elf") || nm.has_suffix (".desktop"))
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
            return nm == "gtk_demo.elf" || nm == "pcm4.elf" || nm == "cairo_demo.elf"
                || nm == "spv_demo.elf" || nm == "vk_demo.elf" || nm == "pango_demo.elf"
                || nm == "compositor.elf";
        }

        private void run_cli_capture (string fp, string label_nm) {
            int out_fd = Sys.create ("_pcm4_out.txt");
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
            int rfd = Sys.open ("_pcm4_out.txt");
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
            Sys.unlink ("_pcm4_out.txt");
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
                int dfd = Sys.open (fp);
                if (dfd >= 0) {
                    var dbuf = new uint8[512];
                    int dnr = Sys.read (dfd, dbuf, 511);
                    Sys.close (dfd);
                    if (dnr > 0) {
                        var dsl = new uint8[dnr];
                        for (int i = 0; i < dnr; i++)
                            dsl[i] = dbuf[i];
                        string raw = __planc_host_bytes_to_str (dsl, dnr);
                        string exec_nm = "";
                        string app_nm = nm;
                        bool term_app = false;
                        int start = 0;
                        for (int i = 0; i <= raw.length; i++) {
                            if (i == raw.length || raw[i] == '\n' || raw[i] == '\r') {
                                if (i > start) {
                                    string ln = raw.substring (start, i - start);
                                    if (ln.has_prefix ("Exec="))
                                        exec_nm = ln.substring (5, ln.length - 5);
                                    else if (ln.has_prefix ("Name="))
                                        app_nm = ln.substring (5, ln.length - 5);
                                    else if (ln == "Terminal=true")
                                        term_app = true;
                                }
                                start = i + 1;
                            }
                        }
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
                }
            }
            if (nm.has_suffix (".elf")) {
                if (is_gui_app (nm)) {
                    want_gui_exec = fp;
                    want_gui_title = nm;
                    want_gui_w = 560;
                    want_gui_h = 380;
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
