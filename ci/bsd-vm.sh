#!/bin/sh
# ci/bsd-vm.sh - whole in-VM body for the FreeBSD/NetBSD vmactions legs:
# deps, then the same build.sh/smoke.sh the Linux legs run.  The caller
# sets BL_PF_BACKEND/BL_EXPECT_SOCK/BL_EXPECT_SYSTEMD.
#
# Same contract as racoon2's FreeBSD vmactions step: BSD /bin/sh has no
# pipefail, so the body's output is captured to ci-logs/vm.log in the
# synced workspace (NOT /tmp, which is VM-local), echoed, and its status
# written to ci-logs/rc.  This script then exits 0 regardless, because
# vmactions only copies the workspace back to the host runner after a
# successful run step; the workflow's "Fail on ..." host step gates on
# ci-logs/rc after the logs are uploaded.
set -eu

if [ "${1:-}" != body ]; then
	mkdir -p ci-logs
	rc=0
	sh "$0" body > ci-logs/vm.log 2>&1 || rc=$?
	cat ci-logs/vm.log
	echo "$rc" > ci-logs/rc
	[ "$rc" -eq 0 ] || echo "bsd-vm.sh: body rc=$rc (the host step fails the job)"
	exit 0
fi

echo "=== $(uname -a) ==="
sh ci/bsd-deps.sh
sh ci/build.sh
sh ci/smoke.sh
