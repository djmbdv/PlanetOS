# Error paths next to the write path: a failed mv/cat keeps its message, and the
# unlink + mkdir round-trip shows up in the listing afterwards.
rm hello.txt
mv missing x
cat nope.txt
mkdir hello.txt
cat hello.txt
ls /
