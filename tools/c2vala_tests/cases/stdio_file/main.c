#include <stdio.h>
#include <string.h>

static void write_sample(const char *path) {
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        printf("open_w_fail\n");
        return;
    }
    fputs("alpha\n", f);
    fprintf(f, "beta=%d\n", 42);
    fputc('Z', f);
    fflush(f);
    fclose(f);
}

static void read_sample(const char *path) {
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        printf("open_r_fail\n");
        return;
    }
    char line[64];
    if (fgets(line, 64, f) != NULL) {
        printf("l1=%s", line);
    }
    long pos = ftell(f);
    printf("pos=%ld\n", pos);

    if (fgets(line, 64, f) != NULL) {
        printf("l2=%s", line);
    }

    int c = fgetc(f);
    printf("ch=%c\n", c);
    ungetc(c, f);
    int c2 = fgetc(f);
    printf("unget=%c\n", c2);

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    printf("sz=%ld\n", sz);

    rewind(f);
    char buf[5];
    unsigned long n = fread(buf, 1, 5, f);
    printf("fread=%lu:%c%c%c%c%c\n", n, buf[0], buf[1], buf[2], buf[3], buf[4]);

    fclose(f);
}

int main(void) {
    const char *p = "/tmp/c2v_stdio_test.txt";
    write_sample(p);
    read_sample(p);
    remove(p);
    fputs("out_ok\n", stdout);
    return 0;
}
