#!/bin/sh
# ci/bsd-deps.sh - install build dependencies inside the FreeBSD/NetBSD
# vmactions VM (same package set and tools racoon2's samples/*-ci scripts
# use).  Berkeley DB 1.85 (dbopen) and the packet filters are in base.
# Root-agnostic: sudo only when not already root.
set -eu
if [ "$(id -u)" = "0" ]; then SUDO=; else SUDO=sudo; fi
case $(uname -s) in
FreeBSD)
	$SUDO env ASSUME_ALWAYS_YES=yes pkg update || true
	$SUDO env ASSUME_ALWAYS_YES=yes pkg install autoconf automake libtool gmake m4
	;;
NetBSD)
	# PKG_PATH is pre-wired by the action's onStarted hook.
	$SUDO /usr/sbin/pkg_add autoconf automake libtool gmake m4
	;;
*)	echo "bsd-deps.sh: unsupported $(uname -s)"; exit 1 ;;
esac
