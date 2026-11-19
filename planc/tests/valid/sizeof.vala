struct Pt {
    public int x;
    public int y;
}
int main () {
    int v = 1;
    print (@"$(sizeof (int)) $(sizeof (Pt)) $(sizeof (v)) $(sizeof (double))\n");
    return 0;
}