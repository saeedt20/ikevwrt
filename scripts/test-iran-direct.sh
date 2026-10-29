#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-iran-direct.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/etc" "$tmp/served"

fail() {
	printf 'test-iran-direct: %s\n' "$*" >&2
	exit 1
}

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
state="$TEST_UCI_STATE"
case "${1:-}" in
	-q)
		shift
		case "${1:-}" in
			get)
				value="$(sed -n "s/^$2=//p" "$state" | tail -n1)"
				[ -n "$value" ] || exit 1
				printf '%s\n' "$value"
				;;
			delete)
				sed -i "\\|^$2=|d" "$state" 2>/dev/null || :
				;;
			*) exit 1 ;;
		esac
		;;
	set)
		key="${2%%=*}"
		sed -i "\\|^$key=|d" "$state" 2>/dev/null || :
		printf '%s=%s\n' "$key" "${2#*=}" >>"$state"
		;;
	commit) ;;
	*) exit 1 ;;
esac
EOF

# The two downloads are the only network dependency.
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		--output) output="$2"; shift 2 ;;
		--connect-timeout | --max-time) shift 2 ;;
		--*) shift ;;
		*) url="$1"; shift ;;
	esac
done
name="${url##*/}"
[ -f "$TEST_SERVED/$name" ] || exit 22
cat "$TEST_SERVED/$name" >"$output"
EOF

# Stands in for /etc/init.d/pbr so a rebuild is observable rather than real.
cat >"$tmp/bin/pbr-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_RESTARTS"
[ "${TEST_PBR_FAIL:-0}" != 1 ]
EOF

chmod 755 "$tmp/bin"/*

TEST_RESTARTS="$tmp/restarts"; export TEST_RESTARTS
: >"$TEST_RESTARTS"

printf 'ikev2-manager.domains.iran_direct=0\n' >"$tmp/uci.state"

# Upstream shapes: domains carry the "+." prefix, networks are plain CIDRs.
: >"$tmp/served/ir.txt"
: >"$tmp/served/ircidr.txt"
i=1
while [ "$i" -le 30 ]; do
	printf '+.site%s.ir\n' "$i" >>"$tmp/served/ir.txt"
	printf '5.%s.0.0/16\n' "$i" >>"$tmp/served/ircidr.txt"
	i=$((i + 1))
done
printf '2a01:%s::/32\n' 5 >>"$tmp/served/ircidr.txt"
# Reserved space the upstream list must never be able to push into the WAN set.
printf '10.0.0.0/8\n192.168.0.0/16\n' >>"$tmp/served/ircidr.txt"

run() {
	PATH="$tmp/bin:$PATH" \
	TEST_UCI_STATE="$tmp/uci.state" \
	TEST_SERVED="$tmp/served" \
	IKEV2_IRAN_DIR="$tmp/etc" \
	IKEV2_IRAN_BASE="http://test.invalid" \
	IKEV2_IRAN_STATUS="$tmp/status" \
	IKEV2_IRAN_LOCK="$tmp/lock" \
	IKEV2_IRAN_PBR_INIT="$tmp/bin/pbr-init" \
	IKEV2_IRAN_UPTIME_FILE="$tmp/uptime" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.lock.status" \
	IKEV2_IRAN_MIN_DOMAINS=10 \
	IKEV2_IRAN_MIN_CIDRS=10 \
	sh "$helper" "$@"
}

printf '600.0\n' >"$tmp/uptime"

run enable >/dev/null || fail 'enable failed'

grep -Fxq 'ir' "$tmp/etc/iran-domains.txt" ||
	fail 'the bare .ir top-level domain is missing'
grep -Fxq 'site1.ir' "$tmp/etc/iran-domains.txt" ||
	fail 'an upstream domain was not imported, or the "+." prefix was kept'
grep -q '^+' "$tmp/etc/iran-domains.txt" &&
	fail 'the upstream prefix leaked into the stored list'
grep -Fxq '5.1.0.0/16' "$tmp/etc/iran-cidrs.txt" ||
	fail 'an upstream network was not imported'
grep -Fxq '2a01:5::/32' "$tmp/etc/iran-cidrs.txt" ||
	fail 'an IPv6 network was dropped'
grep -Eq '^(10\.|192\.168\.)' "$tmp/etc/iran-cidrs.txt" &&
	fail 'a private network reached the WAN list'
[ -s "$TEST_RESTARTS" ] || fail 'enabling did not rebuild the routing rules'

# The editable list is merged into both halves.
printf '# mine\nbale.ai\n185.55.224.0/22\n' >"$tmp/etc/iran-extra.txt"
: >"$TEST_RESTARTS"
run refresh >/dev/null || fail 'refresh with an editable list failed'
grep -Fxq 'bale.ai' "$tmp/etc/iran-domains.txt" ||
	fail 'an operator domain was not merged'
grep -Fxq '185.55.224.0/22' "$tmp/etc/iran-cidrs.txt" ||
	fail 'an operator network was not merged'
grep -Fxq '# mine' "$tmp/etc/iran-domains.txt" &&
	fail 'a comment was stored as a domain'
[ -s "$TEST_RESTARTS" ] || fail 'a changed list did not rebuild the routing rules'

# An unchanged refresh must not restart PBR: the rebuild costs a forwarding
# outage and most days change nothing.
printf 'pbr.ikev2_iran_include.enabled=1\n' >>"$tmp/uci.state"
: >"$TEST_RESTARTS"
run refresh >/dev/null || fail 'an unchanged refresh failed'
[ -s "$TEST_RESTARTS" ] &&
	fail 'an unchanged list still rebuilt the routing rules'

# A private range in the editable list is refused, and the stored lists survive.
domain_count="$(wc -l <"$tmp/etc/iran-domains.txt" | tr -d ' ')"
printf 'bale.ai\n192.168.5.0/24\n' >"$tmp/etc/iran-extra.txt"
run refresh >/dev/null 2>&1 &&
	fail 'a private network in the editable list was accepted'
[ "$(wc -l <"$tmp/etc/iran-domains.txt" | tr -d ' ')" = "$domain_count" ] ||
	fail 'a rejected editable list still replaced the stored lists'

# So is an entry that is neither a domain nor a network.
printf 'not a domain\n' >"$tmp/etc/iran-extra.txt"
run refresh >/dev/null 2>&1 &&
	fail 'an unparsable editable entry was accepted'

# The page submits through a token, and the submission is validated before it
# replaces the stored list.
printf 'bale.ai\n5.160.0.0/16\n' >"$tmp/etc/iran-extra.txt"
cp "$tmp/etc/iran-extra.txt" "$tmp/extra.backup"
printf 'still not a domain\n' >/tmp/ikev2-iran-input-testtoken.txt
run write testtoken >/dev/null 2>&1 &&
	fail 'an invalid submission was stored'
cmp -s "$tmp/etc/iran-extra.txt" "$tmp/extra.backup" ||
	fail 'a rejected submission still modified the stored list'
printf 'eitaa.com\n203.0.113.0/24\n' >/tmp/ikev2-iran-input-testtoken.txt
run write testtoken >/dev/null 2>&1 &&
	fail 'a documentation range was accepted from the page'
printf '# note\neitaa.com\n91.99.0.0/16\n' >/tmp/ikev2-iran-input-testtoken.txt
run write testtoken >/dev/null || fail 'a valid submission was rejected'
grep -Fxq 'eitaa.com' "$tmp/etc/iran-extra.txt" ||
	fail 'a submitted domain was not stored'
grep -Fxq '# note' "$tmp/etc/iran-extra.txt" ||
	fail 'a submitted comment was not preserved'
run write ../escape >/dev/null 2>&1 &&
	fail 'a token containing a path separator was accepted'

# The scheduled refresh must never re-enable a feature that was turned off, and
# must hold off until its window opens.
run disable >/dev/null || fail 'disable failed'
run refresh-if-due >/dev/null || fail 'refresh-if-due failed while disabled'
[ "$(sed -n 's/^ikev2-manager.domains.iran_direct=//p' "$tmp/uci.state" | tail -n1)" = 0 ] ||
	fail 'the scheduled refresh re-enabled the feature'

run status | grep -q '^enabled=0$' || fail 'status does not report the disabled state'
run status | grep -q '^extra=' || fail 'status does not report the editable list size'

# Exercise the same worker entry point used by LuCI and the daily refresh.
run _run update first >/dev/null
grep -Fxq 'state=ok' "$tmp/status" || fail 'background update failed'
[ ! -d "$tmp/lock" ] || fail 'background update retained its lock'
[ ! -d "$tmp/action.lock" ] || fail 'background update retained the global lock'
TEST_PBR_FAIL=1 run _run disable failed-disable >/dev/null
grep -Fxq 'state=error' "$tmp/status" || fail 'disable hid a routing restart failure'
run status >"$tmp/after-failure"
grep -Fxq 'enabled=1' "$tmp/after-failure" || fail 'failed disable was not rolled back'
[ ! -d "$tmp/lock" ] || fail 'failed disable retained its lock'
run _run disable second >/dev/null
grep -Fxq 'state=ok' "$tmp/status" || fail 'disable after an update failed'

TEST_PBR_FAIL=1 run _run update failed >/dev/null
grep -Fxq 'state=error' "$tmp/status" || fail 'routing restart failure was hidden'
run status >"$tmp/after-failure"
grep -Fxq 'enabled=0' "$tmp/after-failure" || fail 'failed enable was not rolled back'
[ ! -d "$tmp/lock" ] || fail 'failed worker retained its lock'

rm -f /tmp/ikev2-iran-input-testtoken.txt
printf 'test-iran-direct OK\n'
