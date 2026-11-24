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

    public interface FileDescriptorBased : Object {
        public abstract int get_fd ();
    }

    public interface PollableInputStream : Object {
        public abstract bool is_readable ();
        public abstract Source create_source (Cancellable? cancellable = null);
    }

    public interface PollableOutputStream : Object {
        public abstract bool is_writable ();
        public abstract Source create_source (Cancellable? cancellable = null);
    }

    public class Cancellable : Object {
        private bool cancel_flag = false;

        public Cancellable () {}

        public signal void cancelled ();

        public bool is_cancelled () {
            return cancel_flag;
        }

        public void cancel () {
            if (cancel_flag)
                return;
            cancel_flag = true;
            cancelled ();
        }

        public void reset () {
            cancel_flag = false;
        }

        public bool set_error_if_cancelled () throws IOError {
            if (cancel_flag)
                throw new IOError.CANCELLED ("Operation was cancelled");
            return false;
        }

        // Source that fires `func` once the cancellable is cancelled. It polls
        // every 10 ms: a futex-backed source needs the futex waiter to expose a
        // pollable handle (Phase B2 of docs/08). `this` is held through the
        // handler record, not captured by the closure.
        public Source create_source (SourceFunc func) {
            var h = new CancelSourceData ();
            h.func = func;
            h.owner = this;
            var src = new Source (0, Source.KIND_TIMEOUT, 10, 0, () => {
                if (!h.owner.is_cancelled ())
                    return true;
                return h.func ();
            });
            return src;
        }
    }

    private class CancelSourceData : Object {
        public SourceFunc func;
        public Cancellable owner;
    }

}
