// user/gio_demo.vala -- exercises the pure-Vala Gio layer on PlanetOS.
//
// Run from the PlanetOS shell:
//     exec gio_demo.elf              # defaults to hello.txt
//     exec gio_demo.elf <file>
//
// Every check prints a deterministic line so the QEMU harness can grep the
// serial log, and the exit status is non-zero when a check fails.

using GLib;
using Gio;

namespace GioDemo {
    private int checks = 0;
    private int failures = 0;
    // Directory that owns this run's scratch files: the parent of the target.
    // Keeping everything next to the target lets the regression cases run in
    // their own `test/<case>/` tree instead of mutating the shared XFS root.
    private string base_dir = ".";
    private string target_name = "hello.txt";
    // Cancellable source counter. planc currently captures locals by value in
    // closures (writes do not reach the enclosing scope), so the callback
    // reports through module state, like mainloop_demo does.
    private int cancel_fired = 0;

    private string at (string name) {
        if (base_dir.length == 0 || base_dir == ".")
            return name;
        if (base_dir == "/")
            return "/" + name;
        return base_dir + "/" + name;
    }

    private void check (string what, bool ok) {
        checks = checks + 1;
        if (ok) {
            print (@"gio:check $what ok\n");
        } else {
            failures = failures + 1;
            print (@"gio:check $what FAIL\n");
        }
    }

    private void report (string what, IOError e) {
        print (@"gio:error $what: $(e.message)\n");
        check (what, false);
    }

    private void demo_info (File f) {
        try {
            var info = f.query_info ();
            print (@"gio:info name=$(info.get_name()) size=$(info.get_size()) type=$(info.get_file_type()) ctype=$(info.get_content_type())\n");
            check ("info-regular", info.get_file_type () == FileType.REGULAR);
            check ("info-content-type", info.get_content_type () == "text/plain");
        } catch (IOError e) {
            report ("info", e);
        }
    }

    private void demo_read_lines (File f) {
        try {
            var stream = f.read ();
            var din = new DataInputStream (stream);
            int n = 0;
            int lines = 0;
            while (true) {
                string? line = din.read_line (out n);
                if (line == null)
                    break;
                print (@"gio:line[$lines] len=$n $line\n");
                lines = lines + 1;
            }
            check ("read-lines", lines > 0);
            din.close ();
            var one = new uint8[1];
            try {
                din.read (one);
                check ("closed-stream", false);
            } catch (IOError e) {
                check ("closed-stream", true);
            }
        } catch (IOError e) {
            report ("read", e);
        }
    }

    private void demo_seek (File f) {
        try {
            var info = f.query_info ();
            int size = info.get_size ();
            var stream = f.read ();
            stream.seek (0, SeekType.END);
            int end = stream.tell ();
            check ("seek-end", end == size);
            stream.seek (0, SeekType.SET);
            check ("seek-set", stream.tell () == 0);
            stream.close ();
        } catch (IOError e) {
            report ("seek", e);
        }
    }

    private void demo_cancellable (File f) {
        var c = new Cancellable ();
        c.cancel ();
        check ("cancellable-flag", c.is_cancelled ());
        try {
            f.query_info ("*", FileQueryInfoFlags.NONE, c);
            check ("cancellable-query", false);
        } catch (IOError e) {
            check ("cancellable-query", true);
        }
        try {
            c.set_error_if_cancelled ();
            check ("cancellable-error", false);
        } catch (IOError e) {
            check ("cancellable-error", true);
        }
    }

    private void demo_memory () {
        try {
            var mos = new MemoryOutputStream ();
            var dout = new DataOutputStream (mos);
            dout.put_string ("memory:first\n");
            dout.put_byte ((uint8) 'X');
            dout.put_string ("\n");
            dout.close ();
            print (@"gio:memory size=$(mos.get_data_size())\n");
            check ("memory-size", mos.get_data_size () > 0);

            var mis = new MemoryInputStream.from_data (mos.get_data ());
            var din = new DataInputStream (mis);
            int n = 0;
            string? first = din.read_line (out n);
            if (first == null) {
                check ("memory-line", false);
            } else {
                check ("memory-line", first == "memory:first");
                var b = din.read_byte ();
                check ("memory-byte", b == (uint8) 'X');
            }

            var mos2 = new MemoryOutputStream ();
            uint8[] init_bytes = { (uint8) 'm', (uint8) 'e', (uint8) 'm', (uint8) 'o', (uint8) 'r', (uint8) 'y', (uint8) ':', (uint8) '1', (uint8) '2', (uint8) '3', (uint8) '4', (uint8) '5', (uint8) '6' };
            mos2.write (init_bytes);
            mos2.seek (7, SeekType.SET);
            uint8[] repl = { (uint8) 's', (uint8) 'e', (uint8) 'c', (uint8) 'n', (uint8) 'd' };
            mos2.write (repl);
            mos2.truncate (12);
            var stolen_bytes = mos2.steal_as_bytes ();
            check ("memory-steal", stolen_bytes.get_size () == 12 && mos2.get_data_size () == 0);
            var mis2 = new MemoryInputStream.from_data (stolen_bytes.get_data ());
            var din2 = new DataInputStream (mis2);
            int tok_len = 0;
            string? tok = din2.read_upto (":", 1, out tok_len);
            check ("memory-upto", tok == "memory" && tok_len == 6);
        } catch (IOError e) {
            report ("memory", e);
        }
    }

    private void demo_write (string path) {
        try {
            var f = File.new_for_path (path);
            var out_stream = f.replace ();
            var dout = new DataOutputStream (out_stream);
            dout.put_string ("written by gio_demo\n");
            dout.close ();
            check ("write-exists", f.query_exists ());

            string text = "";
            if (FileUtils.get_contents (path, out text)) {
                print (@"gio:written size=$(text.length)\n");
                check ("write-content", text == "written by gio_demo\n");
            } else {
                check ("write-content", false);
            }

            var app_stream = f.append_to ();
            var adout = new DataOutputStream (app_stream);
            adout.put_string ("appended line\n");
            adout.close ();

            var in_stream = f.read ();
            var din = new DataInputStream (in_stream);
            int n = 0;
            int lines = 0;
            while (true) {
                string? line = din.read_line (out n);
                if (line == null)
                    break;
                print (@"gio:file[$lines] $line\n");
                lines = lines + 1;
            }
            din.close ();
            check ("append-lines", lines == 2);
            check ("write-delete", f.delete ());
            check ("write-deleted", !f.query_exists ());
        } catch (IOError e) {
            report ("write", e);
        }
    }

    private void demo_contents (string path) {
        try {
            var f = File.new_for_path (path);
            if (!f.query_exists ()) {
                var created = f.create (FileCreateFlags.NONE, null);
                created.close ();
            }
            check ("create-new", f.query_exists ());
            try {
                var again = f.create (FileCreateFlags.NONE, null);
                again.close ();
                check ("create-exists", false);
            } catch (IOError e) {
                check ("create-exists", true);
            }

            var payload = new uint8[3];
            payload[0] = (uint8) 'h';
            payload[1] = (uint8) 'i';
            payload[2] = (uint8) '\n';
            string? new_etag = null;
            bool replaced = f.replace_contents (payload, null, false, FileCreateFlags.REPLACE_DESTINATION, out new_etag, null);
            check ("replace-contents", replaced);

            string text = "";
            if (FileUtils.get_contents (path, out text)) {
                check ("replace-read", text == "hi\n");
            } else {
                check ("replace-read", false);
            }

            uint8[] contents;
            string? etag = null;
            f.load_contents (null, out contents, out etag);
            check ("load-contents", contents.length == 3 && contents[0] == (uint8) 'h');

            var child = f.get_child ("nested");
            check ("child-path", child.get_path () == path + "/nested");

            var af = File.new_for_path (at ("gio_append.tmp"));
            var astr = af.append_to (FileCreateFlags.NONE, null);
            var ad = new DataOutputStream (astr);
            ad.put_string ("fresh\n");
            ad.close ();
            check ("append-create", af.query_exists ());

            check ("append-delete", af.delete ());
            check ("append-gone", !af.query_exists ());

            var moved = File.new_for_path (at ("gio_move.tmp"));
            if (moved.query_exists ())
                moved.delete ();
            check ("move", f.move (moved, FileCopyFlags.NONE, null));
            check ("move-gone", !f.query_exists () && moved.query_exists ());

            var target = File.new_for_path (at ("gio_target.tmp"));
            if (!target.query_exists ()) {
                var t = target.create (FileCreateFlags.NONE, null);
                t.close ();
            }
            try {
                moved.move (target, FileCopyFlags.NONE, null);
                check ("move-exists", false);
            } catch (IOError e) {
                check ("move-exists", true);
                var ec = e.copy ();
                check ("error-matches", e.matches (e.domain, e.code) && ec.message == e.message);
            }

            // GLib.FileStream test
            string fs_path = at ("gio_fstream.tmp");
            var fsw = GLib.FileStream.open (fs_path, "w");
            check ("fstream-open-w", fsw != null);
            if (fsw != null) {
                fsw.puts ("alpha\nbeta\n");
                fsw.close ();
            }
            var fsr = GLib.FileStream.open (fs_path, "r");
            check ("fstream-open-r", fsr != null);
            if (fsr != null) {
                string? l1 = fsr.read_line ();
                int c0 = fsr.getc ();
                fsr.ungetc (c0);
                string? l2 = fsr.read_line ();
                fsr.rewind ();
                fsr.seek (6, GLib.FileSeek.SET);
                long pos_after = fsr.tell ();
                fsr.close ();
                check ("fstream-read", l1 == "alpha" && l2 == "beta" && pos_after == 6);
            }
            Sys.unlink (fs_path);

            // GLib.Quark, PatternSpec, Shell, Markup, OptionContext, Test
            uint32 q1 = GLib.Quark.from_string ("planet-domain");
            uint32 q2 = GLib.Quark.from_string ("planet-domain");
            check ("quark", q1 != 0 && q1 == q2 && GLib.Quark.to_string (q1) == "planet-domain" && GLib.Quark.try_string ("missing-q") == 0);

            var ps = new GLib.PatternSpec ("*.vala");
            check ("pattern", ps.match_string ("gio_demo.vala") && !ps.match_string ("gio_demo.c") && GLib.PatternSpec.match_simple ("a?c*", "abcdef"));

            string[] sh_argv;
            bool sh_ok = false;
            try {
                sh_ok = GLib.Shell.parse_argv ("echo 'hello world' \"a\\\"b\"", out sh_argv);
            } catch (ShellError se) {
                sh_ok = false;
            }
            check ("shell", sh_ok && sh_argv.length == 3 && sh_argv[1] == "hello world" && sh_argv[2] == "a\"b" && GLib.Shell.quote ("a'b") == "'a'\\''b'");

            string esc = GLib.Markup.escape_text ("<b>a & b</b>");
            string stripped = "";
            try {
                stripped = GLib.Markup.strip_tags ("<b>hi &amp; bye</b>");
            } catch (MarkupError me) {
                stripped = "";
            }
            check ("markup", esc == "&lt;b&gt;a &amp; b&lt;/b&gt;" && stripped == "hi & bye");

            var opt_ctx = new GLib.OptionContext ("FILE");
            var e_verb = new GLib.OptionEntry ("verbose", 'v', GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Verbose");
            var e_cnt = new GLib.OptionEntry ("count", 'n', GLib.OptionFlags.NONE, GLib.OptionArg.INT, "Count", "N");
            opt_ctx.add_entry (e_verb);
            opt_ctx.add_entry (e_cnt);
            string[] mock_args = { "prog", "-v", "--count=42", "input.txt" };
            bool opt_ok = false;
            try {
                opt_ok = opt_ctx.parse (ref mock_args);
            } catch (OptionError oe) {
                opt_ok = false;
            }
            check ("options", opt_ok && e_verb.bool_val && e_cnt.int_val == 42 && mock_args.length == 2 && mock_args[1] == "input.txt");

            string[] targs = { "gio_unit" };
            GLib.Test.init (ref targs);
            GLib.Test.add_func ("/glib/basic", () => {
                GLib.Test.assert_true (1 + 1 == 2, "math");
                GLib.Test.assert_cmpstr ("ok", "==", "ok");
                GLib.Test.assert_cmpint (42, ">", 10);
            });
            check ("glib-test", GLib.Test.run () == 0);
            check ("move-overwrite", moved.move (target, FileCopyFlags.OVERWRITE, null));
            check ("move-overwrite-gone", !moved.query_exists () && target.query_exists ());

            check ("target-delete", target.delete ());
            check ("target-gone", !target.query_exists ());
        } catch (IOError e) {
            report ("contents", e);
        }
    }

    private void demo_directories () {
        try {
            var dir = File.new_for_path (at ("gio_dir"));
            if (dir.query_exists ())
                dir.delete ();
            check ("mkdir", dir.make_directory (null));
            check ("mkdir-exists", dir.query_exists ());
            var dir_info = dir.query_info ();
            check ("mkdir-type", dir_info.get_file_type () == FileType.DIRECTORY);

            var file = dir.get_child ("note.txt");
            var out_stream = file.replace ();
            var dout = new DataOutputStream (out_stream);
            dout.put_string ("inside\n");
            dout.close ();
            check ("dir-child-write", file.query_exists ());

            var en = dir.enumerate_children ();
            int count = 0;
            while (true) {
                var info = en.next_file ();
                if (info == null)
                    break;
                count = count + 1;
            }
            en.close ();
            check ("dir-list", count == 1);

            string text = "";
            if (FileUtils.get_contents (at ("gio_dir/note.txt"), out text)) {
                check ("dir-child-read", text == "inside\n");
            } else {
                check ("dir-child-read", false);
            }

            var moved = File.new_for_path (at ("gio_dir/moved.txt"));
            check ("dir-move", file.move (moved, FileCopyFlags.NONE, null));
            check ("dir-move-gone", !file.query_exists () && moved.query_exists ());
            check ("dir-rm-file", moved.delete ());
            check ("dir-rm", dir.delete ());
            check ("dir-gone", !dir.query_exists ());

            var blocked = File.new_for_path (at ("gio_dir2"));
            if (blocked.query_exists ())
                blocked.delete ();
            blocked.make_directory (null);
            var keep = blocked.get_child ("keep.txt");
            var ks = keep.replace ();
            ks.close ();
            try {
                blocked.delete ();
                check ("dir-rm-nonempty", false);
            } catch (IOError e) {
                check ("dir-rm-nonempty", true);
            }
            keep.delete ();
            blocked.delete ();
            check ("dir2-gone", !blocked.query_exists ());
        } catch (IOError e) {
            report ("dirs", e);
        }
    }

    private void demo_enumerate () {
        try {
            var root = File.new_for_path ((base_dir == ".") ? "/" : base_dir);
            var en = root.enumerate_children ();
            int count = 0;
            bool found = false;
            while (true) {
                var info = en.next_file ();
                if (info == null)
                    break;
                count = count + 1;
                if (info.get_name () == target_name)
                    found = true;
            }
            en.close ();
            print (@"gio:children count=$count\n");
            check ("enumerate-count", count > 0);
            check ("enumerate-hello", found);
        } catch (IOError e) {
            report ("enumerate", e);
        }
    }

    private void demo_application (string[] args) {
        var app = new Application ("org.planetos.GioDemo", ApplicationFlags.FLAGS_NONE);
        app.activate.connect ((sender) => {
            print ("gio:signal activate\n");
        });
        check ("app-run", app.run (args) == 0);
        string? id = app.get_application_id ();
        if (id == null) {
            check ("app-id", false);
        } else {
            print (@"gio:app-id $id\n");
            check ("app-id", id == "org.planetos.GioDemo");
        }
    }

    private int phase1_changed_events = 0;
    private bool phase1_fired = false;
    private int phase1_zoom = 0;

    private void demo_phase1_models () {
        var kf = new KeyFile ();
        try {
            kf.load_from_data ("[Desktop Entry]\nName=pcm4\nIconSize=48\nHidden=false\n");
            check ("kf-group", kf.has_group ("Desktop Entry"));
            check ("kf-str", kf.get_string ("Desktop Entry", "Name") == "pcm4");
            check ("kf-int", kf.get_integer ("Desktop Entry", "IconSize") == 48);
            check ("kf-bool", !kf.get_boolean ("Desktop Entry", "Hidden"));
            kf.set_integer ("Desktop Entry", "IconSize", 64);
            check ("kf-set-int", kf.get_integer ("Desktop Entry", "IconSize") == 64);
        } catch (KeyFileError e) {
            check ("kf-err", false);
        }

        var store = new ListStore<string> ();
        phase1_changed_events = 0;
        store.items_changed.connect ((s, pos, rem, add) => {
            phase1_changed_events = phase1_changed_events + 1;
        });
        store.append ("alpha");
        store.append ("gamma");
        store.insert (1, "beta");
        int found_pos = -1;
        check ("liststore-len", store.get_n_items () == 3);
        check ("liststore-find", store.find ("beta", out found_pos) && found_pos == 1);
        store.remove (1);
        check ("liststore-rem", store.get_n_items () == 2 && phase1_changed_events == 4);

        var act = new SimpleAction ("refresh", null);
        phase1_fired = false;
        act.activate.connect ((s, p) => {
            phase1_fired = true;
        });
        var grp = new SimpleActionGroup ();
        grp.add_action (act);
        grp.activate_action ("refresh", null);
        check ("simple-action", phase1_fired);

        var st_act = new SimpleAction.stateful ("zoom", VariantType.INT32 (), Variant.new_int32 (100));
        phase1_zoom = 0;
        st_act.activate.connect ((s, p) => {
            if (p != null) {
                phase1_zoom = p.get_int32 ();
                s.set_state (p);
            }
        });
        grp.add_action (st_act);
        grp.activate_action ("zoom", Variant.new_int32 (150));
        bool zoom_ok = (phase1_zoom == 150);
        Variant? st_cur = st_act.get_state ();
        if (st_cur == null || st_cur.get_int32 () != 150)
            zoom_ok = false;
        check ("variant-action", zoom_ok);

        var ai = AppInfo.get_default_for_type ("text/plain");
        check ("appinfo-mime", ai != null && ai.get_commandline () == "wc.elf");
    }

    private void demo_paths_bytes () {
        var pb = new PathBuf.from_path ("/a/b");
        pb.push ("c");
        check ("pathbuf-join", pb.to_path () == "/a/b/c");
        pb.pop ();
        check ("pathbuf-pop", pb.to_path () == "/a/b");
        pb.set_extension ("txt");
        check ("pathbuf-ext", pb.to_path () == "/a/b.txt");

        check ("byteswap16", GLib.swap16 ((uint16) 0x1234) == (uint16) 0x3412);
        check ("byteswap32", GLib.swap32 (0x12345678U) == 0x78563412U);
        check ("byteswap64", GLib.swap64 (0x0102030405060708UL) == 0x0807060504030201UL);
        check ("format-size", GLib.format_size (1000, FormatSizeFlags.DEFAULT).has_suffix ("kB"));

        var sv = new StrvBuilder ();
        sv.add ("a");
        sv.add ("b");
        var sv_arr = sv.end ();
        check ("strv-builder", sv_arr.length == 2 && sv_arr[1] == "b");

        var parts = Str.strsplit_set ("a,b;c", ",;");
        check ("strsplit-set", parts.length == 3 && parts[2] == "c");


    }

    int main (string[] args) {
        string target = "hello.txt";
        if (args.length > 1)
            target = args[1];

        print (@"gio:demo target=$target\n");
        var f = File.new_for_path (target);
        target_name = f.get_basename ();
        var parent = f.get_parent ();
        base_dir = (parent != null) ? parent.get_path () : ".";
        print (@"gio:path $(f.get_path()) base=$(f.get_basename())\n");
        bool exists = f.query_exists ();
        check ("exists", exists);

        if (exists) {
            demo_info (f);
            demo_read_lines (f);
            demo_seek (f);
            demo_cancellable (f);
        }
        demo_memory ();
        demo_paths_bytes ();
        demo_write (at ("gio_demo.tmp"));
        demo_contents (at ("gio_demo2.tmp"));
        demo_directories ();
        demo_enumerate ();
        demo_application (args);
        demo_phase1_models ();
        demo_io_api ();
        demo_planet_io ();
        demo_regex ();

        print (@"gio:summary checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
    }

    // /dev, Pollable, FileDescriptorBased, IOStream and CancellableSource.
    private void demo_io_api () {
        var dev = File.new_for_path ("/dev/console");
        check ("dev-exists", dev.query_exists ());
        InputStream ins;
        OutputStream outs;
        try {
            ins = dev.read ();
            outs = dev.append_to ();
        } catch (IOError e) {
            report ("dev-streams", e);
            return;
        }
        check ("dev-pollable-in", ins is PollableInputStream);
        check ("dev-fd", ins is FileDescriptorBased
                         && ((FileDescriptorBased) ins).get_fd () >= 3);
        check ("dev-pollable-out", outs is PollableOutputStream);
        check ("dev-writable", outs is PollableOutputStream
                              && ((PollableOutputStream) outs).is_writable ());
        var io = new SimpleIOStream (ins, outs);
        check ("io-stream", io.get_input_stream () == ins && io.get_output_stream () == outs);
        bool closed_ok = false;
        try {
            closed_ok = io.close ();
        } catch (IOError e) {
            closed_ok = false;
        }
        check ("io-close", closed_ok && io.is_closed ());

        // B1/B2: /dev/serial0 readiness-capable Pollable + LineDisciplineConverter
        var ser = File.new_for_path ("/dev/serial0");
        bool ser_ok = ser.query_exists ();
        if (ser_ok) {
            try {
                var sins = ser.read ();
                var souts = ser.append_to ();
                var scvt = new ConverterInputStream (sins, new LineDisciplineConverter (false));
                bool p_ok = (sins is PollableInputStream) && (sins is FileDescriptorBased)
                            && (souts is PollableOutputStream)
                            && ((PollableOutputStream) souts).is_writable ();
                ((PollableInputStream) sins).is_readable ();
                scvt.close ();
                souts.close ();
                ser_ok = p_ok && scvt.is_closed ();
            } catch (IOError e) {
                ser_ok = false;
            }
        }
        check ("dev-serial0", ser_ok);

        var c = new Cancellable ();
        SourceFunc on_cancel = () => {
            cancel_fired = cancel_fired + 1;
            return false;
        };
        var src = c.create_source (on_cancel);
        src.attach (MainContext.default_ ());
        c.cancel ();
        int guard = 0;
        while (cancel_fired == 0 && guard < 100) {
            MainContext.default_ ().iteration (false);
            Sys.sleep_ms (5);
            guard++;
        }
        check ("cancellable-source", cancel_fired == 1);
    }

    private int ring_fired = 0;

    private int svc_hits = 0;
    private string svc_msg = "";
    private int tsvc_tid = 0;
    private string tsvc_msg = "";

    private void on_demo_incoming (SocketConnection conn) {
        svc_hits = svc_hits + 1;
        var din = new DataInputStream (conn.get_input_stream ());
        try {
            int l1 = 0;
            string? line = din.read_line (out l1);
            svc_msg = line ?? "";
            var dout = new DataOutputStream (conn.get_output_stream ());
            dout.put_string ("pong\n");
            conn.close ();
        } catch (IOError e) {
        }
    }

    private void on_threaded_run (SocketConnection conn) {
        tsvc_tid = Sys.tid ();
        var din = new DataInputStream (conn.get_input_stream ());
        try {
            int l1 = 0;
            string? line = din.read_line (out l1);
            tsvc_msg = line ?? "";
            var dout = new DataOutputStream (conn.get_output_stream ());
            dout.put_string ("ack-thread\n");
            conn.close ();
        } catch (IOError e) {
        }
    }

    private void demo_planet_io () {
        int null_fd = Sys.open ("/dev/null");
        if (null_fd >= 3) {
            var p_out = new PlanetOutputStream (null_fd, true);
            var p_in = new PlanetInputStream (null_fd, false);
            bool w_ok = false;
            try {
                var payload = new uint8[4];
                payload[0] = (uint8) 'p';
                w_ok = p_out.write (payload) == 4;
                p_out.close ();
            } catch (IOError e) {
                w_ok = false;
            }
            check ("planet-stream-write", w_ok && p_in.get_fd () == null_fd);
            check ("planet-stream-pollable", (p_out is PollableOutputStream) && (p_in is PollableInputStream));
        } else {
            check ("planet-stream-write", false);
            check ("planet-stream-pollable", false);
        }

        try {
            var ring = PlanetRing.create (1, 2);
            int[] pfd = new int[1];
            pfd[0] = ring.get_fd ();
            bool poll_before = Sys.poll_n (pfd, 1, 0) == 0;
            ring_fired = 0;
            var rsrc = ring.create_source (() => {
                ring_fired = ring_fired + 1;
                return false;
            });
            rsrc.attach (MainContext.default_ ());
            int buf = ring.grant.base_addr + ring.data_offset;
            ring.grant.put_u8 (ring.data_offset, 0);
            int slot = ring.submit (buf, 8, PlanetRing.OP_WRITE, 1);
            ring.kick ();
            bool poll_after = Sys.poll_n (pfd, 1, 0) == 1;
            check ("planet-ring-poll", poll_before && poll_after);
            int st = ring.slot_status (slot);
            int val = ring.grant.get_u8 (ring.data_offset);
            bool ring_ok = st == PlanetRing.ST_DONE && ring.seq () > 0 && !ring.has_pending () && val == 0xA5;
            check ("planet-ring-kick", ring_ok);
            MainContext.default_ ().iteration (false);
            check ("planet-ring-source", ring_fired == 1);
            ring.close ();
            check ("planet-ring-close", ring.ring_handle == -1 && ring.grant.handle == -1);
        } catch (IOError e) {
            check ("planet-ring-poll", false);
            check ("planet-ring-kick", false);
            check ("planet-ring-source", false);
            check ("planet-ring-close", false);
        }

        try {
            var arena = PlanetIoArena.create (1, 512);
            int lid = arena.acquire_lease ();
            bool l_ok = lid >= 0 && arena.lease_state (lid) == PlanetIoArena.LEASE_APP
                        && arena.mark_device (lid)
                        && arena.lease_state (lid) == PlanetIoArena.LEASE_DEVICE
                        && !arena.release_lease (lid);
            check ("planet-arena-device-lock", l_ok);
            bool q_ok = !arena.close () && arena.quarantined && arena.acquire_lease () == -1;
            check ("planet-arena-quarantine", q_ok);
            bool rel_ok = arena.mark_app (lid) && arena.release_lease (lid) && arena.close ();
            check ("planet-arena-release", rel_ok);
        } catch (IOError e) {
            check ("planet-arena-device-lock", false);
            check ("planet-arena-quarantine", false);
            check ("planet-arena-release", false);
        }

        // Phase D: kernel-side ring header-overlap & duplicate-lease enforcement
        try {
            var dring = PlanetRing.create (1, 4, PlanetRing.DEV_ECHO);
            int hdr_slot = dring.submit (dring.grant.base_addr, 8, PlanetRing.OP_WRITE, 1);
            bool hdr_rejected = false;
            try {
                dring.kick ();
            } catch (IOError e) {
                hdr_rejected = (dring.slot_status (hdr_slot) == PlanetRing.ST_ERROR);
            }
            check ("planet-ring-d-hdr-guard", hdr_rejected);
            dring.close ();

            var dring2 = PlanetRing.create (1, 4, PlanetRing.DEV_ECHO);
            int dbuf = dring2.grant.base_addr + dring2.data_offset;
            dring2.submit (dbuf, 8, PlanetRing.OP_WRITE, 7);
            int dup_slot = dring2.submit (dbuf + 64, 8, PlanetRing.OP_WRITE, 7);
            bool dup_rejected = false;
            try {
                dring2.kick ();
            } catch (IOError e) {
                dup_rejected = (dring2.slot_status (dup_slot) == PlanetRing.ST_ERROR);
            }
            bool free_blocked = (Sys.free_page (dring2.grant.base_addr) < 0);
            check ("planet-ring-d-lease-guard", dup_rejected && free_blocked);
            dring2.close ();
        } catch (IOError e) {
            check ("planet-ring-d-hdr-guard", false);
            check ("planet-ring-d-lease-guard", false);
        }

        try {
            var blk = PlanetBlockDevice.open (2, 4);
            var sec0 = new uint8[512];
            int nb = blk.read_sectors (0, 1, sec0);
            bool xfs_ok = nb == 512 && sec0[0] == 0x58 && sec0[1] == 0x46
                          && sec0[2] == 0x53 && sec0[3] == 0x42; // "XFSB"
            check ("planet-blk-ring", xfs_ok);
            blk.close ();
        } catch (IOError e) {
            check ("planet-blk-ring", false);
        }

        // C3.2: SYS_HANDLE_SEND / SYS_HANDLE_RECV / PlanetConnection zero-copy IPC
        try {
            var conn = PlanetConnection.create (1);
            int nh = conn.send_to (Sys.tid ());
            var peer = PlanetConnection.accept_from_inbox ();
            bool ipc_ok = false;
            if (nh > 0 && peer != null) {
                var p = (!) peer;
                uint8[] req = { (uint8) 'p', (uint8) 'i', (uint8) 'n', (uint8) 'g' };
                conn.write_request (req);
                uint8[]? got_req = p.read_request ();
                if (got_req != null && ((!) got_req).length == 4 && ((!) got_req)[0] == (uint8) 'p') {
                    uint8[] resp = { (uint8) 'p', (uint8) 'o', (uint8) 'n', (uint8) 'g' };
                    p.write_response (resp);
                    uint8[]? got_resp = conn.read_response ();
                    ipc_ok = got_resp != null && ((!) got_resp).length == 4
                             && ((!) got_resp)[0] == (uint8) 'p' && ((!) got_resp)[1] == (uint8) 'o';
                }
                p.close ();
            }
            bool bad_send = (Sys.handle_send (-1, conn.grant.handle) < 0);
            conn.close ();
            check ("planet-conn-ipc", ipc_ok && bad_send);
        } catch (IOError e) {
            check ("planet-conn-ipc", false);
        }

        try {
            var ip = InetAddress.new_from_string ("10.0.2.15");
            var isa = new InetSocketAddress.from_string ("10.0.2.2", 8080);
            check ("gio-net-addr", ip != null && ((!) ip).to_string () == "10.0.2.15"
                                   && isa.to_string () == "10.0.2.2:8080");
            var cli = new SocketClient ();
            var conn = cli.connect_to_host ("10.0.2.2:80", 80);
            check ("gio-net-socket", conn.get_socket ().is_connected ());
            conn.close ();

            var svc = new SocketService ();
            uint16 port = svc.add_any_inet_port ();
            svc_hits = 0;
            svc_msg = "";
            svc.incoming.connect ((sender, c, obj) => {
                on_demo_incoming (c);
                return false;
            });
            svc.start ();
            var c2 = cli.connect_to_host (@"127.0.0.1:$port", port);
            var dout = new DataOutputStream (c2.get_output_stream ());
            dout.put_string ("ping\n");
            MainContext.default_ ().iteration (false);
            var din = new DataInputStream (c2.get_input_stream ());
            int l2 = 0;
            string? reply = din.read_line (out l2);
            check ("gio-socket-service", svc_hits == 1 && svc_msg == "ping" && reply == "pong");
            c2.close ();
            svc.stop ();
            svc.close ();

            var tsvc = new ThreadedSocketService (2);
            uint16 tport = tsvc.add_any_inet_port ();
            tsvc_tid = 0;
            tsvc_msg = "";
            tsvc.run.connect ((sender, c, obj) => {
                on_threaded_run (c);
                return false;
            });
            tsvc.start ();
            var c3 = cli.connect_to_host (@"127.0.0.1:$tport", tport);
            var dout3 = new DataOutputStream (c3.get_output_stream ());
            dout3.put_string ("hello-thread\n");
            MainContext.default_ ().iteration (false);
            var din3 = new DataInputStream (c3.get_input_stream ());
            string? reply3 = null;
            for (int w = 0; w < 100; w++) {
                int l3 = 0;
                reply3 = din3.read_line (out l3);
                if (reply3 != null && ((!) reply3).length > 0)
                    break;
                Sys.sleep_ms (5);
            }
            check ("gio-threaded-socket-service",
                   tsvc_tid > 0 && tsvc_tid != Sys.tid ()
                   && tsvc_msg == "hello-thread" && reply3 == "ack-thread");
            c3.close ();
            tsvc.stop ();
            tsvc.close ();
        } catch (IOError e) {
            check ("gio-net-addr", false);
            check ("gio-net-socket", false);
            check ("gio-socket-service", false);
            check ("gio-threaded-socket-service", false);
        }

        // ConverterInputStream + LineDisciplineConverter (CRLF -> LF)
        try {
            var ms = new MemoryInputStream ();
            ms.add_data ("a\r\nb\rc\n".data);
            var cin = new ConverterInputStream (ms, new LineDisciplineConverter (false));
            var cbuf = cin.read_bytes (16);
            string norm = "";
            for (int i = 0; i < cbuf.length; i++) {
                var ch = new uint8[1];
                ch[0] = cbuf[i];
                norm = norm + ((cbuf[i] == '\n') ? "\\n" : "x");
            }
            check ("gio-converter", norm == "x\\nx\\nx\\n");
        } catch (IOError e) {
            check ("gio-converter", false);
        }

        // Subprocess (spawn worker.elf + communicate_utf8)
        try {
            string[] argv = new string[1];
            argv[0] = "worker.elf";
            var sub = new Subprocess.newv (argv, SubprocessFlags.NONE);
            string? sout = null;
            string? serr = null;
            sub.communicate_utf8 (null, null, out sout, out serr);
            check ("gio-subprocess", sub.get_if_exited () && sub.get_exit_status () == 7);
        } catch (IOError e) {
            check ("gio-subprocess", false);
        }

        // Resolver + NetworkService
        try {
            var res = Resolver.get_default ().lookup_by_name ("localhost");
            var ns = new NetworkService ("mercury", "tcp", "gateway");
            var resolved = ns.resolve_first ();
            bool r_ok = false;
            if (res.length == 1 && res[0].to_string () == "127.0.0.1" && resolved != null) {
                SocketAddress r_addr = (!) resolved;
                var r_ia = r_addr.get_inet_address ();
                r_ok = r_addr.get_port () == 5000 && r_ia != null
                       && ((!) r_ia).to_string () == "10.0.2.2";
            }
            check ("gio-resolver-service", r_ok);
        } catch (IOError e) {
            check ("gio-resolver-service", false);
        }

        // UDP Datagram Socket (send_to / receive_from)
        try {
            var srv = new Socket (SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
            srv.bind (new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0), true);
            var srv_addr = srv.get_local_address ();
            var cli_d = new Socket (SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
            var msg = new uint8[3];
            msg[0] = (uint8) 'u';
            msg[1] = (uint8) 'd';
            msg[2] = (uint8) 'p';
            int sent = cli_d.send_to (srv_addr, msg);
            var rbuf = new uint8[8];
            SocketAddress? from_addr = null;
            int got = srv.receive_from (out from_addr, rbuf);
            check ("gio-udp-dgram", sent == 3 && got == 3 && rbuf[0] == (uint8) 'u' && rbuf[2] == (uint8) 'p');
            cli_d.close ();
            srv.close ();
        } catch (IOError e) {
            check ("gio-udp-dgram", false);
        }

        // C3.3: TcpConnection + graceful_disconnect + Socket.shutdown
        try {
            var listener = new SocketListener ();
            uint16 tport = listener.add_any_inet_port ();

            var tcli = new SocketClient ();
            tcli.protocol = SocketProtocol.TCP;
            var tc = tcli.connect_to_host (@"127.0.0.1:$tport", tport);
            Object? sobj = null;
            var ts = listener.accept (out sobj);
            var ts_sock = ts.get_socket ();
            ts_sock.shutdown (false, true);
            bool close_ok = tc.close () && ts.close ();

            var direct_sock = new Socket (SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
            var direct_tcp = new TcpConnection (direct_sock);
            direct_tcp.set_graceful_disconnect (true);
            bool gd_ok = direct_tcp.get_graceful_disconnect () && direct_tcp.graceful_disconnect;
            direct_tcp.close ();
            listener.close ();
            check ("gio-tcp-connection", gd_ok && close_ok && tc.is_closed ());
        } catch (IOError e) {
            check ("gio-tcp-connection", false);
        }

        // TLS 1.3 (BoringSSL-inspired: X25519 + ChaCha20-Poly1305 + SHA-256 + HKDF + TlsBackend/TlsClientConnection)
        var tb = TlsBackend.get_default ();
        bool cert_ok = false;
        try {
            var cert = new TlsCertificate.from_pem ("-----BEGIN CERTIFICATE-----\nCN=localhost\n-----END CERTIFICATE-----\n");
            var id = new NetworkAddress ("localhost", 443);
            cert_ok = (cert.verify (id, cert) == TlsCertificateFlags.NONE);
        } catch (Error e) {
            cert_ok = false;
        }
        check ("gio-tls-backend", tb.supports_tls () && cert_ok);

        // RFC 7748 X25519 + RFC 8439 ChaCha20-Poly1305 round-trip
        uint8[] k_a = new uint8[32];
        uint8[] k_b = new uint8[32];
        TlsCrypto.random_bytes (k_a);
        TlsCrypto.random_bytes (k_b);
        var pub_a = TlsCrypto.x25519_public (k_a);
        var pub_b = TlsCrypto.x25519_public (k_b);
        var ss_a = TlsCrypto.x25519_scalarmult (k_a, pub_b);
        var ss_b = TlsCrypto.x25519_scalarmult (k_b, pub_a);
        bool dh_ok = TlsCrypto.ct_memcmp (ss_a, 0, ss_b, 0, 32);
        uint8[] nonce = new uint8[12];
        uint8[] aad = { 0x17, 0x03, 0x03, 0x00, 0x15 };
        uint8[] pt = { (uint8) 'h', (uint8) 'e', (uint8) 'l', (uint8) 'l', (uint8) 'o' };
        var ct = TlsCrypto.aead_seal (ss_a, nonce, aad, pt);
        uint8[]? dec = TlsCrypto.aead_open (ss_b, nonce, aad, ct);
        bool aead_ok = dh_ok && dec != null && ((!) dec).length == 5 && ((!) dec)[0] == (uint8) 'h';
        check ("gio-tls-x25519-aead", aead_ok);

        // Full TLS 1.3 handshake + encrypted stream over TlsServerConnection <-> TlsClientConnection
        bool tls_hs_ok = false;
        try {
            var tlis = new SocketListener ();
            uint16 tls_port = tlis.add_any_inet_port ();
            var srv_thread = new Thread ("tls-srv", () => {
                try {
                    for (int w = 0; w < 100; w++) {
                        try {
                            Object? o = null;
                            var sc = tlis.accept (out o);
                            var tsrv = TlsServerConnection.create (sc);
                            tsrv.handshake ();
                            var din = new DataInputStream (tsrv.get_input_stream ());
                            int l = 0;
                            string? line = din.read_line (out l);
                            if (line == "secret-ping") {
                                var dout = new DataOutputStream (tsrv.get_output_stream ());
                                dout.put_string ("secret-pong\n");
                            }
                            tsrv.close ();
                            break;
                        } catch (IOError we) {
                            Sys.sleep_ms (5);
                        }
                    }
                } catch (Error e) {
                }
                return null;
            });
            var tcli = new SocketClient ();
            var base_c = tcli.connect_to_host (@"127.0.0.1:$tls_port", tls_port);
            var tls_cli = TlsClientConnection.create (base_c, new NetworkAddress ("localhost", tls_port));
            tls_cli.handshake ();
            var cdout = new DataOutputStream (tls_cli.get_output_stream ());
            cdout.put_string ("secret-ping\n");
            var cdin = new DataInputStream (tls_cli.get_input_stream ());
            int cl = 0;
            string? creply = cdin.read_line (out cl);
            tls_hs_ok = (creply == "secret-pong");
            tls_cli.close ();
            srv_thread.join ();
            tlis.close ();
        } catch (Error e) {
            tls_hs_ok = false;
        }
        check ("gio-tls-handshake", tls_hs_ok);
    }

    private void demo_regex () {
        try {
            var re = new Regex ("\\d+");
            MatchInfo? mi = null;
            bool ok = re.match ("id=42 port=8080", out mi);
            check ("regex-match", ok && mi != null && mi.matches () && mi.fetch (0) == "42");
            check ("regex-next", mi != null && mi.next () && mi.fetch (0) == "8080");
            check ("regex-end", mi != null && !mi.next ());
            check ("regex-anchor", Regex.match_simple ("^[a-z]+$", "planet") && !Regex.match_simple ("^[a-z]+$", "planet9"));
            check ("regex-class", Regex.match_simple ("[A-Z][0-9]+", "v2 X99"));
            check ("regex-replace", re.replace ("a1b22", "#") == "a#b#");
        } catch (RegexError e) {
            check ("regex-compile", false);
        }
    }
}
