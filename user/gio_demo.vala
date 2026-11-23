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
        demo_regex ();

        print (@"gio:summary checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
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
