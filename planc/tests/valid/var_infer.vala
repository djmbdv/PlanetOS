string static_tpl() {
    return @"static $$";
}

int main() {
    var msg = "ok\n";
    var len = msg.length;
    var s2 = static_tpl();
    print(msg);
    print(@"$s2\n");
    return len + s2.length;
}
