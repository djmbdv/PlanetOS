struct Point {
    public string name;
}

int main () {
    Point p = Point () { name = "x" };
    string? r = p?.name;
    return 0;
}
