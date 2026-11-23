// Pure-Vala Gee delegates, interfaces, comparators, hashers, and string/int helpers.
namespace Gee {

    public delegate int CompareDataFunc<G> (G a, G b);
    public delegate int HashDataFunc<G> (G v);
    public delegate bool EqualDataFunc<G> (G a, G b);
    public delegate bool Predicate<G> (G g);
    public delegate bool ForallFunc<G> (G g);
    public delegate R MapFunc<R, G> (G g);

    public interface Iterator<G> : Object {
        public abstract bool next ();
        public abstract bool has_next ();
        public abstract G get ();
    }

    public interface Iterable<G> : Object {
        public abstract Iterator<G> iterator ();
        public abstract bool forall (ForallFunc<G> f);
    }

    public interface Collection<G> : Iterable<G> {
        public abstract int size { get; }
        public abstract bool is_empty { get; }
        public abstract bool add (G item);
        public abstract bool contains (G item);
        public abstract bool remove (G item);
        public abstract void clear ();
        public abstract G[] to_array ();
    }

    public interface List<G> : Collection<G> {
        public abstract G get (int index);
        public abstract void set (int index, G item);
        public abstract int index_of (G item);
        public abstract void insert (int index, G item);
        public abstract G remove_at (int index);
        public abstract G first ();
        public abstract G last ();
    }

    public interface Set<G> : Collection<G> {
    }

    public interface Queue<G> : Collection<G> {
        public abstract bool offer (G item);
        public abstract G peek ();
        public abstract G poll ();
    }

    public interface Deque<G> : Queue<G> {
        public abstract bool offer_head (G item);
        public abstract G peek_head ();
        public abstract G poll_head ();
        public abstract bool offer_tail (G item);
        public abstract G peek_tail ();
        public abstract G poll_tail ();
    }

    public interface Map<K, V> : Object {
        public abstract int size { get; }
        public abstract bool is_empty { get; }
        public abstract bool has_key (K key);
        public abstract bool has (K key, V value);
        public abstract V get (K key);
        public abstract void set (K key, V value);
        public abstract bool unset (K key);
        public abstract void clear ();
    }

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

    internal int _gee_next_seed = 0x13579BDF;

    public int hash_mix (int h, int seed = 0) {
        uint32 x = (uint32) h ^ (uint32) seed;
        x ^= x >> 16;
        x *= (uint32) 0x85EBCA6B;
        x ^= x >> 13;
        x *= (uint32) 0xC2B2AE35;
        x ^= x >> 16;
        return (int) (x & (uint32) 0x7FFFFFFF);
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
