sealed class Leaf {
    public int v;
}
int main () {
    int x = 2;
    switch (x) {
        case 1, 2: print ("one-or-two\n"); break;
        case 3: print ("three\n"); break;
        default: print ("other\n");
    }
    string t = "b";
    switch (t) {
        case "a", "b": print ("str-ab\n"); break;
        default: print ("str-other\n");
    }
    return 0;
}