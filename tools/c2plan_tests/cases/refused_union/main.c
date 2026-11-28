// Must be refused: unions have no Vala equivalent.
union value {
    int i;
    float f;
};

int read_it(union value v) {
    return v.i;
}

int main(void) {
    return 0;
}