public class Box<T> {
    public T value;

    public Box(T v) {
        this.value = v;
    }

    public T get_val() {
        return this.value;
    }

    public void set_val(T v) {
        this.value = v;
    }
}

public class Pair<K, V> {
    public K key;
    public V val;

    public Pair(K k, V v) {
        this.key = k;
        this.val = v;
    }
}

public struct Span<T> {
    public T item;
    public int count;
}

int main() {
    var bi = new Box<int>(10);
    bi.set_val(bi.get_val() + 5);
    print(@"bi=$(bi.get_val())\n");

    var bs = new Box<string>("alpha");
    bs.set_val("beta");
    print(@"bs=$(bs.get_val())\n");

    var p = new Pair<int, string>(7, "seven");
    var bp = new Box<Pair<int, string>>(p);
    print(@"bp=$(bp.value.key):$(bp.value.val)\n");

    Span<string> sp = Span<string>() { item = "span-ok", count = 3 };
    print(@"span=$(sp.item):$(sp.count)\n");

    var ga = new GenericArray<string>();
    ga.add("one");
    ga.add("two");
    ga.add("three");
    ga.add("four");
    ga.add("five");
    ga.add("six");
    ga.add("seven");
    ga.add("eight");
    ga.add("nine");
    ga[1] = "TWO";
    print(@"ga.len=$(ga.length) ga[1]=$(ga[1])\n");
    foreach (var s in ga) {
        print(@"item=$s\n");
    }

    var nums = new GenericArray<int>();
    nums.add(10);
    nums.add(20);
    nums.add(30);
    nums[1] += 5;
    int sum = 0;
    foreach (int n in nums) {
        sum += n;
    }
    print(@"sum=$sum\n");
    return 0;
}
