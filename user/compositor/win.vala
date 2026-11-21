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
    // Ring of pointer/key events for an external (PLANET_WIN_EV) window.
    // Keeps the last CAPACITY events in 32-bit words and reuses the wire
    // buffer, so a push is O(1) and allocates nothing. The sequence number is
    // not stored per event: queued events are always consecutive, so it is
    // derived from the newest one. [Compact] drops the vtable and refcount,
    // which is fine because the ring lives exactly as long as its Win.
    [Compact]
    class ExtEventRing {
        private const int CAPACITY = 16;
        private const int WORDS = 4;
        private int32[] slots = new int32[64];      // CAPACITY * WORDS
        private uint8[] wire = new uint8[324];      // 4 + CAPACITY * 5 * 4
        private int head = 0;
        private int count = 0;
        private uint32 seq = 0;

        public void push (int type, int p1, int p2, int p3) {
            int idx;
            if (count < CAPACITY) {
                idx = (head + count) % CAPACITY;
                count++;
            } else {
                // Full: drop the oldest event by advancing the head.
                idx = head;
                head = (head + 1) % CAPACITY;
            }
            seq++;
            int off = idx * WORDS;
            slots[off + 0] = (int32) type;
            slots[off + 1] = (int32) p1;
            slots[off + 2] = (int32) p2;
            slots[off + 3] = (int32) p3;
        }

        // Writes [count][seq, type, p1, p2, p3]... to `fd` in one call.
        public bool flush_to (int fd) {
            int len = encode ();
            return Sys.write (fd, wire, len) == len;
        }

        // Fills `wire` with the events and returns the length in bytes.
        private int encode () {
            put_le32 (wire, 0, (uint32) count);
            uint32 first = seq - (uint32) count;
            int len = 4;
            for (int i = 0; i < count; i++) {
                int off = ((head + i) % CAPACITY) * WORDS;
                put_le32 (wire, len, first + (uint32) i + 1);
                put_le32 (wire, len + 4, (uint32) slots[off + 0]);
                put_le32 (wire, len + 8, (uint32) slots[off + 1]);
                put_le32 (wire, len + 12, (uint32) slots[off + 2]);
                put_le32 (wire, len + 16, (uint32) slots[off + 3]);
                len += 20;
            }
            return len;
        }

        private static void put_le32 (uint8[] b, int off, uint32 v) {
            b[off + 0] = (uint8) (v & 0xFF);
            b[off + 1] = (uint8) ((v >> 8) & 0xFF);
            b[off + 2] = (uint8) ((v >> 16) & 0xFF);
            b[off + 3] = (uint8) ((v >> 24) & 0xFF);
        }
    }

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
        public int gtk_alloc_x = -1;
        public int gtk_alloc_y = -1;
        public int gtk_alloc_w = -1;
        public int gtk_alloc_h = -1;
        public VteTerminal? term = null;
        public Pcm4CompState? pcm4_state = null;
        public ImageSurface? ext_surf = null;
        // Shared surface (PLANET_WIN_SHM): the block the compositor allocated,
        // the pixel base inside it, and a view over those pixels.
        public int ext_shm = 0;
        public int ext_shm_px = 0;
        public int ext_shm_pages = 0;
        public ImageSurface? ext_shm_surf = null;
        // Frames the client published and the pixels those frames damaged.
        public int ext_rects = 0;
        public int ext_damage_px = 0;
        public int ext_last_dx = 0;
        public int ext_last_dy = 0;
        public int ext_last_dw = 0;
        public int ext_last_dh = 0;
        public int ext_seq = 0;
        public string ext_file = "";
        public string ext_ev_file = "";
        public int ext_tid = -1;
        private ExtEventRing ext_ev;

        public Win (int id, string title, int x, int y, int w, int h, Kind kind) {
            ext_ev = new ExtEventRing ();
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
                        int pct = (gst.clicks * 10) % 101;
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
                    if (sfd < 0) {
                        st_lbl.set_text (@"Cannot open $(pst.clip_path)");
                        return;
                    }
                    string dst = pst.child_path ("copy_" + pst.selected);
                    string dst_rel = dst.has_prefix ("/")
                        ? dst.substring (1, dst.length - 1) : dst;
                    int dfd = Sys.create (dst_rel);
                    if (dfd < 0) {
                        Sys.close (sfd);
                        st_lbl.set_text (@"Cannot create $(dst)");
                        return;
                    }
                    var chunk = new uint8[8192];
                    bool ok = true;
                    while (true) {
                        int nr = Sys.read (sfd, chunk, 8192);
                        if (nr < 0) {
                            ok = false;
                            break;
                        }
                        if (nr == 0)
                            break;
                        if (Sys.write (dfd, chunk, nr) != nr) {
                            ok = false;
                            break;
                        }
                        if (nr < 8192)
                            break;
                    }
                    Sys.close (dfd);
                    Sys.close (sfd);
                    if (!ok) {
                        Sys.unlink (dst_rel);
                        st_lbl.set_text (@"Paste failed: $(dst)");
                        return;
                    }
                    pst.refresh (pst.cwd);
                    st_lbl.set_text (@"Pasted $(dst)");
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

        ~Win () {
            // A [Compact] field is not owned by its container.
            ext_ev.free ();
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

        public void push_ext_event (int type, int p1, int p2, int p3) {
            if (ext_shm != 0) {
                // Shared ring: one slot plus a sequence bump, no syscalls.
                int seq = Sys.peek32 (ext_shm + SharedSurface.OFF_EV_SEQ) + 1;
                int off = ext_shm + SharedSurface.ev_slot (seq % SharedSurface.EV_SLOTS);
                Sys.poke32 (off + 0, type);
                Sys.poke32 (off + 4, p1);
                Sys.poke32 (off + 8, p2);
                Sys.poke32 (off + 12, p3);
                Sys.poke32 (ext_shm + SharedSurface.OFF_EV_SEQ, seq);
                return;
            }
            if (ext_ev_file.length == 0)
                return;
            ext_ev.push (type, p1, p2, p3);
            string tmp = ext_ev_file + ".tmp";
            int fd = Sys.create (tmp);
            if (fd < 0)
                return;
            bool ok = ext_ev.flush_to (fd);
            Sys.close (fd);
            if (!ok) {
                Sys.unlink (tmp);
                return;
            }
            Sys.unlink (ext_ev_file);
            if (Sys.rename (tmp, ext_ev_file) != 0)
                Sys.unlink (tmp);
        }
    }

}
