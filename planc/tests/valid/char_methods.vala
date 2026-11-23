int main () {
    char d = '7';
    if (!d.isdigit () || !d.isalnum () || !d.isxdigit () || !d.isprint () || !d.isgraph ()) return 1;
    if (d.isalpha () || d.isspace () || d.ispunct () || d.iscntrl ()) return 2;
    if (d.digit_value () != 7 || d.xdigit_value () != 7) return 3;

    char u = 'F';
    if (!u.isalpha () || !u.isupper () || !u.isxdigit () || u.islower ()) return 4;
    if (u.tolower () != 'f') return 5;
    if (u.xdigit_value () != 15 || u.digit_value () != -1) return 6;

    char l = 'a';
    if (!l.islower () || !l.isxdigit () || l.toupper () != 'A') return 7;
    if (l.xdigit_value () != 10) return 8;

    char sp = ' ';
    if (!sp.isspace () || !sp.isprint () || sp.isgraph () || sp.ispunct ()) return 9;
    if (!((char) '\n').isspace () || !((char) 0x07).iscntrl ()) return 10;

    char p = '.';
    if (!p.ispunct () || !p.isgraph () || p.isalnum ()) return 11;

    return 0;
}
