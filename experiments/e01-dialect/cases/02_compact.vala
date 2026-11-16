[Compact]
public class Point {
    public int x;
    public int y;
    public Point(int x, int y) { this.x = x; this.y = y; }
}
void main() { var p = new Point(1, 2); print("%d\n", p.x + p.y); }
