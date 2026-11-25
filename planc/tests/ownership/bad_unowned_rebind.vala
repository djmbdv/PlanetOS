class Item {
    public int v = 2;
}

int main () {
    Item a = new Item ();
    unowned Item u = a;
    u = new Item ();
    return u.v;
}
