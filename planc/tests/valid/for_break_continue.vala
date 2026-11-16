int main() {
    int sum = 0;

    /* Consecutive `for (int i = 0; ...)` loops reuse the same loop variable name */
    for (int i = 0; i < 10; i++) {
        if (i == 3) {
            continue;
        }
        if (i == 7) {
            break;
        }
        sum += i;
    }

    for (int i = 5; i > 0; i -= 2) {
        sum += i;
    }

    int k = 0;
    while (k < 10) {
        k++;
        if ((k & 1) == 0) {
            continue;
        }
        if (k > 5) {
            break;
        }
        sum += k;
    }

    /* sum = (0+1+2+4+5+6) + (5+3+1) + (1+3+5) = 18 + 9 + 9 = 36 */
    return sum;
}
