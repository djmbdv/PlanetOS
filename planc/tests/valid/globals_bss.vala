// No initializer: the variable lives in .bss and starts at zero.
int zeroed;

int main() {
    zeroed = zeroed + 5;
    return zeroed;
}
