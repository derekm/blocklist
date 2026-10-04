#!/bin/sh
# ci/build.sh - shared build/assert body for every blocklist CI leg
# (Ubuntu, Fedora, FreeBSD, NetBSD), in the style of racoon2's
# samples/{netbsd,freebsd}-ci/*-build.sh: one script, so every OS
# builds and checks the same thing.  POSIX sh (FreeBSD/NetBSD /bin/sh).
#
# Runs from the checkout root.  Inputs (environment):
#   BL_PF_BACKEND     --with-pf-backend value (nft|iptables|npf|pf|...)
#   BL_PREFIX         --prefix                     (default /usr/local)
#   BL_RUNSTATEDIR    --runstatedir, empty = autoconf default
#                     (${localstatedir}/run)
#   BL_EXPECT_SOCK    socket path libblocklist/blocklistd must compile in
#   BL_EXPECT_SYSTEMD yes|no: whether make install ships systemd units
#   BL_CONFIGURE_EXTRA extra ./configure arguments (word-split)
#   BL_LOGDIR         where logs go                (default ./ci-logs)
# Builds port/ (lib + blocklistd + blocklistctl + srvtest/cltest), checks
# the compiled-in paths, does a DESTDIR install and a header-only consumer
# compile.  Never touches a packet filter.  Exits non-zero on failure.
set -eu

: "${BL_PF_BACKEND:?}" "${BL_EXPECT_SOCK:?}" "${BL_EXPECT_SYSTEMD:?}"
BL_PREFIX=${BL_PREFIX:-/usr/local}
BL_RUNSTATEDIR=${BL_RUNSTATEDIR:-}
TOP=$(pwd)
BL_LOGDIR=${BL_LOGDIR:-$TOP/ci-logs}
mkdir -p "$BL_LOGDIR"

# FreeBSD/NetBSD make is bmake; the automake Makefiles are fine with it,
# but prefer gmake when present (same choice as racoon2's BSD legs).
if command -v gmake >/dev/null 2>&1; then MAKE=gmake; else MAKE=make; fi
CC=${CC:-cc}
export CC
echo "=== $(uname -srm) MAKE=$MAKE CC=$CC pf-backend=$BL_PF_BACKEND ==="

# printable-strings scan without binutils (NetBSD base has no strings
# unless the comp set is installed).
has_string() {	# file string
	LC_ALL=C tr -c '[:print:]' '\n' < "$1" | grep -qxF "$2"
}

cd "$TOP/port"
echo "=== Bootstrap ==="
autoreconf -fi

echo "=== Configure ==="
set -- --prefix="$BL_PREFIX" --sysconfdir=/etc --localstatedir=/var \
	--with-pf-backend="$BL_PF_BACKEND"
[ -n "$BL_RUNSTATEDIR" ] && set -- "$@" --runstatedir="$BL_RUNSTATEDIR"
# shellcheck disable=SC2086
set -- "$@" ${BL_CONFIGURE_EXTRA:-}
echo "./configure $*"
./configure "$@" || { cat config.log > "$BL_LOGDIR/config.log"; exit 1; }
cp config.log "$BL_LOGDIR/config.log"
cp config.h "$BL_LOGDIR/config.h"

echo "=== Build ==="
$MAKE -j2

echo "=== Assert: programs + library built ==="
test -x blocklistd && test -x blocklistctl
test -x srvtest && test -x cltest
lib=
for f in .libs/libblocklist.so.* .libs/libblocklist.so; do
	[ -f "$f" ] && { lib=$f; break; }
done
test -n "$lib" || { echo "no shared libblocklist built"; ls -la .libs; exit 1; }
echo "library: $lib"

echo "=== Assert: configured backend recorded ==="
grep -qx "#define PF_BACKEND \"$BL_PF_BACKEND\"" config.h

echo "=== Assert: compiled-in socket path is $BL_EXPECT_SOCK ==="
# libblocklist (what iked/sshd link) and blocklistd must agree; a mismatch
# silently drops every report.
has_string "$lib" "$BL_EXPECT_SOCK"
daemon=blocklistd
[ -x .libs/blocklistd ] && daemon=.libs/blocklistd
has_string "$daemon" "$BL_EXPECT_SOCK"

echo "=== Assert: helper parses ==="
sh -n "$TOP/libexec/blocklistd-helper"

echo "=== DESTDIR install ==="
DEST="$TOP/_dest"
rm -rf "$DEST"
$MAKE install DESTDIR="$DEST"
( cd "$DEST" && find . -type f -o -type l | sort ) > "$BL_LOGDIR/install-manifest.txt"
cat "$BL_LOGDIR/install-manifest.txt"
P="$DEST$BL_PREFIX"
for f in sbin/blocklistd sbin/blocklistctl libexec/blocklistd-helper \
    include/blocklist.h share/man/man8/blocklistd.8 \
    share/man/man5/blocklistd.conf.5 share/examples/blocklistd.conf \
    share/examples/npf.conf share/examples/blocklistd.nft; do
	test -e "$P/$f" || { echo "missing installed $f"; exit 1; }
done
# libdir is lib64 on Fedora (config.site), lib elsewhere
L=
for d in "$P/lib64" "$P/lib"; do
	[ -e "$d/libblocklist.so" ] && { L=$d; break; }
done
test -n "$L" || { echo "libblocklist.so not installed"; exit 1; }
units=$(grep -c 'systemd/system/blocklistd\.' "$BL_LOGDIR/install-manifest.txt" || true)
case $BL_EXPECT_SYSTEMD in
yes)	[ "$units" -eq 2 ] || { echo "expected 2 systemd units, got $units"; exit 1; } ;;
no)	[ "$units" -eq 0 ] || { echo "systemd units installed on a non-systemd OS"; exit 1; } ;;
esac

echo "=== Header-only consumer (what racoon2 iked compiles) ==="
# <blocklist.h> must be self-contained: no prior <stdarg.h>/<stddef.h>.
cat > "$BL_LOGDIR/consumer.c" <<'C'
#include <blocklist.h>
int main(void)
{
	struct blocklist *b = blocklist_open();
	int a = BLOCKLIST_AUTH_FAIL, o = BLOCKLIST_AUTH_OK;

	(void)blocklist_sa_r(b, a, -1, (const struct sockaddr *)0, 0, "ci");
	blocklist_close(b);
	return o;
}
C
$CC -Wall -Werror -I"$P/include" -o "$BL_LOGDIR/consumer" \
	"$BL_LOGDIR/consumer.c" -L"$L" -lblocklist
echo "consumer OK"
echo "=== build.sh PASS ==="
