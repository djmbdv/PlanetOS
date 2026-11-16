# Directory tree, working directory and path-relative file commands.
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
