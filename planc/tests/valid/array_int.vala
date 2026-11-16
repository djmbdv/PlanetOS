int sum_arr(int[] a) {
    int s = 0;
    for (int i = 0; i < a.length; i++) {
        s += a[i];
    }
    return s;
}

int main() {
    int[] a = new int[4];
    a[0] = 5;
    a[1] = 10;
    a[1] += 3;
    a[2] = 10;
    a[2]++;
    a[3] = 4;
    a[3]--;
    int s1 = sum_arr(a);
    int[] lit = { 10, 20, 30 };
    int s2 = sum_arr(lit);
    print(@"len=$(a.length),$(lit.length) sum=$s1,$s2\n");
    return s1 + s2;
}
