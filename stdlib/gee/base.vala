// Pure-Vala Gee comparators, hashers, and string/int helpers.
namespace Gee {

    public class Comparator<G> : Object {
        public virtual int compare (G a, G b) {
            return 0;
        }
    }

    public class IntComparator : Comparator<int> {
        public override int compare (int a, int b) {
            if (a < b) return -1;
            if (a > b) return 1;
            return 0;
        }
    }

    public class StrComparator : Comparator<string> {
        public override int compare (string a, string b) {
            return str_cmp (a, b);
        }
    }

    public class Hasher<G> : Object {
        public virtual int hash (G v) {
            return __planc_hash (v);
        }

        public virtual bool equal (G a, G b) {
            return a == b;
        }
    }

    public int str_hash (string s) {
        return __planc_hash (s);
    }

    public int int_hash (int v) {
        return __planc_hash (v);
    }

    public int str_cmp (string a, string b) {
        int la = a.length;
        int lb = b.length;
        int n = (la < lb) ? la : lb;
        for (int i = 0; i < n; i++) {
            int ca = (int) a[i];
            int cb = (int) b[i];
            if (ca != cb)
                return ca - cb;
        }
        return la - lb;
    }

    public int int_cmp (int a, int b) {
        if (a < b) return -1;
        if (a > b) return 1;
        return 0;
    }

}
