class C {
    private int hidden () {
        return 1;
    }
}

int main () {
    C c = new C ();
    return c.hidden ();
}
