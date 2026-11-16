string choose(int flag, string a, string b) {
    if (flag) {
        return a;
    }
    return b;
}

int mix8(int a, string s1, int b, string s2, int c, string s3, int d, string s4) {
    print(s1);
    print(s2);
    print(s3);
    print(s4);
    s4 = "mutated";
    return a + b + c + d + s4.length;
}

int main() {
    print(choose(1, "yes\n", "no\n"));
    print(choose(0, "yes\n", "fallback\n"));
    return mix8(1, "A", 2, "B", 3, "C", 4, "D\n");
}
