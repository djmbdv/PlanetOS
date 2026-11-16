string pick_last(string[] xs) {
    return xs[xs.length - 1];
}

int main() {
    string[] arr = { "alpha", "beta", "gamma" };
    string[] blanks = new string[2];
    arr[1] = "BETA";
    string dyn = "del" + "ta";
    blanks[0] = dyn;
    for (int i = 0; i < arr.length; i++) {
        print(@"$(arr[i]):");
    }
    string last = pick_last(blanks);
    print(@"$(blanks[0])|$(last.length)\n");
    return arr.length + blanks.length;
}
