// Tier 0/1 with a libc surface: shows the runtime shim shopping list.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

char *duplicate (const char *s) {
    size_t n = strlen (s) + 1;
    char *copy = (char *) malloc (n);
    if (copy == 0)
        return 0;
    memcpy (copy, s, n);
    return copy;
}

void report (const char *s) {
    char *copy = duplicate (s);
    if (copy != 0) {
        printf ("%s\n", copy);
        free (copy);
    }
}