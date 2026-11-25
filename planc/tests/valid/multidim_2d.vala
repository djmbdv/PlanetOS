class Cell {
    public int v;
}

int main () {
    int r = 3;
    int c = 4;
    int[,] m = new int[r, c];
    print (@"len=$(m.length[0])x$(m.length[1])\n");
    for (int i = 0; i < m.length[0]; i++)
        for (int j = 0; j < m.length[1]; j++)
            m[i, j] = i * 100 + j;
    print (@"m=$(m[0, 0]):$(m[1, 2]):$(m[2, 3])\n");
    m[1, 2] += 5;
    print (@"inc=$(m[1, 2])\n");

    string[,] s = new string[2, 3];
    s[0, 1] = "x";
    print (@"s=$(s.length[0]):$(s.length[1]):$(s[0, 0].length):$(s[0, 1])\n");

    int[] row = m[1];
    print (@"row=$(row.length):$(row[2])\n");

    int total = 0;
    for (int i = 0; i < m.length[0]; i++)
        total += m[i, 0];
    print (@"total=$total\n");

    Cell[,] cells = new Cell[2, 2];
    Cell cc = new Cell ();
    cc.v = 9;
    cells[0, 1] = cc;
    print (@"cell=$(cells[0, 1].v):$(cells[1, 0] == null ? 1 : 0)\n");
    return 0;
}
