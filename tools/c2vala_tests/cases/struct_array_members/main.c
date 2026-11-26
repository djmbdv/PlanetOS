// Inline C arrays: struct members, extern+definition merging, and the string /
// byte-array / pointer initializers that go with them.
#include <stdio.h>

typedef struct {
    short lump[4];
    char name[8];
    int extra;
} frame_t;

typedef struct {
    frame_t frames[3];
    int n;
} def_t;

typedef struct entry_s entry_t;
struct entry_s {
    char label[8];
    int id;
    entry_t *link;
};

// Declared `extern` here and defined with an initializer below: the initializer
// has to survive the merge of both declarations.
extern char *sprnames[];
char *sprnames[] = { "TROO", "SHTG", "PUNG", 0 };
extern int sound_count;
int sound_count = 3;

// Array of structs with an initializer list: a char-array member built from a
// string literal and a pointer into the array itself.
entry_t table[] = {
    { "pistol", 0, &table[1] },
    { "shotgn", 1, &table[0] },
    { "plasma", 2, 0 },
};

frame_t g_frames[2];
def_t g_def;

int main(void) {
    int i;
    int j;

    // `sprnames` keeps its three entries; the trailing NULL is not a slot.
    printf("count=3 sound_count=%d\n", sound_count);
    for (i = 0; i < 3; i++) {
        printf("name[%d]=%s\n", i, sprnames[i]);
    }

    // Array members of a global struct, and of a global array of structs.
    for (i = 0; i < 3; i++) {
        g_def.frames[i].lump[0] = i;
        g_def.frames[i].lump[3] = i * 10;
        printf("frame[%d]=%d,%d,%d\n", i, g_def.frames[i].lump[0],
               g_def.frames[i].lump[3], g_def.frames[i].extra);
    }
    g_def.n = 3;
    printf("def n=%d\n", g_def.n);
    for (i = 0; i < 2; i++) {
        for (j = 0; j < 4; j++) {
            g_frames[i].lump[j] = i * 4 + j;
        }
        printf("g[%d]=%d,%d\n", i, g_frames[i].lump[0], g_frames[i].lump[3]);
    }

    // Struct initializer with a string literal and a pointer into the array.
    for (i = 0; i < 3; i++) {
        printf("entry[%d]=%s id=%d link=%d\n", i, table[i].label, table[i].id,
               table[i].link == 0 ? -1 : table[i].link->id);
    }
    return 0;
}
