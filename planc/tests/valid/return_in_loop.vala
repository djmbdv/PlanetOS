int first_ge(int limit) {
    int i = 0;
    while (i < 100) {
        if (i * i >= limit) {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

int main() {
    return first_ge(50) * 10 + first_ge(0);
}
