int main () {
    unowned string s = @"items=$(1 + 1)";
    print ("%s\n", s);
    return 0;
}
