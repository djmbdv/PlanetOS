struct Pair {
    public int a;
    public string tag;
}

class Holder {
    public string name;
    public Holder(string n) {
        name = n;
    }
}

void inc_ref(ref int x) {
    x += 5;
}

void init_out(out int x) {
    x = 77;
}

void swap_str(ref string a, ref string b) {
    string tmp = a;
    a = b;
    b = tmp;
}

void replace_out_str(out string s) {
    s = @"new-" + "val";
}

void bump_pair(ref Pair p) {
    p.a += 10;
    p.tag = @"$(p.tag)+";
}

void fill_pair(out Pair p) {
    p = Pair() { a = 33, tag = @"filled-" + "ok" };
}

void replace_holder(out Holder? h, ref Holder cur) {
    h = cur;
    cur = new Holder(@"updated-" + cur.name);
}

int main() {
    int n = 10;
    inc_ref(ref n);
    int m = 999;
    init_out(out m);

    string s1 = @"alpha-" + "1";
    string s2 = @"beta-" + "2";
    swap_str(ref s1, ref s2);

    string over = @"old-" + "heap";
    replace_out_str(out over);

    Pair p = Pair() { a = 5, tag = @"p-" + "0" };
    bump_pair(ref p);
    Pair q = Pair() { a = 1, tag = @"stale-" + "x" };
    fill_pair(out q);

    Holder cur = new Holder("first");
    Holder? prev = new Holder("unused");
    replace_holder(out prev, ref cur);

    int[] nums = new int[3];
    nums[1] = 20;
    inc_ref(ref nums[1]);

    string[] tags = new string[2];
    tags[0] = @"elem-" + "old";
    replace_out_str(out tags[0]);

    print(@"int=$n,$m\n");
    print(@"str=$s1,$s2,$over\n");
    print(@"pair=$(p.a):$(p.tag)|$(q.a):$(q.tag)\n");
    print(@"cls=$(prev.name)->$(cur.name)\n");
    print(@"arr=$(nums[1]):$(tags[0])\n");
    return 0;
}
