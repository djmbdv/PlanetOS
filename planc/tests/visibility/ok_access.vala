class Base {
    private int secret = 1;
    protected int prot = 2;
    public int pub = 3;

    private int get_secret () {
        return secret;
    }

    public int reveal () {
        return get_secret () + secret;
    }
}

class Derived : Base {
    public int read_prot () {
        return prot;
    }
}

int main () {
    Base b = new Base ();
    Derived d = new Derived ();
    print (@"$(b.pub):$(d.read_prot ()):$(b.reveal ())\n");
    return 0;
}
