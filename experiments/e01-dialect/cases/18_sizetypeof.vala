public class Thing : Object { public int x; }
void main() { print("%zu %s\n", sizeof(int), typeof(Thing).name()); }
