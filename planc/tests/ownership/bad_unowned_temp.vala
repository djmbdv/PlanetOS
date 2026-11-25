class Item {
    public int v;
}

int main () {
    unowned Item u = new Item ();
    u.v = 1;
    return u.v;
}
