# Command resolution: bare name, any case, exec prefix, worker task.
# Everything writable lives in test/exec so the shared XFS root stays intact.
mkdir test
mkdir test/exec
write test/exec/hello.txt xfs:hello from PlanetOS disk!
wc test/exec/hello.txt
GIO_DEMO.ELF test/exec/hello.txt
exec gio_demo test/exec/hello.txt
exec worker.elf
