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
        string u = "ñandú";
        int uc = u.char_count ();
        int uv = u.validate () ? 1 : 0;
        print (@"user/init.elf: utf8 '$u' chars=$uc valid=$uv\n");
        return 0;
    }
}
