// Two names for one array. Each local is released on its own on the way out, so
// a local that aliases another array must not be treated as an owner: the -O2
// backend releases every array local, which would free the block twice.
int[] origin (int n) {
    var a = new int[n];
    for (int i = 0; i < a.length; i++)
        a[i] = i + 1;
    return a;
}

int total (int[] a) {
    var alias = a;
    var copy_of_alias = alias;
    int s = 0;
    for (int i = 0; i < copy_of_alias.length; i++)
        s += copy_of_alias[i];
    alias[0] = 100;
    return s;
}

void main () {
    var a = origin (8);
    int t = total (a);
    int n = a.length;
    int first = a[0];
    print (@"sum=$t first=$first len=$n\n");
}
