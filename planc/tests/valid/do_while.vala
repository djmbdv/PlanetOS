void main () {
    int a = 0;
    do {
        a += 7;
    } while (a > 100);
    print (@"once=$a\n");

    int b = 0;
    do {
        b++;
    } while (b < 4);
    print (@"count=$b\n");

    int i = 0;
    int sum = 0;
    do {
        i++;
        if (i == 2)
            continue;
        if (i == 5)
            break;
        sum += i;
    } while (i < 10);
    print (@"sum=$sum i=$i\n");

    int j = 0;
    do {
        j++;
        if (j >= 3)
            continue;
    } while (j < 3);
    print (@"cont_exit=$j\n");

    int iter = 0;
    string last = "";
    do {
        string tmp = @"item_$iter";
        last = tmp;
        iter++;
    } while (iter < 3);
    print (@"last=$last\n");

    int z = 0;
    do z += 2; while (z < 6);
    print (@"single=$z\n");

    int outer = 0;
    int total = 0;
    do {
        outer++;
        int inner = 0;
        do {
            inner++;
            if (inner == 2)
                break;
            total += outer * 10 + inner;
        } while (inner < 5);
        if (outer == 2)
            continue;
        total += 1000;
    } while (outer < 3);
    print (@"nested=$total\n");
}
