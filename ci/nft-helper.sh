#!/bin/sh
# ci/nft-helper.sh - exercise libexec/blocklistd-helper against a real
# nftables ruleset.  Must run as root INSIDE a throwaway network
# namespace (the Ubuntu nftables job does `ip netns exec`), so the
# runner's own firewall is never touched.  Covers the native Linux backend: v4/v6
# host entries, a v4 prefix, IPv4-mapped IPv6, rem and flush.
set -eu
TOP=$(pwd)
H="$TOP/libexec/blocklistd-helper"
BL_LOGDIR=${BL_LOGDIR:-$TOP/ci-logs}
mkdir -p "$BL_LOGDIR"
export BLOCKLIST_PF=nft

[ "$(id -u)" = 0 ] || { echo "needs root"; exit 1; }
# refuse to run against the host namespace
[ -n "$(ip netns identify $$ 2>/dev/null)" ] || {
	echo "not inside a named netns; refusing to touch the host ruleset"
	exit 1
}

nft -f "$TOP/etc/nftables/blocklistd.nft"

helper() {	# expect-output args...
	want=$1; shift
	got=$(sh "$H" "$@")
	echo "helper $* -> $got"
	[ "$got" = "$want" ] || { echo "expected '$want'"; exit 1; }
}
in_set() {	# set elem
	nft list set inet blocklistd "$1" | tee -a "$BL_LOGDIR/nft-sets.txt" |
	    grep -qE "(^|[[:space:]{,])$2([[:space:],}]|$)"
}

helper OK add blocklistd udp 192.0.2.1 32 500
helper OK add blocklistd udp 2001:db8::1 128 500
helper OK add blocklistd tcp 198.51.100.0 24 22
helper OK add blocklistd udp ::ffff:203.0.113.7 128 500
nft list ruleset > "$BL_LOGDIR/nft-ruleset.txt"
cat "$BL_LOGDIR/nft-ruleset.txt"
in_set banned4 192.0.2.1
in_set banned6 2001:db8::1
in_set banned4 198.51.100.0/24
in_set banned4 203.0.113.7

helper OK rem blocklistd udp 192.0.2.1 32 500
if in_set banned4 192.0.2.1; then echo "rem did not delete"; exit 1; fi
in_set banned4 198.51.100.0/24

sh "$H" flush blocklistd
if nft list set inet blocklistd banned4 | grep -q elements ||
   nft list set inet blocklistd banned6 | grep -q elements; then
	nft list ruleset; echo "flush left elements"; exit 1
fi
nft delete table inet blocklistd
echo "=== nft-helper.sh PASS ==="
