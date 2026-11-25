class Item {
    public int v = 1;
}

int main () {
    Item a = new Item ();
    Item b = new Item ();
    unowned Item u = a;
    u = b;
    print (@"$(u.v)\n");
    print (@"$(a.v)\n");
    return 0;
}
