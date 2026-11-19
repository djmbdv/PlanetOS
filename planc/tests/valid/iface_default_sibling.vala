interface Item {
    public abstract string raw ();
    public virtual string shown () {
        return "[" + raw () + "]";
    }
}
class Thing : Item {
    public string shown () {
        return "t" + raw ();
    }
    public string raw () {
        return "r";
    }
}
class Plain : Item {
    public string raw () {
        return "p";
    }
}
int main () {
    Item a = new Thing ();
    Item b = new Plain ();
    print (@"$(a.shown ()) $(b.shown ())\n");
    return 0;
}