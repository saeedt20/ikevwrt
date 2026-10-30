#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid

# Iranian domains come from the packaged, attributed snapshot; no runtime downloads.
set -eu
umask 077

bundle="${IKEV2_IRAN_BUNDLE:-/usr/share/ikev2-domains/iran-domains.txt}"
directory="${IKEV2_IRAN_DIR:-/etc/ikev2-manager}"
domains="$directory/iran-domains.txt"
cidrs="$directory/iran-cidrs.txt"
# Operator additions and removals, preserved across upgrades and editable from
# the routing page. Entries are merged into the packaged list.
extra="$directory/iran-extra.txt"
status_file="${IKEV2_IRAN_STATUS:-/var/run/ikev2-iran-direct.status}"
lock_dir="${IKEV2_IRAN_LOCK:-/var/run/ikev2-iran-direct.lock}"
config='ikev2-manager.domains.iran_direct'
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
. "$runtime_lib_dir/actions.sh"

enabled() { [ "$(uci -q get "$config" 2>/dev/null || true)" = 1 ]; }
count() { [ -f "$1" ] && wc -l < "$1" || printf '0\n'; }
status() {
	if enabled; then printf 'enabled=1\n'; else printf 'enabled=0\n'; fi
	printf 'domains=%s\n' "$(count "$domains")"
	printf 'cidrs=%s\n' "$(count "$cidrs")"
	printf 'extra=%s\n' "$(count "$extra")"
	[ ! -f "$status_file" ] || cat "$status_file"
}
# Shared by the packaged list and the editable one, so an operator entry can
# never reach the WAN set through a rule the upstream list would be refused for.
validate_cidrs() {
	awk -F/ '
		/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		{ sub(/\r$/, ""); if (NF!=2 || $2 !~ /^[0-9]+$/) exit 1;
		  if ($1 ~ /:/) {
		    if ($1 !~ /^[0-9a-fA-F:]+$/ || $1 !~ /:/ || $2<16 || $2>128) exit 1;
		    prefix=tolower(substr($1,1,4));
		    if (prefix ~ /^(fc|fd|fe8|fe9|fea|feb|ff)/ ||
		        tolower($1) ~ /^2001:db8:/) next;
		    print $0; next;
		  }
		  if ($2<8 || $2>32) exit 1;
		  n=split($1,a,"."); if (n!=4) exit 1;
		  for (i=1;i<=4;i++) if (a[i] !~ /^[0-9]+$/ || a[i]>255) exit 1;
		  # Never mark local, reserved, documentation or multicast addresses WAN.
		  if (a[1]<2 || a[1]>=224 || a[1]==10 || a[1]==127 ||
		      (a[1]==100 && a[2]>=64 && a[2]<=127) ||
		      (a[1]==169 && a[2]==254) ||
		      (a[1]==172 && a[2]>=16 && a[2]<=31) ||
		      (a[1]==192 && (a[2]==168 || a[2]==0 || a[2]==2)) ||
		      (a[1]==198 && (a[2]==18 || a[2]==19 || a[2]==51)) ||
		      (a[1]==203 && a[2]==0 && a[3]==113)) next;
		  print $0 }
	' "$1" > "$2"
}

prepare() {
	work="$1"
	[ -s "$bundle" ] || { echo 'Bundled Iranian domains are missing' >&2; return 1; }
	cp "$bundle" "$work/domains" || return 1
	: >"$work/cidrs"
	merge_extra "$work"
}

# The editable list holds both kinds of entry, one per line. It is validated
# before applying it: an entry
# that cannot be classified fails the update and names its line, because a typo
# that is silently dropped looks exactly like a working rule on the page.
merge_extra() {
	work="$1"
	[ -s "$extra" ] || return 0
	[ "$(wc -c < "$extra")" -le 262144 ] || {
		echo 'The editable Iran list is larger than the supported limit' >&2
		return 1
	}
	awk -v domain_out="$work/extra.domains" -v cidr_out="$work/extra.cidrs" '
		{ sub(/\r$/, ""); sub(/#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
		$0 == "" { next }
		{
			entry = tolower($0)
			if (index(entry, "/") > 0) {
				print entry > cidr_out
				next
			}
			if (length(entry) > 253 || entry !~ /^[a-z0-9.-]+$/ ||
			    entry ~ /\.\./ || entry ~ /^[-.]/ || entry ~ /[-.]$/) {
				printf "line %d is neither a domain nor an IP network: %s\n", NR, $0 > "/dev/stderr"
				exit 1
			}
			print entry > domain_out
		}
	' "$extra" || return 1
	if [ -s "$work/extra.cidrs" ]; then
		# Reuse the network validator so the same reserved, private and
		# documentation ranges are refused here.
		validate_cidrs "$work/extra.cidrs" "$work/extra.checked" || {
			echo 'The editable Iran list contains an invalid IP network' >&2
			return 1
		}
		[ "$(count "$work/extra.cidrs")" = "$(count "$work/extra.checked")" ] || {
			echo 'The editable Iran list contains a reserved or private IP network' >&2
			return 1
		}
		cat "$work/extra.checked" >> "$work/cidrs"
		sort -u "$work/cidrs" > "$work/cidrs.merged"
		mv "$work/cidrs.merged" "$work/cidrs"
	fi
	if [ -s "$work/extra.domains" ]; then
		cat "$work/extra.domains" >> "$work/domains"
		sort -u "$work/domains" > "$work/domains.merged"
		mv "$work/domains.merged" "$work/domains"
	fi
	return 0
}
sync_pbr() {
	uci -q delete pbr.ikev2_iran_domains || true
	uci -q delete pbr.ikev2_iran_cidrs || true
	if ! enabled; then
		uci -q delete pbr.ikev2_iran_include || true
		uci commit pbr
		return 0
	fi
	[ -s "$domains" ] && [ -f "$cidrs" ] || return 1
	uci set pbr.config.ipv6_enabled='1'
	uci -q delete pbr.ikev2_iran_include || true
	uci set pbr.ikev2_iran_include=include
	uci set pbr.ikev2_iran_include.path='/usr/share/pbr/pbr.user.ikev2-iran'
	uci set pbr.ikev2_iran_include.enabled='1'
	uci commit pbr
}
apply() {
	"${IKEV2_IRAN_PBR_INIT:-/etc/init.d/pbr}" restart >/dev/null 2>&1 || return 1
	if [ "$(uci -q get ikev2-manager.domains.engine 2>/dev/null || true)" = fakeip ]; then
		"${IKEV2_IRAN_DOMAIN_HELPER:-/usr/libexec/ikev2-domain-router}" refresh >/dev/null 2>&1 || return 1
	fi
	return 0
}
update() {
	work="$(mktemp -d /tmp/ikev2-iran-direct.XXXXXX)" || exit 1
	trap 'rm -rf "$work"' EXIT HUP INT TERM
	prepare "$work" || { echo 'Bundled Iran list validation failed' >&2; exit 1; }
	mkdir -p "$directory"
	[ ! -f "$domains" ] || cp "$domains" "$work/domains.old"
	[ ! -f "$cidrs" ] || cp "$cidrs" "$work/cidrs.old"
	previous=0; enabled && previous=1
	# Reapplying the same bundled list must not restart PBR.
	if [ "$previous" = 1 ] &&
	   [ -f "$work/domains.old" ] && cmp -s "$work/domains" "$work/domains.old" &&
	   [ -f "$work/cidrs.old" ] && cmp -s "$work/cidrs" "$work/cidrs.old" &&
	   [ "$(uci -q get pbr.ikev2_iran_include.enabled 2>/dev/null || true)" = 1 ]; then
		status
		return 0
	fi
	cp "$work/domains" "$domains.new"
	cp "$work/cidrs" "$cidrs.new"
	chmod 600 "$domains.new" "$cidrs.new"
	mv "$domains.new" "$domains"
	mv "$cidrs.new" "$cidrs"
	uci set "$config=1"
	uci commit ikev2-manager
	if ! sync_pbr || ! apply; then
		if [ -f "$work/domains.old" ]; then mv "$work/domains.old" "$domains"; else rm -f "$domains"; fi
		if [ -f "$work/cidrs.old" ]; then mv "$work/cidrs.old" "$cidrs"; else rm -f "$cidrs"; fi
		uci set "$config=$previous"
		uci commit ikev2-manager
		sync_pbr || true
		apply || true
		echo 'Iran routing failed; previous configuration restored' >&2
		exit 1
	fi
	status
}
disable() {
	previous="$(uci -q get "$config" 2>/dev/null || echo 0)"
	if ! uci set "$config=0" || ! uci commit ikev2-manager ||
	   ! sync_pbr || ! apply; then
		uci set "$config=$previous"
		uci commit ikev2-manager
		sync_pbr || true
		apply || true
		return 1
	fi
	status
}

write_action_status() {
	printf 'action_id=%s\nstate=%s\nmessage=%s\n' "$1" "$2" "$3" \
		> "$status_file.new"
	mv "$status_file.new" "$status_file"
}
schedule() {
	action="$1"
	id="$(date +%s)-$$"
	write_action_status "$id" running 'Updating Iranian routing rules...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -b -q -S -x "$0" -- _run "$action" "$id" || return 1
	else
		setsid "$0" _run "$action" "$id" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$id"
}
run_async() {
	action="$1" id="$2"
	pid_lock_acquire "$lock_dir" || {
		write_action_status "$id" error 'Another Iranian list update is running.'
		exit 1
	}
	trap 'pid_lock_release "$lock_dir"' EXIT HUP INT TERM
	if ! acquire_action_lock iran-direct "$id"; then
		write_action_status "$id" error 'Another router action is already in progress.'
		return 1
	fi
	trap 'pid_lock_release "$lock_dir"; release_action_lock' EXIT HUP INT TERM
	if ( "$action" ) >/tmp/ikev2-iran-direct.log 2>&1; then
		write_action_status "$id" ok 'Iranian direct routing updated.'
	else
		write_action_status "$id" error 'Iranian routing failed; previous configuration was preserved.'
	fi
}
# The page stages its text under a fixed prefix and passes the token, so the ACL
# can allow the call without allowing an arbitrary path. The submission is
# validated before it replaces the stored list: an entry accepted here and
# rejected later would fail the next scheduled refresh instead of the save the
# operator is watching.
write_extra() {
	token="${1:-}"
	case "$token" in
		'' | *[!0-9a-z-]*) echo 'invalid input token' >&2; exit 2 ;;
	esac
	input="/tmp/ikev2-iran-input-$token.txt"
	[ -f "$input" ] && [ ! -L "$input" ] || { echo 'The submitted list is missing' >&2; exit 1; }
	work="$(mktemp -d /tmp/ikev2-iran-write.XXXXXX)" || exit 1
	trap 'rm -rf "$work"; rm -f "$input"' EXIT HUP INT TERM
	: > "$work/domains"
	: > "$work/cidrs"
	# merge_extra reads the global, so point it at the candidate for the dry run
	# and put it back before anything is stored.
	stored="$extra"
	extra="$input"
	if ! merge_extra "$work"; then
		extra="$stored"
		exit 1
	fi
	extra="$stored"
	mkdir -p "$directory"
	cp "$input" "$extra.new"
	chmod 600 "$extra.new"
	mv "$extra.new" "$extra"
	printf 'domains=%s\ncidrs=%s\n' "$(count "$work/domains")" "$(count "$work/cidrs")"
}

check_lists() {
	work="$(mktemp -d /tmp/ikev2-iran-check.XXXXXX)" || exit 1
	trap 'rm -rf "$work"' EXIT HUP INT TERM
	prepare "$work"
	printf 'domains=%s\ncidrs=%s\n' "$(count "$work/domains")" "$(count "$work/cidrs")"
}

case "${1:-}" in
	status) status ;;
	check-lists) check_lists ;;
	sync) sync_pbr ;;
	enable) update ;;
	disable) disable ;;
	enable-async) schedule update ;;
	disable-async) schedule disable ;;
	read) [ -f "$extra" ] && cat "$extra" || true ;;
	write) write_extra "${2:-}" ;;
	_run) run_async "$2" "$3" ;;
	*)
		echo 'Usage: ikev2-iran-direct status|check-lists|sync|enable|disable|read|write TOKEN' >&2
		exit 2
		;;
esac
