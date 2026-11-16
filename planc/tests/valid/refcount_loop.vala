string make_tag(int n) {
    string s = @"item-$n";
    return "[" + s + "]";
}

int[] make_pair(int x) {
    int[] p = new int[2];
    p[0] = x;
    p[1] = x + 1;
    return p;
}

int main() {
    int acc = 0;
    for (int i = 0; i < 500; i++) {
        string tag = make_tag(i);
        if (i % 10 == 0) {
            string extra = tag + "!";
            acc += extra.length;
            continue;
        }
        string[] sa = { tag, "ok" };
        int[] pair = make_pair(i);
        acc += pair[0] + pair[1] + sa[0].length;
    }
    for (int j = 0; j < 20; j++) {
        string tmp = @"brk-$j";
        if (j == 5) {
            string inner = tmp + ":stop";
            acc += inner.length;
            break;
        }
    }
    if (acc <= 0) {
        return 1;
    }
    return 0;
}
