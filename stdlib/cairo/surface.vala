// Pure-Vala Cairo Format and ImageSurface.
using Planet;

namespace Cairo {

    public enum Format {
        ARGB32,
        RGB24
    }

    public class ImageSurface : Object {
        private const int MAX_DIM = 8192;

        public Format format { get; private set; }
        public int width { get; private set; }
        public int height { get; private set; }
        public int buf_addr { get; private set; }
        private int alloc_pages = 0;

        public ImageSurface (Format fmt, int w, int h) {
            format = fmt;
            if (w <= 0 || h <= 0 || w > MAX_DIM || h > MAX_DIM) {
                width = 0;
                height = 0;
                buf_addr = 0;
                return;
            }
            width = w;
            height = h;
            int bytes = w * h * 4;
            int pages = (bytes + 4095) / 4096;
            alloc_pages = pages;
            buf_addr = Sys.alloc_pages (pages);
            if (buf_addr <= 0) {
                buf_addr = 0;
                alloc_pages = 0;
            }
        }

        public bool is_valid () {
            return buf_addr != 0 && width > 0 && height > 0;
        }

        public void destroy () {
            if (buf_addr != 0 && alloc_pages > 0) {
                for (int p = 0; p < alloc_pages; p++)
                    Sys.free_page (buf_addr + p * 4096);
            }
            buf_addr = 0;
            alloc_pages = 0;
        }

        public int get_width () { return width; }
        public int get_height () { return height; }
        public void flush () {}
    }

}
