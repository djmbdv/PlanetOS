namespace Geo {
    public enum Kind {
        DOT,
        BOX
    }

    public class Box : Object {
        public Kind kind;
        public int w;
        public int h;

        public Box (Kind k, int w, int h) {
            this.kind = k;
            this.w = w;
            this.h = h;
        }
    }
}

namespace App.Util {
    public int area (Geo.Box b) {
        return b.w * b.h;
    }
}

int main () {
    Geo.Box b = new Geo.Box (Geo.Kind.BOX, 5, 8);
    int a = App.Util.area (b);
    print (@"$a\n");
    return 0;
}

