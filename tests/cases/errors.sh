# Error paths: XFS stays read-only and a failed mkdir must not shadow it.
rm hello.txt
mv missing x
cat nope.txt
mkdir hello.txt
cat hello.txt
