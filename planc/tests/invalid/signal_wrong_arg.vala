class Foo {
    public signal void ping (int x);
}

int main () {
    var f = new Foo ();
    f.ping ("not_an_int");
    return 0;
}
