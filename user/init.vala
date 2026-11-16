namespace UserInit {
    class Counter {
        public int value;
        public Counter (int v) {
            value = v;
        }
        public int next () {
            value = value + 1;
            return value;
        }
    }

    int main () {
        print ("user/init.elf: hello from --target=planetos!\n");
        var c = new Counter (41);
        var n = c.next ();
        print (@"user/init.elf: Counter.next() = $n\n");
        return 0;
    }
}
