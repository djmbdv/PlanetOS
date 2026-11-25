// Pure-Vala Gio.Subprocess and Gio.SubprocessLauncher over PlanetOS Sys.spawn/set_stdio/wait/kill.
using GLib;
using Planet;

namespace Gio {

    public enum SubprocessFlags {
        NONE = 0,
        STDIN_PIPE = 1,
        STDIN_INHERIT = 2,
        STDOUT_PIPE = 4,
        STDOUT_SILENCE = 8,
        STDERR_PIPE = 16,
        STDERR_SILENCE = 32,
        STDERR_MERGE = 64
    }

    public class Subprocess : Object {
        private static int next_seq = 1;

        private int tid = -1;
        private SubprocessFlags flags;
        private bool waited = false;
        private int exit_status = -1;
        private string? stdout_path = null;
        private string? stdin_path = null;
        private InputStream? stdout_stream = null;
        private OutputStream? stdin_stream = null;

        public Subprocess.newv (string[] argv, SubprocessFlags flags) throws IOError {
            var launcher = new SubprocessLauncher (flags);
            var sub = launcher.spawnv (argv);
            this.tid = sub.tid;
            this.flags = sub.flags;
            this.stdout_path = sub.stdout_path;
            this.stdin_path = sub.stdin_path;
            sub.tid = -1;
            sub.stdout_path = null;
            sub.stdin_path = null;
        }

        internal Subprocess.with_tid (int tid, SubprocessFlags flags, string? stdout_path, string? stdin_path) {
            this.tid = tid;
            this.flags = flags;
            this.stdout_path = stdout_path;
            this.stdin_path = stdin_path;
        }

        ~Subprocess () {
            cleanup_temp ();
        }

        internal static int alloc_seq () {
            return next_seq++;
        }

        private void cleanup_temp () {
            if (stdout_path != null) {
                Sys.unlink ((!) stdout_path);
                stdout_path = null;
            }
            if (stdin_path != null) {
                Sys.unlink ((!) stdin_path);
                stdin_path = null;
            }
        }

        public int get_tid () {
            return tid;
        }

        public string? get_identifier () {
            if (tid <= 0)
                return null;
            return @"$tid";
        }

        public bool wait (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Subprocess.wait cancelled");
            if (waited)
                return true;
            if (tid <= 0)
                throw new IOError.INVALID_ARGUMENT ("Subprocess has invalid tid");
            exit_status = Sys.wait (tid);
            waited = true;
            return true;
        }

        public bool wait_check (Cancellable? cancellable = null) throws IOError {
            wait (cancellable);
            if (exit_status != 0)
                throw new IOError.FAILED (@"Subprocess exited with status $exit_status");
            return true;
        }

        public bool get_if_exited () {
            if (!waited && tid > 0) {
                int st = Sys.wait_nb (tid);
                if (st != -1) {
                    exit_status = st;
                    waited = true;
                }
            }
            return waited;
        }

        public bool get_successful () {
            return waited && exit_status == 0;
        }

        public int get_exit_status () {
            return exit_status;
        }

        public void force_exit () {
            if (tid > 0 && !waited) {
                Sys.kill (tid);
                exit_status = -1;
                waited = true;
            }
        }

        public InputStream? get_stdout_pipe () {
            if (stdout_stream == null && stdout_path != null) {
                try {
                    stdout_stream = File.new_for_path ((!) stdout_path).read ();
                } catch (IOError e) {
                    return null;
                }
            }
            return stdout_stream;
        }

        public OutputStream? get_stdin_pipe () {
            if (stdin_stream == null && stdin_path != null) {
                try {
                    stdin_stream = File.new_for_path ((!) stdin_path).replace ();
                } catch (IOError e) {
                    return null;
                }
            }
            return stdin_stream;
        }

        public bool communicate_utf8 (string? stdin_buf, Cancellable? cancellable,
                                      out string? stdout_buf, out string? stderr_buf) throws IOError {
            stdout_buf = null;
            stderr_buf = null;
            wait (cancellable);
            if (stdout_path != null) {
                string txt = "";
                if (FileUtils.get_contents ((!) stdout_path, out txt))
                    stdout_buf = txt;
                else
                    stdout_buf = "";
            }
            return true;
        }
    }

    public class SubprocessLauncher : Object {
        private SubprocessFlags flags;
        private string? cwd = null;

        public SubprocessLauncher (SubprocessFlags flags) {
            this.flags = flags;
        }

        public void set_flags (SubprocessFlags flags) {
            this.flags = flags;
        }

        public void set_cwd (string cwd) {
            this.cwd = cwd;
        }

        public void setenv (string variable, string value, bool overwrite) {
            Environment.set_variable (variable, value, overwrite);
        }

        public Subprocess spawnv (string[] argv) throws IOError {
            if (argv.length == 0)
                throw new IOError.INVALID_ARGUMENT ("SubprocessLauncher.spawnv: empty argv");

            string exe = argv[0];
            string cmdline = "";
            for (int i = 0; i < argv.length; i++) {
                if (i > 0)
                    cmdline = cmdline + " ";
                cmdline = cmdline + argv[i];
            }

            int seq = Subprocess.alloc_seq ();
            int in_fd = -1;
            int out_fd = -1;
            string? out_path = null;
            string? in_path = null;

            if ((flags & SubprocessFlags.STDOUT_PIPE) != 0) {
                out_path = @"/sub_out_$seq.tmp";
                out_fd = Sys.create ((!) out_path);
                if (out_fd < 0)
                    throw_io_error ("SubprocessLauncher(stdout_pipe)");
            } else if ((flags & SubprocessFlags.STDOUT_SILENCE) != 0) {
                out_fd = Sys.open ("/dev/null");
            }

            if ((flags & SubprocessFlags.STDIN_PIPE) != 0) {
                in_path = @"/sub_in_$seq.tmp";
                int tmp_w = Sys.create ((!) in_path);
                if (tmp_w >= 0)
                    Sys.close (tmp_w);
                in_fd = Sys.open ((!) in_path);
            }

            if (in_fd >= 0 || out_fd >= 0)
                Sys.set_stdio (in_fd, out_fd);

            int tid = Sys.spawn (exe, cmdline);

            if (in_fd >= 0 || out_fd >= 0)
                Sys.set_stdio (-1, -1);
            if (out_fd >= 3)
                Sys.close (out_fd);
            if (in_fd >= 3)
                Sys.close (in_fd);

            if (tid <= 0) {
                if (out_path != null) Sys.unlink ((!) out_path);
                if (in_path != null) Sys.unlink ((!) in_path);
                throw_io_error (@"SubprocessLauncher.spawnv($exe)");
            }

            return new Subprocess.with_tid (tid, flags, out_path, in_path);
        }
    }
}
