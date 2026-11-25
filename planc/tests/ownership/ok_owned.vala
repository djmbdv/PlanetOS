class Item {
    public int v = 4;
}

class Holder {
    public Item? slot;
}

int main () {
    Item it = new Item ();
    Holder h = new Holder ();
    h.slot = it;
    print (@"$(h.slot.v)\n");
    return 0;
}