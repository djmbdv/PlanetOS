int main () {
    int[] xs = { 42 };
    int* p = &xs[0];
    uintptr a = uintptr.from_pointer (p);
    if (a == 0) return 1;

    void* vp = a.to_pointer ();
    uintptr b = uintptr.from_pointer (vp);
    if (a != b) return 2;

    void* np = null;
    if (uintptr.from_pointer (np) != 0) return 3;
    uintptr z = 0;
    if (z.to_pointer () != null) return 4;

    int[] buf = new int[8];
    uintptr p0 = uintptr.from_pointer (&buf[0]);
    uintptr p4 = uintptr.from_pointer (&buf[4]);
    if (p4 - p0 != 32) return 5;

    uint8[] bytes = new uint8[4];
    if (uintptr.from_pointer ((void*) bytes) == 0) return 6;

    return 0;
}
