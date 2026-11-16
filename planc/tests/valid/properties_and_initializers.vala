class Config {
    public string title { get; set; default = "app"; }
    public int port { get; set; default = 8080; }
    private int _retries = 1;

    public int retries {
        get {
            return _retries;
        }
        set {
            _retries = value * 2;
        }
    }

    public Config(string title) {
        this.title = title;
    }
}

class BaseWidget {
    public virtual int weight {
        get {
            return 10;
        }
        set {
        }
    }
    public virtual string kind { get; set; default = "base"; }
}

class Button : BaseWidget {
    private int _w = 42;
    public override int weight {
        get {
            return _w;
        }
        set {
            _w = value;
        }
    }
    public override string kind {
        get {
            return "button";
        }
        set {
        }
    }
}

int main() {
    var bare = new Config("bare");
    var cfg = new Config("web") { port = 9000, retries = 3 };
    cfg.title = @"prod-" + "v2";

    BaseWidget b = new Button();
    b.weight = 99;

    print(@"bare=$(bare.title):$(bare.port):$(bare.retries)\n");
    print(@"cfg=$(cfg.title):$(cfg.port):$(cfg.retries)\n");
    print(@"widget=$(b.kind):$(b.weight)\n");
    return 0;
}
