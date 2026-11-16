public interface Named {
    public abstract string get_name();
    public virtual string badge() {
        return "named";
    }
}

public interface Described : Named {
    public abstract int weight();
}

public interface Clickable {
    public abstract string on_click(int code);
}

public class BaseItem {
    public int id;

    public BaseItem(int id) {
        this.id = id;
    }

    public virtual string kind() {
        return "base";
    }
}

public class Button : BaseItem, Described, Clickable {
    public string label;

    public Button(int id, string label) : base(id) {
        this.label = label;
    }

    public override string kind() {
        return "button";
    }

    public string get_name() {
        return label;
    }

    public virtual string badge() {
        return "btn-badge";
    }

    public int weight() {
        return id * 10;
    }

    public string on_click(int code) {
        return @"click:$label:$code";
    }
}

public class CustomButton : Button {
    public CustomButton(int id, string label) : base(id, label) {
    }

    public override string badge() {
        return "custom-badge";
    }

    public override string kind() {
        return "custom";
    }
}

public class LabelOnly : Named {
    public string text;

    public LabelOnly(string text) {
        this.text = text;
    }

    public string get_name() {
        return text;
    }
}

int main() {
    var b = new Button(2, "OK");
    var cb = new CustomButton(3, "Go");
    var lo = new LabelOnly("Info");

    Described d = b;
    Clickable c = b;
    print(@"d=$(d.get_name()):$(d.weight()):$(d.badge())\n");
    print(@"c=$(c.on_click(9))\n");

    Named[] items = new Named[3];
    items[0] = b;
    items[1] = cb;
    items[2] = lo;

    for (int i = 0; i < items.length; i++) {
        Named n = items[i];
        print(@"i=$i name=$(n.get_name()) badge=$(n.badge())\n");
        if (n is Clickable) {
            var cl = (Clickable) n;
            print(@"clickable=$(cl.on_click(i))\n");
        }
        var as_btn = n as Button;
        if (as_btn != null) {
            print(@"btn_kind=$(as_btn.kind())\n");
        }
    }

    BaseItem bi = b;
    var n2 = (Named) bi;
    print(@"n2=$(n2.get_name())\n");
    return 0;
}
