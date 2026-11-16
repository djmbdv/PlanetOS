class Payload {
    public string tag;

    public Payload(string tag) {
        this.tag = tag;
    }

    ~Payload() {
        print(@"~Payload:$(this.tag)\n");
    }
}

class BaseRes {
    public string name;

    public BaseRes(string name) {
        this.name = name;
    }

    ~BaseRes() {
        print(@"~BaseRes:$(this.name)\n");
    }
}

class Holder : BaseRes {
    public Payload? child;

    public Holder(string name, Payload p) : base(name) {
        this.child = p;
    }

    ~Holder() {
        print(@"~Holder:$(this.name)\n");
    }
}

int main() {
    {
        Holder[] hs = {
            new Holder("first", new Payload("p1")),
            new Holder("second", new Payload("p2"))
        };
        hs[0].child = null;
        print("mid\n");
    }
    print("after\n");
    return 0;
}
