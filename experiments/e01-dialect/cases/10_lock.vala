void main() {
    var m = Mutex();
    lock (m) { print("inside\n"); }
}
