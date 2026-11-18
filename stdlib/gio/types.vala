// Pure-Vala Gio error domain, enums, and Cancellable.
using GLib;
using Planet;

namespace Gio {

    public errordomain IOError {
        FAILED,
        NOT_FOUND,
        EXISTS,
        INVALID_ARGUMENT,
        NOT_SUPPORTED,
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
        ALL_METADATA
    }

    public enum SeekType {
        CUR,
        SET,
        END
    }

    public enum ApplicationFlags {
        FLAGS_NONE,
        HANDLES_OPEN,
        NON_UNIQUE
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
