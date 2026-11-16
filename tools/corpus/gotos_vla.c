// Tier 2: goto/labels and variable-length arrays.
int first_negative (const int *v, int n) {
    int found = -1;
    for (int i = 0; i < n; i++) {
        if (v[i] < 0) {
            found = i;
            goto done;
        }
    }
done:
    return found;
}

int vla_sum (int n) {
    int scratch[n];
    for (int i = 0; i < n; i++)
        scratch[i] = i;
    int s = 0;
    for (int i = 0; i < n; i++)
        s += scratch[i];
    return s;
}