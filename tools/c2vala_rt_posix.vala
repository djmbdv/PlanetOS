// Host-Linux POSIX syscall FileStream + remove/rename shim for tools/c2vala_tests/run.py.

[AsmBody(@"
    lea 16(%rsi), %rsi
    xor %eax, %eax
    syscall
    ret
")]
private static extern int64 c_sys_read (int fd, uint8[] buf, int count);

[AsmBody(@"
    lea 16(%rsi), %rsi
    mov $1, %rax
    syscall
    ret
")]
private static extern int64 c_sys_write (int fd, uint8[] buf, int count);

[AsmBody(@"
    lea 16(%rsi), %rsi
    mov %rcx, %r10
    mov $257, %rax
    syscall
    ret
")]
private static extern int c_sys_openat (int dirfd, string path, int flags, int mode);

[AsmBody(@"
    mov $3, %rax
    syscall
    ret
")]
private static extern int c_sys_close (int fd);

[AsmBody(@"
    mov $8, %rax
    syscall
    ret
")]
private static extern int64 c_sys_lseek (int fd, int64 offset, int whence);

[AsmBody(@"
    lea 16(%rsi), %rsi
    mov $263, %rax
    syscall
    ret
")]
private static extern int c_sys_unlinkat (int dirfd, string path, int flags);

[AsmBody(@"
    lea 16(%rsi), %rsi
    lea 16(%rcx), %r10
    mov $264, %rax
    syscall
    ret
")]
private static extern int c_sys_renameat (int olddirfd, string oldpath, int newdirfd, string newpath);

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

    private FileStream (int fd, bool owned_fd = true) {
        this.fd = fd;
        this.owned_fd = owned_fd;
    }

    ~FileStream () {
        if (owned_fd && fd >= 0) {
            c_sys_close (fd);
            fd = -1;
        }
    }

    public static FileStream? open (string path, string mode) {
        if (mode.length == 0)
            return null;
        bool plus = false;
        for (int i = 0; i < mode.length; i++) {
            if (mode[i] == '+')
                plus = true;
        }
        int flags = 0;
        uint8 m0 = mode[0];
        if (m0 == 'r') {
            flags = plus ? 2 : 0;
        } else if (m0 == 'w') {
            flags = (plus ? 2 : 1) | 64 | 512;
        } else if (m0 == 'a') {
            flags = (plus ? 2 : 1) | 64 | 1024;
        } else {
            return null;
        }
        flags = flags | 524288;
        int fd = c_sys_openat (-100, path, flags, 420);
        if (fd < 0)
            return null;
        return new FileStream (fd, true);
    }

    public static FileStream? fdopen (int fildes, string mode) {
        if (fildes < 0)
            return null;
        return new FileStream (fildes, false);
    }

    public int close_now () {
        if (fd < 0)
            return -1;
        rpos = 0;
        rlen = 0;
        int r = owned_fd ? c_sys_close (fd) : 0;
        fd = -1;
        return r < 0 ? -1 : 0;
    }

    public int fileno () { return fd; }
    public bool eof () { return eof_flag; }
    public int error () { return err_flag; }
    public void clearerr () { eof_flag = false; err_flag = 0; }
    public int flush () { return 0; }
    public void rewind () { seek (0, FileSeek.SET); clearerr (); }

    public int seek (long offset, FileSeek whence) {
        if (fd < 0)
            return -1;
        long adj = offset;
        if (whence == FileSeek.CUR && rpos < rlen)
            adj = adj - (long) (rlen - rpos);
        pushback = -1;
        rpos = 0;
        rlen = 0;
        int64 r = c_sys_lseek (fd, (int64) adj, (int) whence);
        if (r < 0) {
            err_flag = 1;
            return -1;
        }
        eof_flag = false;
        return 0;
    }

    public long tell () {
        if (fd < 0)
            return -1;
        int64 r = c_sys_lseek (fd, 0, 1);
        if (r < 0)
            return -1;
        int64 buffered = (int64) (rlen - rpos);
        if (buffered > 0 && r >= buffered)
            r = r - buffered;
        if (pushback >= 0 && r > 0)
            r = r - 1;
        return (long) r;
    }

    private int64 read_retry (uint8[] dst, int count) {
        while (true) {
            int64 n = c_sys_read (fd, dst, count);
            if (n == -4)
                continue;
            return n;
        }
    }

    private int refill_rbuf () {
        if (rbuf == null)
            rbuf = new uint8[4096];
        rpos = 0;
        rlen = 0;
        var b = (!) rbuf;
        int64 n = read_retry (b, b.length);
        if (n < 0) {
            err_flag = 1;
            return -1;
        }
        if (n == 0) {
            eof_flag = true;
            return 0;
        }
        rlen = (int) n;
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
            for (int i = 0; i < take; i++)
                buf[got + i] = b[rpos + i];
            rpos = rpos + take;
            got = got + take;
        }
        if (got < want) {
            var tmp = new uint8[want - got];
            int64 n = read_retry (tmp, want - got);
            if (n < 0) {
                err_flag = 1;
            } else if (n == 0) {
                eof_flag = true;
            } else {
                for (int i = 0; i < (int) n; i++)
                    buf[got + i] = tmp[i];
                got = got + (int) n;
            }
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
                for (int i = 0; i < rem; i++)
                    slice[i] = data[off + i];
            }
            int64 n = c_sys_write (fd, slice, rem);
            if (n == -4)
                continue;
            if (n <= 0) {
                err_flag = 1;
                return off > 0 ? off : -1;
            }
            off = off + (int) n;
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
}

public int c_remove (string path) {
    return c_sys_unlinkat (-100, path, 0) < 0 ? -1 : 0;
}

public int c_rename (string oldpath, string newpath) {
    return c_sys_renameat (-100, oldpath, -100, newpath) < 0 ? -1 : 0;
}

public void c_init_stdio_host (out FileStream? sin, out FileStream? sout, out FileStream? serr) {
    sin = FileStream.fdopen (0, "r");
    sout = FileStream.fdopen (1, "w");
    serr = FileStream.fdopen (2, "w");
}
