class Item {
    public int v = 7;
}

int main () {
    Item a = new Item ();
    unowned Item u = a;
    print (@"$(u.v)\n");
    return 0;
}
