class Box {
    public int v = 1;
    public string name = "box";
    public string echo (int x) { return @"$(name):$(x)"; }
}

int calls = 0;

Box? maybe (bool have) {
    calls++;
    if (have)
        return new Box ();
    return null;
}

int bump () {
    calls++;
    return 7;
}

int main () {
    Box? a = maybe (false);
    string? n1 = a?.name;
    print (@"null=$(n1 == null ? 1 : 0) calls=$(calls)\n");

    calls = 0;
    string? e1 = maybe (false)?.echo (bump ());
    print (@"short=$(e1 == null ? 1 : 0) calls=$(calls)\n");

    calls = 0;
    string? e2 = maybe (true)?.echo (bump ());
    print (@"ok=$(e2) calls=$(calls)\n");

    Box? b = new Box ();
    string? n2 = b?.name;
    print (@"member=$(n2)\n");

    Box? c = new Box ();
    for (int i = 0; i < 3; i++) {
        string? ls = c?.name;
        if (ls != null)
            print (@"loop$(i)=$(ls)\n");
    }
    return 0;
}
