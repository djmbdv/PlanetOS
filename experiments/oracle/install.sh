#!/bin/sh
# Installs the Vala oracle into a local prefix, without root.
#
# Why this exists: valac is needed as a semantic reference during development,
# but it is NEVER part of the shipped toolchain (see docs/02-compiler.md).
# This script only builds the host-side experimentation environment.
set -eu

PREFIX="${PLANETOS_TC:-$HOME/.local/share/planetos-tc}"
PACKAGES="valac valac-bin valac-0.56-vapi libvala-0.56-0 libvalacodegen-0.56-0
          libglib2.0-dev libglib2.0-dev-bin libglib2.0-0t64 libglib2.0-bin
          libgio-2.0-dev"

mkdir -p "$PREFIX/debs" "$PREFIX/root" "$PREFIX/pc-extra"
cd "$PREFIX/debs"

# shellcheck disable=SC2086
apt-get download $PACKAGES

for d in ./*.deb; do dpkg-deb -x "$d" "$PREFIX/root"; done

# glib-2.0.pc declares Requires.private entries we do not need in order to
# compile: empty descriptors satisfy pkg-config.
cat > "$PREFIX/pc-extra/libpcre2-8.pc" <<'EOF'
Name: libpcre2-8
Description: validation stub for the Requires.private of glib-2.0
Version: 10.45
Libs: -lpcre2-8
EOF
cat > "$PREFIX/pc-extra/sysprof-capture-4.pc" <<'EOF'
Name: sysprof-capture-4
Description: validation stub for the Requires.private of glib-2.0
Version: 48.0
Libs: -lsysprof-capture-4
EOF

# The packaged .pc files point at /usr; rewrite them to the local prefix.
for n in glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0; do
    src="$PREFIX/root/usr/lib/x86_64-linux-gnu/pkgconfig/$n.pc"
    [ -f "$src" ] || continue
    sed "s|^prefix=/usr|prefix=$PREFIX/root/usr|" "$src" > "$PREFIX/pc-extra/$n.pc"
done

echo "oracle installed in $PREFIX"
echo "use it with:  . $PREFIX/env.sh"
