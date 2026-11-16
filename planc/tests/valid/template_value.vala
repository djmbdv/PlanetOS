void show(string s) {
    print(s);
}

int main() {
    string name = "planc";
    int id = 5;
    string s = @"user=$name id=$id\n";
    string k = @"plain\n";
    show(s);
    show(k);
    show(@"expr=$(id * 10 + 2)\n");
    string joined = @"[$name]" + @"($id)\n";
    print(joined);
    return joined.length;
}
