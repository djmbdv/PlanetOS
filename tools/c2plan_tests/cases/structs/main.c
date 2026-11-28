// Tier 1: enums, structs by pointer, arrays of structs, string returns.
#include <stdio.h>
#include <string.h>

typedef enum { NORTH = 0, EAST = 1, SOUTH = 2, WEST = 3 } dir_t;

typedef struct {
    int x;
    int y;
} point_t;

static const char *dir_name(dir_t d) {
    switch (d) {
    case NORTH: return "north";
    case EAST:  return "east";
    case SOUTH: return "south";
    case WEST:  return "west";
    }
    return "?";
}

void step(point_t *p, dir_t d) {
    if (d == NORTH) {
        p->y = p->y + 1;
    } else if (d == EAST) {
        p->x = p->x + 1;
    } else if (d == SOUTH) {
        p->y = p->y - 1;
    } else {
        p->x = p->x - 1;
    }
}

int main(void) {
    point_t path[4];
    dir_t dirs[4];
    int i;

    for (i = 0; i < 4; i++) {
        path[i].x = 0;
        path[i].y = 0;
        dirs[i] = (dir_t) i;
        step(&path[i], dirs[i]);
        printf("i=%d dir=%s pos=%d,%d\n", i, dir_name(dirs[i]), path[i].x, path[i].y);
        if (strcmp(dir_name(dirs[i]), "east") == 0) {
            printf("east found at %d\n", i);
        }
    }
    return 0;
}