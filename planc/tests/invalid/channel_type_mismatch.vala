int main () {
    var ch = new Channel<int> ();
    ch.send ("bad");
    return 0;
}
