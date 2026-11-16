errordomain Failure { SEVERE, MINOR }
int attempt(bool failing) throws Failure {
    if (failing) throw new Failure.MINOR("minor");
    return 7;
}
void main() {
    try { print("%d\n", attempt(false)); }
    catch (Failure f) { print("error %s\n", f.message); }
}
