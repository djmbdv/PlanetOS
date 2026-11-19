// Window model and embedded GTK/VTE widgets for PlanetOS compositor.
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
    public class Win : Object {
        public int id;
        public string title;
        public Kind kind;
        public int x;
        public int y;
        public int w;
        public int h;
        public int z;
        public bool alive = true;
        public bool maximized = false;
        public int layout_state = 0;
        public int rx;
        public int ry;
        public int rw;
        public int rh;
        public Box? gtk_root = null;
        public VteTerminal? term = null;
        public Pcm4CompState? pcm4_state = null;
        public ImageSurface? ext_surf = null;
        public int ext_seq = 0;
        public string ext_file = "";
        public string ext_ev_file = "";
        public int32 ext_ev_seq = 0;
        public int ext_tid = -1;
        private GenericArray<int32>? ext_ev_q = null;

        public Win (int id, string title, int x, int y, int w, int h, Kind kind) {
            this.id = id;
            this.title = title;
            this.x = x;
            this.y = y;
            this.w = w;
            this.h = h;
            this.kind = kind;
            if (kind == Kind.TERMINAL) {
                term = new VteTerminal ();
            } else if (kind == Kind.GTK) {
                var box = new Box (Orientation.VERTICAL, 8);
                var lbl = new Label ("GTK + TrueType (7)");
                lbl.font_size = 18.0;
                var ent = new Entry ("PlanetOS 7");
                var chk = new CheckButton ("Auto-progress", true);
                var pbar = new ProgressBar ();
                pbar.set_text ("0%");
                var gst = new GtkCompState ();
                var st_lbl = new Label (@"Clicks: $(gst.clicks)");
                var btn = new Button ("Increment (+1)");
                btn.clicked.connect ((sender) => {
                    gst.clicks = gst.clicks + 1;
                    st_lbl.set_text (@"Clicks: $(gst.clicks) | $(ent.get_text ())");
                    if (chk.get_active ()) {
                        int pct = (gst.clicks * 10) % 110;
                        if (pct > 100) pct = 100;
                        pbar.set_fraction ((double) pct / 100.0);
                        pbar.set_text (@"$pct%");
                    }
                });
                box.pack_start (lbl);
                box.pack_start (ent);
                box.pack_start (chk);
                box.pack_start (pbar);
                box.pack_start (new Separator ());
                box.pack_start (btn);
                box.pack_start (st_lbl);
                gtk_root = box;
            } else if (kind == Kind.FILES) {
                var pst = new Pcm4CompState ();
                var root = new Box (Orientation.VERTICAL, 6);
                var bar = new Box (Orientation.HORIZONTAL, 4);
                var b_up = new Button ("Up");
                var b_ref = new Button ("Ref");
                var b_cp = new Button ("Copy");
                var b_pa = new Button ("Paste");
                var b_rm = new Button ("Del");
                var ent = new Entry ("/");
                bar.pack_start (b_up);
                bar.pack_start (b_ref);
                bar.pack_start (b_cp);
                bar.pack_start (b_pa);
                bar.pack_start (b_rm);
                bar.pack_start (ent);

                var paned = new Paned (Orientation.HORIZONTAL);
                paned.set_position (120);
                paned.set_size_request (w - 30, h - 100);
                var side = new ListBox ();
                var r0 = new Box (Orientation.HORIZONTAL, 4);
                r0.pack_start (new Image.from_icon_name ("folder", 14));
                r0.pack_start (new Label ("/"));
                side.append (r0);
                var r1 = new Box (Orientation.HORIZONTAL, 4);
                r1.pack_start (new Image.from_icon_name ("text-x-generic", 14));
                r1.pack_start (new Label ("hello.txt"));
                side.append (r1);
                paned.set_start_child (side);

                var nb = new Notebook ();
                var sc_f = new ScrolledWindow ();
                var lv = new ListView ();
                lv.focused = true;
                sc_f.set_child (lv);
                nb.append_page (sc_f, "Files");
                var sc_p = new ScrolledWindow ();
                var prev_lbl = new Label ("Select a file to preview.");
                sc_p.set_child (prev_lbl);
                nb.append_page (sc_p, "Preview");
                paned.set_end_child (nb);

                var st_lbl = new Label ("Ready");
                pst.path_entry = ent;
                pst.lv = lv;
                pst.status = st_lbl;
                pst.preview = prev_lbl;
                pst.nb = nb;

                b_up.clicked.connect ((sender) => { pst.refresh ("/"); });
                b_ref.clicked.connect ((sender) => { pst.refresh (pst.cwd); });
                ent.activate.connect ((sender) => { pst.refresh (ent.get_text ()); });
                lv.selection_changed.connect ((sender, idx) => {
                    if (idx >= 0 && idx < pst.names.length) {
                        pst.selected = pst.names[idx];
                        st_lbl.set_text (@"Selected: $(pst.selected)");
                    }
                });
                lv.activate.connect ((sender, idx) => {
                    if (idx >= 0 && idx < pst.names.length)
                        pst.open_entry (pst.names[idx]);
                });
                side.row_activated.connect ((sender, row) => {
                    if (row != null && row.get_index () == 0)
                        pst.refresh ("/");
                    else if (row != null && row.get_index () == 1)
                        pst.open_entry ("hello.txt");
                });
                b_cp.clicked.connect ((sender) => {
                    if (pst.selected.length > 0) {
                        pst.clip_path = pst.selected;
                        st_lbl.set_text (@"Copied: $(pst.selected)");
                    }
                });
                b_pa.clicked.connect ((sender) => {
                    if (pst.clip_path.length == 0)
                        return;
                    int sfd = Sys.open (pst.clip_path);
                    if (sfd >= 0) {
                        int sz = Sys.file_size (sfd);
                        if (sz < 0) sz = 0;
                        var buf = new uint8[sz > 0 ? sz : 1];
                        int nr = (sz > 0) ? Sys.read (sfd, buf, sz) : 0;
                        Sys.close (sfd);
                        string dst_nm = "copy_" + pst.clip_path;
                        int dfd = Sys.create (dst_nm);
                        if (dfd >= 0) {
                            if (nr > 0)
                                Sys.write (dfd, buf, nr);
                            Sys.close (dfd);
                            pst.refresh (pst.cwd);
                            st_lbl.set_text (@"Pasted $dst_nm");
                        }
                    }
                });
                b_rm.clicked.connect ((sender) => {
                    if (pst.selected.length > 0) {
                        string fp = pst.child_path (pst.selected);
                        string rel = fp.has_prefix ("/") ? fp.substring (1, fp.length - 1) : fp;
                        if (Sys.unlink (rel) >= 0) {
                            pst.refresh (pst.cwd);
                            st_lbl.set_text (@"Deleted $(pst.selected)");
                        }
                    }
                });

                root.pack_start (bar);
                root.pack_start (paned);
                root.pack_start (st_lbl);
                pst.refresh ("/");
                pcm4_state = pst;
                gtk_root = root;
            }
        }

        public bool contains (int px, int py) {
            return px >= x && px < x + w && py >= y && py < y + h;
        }

        public bool in_title (int px, int py) {
            return px >= x + BORDER && px < x + w - BORDER
                && py >= y + BORDER && py < y + BORDER + TITLE_H;
        }

        public int close_x () { return x + w - BORDER - BTN_GAP - BTN; }
        public int max_x () { return x + w - BORDER - BTN_GAP - BTN - BTN_GAP - BTN; }
        public int btn_y () { return y + BORDER + (TITLE_H - BTN) / 2; }

        public bool in_close (int px, int py) {
            int bx = close_x ();
            int by = btn_y ();
            return px >= bx && px < bx + BTN && py >= by && py < by + BTN;
        }

        public bool in_max (int px, int py) {
            int bx = max_x ();
            int by = btn_y ();
            return px >= bx && px < bx + BTN && py >= by && py < by + BTN;
        }

        public bool in_resize (int px, int py) {
            return !maximized && px >= x + w - 14 && px < x + w && py >= y + h - 14 && py < y + h;
        }

        public int content_y () { return y + BORDER + TITLE_H; }
        public int content_h () { return h - TITLE_H - 2 * BORDER; }

        private static void put_le32 (uint8[] b, int off, int32 val) {
            int v = (int) val;
            b[off + 0] = (uint8) (v & 0xFF);
            b[off + 1] = (uint8) ((v >> 8) & 0xFF);
            b[off + 2] = (uint8) ((v >> 16) & 0xFF);
            b[off + 3] = (uint8) ((v >> 24) & 0xFF);
        }

        public void push_ext_event (int type, int p1, int p2, int p3) {
            if (ext_ev_file.length == 0)
                return;
            if (ext_ev_q == null)
                ext_ev_q = new GenericArray<int32> ();
            ext_ev_seq++;
            ext_ev_q.add (ext_ev_seq);
            ext_ev_q.add ((int32) type);
            ext_ev_q.add ((int32) p1);
            ext_ev_q.add ((int32) p2);
            ext_ev_q.add ((int32) p3);
            while (ext_ev_q.length > 80) { // max 16 events * 5 ints
                for (int i = 0; i < 5; i++)
                    ext_ev_q.remove_index (0);
            }
            int cnt = ext_ev_q.length / 5;
            var buf = new uint8[4 + cnt * 20];
            put_le32 (buf, 0, (int32) cnt);
            for (int i = 0; i < ext_ev_q.length; i++)
                put_le32 (buf, 4 + i * 4, ext_ev_q[i]);
            string tmp = ext_ev_file + ".tmp";
            int fd = Sys.create (tmp);
            if (fd < 0)
                return;
            int wr = Sys.write (fd, buf, buf.length);
            Sys.close (fd);
            if (wr == buf.length) {
                Sys.unlink (ext_ev_file);
                Sys.rename (tmp, ext_ev_file);
            } else {
                Sys.unlink (tmp);
            }
        }
    }

}
