# The Gio layer (files, streams, directories) must stay green and idempotent.
# The demo keeps every scratch file next to its target, so it runs in test/gio.
mkdir test
mkdir test/gio
write test/gio/hello.txt hola
gio_demo test/gio/hello.txt
gio_demo test/gio/hello.txt
