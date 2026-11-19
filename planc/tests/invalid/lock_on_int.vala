int main () {
    int v = 3;
    lock (v) {
        print ("x\n");
    }
    return 0;
}