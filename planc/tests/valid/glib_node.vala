int main () {
    var root = new GLib.Node<string> ("root");
    var a = root.append (new GLib.Node<string> ("a"));
    var b = root.append (new GLib.Node<string> ("b"));
    var c = root.prepend (new GLib.Node<string> ("c"));
    var a1 = a.append (new GLib.Node<string> ("a1"));
    print (@"n=$(root.n_children ()) first=$(root.first_child ().data) last=$(root.last_child ().data) nth1=$(root.nth_child (1).data) depth=$(a1.depth ()) root=$(a1.get_root ().data)\n");
    b.unlink ();
    print (@"after_unlink=$(root.n_children ()) last=$(root.last_child ().data)\n");
    if (c.data != "c") return 1;
    return 0;
}
