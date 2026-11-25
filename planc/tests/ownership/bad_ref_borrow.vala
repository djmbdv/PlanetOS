class Item {
    public int v = 1;
}

void fill (ref Item slot) {
    slot = new Item ();
}

int main () {
    Item a = new Item ();
    unowned Item u = a;
    fill (ref u);
    return 0;
}
