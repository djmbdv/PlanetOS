class Item {
    public int v;
}

class Holder {
    public Item? slot;
}

int main () {
    Item it = new Item ();
    unowned Item u = it;
    Holder h = new Holder ();
    h.slot = u;
    return 0;
}