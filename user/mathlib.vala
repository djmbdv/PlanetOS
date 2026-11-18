// PlanetOS dynamic library (.dlib) example: pure-Vala exported functions.

public int dlib_add (int a, int b) {
    return a + b;
}

public int dlib_mul (int a, int b) {
    return a * b;
}

public int dlib_mix (int a, int b) {
    return (a * 3) + (b * 2);
}
