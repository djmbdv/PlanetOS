struct Named {
    public string name;
    public int v;
}

int main () {
    var arr = new Named[2];
    arr[0].name = "a";
    print (@"$(arr[0].name)\n");
    return 0;
}
