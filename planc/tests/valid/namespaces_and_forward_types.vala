using Geometry;
using App.Core;

int area_of(Rect r) {
    return r.dim.w * r.dim.h;
}

Rect make_checked(int w, int h) throws ShapeErr {
    if (w < 0 || h < 0) {
        throw new ShapeErr.BAD("negative dim");
    }
    Dim d = Dim() { w = w, h = h };
    return new Rect(ShapeKind.RECT, d);
}

namespace Geometry {
    public enum ShapeKind {
        CIRCLE,
        RECT
    }

    public errordomain ShapeErr {
        BAD
    }

    public struct Dim {
        public int w;
        public int h;
    }

    public class Rect {
        public ShapeKind kind;
        public Dim dim;

        public Rect(ShapeKind k, Dim d) {
            kind = k;
            dim = d;
        }
    }
}

namespace App.Core {
    public int run_check() {
        try {
            var r = make_checked(6, 7);
            int a = area_of(r);
            print(@"area=$a\n");
            var bad = make_checked(-1, 5);
            return bad.dim.w;
        } catch (ShapeErr e) {
            print(@"err:$(e.message)\n");
        }
        return 0;
    }
}

int main() {
    Dim d = Dim() { w = 3, h = 4 };
    var g = new Rect(ShapeKind.CIRCLE, d);
    print(@"g=$(area_of(g))\n");
    return run_check();
}
