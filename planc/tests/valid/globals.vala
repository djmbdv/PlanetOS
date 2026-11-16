int counter = 7;

int bump() {
    counter = counter + 1;
    return 0;
}

int main() {
    bump();
    bump();
    return counter;
}
