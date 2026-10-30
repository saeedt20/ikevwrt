#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/bin" "$work/iran"
printf 'ir\n' >"$work/iran/iran-domains.txt"
: >"$work/iran/iran-cidrs.txt"
cat >"$work/bin/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "${TEST_IRAN_ENABLED:-1}"
EOF
cat >"$work/bin/ip" <<'EOF'
#!/bin/sh
[ "$*" = '-4 rule show' ] || exit 1
[ "${TEST_MISSING_VPN:-0}" != 1 ] || exit 0
echo '29999: from all fwmark 0x50000/0xff0000 lookup pbr_ikev2out'
EOF
chmod 755 "$work/bin/uci" "$work/bin/ip"
export PATH="$work/bin:$PATH" IKEV2_IRAN_DIR="$work/iran"
export nftTempFile="$work/pbr.nft" packageDnsmasqFile="$work/pbr.dnsmasq"
export TEST_IRAN_INCLUDE="$root/ikev2-manager-runtime/pbr.user.ikev2-iran"
reset_rules() {
	cat >"$nftTempFile" <<'EOF'
add rule inet fw4 pbr_prerouting meta mark & 0xff0000 != 0 return
add rule inet fw4 pbr_prerouting ip daddr @pbr_wan_4_dst_ip_user goto pbr_mark_0x090000
EOF
	: >"$packageDnsmasqFile"
}
run_include() {
	sh -eu -c 'nft() { printf "%s\n" "$*" >>"$nftTempFile"; }; . "$TEST_IRAN_INCLUDE"'
}
reset_rules
run_include
grep -Fxq 'nftset=/ir/4#inet#fw4#pbr_wan_4_dst_ip_user,6#inet#fw4#pbr_wan_6_dst_ip_user' "$packageDnsmasqFile"
python3 - "$nftTempFile" <<'PY'
import re, sys
from pathlib import Path
rules = Path(sys.argv[1]).read_text()
priority = re.search(r'^insert rule inet fw4 pbr_prerouting meta mark & (0x[0-9a-f]+) == (0x[0-9a-f]+) ip daddr @pbr_wan_4_dst_ip_user counter goto (pbr_mark_0x[0-9a-f]+) comment "ikev2-iran:priority"$', rules, re.M)
assert priority, 'Iran bypass must precede PBR\'s marked-packet return'
mask, vpn = (int(x, 16) for x in priority.group(1, 2))
wan = int(priority.group(3).removeprefix('pbr_mark_'), 16)
def route(mark, iran):
    if mark & mask == vpn and iran:
        mark = (mark & ~mask) | wan
    return mark
assert route(0x50000, True) == 0x90000
assert route(0x40050000, True) == 0x40090000, 'preserve unrelated DPI marks'
assert route(0x50000, False) == 0x50000, 'ordinary full-route traffic stays VPN'
assert route(0x400000, True) == 0x400000, 'do not steal FakeIP proxy packets'
assert route(0x90000, True) == 0x90000, 'keep excluded devices direct'
PY
reset_rules
TEST_IRAN_ENABLED=0 run_include
[ ! -s "$packageDnsmasqFile" ]
! grep -q ikev2-iran:priority "$nftTempFile"
reset_rules
if TEST_MISSING_VPN=1 run_include 2>/dev/null; then
	echo 'Missing VPN mark was silently accepted' >&2; exit 1
fi
! grep -q ikev2-iran:priority "$nftTempFile"
reset_rules
sed -i.bak 's/pbr_mark_0x090000/foreign_chain/' "$nftTempFile"
if run_include 2>/dev/null; then
	echo 'Unrecognized WAN mark chain was accepted' >&2; exit 1
fi
printf 'Iran-direct priority over device full-route tests OK\n'
