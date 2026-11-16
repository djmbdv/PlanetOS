bool g_flag = true;
bool g_zero;

bool is_even(int n) {
    return (n & 1) == 0;
}

int main() {
    bool a = true;
    bool b = false;
    var c = 3 < 4;
    var d = !a;
    print(@"a=$a b=$b c=$c d=$d g=$g_flag z=$g_zero\n");
    if (is_even(4) && !b && g_flag) {
        return 42;
    }
    return 0;
}
