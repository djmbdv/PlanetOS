#!/bin/sh
# Environment for the Vala oracle. Usage:  . experiments/oracle/env.sh
TC="${PLANETOS_TC:-$HOME/.local/share/planetos-tc}"
[ -d "$TC/root" ] || { echo "oracle missing; run experiments/oracle/install.sh" >&2; return 1 2>/dev/null || exit 1; }
export PLANETOS_TC="$TC"
export PATH="$TC/root/usr/bin:$PATH"
export LD_LIBRARY_PATH="$TC/root/usr/lib/x86_64-linux-gnu:$TC/root/usr/lib/x86_64-linux-gnu/vala-0.56${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$TC/pc-extra:$TC/root/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$TC/root/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
