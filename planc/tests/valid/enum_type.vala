enum Mode {
    NONE = 0,
    READ = 1,
    WRITE,
    EXEC = 4
}

Mode g_mode = Mode.WRITE;

int check_mode(Mode m) {
    if (m == Mode.READ) {
        return 10;
    }
    if (m == Mode.WRITE) {
        return 20;
    }
    return 30;
}

int main() {
    Mode m = Mode.EXEC;
    print(@"g=$g_mode m=$m\n");
    return check_mode(g_mode) + check_mode(m);
}
