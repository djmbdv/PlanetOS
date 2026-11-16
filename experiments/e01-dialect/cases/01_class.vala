public class Greeting : Object {
    public string name { get; set; default = "world"; }
    public int times { get; set; default = 1; }
    public signal void said(string who);
    public Greeting(string n) { this.name = n; }
    public virtual string text() { return "hello " + name; }
}
public class Loud : Greeting {
    public Loud() { base("loud"); }
    public override string text() { return "HELLO " + name; }
}
void main() { var g = new Greeting("x"); print("%s %d\n", g.text(), g.times); }
