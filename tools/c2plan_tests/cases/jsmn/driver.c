// jsmn end-to-end case: the same source is compiled with gcc and translated to
// Vala by tools/c2vala.py; both binaries must print identical output.
#include "jsmn.h"

#include <stdio.h>
#include <string.h>

int main(void) {
    jsmntok_t tokens[64];
    jsmn_parser p;
    const char *json = "{\"name\":\"planet\",\"n\":[1,2,3],\"ok\":true,\"nil\":null}";
    int n;
    int i;

    jsmn_init(&p);
    n = jsmn_parse(&p, json, strlen(json), tokens, 64);
    printf("tokens=%d\n", n);
    for (i = 0; i < n; i++) {
        printf("%d type=%d start=%d end=%d size=%d\n",
               i, (int) tokens[i].type, tokens[i].start, tokens[i].end, tokens[i].size);
    }

    /* second pass over a truncated document must report JSMN_ERROR_PART */
    jsmn_init(&p);
    n = jsmn_parse(&p, "{\"a\":", 5, tokens, 64);
    printf("partial=%d\n", n);
    return 0;
}