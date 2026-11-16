int max(int a, int b) {
    if (a > b) {
        return a;
    } else {
        return b;
    }
}

int main() {
    return max(3, 9) * 10 + max(9, 3);
}
