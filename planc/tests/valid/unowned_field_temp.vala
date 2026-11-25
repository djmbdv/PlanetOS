class Name {
    public string text;
}

Name make (string t) {
    Name n = new Name ();
    n.text = t;
    return n;
}

int main () {
    unowned string s = make ("hi").text;
    print (@"$s\n");
    return 0;
}
