#!/bin/sh
# ci/smoke.sh - end-to-end smoke of libblocklist + blocklistd +
# blocklistctl on the build tree, WITHOUT touching a packet filter:
# blocklistd runs with -C pointing at a fake helper that only logs.
#
# srvtest (upstream test/srvtest.c) reports every datagram/connection it
# gets to blocklistd via blocklist_sa()/blocklist() on the *compiled-in*
# socket path; cltest sends them.  blocklistd itself is told -s
# $BL_EXPECT_SOCK (the path the service unit / rc.d script use), so the
# smoke fails if library and daemon disagree.  Checks: a UDP and a TCP
# report each reach blocklistd, match their [local] rule, trigger an
# "add" through the helper, show up in blocklistctl, and are restored by
# a blocklistd -r restart.  Needs root (socket dir).
set -eu

: "${BL_EXPECT_SOCK:?}"
TOP=$(pwd)
BL_LOGDIR=${BL_LOGDIR:-$TOP/ci-logs}
mkdir -p "$BL_LOGDIR"
B="$TOP/port"
W=$(mktemp -d /tmp/blsmoke.XXXXXX)
[ "$(id -u)" = 0 ] || { echo "smoke.sh must run as root"; exit 1; }

UPORT=16161 TPORT=16162
cat > "$W/blocklistd.conf" <<C
[local]
$UPORT	dgram	udp	*	*	2	1h
$TPORT	stream	tcp	*	*	2	1h
C
cat > "$W/helper" <<H
#!/bin/sh
echo "\$*" >> "$W/helper.log"
echo OK
H
chmod +x "$W/helper"
: > "$W/helper.log"

mkdir -p "$(dirname "$BL_EXPECT_SOCK")"
if [ -S "$BL_EXPECT_SOCK" ]; then
	echo "stale $BL_EXPECT_SOCK (is a system blocklistd running?)"
	ps ax | grep '[b]locklistd' || true
	exit 1
fi

DPID= SPIDS=
cleanup() {
	for p in $SPIDS $DPID; do kill "$p" 2>/dev/null || true; done
	sleep 1
	rm -f "$BL_EXPECT_SOCK"
	cp "$W/helper.log" "$BL_LOGDIR/smoke-helper.log" 2>/dev/null || true
	cp "$W"/blocklistd*.log "$BL_LOGDIR/" 2>/dev/null || true
	rm -rf "$W"
}
trap cleanup EXIT INT TERM

start_daemon() {	# logname extra-flags
	"$B/blocklistd" -d -v $2 -c "$W/blocklistd.conf" -C "$W/helper" \
	    -D "$W/state.db" -s "$BL_EXPECT_SOCK" -t 1 > "$W/$1" 2>&1 &
	DPID=$!
	i=0
	while [ ! -S "$BL_EXPECT_SOCK" ]; do
		i=$((i + 1))
		[ $i -le 50 ] || { cat "$W/$1"; echo "blocklistd did not create socket"; exit 1; }
		sleep 0.2 2>/dev/null || sleep 1
	done
}

wait_for() {	# file pattern what
	i=0
	until grep -q "$2" "$1"; do
		i=$((i + 1))
		if [ $i -gt 50 ]; then
			echo "--- $1 ---"; cat "$1"
			echo "--- blocklistd log ---"; cat "$W"/blocklistd*.log
			echo "timed out waiting for: $3"; exit 1
		fi
		sleep 0.2 2>/dev/null || sleep 1
	done
	echo "ok: $3"
}

echo "=== start blocklistd (fake helper, -s $BL_EXPECT_SOCK) ==="
start_daemon blocklistd.log ""

echo "=== UDP report via blocklist_sa() ==="
# srvtest -u serves exactly one datagram (the parent closes the shared
# socket after forking the reporter), so stop it once the report landed.
"$B/srvtest" -u -p $UPORT > "$W/srvtest-udp.log" 2>&1 &
UPID=$!
SPIDS="$SPIDS $UPID"
sleep 1
"$B/cltest" -u -p $UPORT -m "ci udp smoke"
wait_for "$W/helper.log" "^add .*127\.0\.0\.1 [0-9]* $UPORT" "UDP report -> helper add"
kill "$UPID" 2>/dev/null || true

echo "=== TCP report via blocklist() ==="
"$B/srvtest" -p $TPORT > "$W/srvtest-tcp.log" 2>&1 &
SPIDS="$SPIDS $!"
sleep 1
"$B/cltest" -p $TPORT -m "ci tcp smoke"
wait_for "$W/helper.log" "^add .*127\.0\.0\.1 [0-9]* $TPORT" "TCP report -> helper add"

grep -q 'msg="ci udp smoke"' "$W/blocklistd.log"
grep -q 'msg="ci tcp smoke"' "$W/blocklistd.log"

echo "=== blocklistctl sees both bans ==="
# blocklistd syncs its db on the -t timer, so poll for a few seconds.
D="$BL_LOGDIR/smoke-blocklistctl.txt"
i=0
while :; do
	"$B/blocklistctl" dump -D "$W/state.db" -b > "$D" 2>&1 || true
	grep -q "127\.0\.0\.1/[0-9]*:$UPORT" "$D" &&
	    grep -q "127\.0\.0\.1/[0-9]*:$TPORT" "$D" && break
	i=$((i + 1))
	[ $i -le 30 ] || { cat "$D"; echo "bans not in blocklistctl dump"; exit 1; }
	sleep 1
done
cat "$D"

echo "=== restart with -r restores bans ==="
kill "$DPID"; wait "$DPID" 2>/dev/null || true; DPID=
rm -f "$BL_EXPECT_SOCK"
: > "$W/helper.log"
start_daemon blocklistd-restore.log "-r"
wait_for "$W/helper.log" "^flush " "restore flush"
wait_for "$W/helper.log" "^add .* $UPORT" "restore re-add UDP"
wait_for "$W/helper.log" "^add .* $TPORT" "restore re-add TCP"
echo "=== smoke.sh PASS ==="
