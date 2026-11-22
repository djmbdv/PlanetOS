int main () {
    char bel = '\a';
    char bs = '\b';
    char ff = '\f';
    char vt = '\v';
    char hex = '\x41';
    char uni = '\u0042';
    string s = "[\x07][\x41][\u00e9]";
    print (@"$(bel) $(bs) $(ff) $(vt) $(hex) $(uni)\n");
    print (@"$s\n");
    return 0;
}
