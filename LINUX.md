# Linux port of blocklistd

This branch (`linux-port`) makes the existing portable tree in `port/` a
first-class Linux package. The C daemon and `libblocklist` already
cross-compile:

```
cd port && autoreconf -fi && ./configure && make
```

on Ubuntu (libdb185 + libtool `LTLIBOBJS` for `pidfile`, `fparseln`,
`sockaddr_snprintf`, `vsyslog_r`). That is the **cross-platform
compile**. What Linux still lacked — and what this branch adds — is the
**Linux XOR half** of the OS glue, the same split racoon2 uses on
`int/gsoc2026`.

## XOR compile: racoon2 vs blocklist

Racoon2 `int/gsoc2026` does not try to make one source file speak every
kernel ABI. It selects **exactly one** key-management backend at
configure time:

| Host | Default backend | Compat / sanity backend |
|------|-----------------|-------------------------|
| Linux | `--with-km-backend=xfrm` (`lib/if_xfrm.c`, NETLINK_XFRM) | `--with-km-backend=pfkey` (lossy AF_KEY; compile only) |
| NetBSD / FreeBSD | `if_pfkeyv2.c` | n/a |
| Startup | `samples/systemd/` | `samples/rc.d/` |

CI encodes the XOR: `ubuntu.yml` has `build-xfrm` (default, gates the
live matrix) and `build-pfkey` (sanity only). Mixing both into one
`iked` binary is not supported.

Blocklist had the inverse problem. `port/configure.ac` is already the
cross-platform compile (autoconf + `AC_REPLACE_FUNCS`). The helper
script then auto-detected npf/pf/ipfw/ipfilter/iptables at *runtime*
and the iptables path appended one INPUT rule per offender. That is
fine as a stub and wrong as a Linux default.

This branch makes the packet-filter backend an explicit XOR too:

```
./configure --with-pf-backend=nft        # Linux default (sets + timeout)
./configure --with-pf-backend=iptables   # compat / sanity only
./configure --with-pf-backend=auto       # detect: nft > iptables > BSD pf
```

| | racoon2 `int/gsoc2026` | blocklist `linux-port` |
|--|------------------------|-------------------------|
| Cross-platform compile | autoconf + `AC_CANONICAL_HOST` + subdir configures | `port/configure.ac` + `AC_REPLACE_FUNCS` + libdb |
| Linux-only backend | `lib/if_xfrm.c` | nftables sets in `blocklistd-helper` + `etc/nftables/blocklistd.nft` |
| Compat backend | Linux `AF_KEY` pfkey | iptables chain (existing stub, not the default) |
| Init | systemd units, paths resolved at configure | `etc/systemd/blocklistd.service` |
| CI | Ubuntu xfrm + pfkey jobs | Ubuntu nft + iptables jobs |
| What is *not* XOR'd | IKE parser, admin socket | `libblocklist`, `blocklistd`, `blocklistctl`, `blocklistd.conf` |

The helper still contains the BSD engines so a single script ships
everywhere. On Linux, `nft` wins unless you force `BLOCKLIST_PF=iptables`
or `--with-pf-backend=iptables`.

## Build (Linux)

```
sudo apt-get install autoconf automake libtool pkg-config gcc make libdb-dev
cd port
autoreconf -fi
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
            --runstatedir=/run --with-pf-backend=nft
make -j$(nproc)
sudo make install
sudo install -d /var/db /run
sudo cp ../etc/blocklistd.conf.linux /etc/blocklistd.conf
sudo nft -f ../etc/nftables/blocklistd.nft
sudo systemctl enable --now blocklistd
```

`blocklistd` restores rules from `/var/db/blocklistd.db` when started
with `-r` (the unit file does this).

## Helper contract (unchanged)

```
blocklistd-helper add|rem|flush <rulename> <proto> <addr> <mask> <port> [id]
```

nft implementation:

- `add`  → `nft add element inet blocklistd banned4 { addr }`
  Duration is not passed by the helper protocol today; nft set
  elements honor the set's default timeout, and `blocklistd`
  itself issues `rem` when the configured duration expires.
- `rem`  → `nft delete element …`
- `flush`→ `nft flush set inet blocklistd banned4` (and banned6)

UDP/500 and UDP/4500 (IKE / NAT-T) use the same source-address sets.
Port is recorded in the database but the default nft table drops the
peer for all ports — IKE scanners hop 500↔4500.

## Making racoon2 / iked blocklist-aware

IKE scanners hit UDP/500 and UDP/4500 with short packets, bad cookies,
bogus SPIs, and failed AUTH. iked already counts these in `isakmpstat`
(`malformed_message`, `invalid_ike_spi`, `authentication_failed`,
`shortpacket`). None of those counters currently call out.

Hook the existing library the same way `diff/ssh.diff` does, but pass
the peer `sockaddr` because IKE is datagram (`blocklist_sa`, not
`blocklist` on an accepted fd).

Call sites (all already have `remote`):

| Event | File | Action |
|-------|------|--------|
| packet shorter than ISAKMP header / length insane | `iked/isakmp.c` (`shortpacket`, `malformed_message`) | `BLOCKLIST_AUTH_FAIL` |
| malformed cookie / invalid IKE SPI | `iked/ikev1/ikev1.c`, QCD unknown SA | `BLOCKLIST_AUTH_FAIL` |
| `ikev2_verify` → `VERIFIED_FAILURE` | `iked/ikev2_auth.c` | `BLOCKLIST_AUTH_FAIL` |
| AUTH success, CHILD installed | child-up path | `BLOCKLIST_AUTH_OK` |
| obvious flood after cookie ignore / QCD replay | `ikev2_child.c` anti-DoS comment | `BLOCKLIST_ABUSIVE_BEHAVIOR` (immediate ban) |

Configure flag on the racoon2 side, parallel to `--with-km-backend`:

```
AC_ARG_ENABLE(blocklist,
  [AS_HELP_STRING([--enable-blocklist], [notify blocklistd of IKE abuse])],
  [], [enable_blocklist=no])
```

`blocklistd.conf` fragment:

```
[local]
isakmp      dgram   udp     *   blocklistd  8   1h
isakmp-natt dgram   udp     *   blocklistd  8   1h
500         dgram   udp     *   blocklistd  8   1h
4500        dgram   udp     *   blocklistd  8   1h
[remote]
# never ban the other matrix namespace / peer under test
```

Do **not** ban on every `INVALID_SYNTAX` during a legitimate rekey —
iOS answers `INVALID_SYNTAX` to some CREATE_CHILD shapes
(`ikev2_rekey.c`). Rate-limit to: parse failures on the *first*
message from an unknown SPI, AUTH failure, and short/garbage headers.
That is the scanner pattern; the others are protocol.

A patch sketch lives in `diff/iked.diff`. Apply it on
`derekm/racoon2` `int/gsoc2026`, do not merge it here.
