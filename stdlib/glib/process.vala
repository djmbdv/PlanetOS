// Pure-Vala GLib.Process, SpawnError, SpawnFlags, and ProcessSignal (non-deprecated API).
using Planet;

namespace GLib {

    public errordomain SpawnError {
        FORK,
        READ,
        CHDIR,
        ACCES,
        PERM,
        TOO_BIG,
        NOEXEC,
        NAMETOOLONG,
        NOENT,
        NOMEM,
        NOTDIR,
        LOOP,
        TXTBUSY,
        IO,
        NFILE,
        MFILE,
        INVAL,
        ISDIR,
        LIBBAD,
        FAILED
    }

    public enum SpawnFlags {
        DEFAULT = 0,
        LEAVE_DESCRIPTORS_OPEN = 1,
        DO_NOT_REAP_CHILD = 2,
        SEARCH_PATH = 4,
        STDOUT_TO_DEV_NULL = 8,
        STDERR_TO_DEV_NULL = 16,
        CHILD_INHERITS_STDIN = 32,
        FILE_AND_ARGV_ZERO = 64,
        SEARCH_PATH_FROM_ENVP = 128,
        CLOEXEC_PIPES = 256
    }

    public enum ProcessSignal {
        HUP = 1,
        INT = 2,
        QUIT = 3,
        ILL = 4,
        TRAP = 5,
        ABRT = 6,
        BUS = 7,
        FPE = 8,
        KILL = 9,
        SEGV = 11,
        PIPE = 13,
        ALRM = 14,
        TERM = 15,
        USR1 = 10,
        USR2 = 12,
        CHLD = 17,
        CONT = 18,
        STOP = 19,
        TSTP = 20,
        TTIN = 21,
        TTOU = 22
    }

    public delegate void SpawnChildSetupFunc ();

    public class Process : Object {

        private static string join_cmdline (string[] argv) {
            var sb = new StringBuilder ();
            for (int i = 0; i < argv.length; i++) {
                if (i > 0)
                    sb.append_c (' ');
                string arg = argv[i];
                bool need_quote = (arg.length == 0);
                for (int k = 0; k < arg.length && !need_quote; k++) {
                    uint8 c = arg[k];
                    if (c == ' ' || c == '\t' || c == '"' || c == '\'' || c == '\\')
                        need_quote = true;
                }
                if (!need_quote) {
                    sb.append (arg);
                } else {
                    sb.append_c ('"');
                    for (int k = 0; k < arg.length; k++) {
                        uint8 c = arg[k];
                        if (c == '"' || c == '\\')
                            sb.append_c ('\\');
                        sb.append_c ((char) c);
                    }
                    sb.append_c ('"');
                }
            }
            return sb.str;
        }

        public static string[] split_command_line (string command_line) throws SpawnError {
            string[] argv;
            try {
                Shell.parse_argv (command_line, out argv);
            } catch (ShellError e) {
                throw new SpawnError.INVAL (e.message);
            }
            return argv;
        }

        public static bool spawn_async (string? working_directory, string[] argv, string[]? envp, SpawnFlags flags, SpawnChildSetupFunc? child_setup, out int child_pid) throws SpawnError {
            child_pid = 0;
            if (argv.length == 0 || argv[0].length == 0)
                throw new SpawnError.INVAL ("Empty argv");
            string prog = argv[0];
            if (prog.has_prefix ("/"))
                prog = prog.substring (1);
            if (prog.length == 0)
                throw new SpawnError.INVAL ("Invalid program path");
            string cmdline = join_cmdline (argv);
            if (child_setup != null)
                child_setup ();
            int tid = Sys.spawn (prog, cmdline);
            if (tid < 0)
                throw new SpawnError.NOENT (@"Failed to spawn '$(argv[0])'");
            child_pid = tid;
            return true;
        }

        public static bool spawn_async_with_fds (string? working_directory, string[] argv, string[]? envp, SpawnFlags flags, SpawnChildSetupFunc? child_setup, out int child_pid, int stdin_fd = -1, int stdout_fd = -1, int stderr_fd = -1) throws SpawnError {
            if (stdin_fd >= 0 || stdout_fd >= 0 || stderr_fd >= 0)
                throw new SpawnError.INVAL ("Custom fd redirection is not supported on PlanetOS");
            return spawn_async (working_directory, argv, envp, flags, child_setup, out child_pid);
        }

        public static bool spawn_async_with_pipes (string? working_directory, string[] argv, string[]? envp, SpawnFlags flags, SpawnChildSetupFunc? child_setup, out int child_pid, out int standard_input, out int standard_output, out int standard_error) throws SpawnError {
            child_pid = 0;
            standard_input = -1;
            standard_output = -1;
            standard_error = -1;
            return spawn_async (working_directory, argv, envp, flags, child_setup, out child_pid);
        }

        public static bool spawn_sync (string? working_directory, string[] argv, string[]? envp, SpawnFlags flags, SpawnChildSetupFunc? child_setup, out string standard_output, out string standard_error, out int wait_status) throws SpawnError {
            standard_output = "";
            standard_error = "";
            wait_status = 0;
            int pid = 0;
            spawn_async (working_directory, argv, envp, flags, child_setup, out pid);
            int code = Sys.wait (pid);
            if (code < 0)
                wait_status = 15; // signaled / wait failed
            else
                wait_status = (code & 0xFF) << 8;
            return true;
        }

        public static bool spawn_command_line_async (string command_line) throws SpawnError {
            var argv = split_command_line (command_line);
            int pid = 0;
            return spawn_async (null, argv, null, SpawnFlags.SEARCH_PATH, null, out pid);
        }

        public static bool spawn_command_line_sync (string command_line, out string standard_output, out string standard_error, out int wait_status) throws SpawnError {
            var argv = split_command_line (command_line);
            return spawn_sync (null, argv, null, SpawnFlags.SEARCH_PATH, null, out standard_output, out standard_error, out wait_status);
        }

        public static void close_pid (int pid) {
            // PlanetOS task IDs do not hold a separate descriptor.
        }

        public static bool check_wait_status (int wait_status) throws SpawnError {
            if (if_exited (wait_status)) {
                int code = exit_status (wait_status);
                if (code == 0)
                    return true;
                throw new SpawnError.FAILED (@"Child process exited with code $code");
            }
            if (if_signaled (wait_status)) {
                int sig = (int) term_sig (wait_status);
                throw new SpawnError.FAILED (@"Child process killed by signal $sig");
            }
            throw new SpawnError.FAILED ("Child process did not exit normally");
        }

        public static bool if_exited (int status) {
            return (status & 0x7F) == 0;
        }

        public static int exit_status (int status) {
            return (status >> 8) & 0xFF;
        }

        public static bool if_signaled (int status) {
            int low = status & 0x7F;
            return low != 0 && low != 0x7F;
        }

        public static ProcessSignal term_sig (int status) {
            return (ProcessSignal) (status & 0x7F);
        }

        public static bool core_dump (int status) {
            return (status & 0x80) != 0;
        }

        public static bool if_stopped (int status) {
            return (status & 0xFF) == 0x7F;
        }

        public static ProcessSignal stop_sig (int status) {
            return (ProcessSignal) ((status >> 8) & 0xFF);
        }

        public static bool if_continued (int status) {
            return status == 0xFFFF;
        }

        public static void abort () {
            exit (134);
        }

        public static void exit (int status) {
            exit (status);
        }

        public static int raise (ProcessSignal sig) {
            if (sig == ProcessSignal.ABRT || sig == ProcessSignal.KILL
                || sig == ProcessSignal.TERM || sig == ProcessSignal.INT
                || sig == ProcessSignal.QUIT || sig == ProcessSignal.SEGV) {
                exit (128 + (int) sig);
            }
            return 0;
        }
    }

}
