#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/bin" "$work/etc" "$work/config"
cat >"$work/bin/uci" <<'UCI'
#!/bin/sh
exec "$TEST_UCI_STUB" -c "$UCI_STUB_DIR" "$@"
UCI
cat >"$work/bin/network-forbidden" <<'NO_NET'
#!/bin/sh
echo 'Iran list operation attempted a network download' >&2
exit 99
NO_NET
for command in curl wget uclient-fetch; do cp "$work/bin/network-forbidden" "$work/bin/$command"; done
cat >"$work/bin/pbr" <<'PBR'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_RESTARTS"
[ "${TEST_PBR_FAIL:-0}" = 0 ]
PBR
chmod +x "$work/bin"/*
printf 'domains=domains\ndomains.iran_direct=0\ndomains.engine=nftset\n' >"$work/config/ikev2-manager"
printf 'config=pbr\n' >"$work/config/pbr"
export PATH="$work/bin:$PATH" TEST_UCI_STUB="$root/scripts/uci-stub.sh" UCI_STUB_DIR="$work/config"
export IKEV2_IRAN_DIR="$work/etc" IKEV2_IRAN_BUNDLE="$root/luci-ikev2-domains/iran/domains.lst"
export IKEV2_IRAN_STATUS="$work/status" IKEV2_IRAN_LOCK="$work/lock"
export IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" IKEV2_ACTION_LOCK="$work/action.lock" IKEV2_ACTION_LOCK_STATUS="$work/action.status"
export IKEV2_IRAN_PBR_INIT="$work/bin/pbr" TEST_RESTARTS="$work/restarts"
run() { sh "$root/ikev2-manager-runtime/ikev2-iran-direct.sh" "$@"; }
run _run update enable >/dev/null
grep -Fxq state=ok "$work/status"
cmp "$IKEV2_IRAN_BUNDLE" "$work/etc/iran-domains.txt"
[ ! -s "$work/etc/iran-cidrs.txt" ]
[ ! -d "$work/lock" ] && [ ! -d "$work/action.lock" ]
[ "$(uci -q get ikev2-manager.domains.iran_direct)" = 1 ]
# The status path is available offline and reports the packaged domain count.
run status >"$work/report"
grep -Fxq 'cidrs=0' "$work/report"
# A failed routing transition preserves the previous setting and releases locks.
TEST_PBR_FAIL=1 run _run disable failure >/dev/null
grep -Fxq state=error "$work/status"
[ "$(uci -q get ikev2-manager.domains.iran_direct)" = 1 ]
run _run disable disable >/dev/null
grep -Fxq state=ok "$work/status"
[ "$(uci -q get ikev2-manager.domains.iran_direct)" = 0 ]
TEST_PBR_FAIL=1 run _run update failure >/dev/null
grep -Fxq state=error "$work/status"
[ "$(uci -q get ikev2-manager.domains.iran_direct)" = 0 ]
[ ! -d "$work/lock" ] && [ ! -d "$work/action.lock" ]
# Runtime update commands are retired, including the scheduled path.
for action in refresh refresh-async refresh-if-due; do
	if run "$action" >/dev/null 2>&1; then echo "Retired action accepted: $action" >&2; exit 1; fi
done
printf 'offline Iran snapshot and routing rollback tests OK\n'
