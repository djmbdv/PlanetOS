[CCode (cname = "my_native_name")]
public class Thing : Object {
    [CCode (cname = "my_native_method")]
    public void run() { }
}
void main() { new Thing().run(); }
