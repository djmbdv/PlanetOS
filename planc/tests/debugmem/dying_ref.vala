class Dying {
    public Dying again () { return this; }
    ~Dying () {
        Dying? x = again ();
    }
}

int main () {
    Dying d = new Dying ();
    return 0;
}