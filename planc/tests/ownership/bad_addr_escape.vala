class Holder {
    public int* p;
}

int main () {
    int x = 1;
    Holder h = new Holder ();
    h.p = &x;
    return 0;
}