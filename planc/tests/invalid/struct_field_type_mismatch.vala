struct Point {
    int x;
    int y;
}

int main() {
    Point p = Point() { x = "oops" };
    return p.x;
}
