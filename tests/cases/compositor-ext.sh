# Saturn inside the compositor: the compositor allocates the shared block, the
# client attaches it, draws and publishes a frame, and the compositor turns the
# published rectangle into damage (no file transport involved).
compositor --ext saturn.elf --keys abcd --frames 400
ls /tmp
