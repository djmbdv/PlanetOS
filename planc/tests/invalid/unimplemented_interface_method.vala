public interface Worker {
    public abstract void work();
}

public class Lazy : Worker {
    public int x;

    public Lazy(int x) {
        this.x = x;
    }
}

void main() {
    var l = new Lazy(1);
}
