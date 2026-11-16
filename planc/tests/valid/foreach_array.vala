class Item {
    public int v;
    public string tag;

    public Item(int v, string tag) {
        this.v = v;
        this.tag = tag;
    }
}

int main() {
    int[] nums = { 1, 2, 3, 4, 5, 6 };
    int sum = 0;
    foreach (int n in nums) {
        if (n == 2) {
            continue;
        }
        if (n == 5) {
            break;
        }
        sum += n;
    }

    string[] words = { "hi" + "1", "hi" + "2", "hi" + "3" };
    string joined = "";
    foreach (var s in words) {
        if (s == "hi1") {
            words = { "replaced" };
        }
        joined = joined + s + ",";
    }

    Item[] items = { new Item(10, "x" + "1"), new Item(20, "x" + "2") };
    int[] sub = { 1, 2 };
    int total = 0;
    foreach (var it in items) {
        foreach (int k in sub) {
            total += it.v + k;
        }
    }

    print(@"$(sum):$(joined):$(words[0]):$(total)\n");
    return sum + total;
}
