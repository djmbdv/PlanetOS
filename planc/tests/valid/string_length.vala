int main() {
    string empty;
    string ascii = "abc";
    string utf8 = "añb";
    return empty.length * 100 + ascii.length * 10 + utf8.length;
}
