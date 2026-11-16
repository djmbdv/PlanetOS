errordomain Failure { SEVERE, MINOR }
int attempt(bool failing) throws Failure {
    if (failing) throw new Failure.SEVERE("severe");
    return 7;
}
void main() {
    try { print("%d\n", attempt(false)); }
    catch (Failure f) { print("caught %d %s\n", f.code, f.message); }
}
