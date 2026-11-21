# Directory tree, working directory and path-relative file commands, inside a
# test/ subtree so the case never touches the shared XFS root.
mkdir test
mkdir test/dirs
cd test/dirs
mkdir docs
cd docs
pwd
write note.txt hola
ls -l
cat note.txt
cd ..
cat docs/note.txt
mv docs/note.txt docs/n2.txt
cat docs/n2.txt
rm docs
rm docs/n2.txt
rm docs
test -e docs || echo dir-gone
