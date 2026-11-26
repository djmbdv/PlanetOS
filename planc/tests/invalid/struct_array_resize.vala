struct P {
    public int x;
    public int y;
}

int main () {
    var arr = new P[2];
    arr[0].x = 1;
    arr.resize (4);
    return arr.length;
}
