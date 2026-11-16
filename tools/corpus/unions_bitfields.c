// Tier 2: unions and bitfields have no Vala equivalent.
union value {
    int i;
    float f;
    unsigned char bytes[4];
};

struct flags {
    unsigned int ready : 1;
    unsigned int error : 1;
    unsigned int mode  : 4;
};

int read_union (union value v) {
    return v.i;
}