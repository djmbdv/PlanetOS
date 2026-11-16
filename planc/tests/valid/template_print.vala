void main() {
    string name = "PlanetOS";
    int n = 42;
    int zero = 0;
    int neg = -123;
    int min64 = -9223372036854775807 - 1;
    print(@"hello $name, n=$n, zero=$zero, neg=$neg\n");
    print(@"expr=$(n * 2 + 1), len=$(name.length), cost=$$100\n");
    print(@"min=$min64\n");
    print(@"");
}
