// `#if` / `#elif` / `#else` / `#endif` and `"""` verbatim strings.
void main () {
#if VALA_0_56
    print ("v056\n");
#endif
#if VALA_0_60
    print ("v060\n");
#elif VALA_0_50
    print ("elif\n");
#else
    print ("else\n");
#endif
#if FOO
    print ("foo\n");
#endif
#if !FOO && (VALA_0_56 || FOO)
    print ("and-or-not\n");
#endif
    string v = """a\nb
  c""";
    print (@"$(v.length)\n");
    print (v);
    print ("\n");
}