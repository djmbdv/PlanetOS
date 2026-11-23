// Test suite for GLib.Uuid (WyRand + AVX2).
using GLib;

int main (string[] args) {
    int fails = 0;
    int checks = 0;

    string u1 = Uuid.string_random ();
    string u2 = Uuid.string_random ();
    print (@"uuid:1=$u1\n");
    print (@"uuid:2=$u2\n");

    checks++;
    if (u1.length != 36 || !Uuid.string_is_valid (u1)) {
        print ("uuid: FAIL u1 invalid\n");
        fails++;
    }
    checks++;
    if (u2.length != 36 || !Uuid.string_is_valid (u2)) {
        print ("uuid: FAIL u2 invalid\n");
        fails++;
    }
    checks++;
    if (u1 == u2) {
        print ("uuid: FAIL u1 == u2\n");
        fails++;
    }
    checks++;
    if (u1[14] != '4') {
        print ("uuid: FAIL u1 version != 4\n");
        fails++;
    }
    checks++;
    char v1 = u1[19];
    if (v1 != '8' && v1 != '9' && v1 != 'a' && v1 != 'b') {
        print ("uuid: FAIL u1 variant invalid\n");
        fails++;
    }

    checks++;
    if (!Uuid.string_is_valid ("550E8400-E29B-41D4-A716-446655440000")) {
        print ("uuid: FAIL uppercase valid\n");
        fails++;
    }
    checks++;
    if (Uuid.string_is_valid ("") || Uuid.string_is_valid ("550e8400-e29b-41d4-a716-44665544000")
        || Uuid.string_is_valid ("550e8400e29b-41d4-a716-4466554400000")
        || Uuid.string_is_valid ("550e8400-e29b-41d4-a716-44665544000g")) {
        print ("uuid: FAIL invalid accepted\n");
        fails++;
    }

    print (@"uuid:summary checks=$checks failures=$fails\n");
    return (fails == 0) ? 0 : 1;
}
