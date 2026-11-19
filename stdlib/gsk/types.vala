// Pure-Vala GSK geometry and gradient stop types for PlanetOS.

namespace Gsk {

    /**
     * Axis-aligned 2D rectangle with double-precision coordinates.
     */
    public class Rect : Object {
        public double x;
        public double y;
        public double w;
        public double h;

        public Rect (double rx, double ry, double rw, double rh) {
            x = rx;
            y = ry;
            w = rw;
            h = rh;
        }

        public bool is_empty () {
            return w <= 0.0 || h <= 0.0;
        }

        public bool contains (double px, double py) {
            if (is_empty ())
                return false;
            return px >= x && px < (x + w) && py >= y && py < (y + h);
        }

        public Rect copy () {
            return new Rect (x, y, w, h);
        }

        public Rect? intersect (Rect? other) {
            if (other == null || is_empty () || other.is_empty ())
                return null;
            double ix0 = (x > other.x) ? x : other.x;
            double iy0 = (y > other.y) ? y : other.y;
            double ix1 = ((x + w) < (other.x + other.w)) ? (x + w) : (other.x + other.w);
            double iy1 = ((y + h) < (other.y + other.h)) ? (y + h) : (other.y + other.h);
            if (ix1 <= ix0 || iy1 <= iy0)
                return null;
            return new Rect (ix0, iy0, ix1 - ix0, iy1 - iy0);
        }
    }

    /**
     * Rectangle with uniform corner radius.
     */
    public class RoundedRect : Object {
        public Rect bounds;
        public double radius;

        public RoundedRect (double x, double y, double w, double h, double r) {
            bounds = new Rect (x, y, w, h);
            radius = r;
        }

        public double clamped_radius () {
            if (bounds == null || bounds.is_empty () || radius <= 0.0)
                return 0.0;
            double max_r = ((bounds.w < bounds.h) ? bounds.w : bounds.h) * 0.5;
            return (radius > max_r) ? max_r : radius;
        }
    }

    /**
     * Color stop for linear gradient render nodes.
     */
    public class ColorStop : Object {
        public double offset;
        public double r;
        public double g;
        public double b;
        public double a;

        public ColorStop (double off, double cr, double cg, double cb, double ca) {
            offset = (off < 0.0) ? 0.0 : ((off > 1.0) ? 1.0 : off);
            r = cr;
            g = cg;
            b = cb;
            a = ca;
        }
    }
}
