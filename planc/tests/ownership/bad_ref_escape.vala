class Holder {
    public int v;
}

class Keep {
    public static Holder? slot;
}

void steal (ref Holder h) {
    Keep.slot = h;
}

int main () {
    Holder a = new Holder ();
    steal (ref a);
    return 0;
}