// Background worker task for preemptive multitasking test (--target=planetos --image-base=0x900000).

using Planet;

namespace UserWorker {

    int main () {
        int start = Sys.ticks ();
        int cur = start;
        while (cur - start < 4) {
            Sys.yield_cpu ();
            cur = Sys.ticks ();
        }
        print (@"worker: completed after $(cur - start) ticks\n");
        return 7;
    }
}
