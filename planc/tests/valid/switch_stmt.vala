enum Kind {
    ALPHA,
    BETA,
    GAMMA,
    DELTA
}

int eval_int(int x) {
    int r = 0;
    switch (x) {
        case 1:
        case 2:
            r = 20;
            break;
        default:
            r = 7;
            break;
    }
    return r;
}

int eval_kind(Kind k) {
    switch (k) {
        case Kind.ALPHA:
            return 1;
        case Kind.BETA:
        case Kind.GAMMA:
            return 3;
        default:
            return 9;
    }
}

int eval_str(string prefix) {
    switch (prefix + "_k") {
        case "bar_k":
            return 1;
        case "foo" + "_k":
            return 4;
        default:
            return 0;
    }
}

int main() {
    int a = eval_int(2);
    int b = eval_int(99);
    int c = eval_kind(Kind.BETA);
    int d = eval_str("foo");

    int acc = 0;
    string tmp = "item";
    for (int i = 0; i < 4; i++) {
        switch (i) {
            case 0:
                string s0 = tmp + "0";
                acc += s0.length;
                break;
            case 1:
                string s1 = tmp + "1";
                if (s1.length == 5) {
                    continue;
                }
                acc += 100;
                break;
            case 2:
            case 3:
                acc += 2;
                break;
            default:
                break;
        }
        acc += 1;
    }

    print(@"$(a),$(b),$(c),$(d),$(acc)\n");
    return a + b + c + d + acc;
}
