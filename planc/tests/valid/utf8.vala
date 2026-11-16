// Test: native UTF-8 literals, \u/\U escapes, unichar, char_count, get_char, validate
// Expect exit: 0
// Expect stdout:
// chars=5 valid=1
// cp0=0xF1 cp1=0x20AC cp2=0x1F680

int main () {
    string s = "ñ€\U0001F680\u00e1!";
    int cc = s.char_count ();
    int ok = s.validate () ? 1 : 0;
    print (@"chars=$cc valid=$ok\n");
    unichar c0 = s.get_char (0);
    unichar c1 = s.get_char (2);
    unichar c2 = s.get_char (5);
    if (c0 == 0xF1 && c1 == 0x20AC && c2 == 0x1F680)
        print ("cp0=0xF1 cp1=0x20AC cp2=0x1F680\n");
    return 0;
}
