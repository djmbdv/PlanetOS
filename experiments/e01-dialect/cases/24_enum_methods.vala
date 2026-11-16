public enum Color { RED, GREEN; public string label() { return "color"; } }
void main() { print("%s %d\n", Color.GREEN.label(), Color.GREEN); }
