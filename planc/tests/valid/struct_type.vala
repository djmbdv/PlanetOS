public struct Point {
    int x;
    int y;
}

struct Box {
    Point origin;
    string label;
    bool active;
}

Point g_pt;
Box g_box;

Point make_point(int x, int y) {
    return Point() { x = x, y = y };
}

Point add_points(Point a, Point b) {
    return Point() { x = a.x + b.x, y = a.y + b.y };
}

void mutate_copy(Point p) {
    p.x = 999;
    p.y = 999;
}

int main() {
    var p1 = make_point(3, 4);
    Point p2 = p1;
    p2.x = 10;
    mutate_copy(p1);

    /* Two struct-returning calls inside one argument list */
    Point sum = add_points(make_point(1, 2), make_point(5, 6));

    Box b = Box() { origin = p1, label = "ok", active = true };
    b.origin.x += 2;
    b.origin.y++;

    g_pt.x = 7;
    g_box.origin = make_point(2, 3);
    g_box.label = "g";

    print(@"p1=$(p1.x),$(p1.y) p2=$(p2.x) b=$(b.label):$(b.origin.x),$(b.origin.y):$(b.active) g=$(g_box.label):$(g_pt.x)\n");
    return p1.x + p1.y + p2.x + sum.x + sum.y + b.origin.x + b.origin.y + g_box.origin.y + g_pt.x;
}
