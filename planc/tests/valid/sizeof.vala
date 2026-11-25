namespace Geo {
    public struct Vec3 {
        public double x;
        public double y;
        public double z;
    }
}

struct Pt {
    public int x;
    public int y;
}

const int PT_BYTES = sizeof (Pt);
const int INT_BYTES = sizeof (int);

int size_of_type<T> () {
    return sizeof (T);
}

int main () {
    int v = 1;
    int[] arr = new int[3];
    print (@"$(sizeof (int)) $(sizeof (Pt)) $(sizeof (v)) $(sizeof (double))\n");
    print (@"$PT_BYTES $INT_BYTES $(sizeof (Geo.Vec3)) $(sizeof (void)) $(sizeof (int[]))\n");
    print (@"$(size_of_type<int> ()) $(size_of_type<Pt> ()) $(sizeof (arr)) $(sizeof (Pt () { x = 1, y = 2 }))\n");
    return 0;
}
