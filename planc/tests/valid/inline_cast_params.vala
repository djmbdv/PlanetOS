// Parameter substitution has to walk into casts. A cast used to be invisible to
// the inliner walkers, so inlining a callee whose body is `return (int) (...)`
// or whose argument is `(uint32) ms` left the callee's parameter name behind and
// it failed to resolve in the caller.

int scaled (int a, int b) {
    return (int) (((int64) a * (int64) b) >> 16);
}

void sink (uint32 v) {
    print (@"sink=$((int) v)\n");
}

void relay (int ms) {
    sink ((uint32) ms);
}

int widen (uint8 b) {
    return (int) b;
}

int main () {
    print (@"scaled=$((int) scaled (65536, 3))\n");
    relay (7);
    int ms = 5;
    relay (ms);
    uint8[] bytes = new uint8[3];
    bytes[0] = 200;
    bytes[1] = 7;
    bytes[2] = 255;
    int total = 0;
    for (int i = 0; i < bytes.length; i++)
        total += widen (bytes[i]);
    print (@"total=$total\n");
    return 0;
}
