struct P {
    public int x;
    public int y;
}

int main () {
    var arr = new P[2];
    arr[0].x = 1;
    arr[1].x = 2;
    int i = 2;
    arr[i].x = 3;
    return arr[0].x;
}
