#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid

# Iranian destination lists are downloaded as data, never executed. The source
# and its GPL-3.0 license are documented in README.md.
set -eu
umask 077

base="${IKEV2_IRAN_BASE:-https://raw.githubusercontent.com/Chocolate4U/Iran-clash-rules/release}"
directory="${IKEV2_IRAN_DIR:-/etc/ikev2-manager}"
domains="$directory/iran-domains.txt"
cidrs="$directory/iran-cidrs.txt"
# Operator additions and removals, preserved across upgrades and editable from
# the routing page. Entries are merged into the downloaded lists.
extra="$directory/iran-extra.txt"
status_file="${IKEV2_IRAN_STATUS:-/var/run/ikev2-iran-direct.status}"
lock_dir="${IKEV2_IRAN_LOCK:-/var/run/ikev2-iran-direct.lock}"
# The refresh schedule lives on flash beside the lists, so a reboot neither
# loses the last success nor forgets that today's refresh already ran.
state_file="$directory/iran-refresh.state"
refresh_interval="${IKEV2_IRAN_REFRESH_INTERVAL:-86400}"
refresh_retry="${IKEV2_IRAN_REFRESH_RETRY:-3600}"
uptime_file="${IKEV2_IRAN_UPTIME_FILE:-/proc/uptime}"
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
fetch() {
	url="$1" output="$2"
	if command -v curl >/dev/null 2>&1; then
		curl --fail --location --silent --show-error --connect-timeout 10 \
			--max-time 60 --output "$output" "$url"
	else
		uclient-fetch -q -T 60 -O "$output" "$url"
	fi
}
# Shared by the downloaded list and the editable one, so an operator entry can
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
	fetch "$base/ir.txt" "$work/domains.raw"
	fetch "$base/ircidr.txt" "$work/cidrs.raw"
	[ "$(wc -c < "$work/domains.raw")" -le 2500000 ] || return 1
	[ "$(wc -c < "$work/cidrs.raw")" -le 300000 ] || return 1
	awk '
		/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		{ sub(/\r$/, ""); if (substr($0,1,2) != "+.") exit 1;
		  d=substr($0,3); if (length(d)>253 || d !~ /^[a-z0-9.-]+$/ ||
		  d ~ /\.\./ || d ~ /^[-.]/ || d ~ /[-.]$/) exit 1;
		  print d }
	' "$work/domains.raw" > "$work/domains.unsorted" || return 1
	sort -u "$work/domains.unsorted" > "$work/domains"
	# All .ir names match, including names absent from the upstream list.
	printf 'ir\n' >> "$work/domains"
	sort -u "$work/domains" > "$work/domains.sorted"
	mv "$work/domains.sorted" "$work/domains"
	validate_cidrs "$work/cidrs.raw" "$work/cidrs.unsorted" || return 1
	sort -u "$work/cidrs.unsorted" > "$work/cidrs"
	[ "$(count "$work/domains")" -ge "${IKEV2_IRAN_MIN_DOMAINS:-1000}" ] &&
	[ "$(count "$work/cidrs")" -ge "${IKEV2_IRAN_MIN_CIDRS:-1000}" ] || return 1
	merge_extra "$work"
}

# The editable list holds both kinds of entry, one per line. It is validated
# with the same rules as the downloaded lists rather than more loosely: an entry
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
		# Reuse the downloaded-list validator so the same reserved, private and
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
	[ -s "$domains" ] && [ -s "$cidrs" ] || return 1
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
	prepare "$work" || { echo 'Iran list download or validation failed' >&2; exit 1; }
	mkdir -p "$directory"
	[ ! -f "$domains" ] || cp "$domains" "$work/domains.old"
	[ ! -f "$cidrs" ] || cp "$cidrs" "$work/cidrs.old"
	previous=0; enabled && previous=1
	# A refresh that finds nothing new must not restart PBR: the rebuild costs a
	# forwarding outage, and on the daily schedule most days change nothing.
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

state_value() { sed -n "s/^$1=//p" "$state_file" 2>/dev/null | tail -n1; }
numeric() { case "$1" in '' | *[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$1" ;; esac; }
state_set() {
	mkdir -p "$directory" || return 1
	{
		[ ! -f "$state_file" ] || grep -v "^$1=" "$state_file" || true
		printf '%s=%s\n' "$1" "$2"
	} > "$state_file.new" && mv "$state_file.new" "$state_file"
}

# Whether the scheduled refresh should run now. Never while the feature is off,
# so a daily run can never re-enable what the operator turned off; at most once
# per retry window; once after every boot; and otherwise daily at a stable
# per-router offset so a fleet does not reach the publisher in the same minute.
refresh_due() {
	mode="${1:-}"
	enabled || return 1
	now="$(date +%s)"
	last_attempt="$(numeric "$(state_value last_attempt)")"
	last_success="$(numeric "$(state_value last_success)")"
	jitter="$(state_value jitter)"
	case "$jitter" in
		'' | *[!0-9]*)
			jitter=$(( ${RANDOM:-$$} % 3600 ))
			[ "$mode" = probe ] || state_set jitter "$jitter" || true
			;;
	esac
	uptime="$(numeric "$(cut -d. -f1 "$uptime_file" 2>/dev/null)")"
	boot=$((now - uptime))
	[ $((now - last_attempt)) -ge "$refresh_retry" ] || return 1
	[ "$last_attempt" -ge "$boot" ] || return 0
	[ $((now - last_success)) -ge $((refresh_interval + jitter)) ]
}

scheduled_update() {
	state_set last_attempt "$(date +%s)" || true
	if update; then
		state_set last_success "$(date +%s)" || true
		return 0
	fi
	return 1
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
	enable | refresh) update ;;
	disable) disable ;;
	enable-async) schedule update ;;
	refresh-async) schedule update ;;
	disable-async) schedule disable ;;
	refresh-if-due)
		refresh_due || exit 0
		schedule scheduled_update
		;;
	read) [ -f "$extra" ] && cat "$extra" || true ;;
	write) write_extra "${2:-}" ;;
	_run) run_async "$2" "$3" ;;
	*)
		echo 'Usage: ikev2-iran-direct status|check-lists|sync|enable|refresh|disable|refresh-if-due|read|write TOKEN' >&2
		exit 2
		;;
esac
