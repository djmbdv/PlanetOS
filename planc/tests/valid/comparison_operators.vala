// Every comparison operator, signed and unsigned, at the value boundaries
// where a condition-code mistake shows up. `setcc`/`inverted_branch` dispatch
// on op[0], so a wrong mapping must fail here.
int lt_s (int a, int b) { return a < b; }
int le_s (int a, int b) { return a <= b; }
int gt_s (int a, int b) { return a > b; }
int ge_s (int a, int b) { return a >= b; }
int eq_s (int a, int b) { return a == b; }
int ne_s (int a, int b) { return a != b; }

int lt_u (uint64 a, uint64 b) { return a < b; }
int le_u (uint64 a, uint64 b) { return a <= b; }
int gt_u (uint64 a, uint64 b) { return a > b; }
int ge_u (uint64 a, uint64 b) { return a >= b; }
int eq_u (uint64 a, uint64 b) { return a == b; }
int ne_u (uint64 a, uint64 b) { return a != b; }

int main() {
    int64[] vals = new int64[9];
    vals[0] = -9223372036854775807 - 1;
    vals[1] = -2147483648;
    vals[2] = -1000;
    vals[3] = -1;
    vals[4] = 0;
    vals[5] = 1;
    vals[6] = 1000;
    vals[7] = 2147483647;
    vals[8] = 9223372036854775807;
    int bad = 0;
    // Signed 64-bit comparisons, reference results from int64 arithmetic.
    int64[] a64 = new int64[3];
    a64[0] = -1;
    a64[1] = 0;
    a64[2] = 1;
    for (int i = 0; i < 9; i++) {
        int64 x = vals[i];
        for (int j = 0; j < 3; j++) {
            int64 y = a64[j];
            bool want;
            want = x < y;   if (lt_s((int) x, (int) y) != (want ? 1 : 0)) bad++;
            want = x <= y;  if (le_s((int) x, (int) y) != (want ? 1 : 0)) bad++;
            want = x > y;   if (gt_s((int) x, (int) y) != (want ? 1 : 0)) bad++;
            want = x >= y;  if (ge_s((int) x, (int) y) != (want ? 1 : 0)) bad++;
            want = x == y;  if (eq_s((int) x, (int) y) != (want ? 1 : 0)) bad++;
            want = x != y;  if (ne_s((int) x, (int) y) != (want ? 1 : 0)) bad++;
        }
    }
    // Unsigned: 0 and 2^63 sort below 2^64-1, which signed codes would flip.
    uint64[] uvals = new uint64[5];
    uvals[0] = 0u;
    uvals[1] = 1u;
    uvals[2] = 9223372036854775808u;
    uvals[3] = 9223372036854775809u;
    uvals[4] = 18446744073709551615u;
    for (int i = 0; i < 5; i++) {
        uint64 x = uvals[i];
        for (int j = 0; j < 5; j++) {
            uint64 y = uvals[j];
            bool want;
            want = x < y;   if (lt_u(x, y) != (want ? 1 : 0)) bad++;
            want = x <= y;  if (le_u(x, y) != (want ? 1 : 0)) bad++;
            want = x > y;   if (gt_u(x, y) != (want ? 1 : 0)) bad++;
            want = x >= y;  if (ge_u(x, y) != (want ? 1 : 0)) bad++;
            want = x == y;  if (eq_u(x, y) != (want ? 1 : 0)) bad++;
            want = x != y;  if (ne_u(x, y) != (want ? 1 : 0)) bad++;
        }
    }
    // Branch forms use the inverted conditions; check both directions.
    int signed_hits = 0;
    int unsigned_hits = 0;
    for (int i = 0; i < 9; i++) {
        if (vals[i] < 0) signed_hits++;
        if (vals[i] >= 0) signed_hits += 10;
        if ((uint64) (i > 0 ? 1u : 0u) <= 1u) unsigned_hits++;
    }
    for (int i = 0; i < 5; i++) {
        if (uvals[i] > 9223372036854775808u) unsigned_hits += 100;
    }
    print(@"bad=$bad s=$signed_hits u=$unsigned_hits\n");
    return bad;
}
