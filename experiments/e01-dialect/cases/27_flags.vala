[Flags]
public enum Permission { READ = 1, WRITE = 2, ALL = READ | WRITE }
void main() { print("%d\n", (int)Permission.ALL); }
