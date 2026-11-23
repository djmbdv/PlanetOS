// Pure-Vala GLib.FileStream (stdio-compatible buffered stream) for PlanetOS.
using Planet;

namespace GLib {

    public enum FileSeek {
        SET = 0,
        CUR = 1,
        END = 2
    }

    public class FileStream : Object {
        private int fd;
        private bool owned_fd;
        private bool eof_flag = false;
        private int err_flag = 0;
        private int pushback = -1;
        private uint8[]? rbuf = null;
        private int rpos = 0;
        private int rlen = 0;
        private int cur_pos = 0;

        private FileStream (int fd, bool owned_fd = true) {
            this.fd = fd;
            this.owned_fd = owned_fd;
        }

        ~FileStream () {
            if (owned_fd && fd >= 0) {
                Sys.close (fd);
                fd = -1;
            }
        }

        public static FileStream? open (string path, string mode) {
            if (path.length == 0 || mode.length == 0)
                return null;
            uint8 m0 = mode[0];
            bool plus = false;
            for (int i = 0; i < mode.length; i++) {
                if (mode[i] == '+')
                    plus = true;
            }
            int fd = -1;
            if (m0 == 'r') {
                fd = Sys.open (path);
                if (fd < 0)
                    return null;
                return new FileStream (fd, true);
            } else if (m0 == 'w') {
                fd = Sys.create (path);
                if (fd < 0)
                    return null;
                return new FileStream (fd, true);
            } else if (m0 == 'a') {
                fd = Sys.open (path);
                if (fd < 0) {
                    if (!plus) {
                        fd = Sys.create (path);
                    } else {
                        fd = Sys.create (path);
                    }
                    if (fd < 0)
                        return null;
                    return new FileStream (fd, true);
                }
                var fs = new FileStream (fd, true);
                fs.seek (0, FileSeek.END);
                return fs;
            }
            return null;
        }

        public static FileStream? fdopen (int fildes, string mode) {
            if (fildes < 0 || mode.length == 0)
                return null;
            return new FileStream (fildes, false);
        }

        public int close () {
            if (fd < 0)
                return -1;
            rpos = 0;
            rlen = 0;
            pushback = -1;
            int r = owned_fd ? Sys.close (fd) : 0;
            fd = -1;
            return (r < 0) ? -1 : 0;
        }

        public int close_now () {
            return close ();
        }

        public int fileno () {
            return fd;
        }

        public bool eof () {
            return eof_flag;
        }

        public int error () {
            return err_flag;
        }

        public void clearerr () {
            eof_flag = false;
            err_flag = 0;
        }

        public int flush () {
            return 0;
        }

        public void rewind () {
            seek (0, FileSeek.SET);
            clearerr ();
        }

        public int seek (long offset, FileSeek whence) {
            if (fd < 0)
                return -1;
            long target = offset;
            if (whence == FileSeek.CUR) {
                long logical = (long) cur_pos - (long) (rlen - rpos);
                if (pushback >= 0 && logical > 0)
                    logical = logical - 1;
                target = logical + offset;
            } else if (whence == FileSeek.END) {
                int sz = Sys.file_size (fd);
                if (sz < 0) {
                    err_flag = (Sys.errno_code () != 0) ? Sys.errno_code () : Sys.EIO;
                    return -1;
                }
                target = (long) sz + offset;
            }
            if (target < 0 || target > 2147483647L) {
                err_flag = (Sys.errno_code () != 0) ? Sys.errno_code () : Sys.EIO;
                return -1;
            }
            pushback = -1;
            rpos = 0;
            rlen = 0;
            int r = Sys.seek (fd, (int) target);
            if (r < 0) {
                err_flag = (Sys.errno_code () != 0) ? Sys.errno_code () : Sys.EIO;
                return -1;
            }
            cur_pos = (int) target;
            eof_flag = false;
            return 0;
        }

        public long tell () {
            if (fd < 0)
                return -1;
            long logical = (long) cur_pos - (long) (rlen - rpos);
            if (pushback >= 0 && logical > 0)
                logical = logical - 1;
            return logical;
        }

        private int refill_rbuf () {
            if (rbuf == null)
                rbuf = new uint8[4096];
            rpos = 0;
            rlen = 0;
            var b = (!) rbuf;
            int n = Sys.read (fd, b, b.length);
            if (n < 0) {
                err_flag = (Sys.errno_code () != 0) ? Sys.errno_code () : Sys.EIO;
                return -1;
            }
            if (n == 0) {
                eof_flag = true;
                return 0;
            }
            cur_pos = cur_pos + n;
            rlen = n;
            return rlen;
        }

        public size_t read (uint8[] buf, size_t size = 1) {
            if (fd < 0 || size == 0 || buf.length == 0)
                return 0;
            int want = buf.length;
            int got = 0;
            if (pushback >= 0 && want > 0) {
                buf[0] = (uint8) pushback;
                pushback = -1;
                got = 1;
            }
            if (got < want && rpos < rlen && rbuf != null) {
                var b = (!) rbuf;
                int avail = rlen - rpos;
                int take = (want - got < avail) ? (want - got) : avail;
                Memory.copy (Sys.byte_arr_addr (buf) + got, Sys.byte_arr_addr (b) + rpos, (size_t) take);
                rpos = rpos + take;
                got = got + take;
            }
            while (got < want) {
                int rem = want - got;
                if (got == 0) {
                    int n = Sys.read (fd, buf, want);
                    if (n < 0) {
                        err_flag = (Sys.errno_code () != 0) ? Sys.errno_code () : Sys.EIO;
                        break;
                    }
                    if (n == 0) {
                        eof_flag = true;
                        break;
                    }
                    cur_pos = cur_pos + n;
                    got = n;
                    continue;
                }
                var tmp = new uint8[rem];
                int n = Sys.read (fd, tmp, rem);
                if (n < 0) {
                    err_flag = (Sys.errno_code () != 0) ? Sys.errno_code () : Sys.EIO;
                    break;
                }
                if (n == 0) {
                    eof_flag = true;
                    break;
                }
                Memory.copy (Sys.byte_arr_addr (buf) + got, Sys.byte_arr_addr (tmp), (size_t) n);
                cur_pos = cur_pos + n;
                got = got + n;
            }
            return (size_t) ((size > 1) ? (got / (int) size) : got);
        }

        private int write_all_fd (uint8[] data, int len) {
            int off = 0;
            while (off < len) {
                int rem = len - off;
                uint8[] slice;
                if (off == 0) {
                    slice = data;
                } else {
                    slice = new uint8[rem];
                    Memory.copy (Sys.byte_arr_addr (slice), Sys.byte_arr_addr (data) + off, (size_t) rem);
                }
                int n = Sys.write (fd, slice, rem);
                if (n <= 0) {
                    err_flag = (Sys.errno_code () != 0) ? Sys.errno_code () : Sys.EIO;
                    return (off > 0) ? off : -1;
                }
                cur_pos = cur_pos + n;
                off = off + n;
            }
            return off;
        }

        public size_t write (uint8[] buf, size_t size = 1) {
            if (fd < 0 || size == 0 || buf.length == 0)
                return 0;
            int w = write_all_fd (buf, buf.length);
            if (w <= 0)
                return 0;
            return (size_t) ((size > 1) ? (w / (int) size) : w);
        }

        public int getc () {
            if (pushback >= 0) {
                int c = pushback;
                pushback = -1;
                return c;
            }
            if (rpos >= rlen) {
                if (refill_rbuf () <= 0)
                    return -1;
            }
            var b = (!) rbuf;
            int ch = (int) b[rpos];
            rpos = rpos + 1;
            return ch;
        }

        public int ungetc (int c) {
            if (c < 0)
                return -1;
            pushback = c & 0xff;
            eof_flag = false;
            return pushback;
        }

        public int putc (char c) {
            var b = new uint8[1];
            b[0] = (uint8) c;
            if (write_all_fd (b, 1) != 1)
                return -1;
            return (int) ((uint8) c);
        }

        public int puts (string s) {
            if (s.length == 0)
                return 0;
            return write_all_fd (s.data, s.length);
        }

        public void printf (string s) {
            puts (s);
        }

        public string? read_line () {
            var ba = new ByteArray.sized (128);
            while (true) {
                int c = getc ();
                if (c < 0) {
                    if (ba.len == 0)
                        return null;
                    break;
                }
                if (c == '\n')
                    break;
                if (c == '\r')
                    continue;
                ba.append_byte ((uint8) c);
            }
            return ba.to_string ();
        }

        public string? gets (char[] s) {
            if (s.length <= 1)
                return null;
            int max_chars = s.length - 1;
            int i = 0;
            int init_cap = (max_chars > 4096) ? 4096 : max_chars;
            var ba = new ByteArray.sized (init_cap);
            while (i < max_chars) {
                int c = getc ();
                if (c < 0) {
                    if (i == 0)
                        return null;
                    break;
                }
                s[i] = (char) c;
                ba.append_byte ((uint8) c);
                i++;
                if (c == '\n')
                    break;
            }
            s[i] = '\0';
            return ba.to_string ();
        }
    }

    private FileStream? _stdin = null;
    private FileStream? _stdout = null;
    private FileStream? _stderr = null;

    public FileStream get_stdin () {
        if (_stdin == null)
            _stdin = FileStream.fdopen (0, "r");
        return (!) _stdin;
    }

    public FileStream get_stdout () {
        if (_stdout == null)
            _stdout = FileStream.fdopen (1, "w");
        return (!) _stdout;
    }

    public FileStream get_stderr () {
        if (_stderr == null)
            _stderr = FileStream.fdopen (2, "w");
        return (!) _stderr;
    }
}
