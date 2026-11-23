[SimpleType]
struct Handle {
    public uint64 id;
}

[Arena]
int arena_work (int n) {
    int[] scratch = new int[n];
    int sum = 0;
    for (int i = 0; i < scratch.length; i++) {
        scratch[i] = i + 1;
        sum += scratch[i];
    }
    return sum;
}

int stack_and_borrow (int[] src) {
    var borrowed = src;
    int[] tmp = new int[8];
    for (int i = 0; i < tmp.length; i++)
        tmp[i] = (i < borrowed.length) ? borrowed[i] * 2 : 0;
    int acc = 0;
    for (int i = 0; i < tmp.length; i++)
        acc += tmp[i];
    return acc;
}

int main () {
    Handle h = Handle () { id = 99 };
    int a = arena_work (10);
    int[] data = { 1, 2, 3, 4 };
    int b = stack_and_borrow (data);
    print (@"$(h.id) $a $b\n");
    return 0;
}
