public class Resource : Object { public Mutex mutex; }
void main() { var r = new Resource(); lock (r.mutex) { print("inside\n"); } }
