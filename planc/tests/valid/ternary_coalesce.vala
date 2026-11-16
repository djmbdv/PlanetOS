const int GLOBAL_OFFSET = 5;
const string GLOBAL_PREFIX = "cfg";

enum Status {
    OK = 1,
    ERR = 2;

    public bool is_ok() {
        return this == OK;
    }

    public static int code_max() {
        return 99;
    }
}

struct Vec2 {
    public int x;
    public int y;

    public int dot_self() {
        return this.x * this.x + y * y;
    }

    public static Vec2 unit_x() {
        return Vec2 () { x = 1, y = 0 };
    }
}

class Box {
    public const int STEP = 10;
    public string label;

    public Box(string label) {
        this.label = label;
    }

    public static Box make(string s) {
        return new Box(s);
    }
}

int calls = 0;

Box bump() {
    calls += 1;
    return new Box("fallback_" + "1");
}

int main() {
    int a = (1 < 2) ? Box.STEP : GLOBAL_OFFSET;
    string msg = false ? ("a" + "1") : (true ? (GLOBAL_PREFIX + "_ok") : "no");

    Box? nb = Box.make("box" + "1");
    string lbl = nb != null ? nb.label : "empty";

    Box b1 = nb ?? bump();
    Box? missing = null;
    Box unwrapped = missing ?? bump();

    Vec2 v = Vec2 () { x = 3, y = 4 };
    Vec2 u = Vec2.unit_x();

    print(@"$(msg):$(lbl):$(b1.label):$(unwrapped.label):$(Status.code_max()):$(Status.OK.is_ok()):$(calls):$(v.dot_self()):$(u.dot_self())\n");
    return a + calls + v.dot_self() + u.dot_self();
}
