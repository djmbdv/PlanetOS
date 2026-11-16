string greeting = "hi ";
string uninit;

void swap_msg() {
    greeting = "planet\n";
}

int main() {
    print(uninit);
    print(greeting);
    swap_msg();
    print(greeting);
    return greeting.length;
}
