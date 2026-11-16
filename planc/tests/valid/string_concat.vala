string greet(string who) {
    return "hello " + who + "!";
}

int main() {
    string a = "hello" + " " + "world\n";
    print(a);
    string g = greet("Planet" + "OS");
    print(@"$g\n");
    if (g == "hello PlanetOS!" && g.length == 15) {
        return a.length;
    }
    return 1;
}
