int add_with_default(int a, int b = 10, int c = 5) {
    return a + b + c;
}

public class Config {
    public string name;
    public int code;
    public int port;

    public Config(string name = "main") : this.with_code(name, 7) {
    }

    public Config.with_code(string name, int code = 42, int port = 8080) {
        this.name = name;
        this.code = code;
        this.port = port;
    }

    public Config.preset() : this("preset") {
        this.code = 100;
    }

    public static int calc(int x, int scale = 2) {
        return x * scale;
    }

    public string summary(string sep = ":") {
        return @"$name$sep$code$sep$port";
    }
}

int main(string[] args) {
    var c1 = new Config();
    var c2 = new Config.with_code("custom");
    var c3 = new Config.with_code("full", 99, 9000);
    var c4 = new Config.preset();

    string s2 = c2.summary("/");
    print(@"c1=$(c1.summary())\n");
    print(@"c2=$s2\n");
    print(@"c3=$(c3.summary())\n");
    print(@"c4=$(c4.summary())\n");
    print(@"fn=$(add_with_default(1)):$(add_with_default(1, 2)):$(add_with_default(1, 2, 3))\n");
    print(@"st=$(Config.calc(6)):$(Config.calc(6, 5))\n");

    int raw = 0x12ab;
    int u8 = (int) ((uint8) (raw & 0xff));
    int s8 = (int) ((int8) 0xfb);
    print(@"casts=$u8:$s8\n");

    int argc = args.length;
    bool has_prog = args[0].length > 0;
    print(@"args=$argc:$has_prog\n");
    return 0;
}
