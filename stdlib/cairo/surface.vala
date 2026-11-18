// Pure-Vala Cairo Format and ImageSurface.
using Planet;

namespace Cairo {

    public enum Format {
        ARGB32,
        RGB24
    }

    public class ImageSurface : Object {
        public int width { get; private set; }
        public int height { get; private set; }
        public int buf_addr { get; private set; }

        public ImageSurface (Format fmt, int w, int h) {
            width = w;
            height = h;
            int bytes = w * h * 4;
            int pages = (bytes + 4095) / 4096;
            buf_addr = Sys.alloc_pages (pages);
        }

        public int get_width () { return width; }
        public int get_height () { return height; }
        public void flush () {}
    }

}
