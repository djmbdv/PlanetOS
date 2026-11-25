// Pure-Vala Gio.Converter, ConverterInputStream, ConverterOutputStream, and LineDisciplineConverter.
using GLib;

namespace Gio {

    public enum ConverterResult {
        ERROR = 0,
        CONVERTED = 1,
        FINISHED = 2,
        FLUSHED = 3
    }

    public enum ConverterFlags {
        NO_FLAGS = 0,
        INPUT_AT_END = 1,
        FLUSH = 2
    }

    public interface Converter : Object {
        public abstract ConverterResult convert (uint8[] inbuf, uint8[] outbuf,
                                                 ConverterFlags flags,
                                                 out int bytes_read,
                                                 out int bytes_written) throws IOError;
        public abstract void reset ();
    }

    /**
     * Streaming byte converter for Contract A devices (/dev/serial0, /dev/console).
     * Normalizes CR / CRLF -> LF (input) or LF -> CRLF (output).
     */
    public class LineDisciplineConverter : Object, Converter {
        private bool to_crlf;
        private bool prev_cr = false;

        public LineDisciplineConverter (bool to_crlf = false) {
            this.to_crlf = to_crlf;
        }

        public void reset () {
            prev_cr = false;
        }

        public ConverterResult convert (uint8[] inbuf, uint8[] outbuf,
                                        ConverterFlags flags,
                                        out int bytes_read,
                                        out int bytes_written) throws IOError {
            int ri = 0;
            int wi = 0;
            while (ri < inbuf.length && wi < outbuf.length) {
                uint8 c = inbuf[ri];
                if (to_crlf) {
                    if (c == '\n') {
                        if (wi + 1 >= outbuf.length)
                            break;
                        outbuf[wi++] = (uint8) '\r';
                        outbuf[wi++] = (uint8) '\n';
                        ri++;
                    } else {
                        outbuf[wi++] = c;
                        ri++;
                    }
                } else {
                    if (c == '\r') {
                        outbuf[wi++] = (uint8) '\n';
                        prev_cr = true;
                        ri++;
                    } else if (c == '\n' && prev_cr) {
                        prev_cr = false;
                        ri++;
                    } else {
                        prev_cr = false;
                        outbuf[wi++] = c;
                        ri++;
                    }
                }
            }
            bytes_read = ri;
            bytes_written = wi;
            if ((flags & ConverterFlags.INPUT_AT_END) != 0 && ri == inbuf.length)
                return ConverterResult.FINISHED;
            if ((flags & ConverterFlags.FLUSH) != 0 && ri == inbuf.length)
                return ConverterResult.FLUSHED;
            return ConverterResult.CONVERTED;
        }
    }

    public class ConverterInputStream : FilterInputStream {
        private Converter converter;
        private uint8[] raw_buf = new uint8[4096];
        private int raw_len = 0;
        private bool eof = false;

        public ConverterInputStream (InputStream base_stream, Converter converter) : base (base_stream) {
            this.converter = converter;
        }

        public Converter get_converter () {
            return converter;
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            if (buffer.length == 0)
                return 0;

            while (true) {
                if (raw_len == 0 && !eof) {
                    int n = base_stream.read (raw_buf, cancellable);
                    if (n <= 0)
                        eof = true;
                    else
                        raw_len = n;
                }

                var slice = new uint8[raw_len];
                for (int i = 0; i < raw_len; i++)
                    slice[i] = raw_buf[i];
                ConverterFlags fl = eof ? ConverterFlags.INPUT_AT_END : ConverterFlags.NO_FLAGS;
                int br = 0;
                int bw = 0;
                converter.convert (slice, buffer, fl, out br, out bw);

                if (br > 0) {
                    int rem = raw_len - br;
                    for (int i = 0; i < rem; i++)
                        raw_buf[i] = raw_buf[br + i];
                    raw_len = rem;
                }
                if (bw > 0)
                    return bw;
                if (eof)
                    return 0;
            }
        }
    }

    public class ConverterOutputStream : FilterOutputStream {
        private Converter converter;
        private uint8[] out_buf = new uint8[4096];

        public ConverterOutputStream (OutputStream base_stream, Converter converter) : base (base_stream) {
            this.converter = converter;
        }

        public Converter get_converter () {
            return converter;
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            if (buffer.length == 0)
                return 0;

            int br = 0;
            int bw = 0;
            converter.convert (buffer, out_buf, ConverterFlags.NO_FLAGS, out br, out bw);
            if (bw > 0) {
                var chunk = new uint8[bw];
                for (int i = 0; i < bw; i++)
                    chunk[i] = out_buf[i];
                int wrote = 0;
                base_stream.write_all (chunk, out wrote, cancellable);
            }
            return br;
        }

        public override bool flush (Cancellable? cancellable = null) throws IOError {
            int br = 0;
            int bw = 0;
            var empty = new uint8[0];
            converter.convert (empty, out_buf, ConverterFlags.FLUSH, out br, out bw);
            if (bw > 0) {
                var chunk = new uint8[bw];
                for (int i = 0; i < bw; i++)
                    chunk[i] = out_buf[i];
                int wrote = 0;
                base_stream.write_all (chunk, out wrote, cancellable);
            }
            return base_stream.flush (cancellable);
        }
    }
}
