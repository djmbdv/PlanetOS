int main() {
    string s = "ABC";
    int sum = 0;
    for (int i = 0; i < s.length; i++) {
        sum += s[i];
    }
    string u = "añb";
    print(@"s0=$(s[0]) len=$(u.length) u3=$(u[3])\n");
    return (sum - 198) + (u[0] - 97) + (u[3] - 98) + u.length * 10 + s[1] - 66;
}
