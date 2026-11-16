int boom() {
    print("boom\n");
    return 1;
}

int main() {
    // The right operand must not be evaluated when the left one decides.
    int r = 0 != 0 && boom() != 0;
    int s = 1 == 1 || boom() != 0;
    if (r) {
        return 1;
    }
    if (!s) {
        return 2;
    }
    return 7;
}
