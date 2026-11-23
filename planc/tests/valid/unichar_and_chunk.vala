int main () {
    unichar u = 'g';
    if (!u.validate () || !u.isalpha () || !u.islower ()) return 1;
    if (u.totitle () != 'G' || u.toupper () != 'G') return 2;

    unichar bad = 0xD800;
    if (bad.validate ()) return 3;
    unichar bad2 = 0x110000;
    if (bad2.validate ()) return 4;

    unichar ok = 0x1F600;
    if (!ok.validate ()) return 5;

    return 0;
}
