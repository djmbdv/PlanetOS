class Item {
    public int v = 1;
}

int main () {
    Item a = new Item ();
    unowned Item u = a;
    a = new Item ();
    print (@"$(u.v)\n");
    return 0;
}
