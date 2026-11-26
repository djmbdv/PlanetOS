// `printf` refuses a format that is not a literal: the conversions could not
// be checked against the arguments.
void main () {
    string fmt = "%d";
    print ((fmt).printf (1));
}
