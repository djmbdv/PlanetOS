class Item {
    public int v;
}

int main () {
    Item a = new Item ();
    a.v = 3;
    string s = "ok";
    int[] xs = { 1, 2, 3 };
    print (@"$(a.v):$(s):$(xs.length)\n");
    return 0;
}