string id(string s) {
    return s;
}

int main() {
    string a = "planet";
    string b = id("planet");
    string c = "plan";
    string empty;

    int score = 0;
    if (a == b) { score = score + 1; }
    if (a == "planet") { score = score + 2; }
    if (a != c) { score = score + 4; }
    if (c == a) { score = score + 8; }
    if (empty == "") { score = score + 16; }
    if (a != "planet") { score = score + 32; }
    return score;
}
