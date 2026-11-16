abstract class Shape {
    public string kind;

    public Shape(string kind) {
        this.kind = kind;
    }

    public abstract int area();

    public virtual string describe() {
        return @"shape:$(this.kind)";
    }
}

class Rect : Shape {
    public int w;
    public int h;

    public Rect(int w, int h) : base("rect") {
        this.w = w;
        this.h = h;
    }

    public override int area() {
        return w * h;
    }

    public override string describe() {
        return base.describe() + @"($(this.w)x$(this.h))";
    }
}

class Circle : Shape {
    public int r;

    public Circle(int r) : base("circle") {
        this.r = r;
    }

    public override int area() {
        return 3 * r * r;
    }
}

int main() {
    Shape[] shapes = { new Rect(3, 4), new Circle(5) };
    int sum = 0;
    for (int i = 0; i < shapes.length; i++) {
        Shape s = shapes[i];
        int a = s.area();
        sum += a;
        string d = s.describe();
        print(@"$d area=$a\n");
        if (s is Rect) {
            Rect r = (Rect) s;
            sum += r.w;
        }
        Circle? c = s as Circle;
        if (c != null) {
            sum += c.r;
        }
    }
    return sum;
}
