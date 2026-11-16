void main() {
    var l = new GenericArray<int>();
    l.add(1); l.add(2);
    foreach (var x in l) print("%d\n", x);
}
