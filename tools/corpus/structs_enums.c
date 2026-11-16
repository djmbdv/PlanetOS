// Tier 1: structs, enums and typedefs need a mechanical rewrite.
typedef enum { RED, GREEN, BLUE } color_id;

struct pixel {
    int x;
    int y;
    color_id c;
};

int pixel_sum (struct pixel p) {
    return p.x + p.y + (int) p.c;
}

int classify (int v) {
    switch (v) {
        case 0: return RED;
        case 1: return GREEN;
        default: return BLUE;
    }
}