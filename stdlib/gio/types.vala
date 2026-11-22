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
