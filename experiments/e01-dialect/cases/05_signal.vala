public class Emitter : Object {
    public signal void notice(int code, string message);
    public void fire(int c, string m) { notice(c, m); }
}
void main() {
    var e = new Emitter();
    e.notice.connect((c, m) => print("child: %d %s\n", c, m));
    e.fire(1, "one");
}
