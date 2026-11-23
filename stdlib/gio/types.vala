// Pure-Vala Gio error domain, enums, and Cancellable.
using GLib;
using Planet;

namespace Gio {

    public errordomain IOError {
        FAILED,
        NOT_FOUND,
        EXISTS,
        IS_DIRECTORY,
        NOT_DIRECTORY,
        NOT_EMPTY,
        NOT_REGULAR_FILE,
        PERMISSION_DENIED,
        INVALID_ARGUMENT,
        NOT_SUPPORTED,
        TIMED_OUT,
        WOULD_BLOCK,
        PARTIAL_INPUT,
        INVALID_DATA,
        HOST_NOT_FOUND,
        CONNECTION_REFUSED,
        BROKEN_PIPE,
        BUSY,
        PENDING,
        CANCELLED,
        CLOSED
    }

    public enum FileType {
        UNKNOWN,
        REGULAR,
        DIRECTORY,
        SYMBOLIC_LINK,
        SPECIAL,
        SHORTCUT,
        MOUNTABLE
    }

    // Converts the kernel errno (SYS_ERRNO) into the closest IOError member.
    public static void throw_io_error (string what) throws IOError {
        int e = Sys.errno_code ();
        string msg = @"$what: $(Sys.strerror (e))";
        if (e == Sys.ENOENT)
            throw new IOError.NOT_FOUND (msg);
        if (e == Sys.EACCES)
            throw new IOError.PERMISSION_DENIED (msg);
        if (e == Sys.EEXIST)
            throw new IOError.EXISTS (msg);
        if (e == Sys.EISDIR)
            throw new IOError.IS_DIRECTORY (msg);
        if (e == Sys.ENOTDIR)
            throw new IOError.NOT_DIRECTORY (msg);
        if (e == Sys.EINVAL)
            throw new IOError.INVALID_ARGUMENT (msg);
        if (e == Sys.ETIMEDOUT)
            throw new IOError.TIMED_OUT (msg);
        if (e == Sys.EPIPE)
            throw new IOError.BROKEN_PIPE (msg);
        throw new IOError.FAILED (msg);
    }

    public enum FileQueryInfoFlags {
        NONE,
        NOFOLLOW_SYMLINKS
    }

    public enum FileCreateFlags {
        NONE,
        PRIVATE,
        REPLACE_DESTINATION
    }

    public enum FileCopyFlags {
        NONE,
        OVERWRITE,
        BACKUP,
        NOFOLLOW_SYMLINKS,
        ALL_METADATA,
        NO_FALLBACK_FOR_MOVE,
        TARGET_DEFAULT_PERMS
    }

    public enum SeekType {
        CUR,
        SET,
        END
    }

    public enum DataStreamByteOrder {
        BIG_ENDIAN,
        LITTLE_ENDIAN,
        HOST_ENDIAN
    }

    public enum DataStreamNewlineType {
        LF,
        CR,
        CR_LF,
        ANY
    }

    public enum OutputStreamSpliceFlags {
        NONE,
        CLOSE_SOURCE,
        CLOSE_TARGET
    }

    public enum ApplicationFlags {
        FLAGS_NONE,
        HANDLES_OPEN,
        HANDLES_COMMAND_LINE,
        SEND_ENVIRONMENT,
        NON_UNIQUE,
        IS_SERVICE,
        IS_LAUNCHER,
        ALLOW_REPLACEMENT,
        REPLACE
    }

    public interface Seekable : Object {
        public abstract int tell ();
        public abstract bool can_seek ();
        public abstract bool seek (int offset, SeekType type, Cancellable? cancellable = null) throws IOError;
        public abstract bool can_truncate ();
        public abstract bool truncate (int offset, Cancellable? cancellable = null) throws IOError;
    }

    public class Cancellable : Object {
        private bool cancelled = false;

        public Cancellable () {}

        public bool is_cancelled () {
            return cancelled;
        }

        public void cancel () {
            cancelled = true;
        }

        public void reset () {
            cancelled = false;
        }

        public bool set_error_if_cancelled () throws IOError {
            if (cancelled)
                throw new IOError.CANCELLED ("Operation was cancelled");
            return false;
        }
    }

}
