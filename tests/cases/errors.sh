# Error paths next to the write path: a failed mv/cat keeps its message, and the
# unlink + mkdir round-trip shows up in the listing afterwards. The case works
# inside test/errors: deleting the XFS root hello.txt would break later cases.
mkdir test
mkdir test/errors
write test/errors/victim.txt hola
rm test/errors/victim.txt
mv test/errors/missing test/errors/x
cat test/errors/nope.txt
mkdir test/errors/hello.txt
cat test/errors/hello.txt
ls test/errors
