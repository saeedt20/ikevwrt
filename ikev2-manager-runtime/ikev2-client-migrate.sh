#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid
set -eu
umask 077

root="${IKEV2_ROOT:-}"
config_dir="${IKEV2_UCI_CONFIG_DIR:-$root/etc/config}"
uci_bin="${IKEV2_UCI_BIN:-/sbin/uci}"
uci() { "$uci_bin" -c "$config_dir" "$@"; }
config=ikev2-manager
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
. "$runtime_lib_dir/actions.sh"
acquire_action_lock client-only-upgrade "$$" || { echo 'Another configuration action is running' >&2; exit 1; }
trap 'release_action_lock' EXIT
trap 'exit 1' HUP INT TERM
[ "$(uci -q get "$config.globals.client_only_schema" 2>/dev/null || true)" != 1 ] || exit 0
bundle="$root/usr/share/ikev2-domains/iran-domains.txt"
[ -s "$bundle" ] || { echo 'Bundled Iranian domains are missing' >&2; exit 1; }
state="$root/etc/ikev2-manager"
mkdir -p "$state"
chmod 700 "$state"

legacy=0
uci -q get "$config.server" >/dev/null 2>&1 && legacy=1
[ ! -e "$state/users.db" ] || legacy=1
if [ "$legacy" = 1 ]; then
	# Keep one private recovery archive; never copy it into a release artifact.
	if [ ! -f "$state/legacy-inbound-backup.tar.gz" ]; then
		set -- etc/config/ikev2-manager
		for path in etc/ikev2-manager/users.db etc/ikev2-manager/inbound.custom.conf \
			etc/swanctl/conf.d/30-inbound.conf etc/swanctl/conf.d/91-inbound-secrets.conf \
			etc/swanctl/x509/ikev2.pem etc/swanctl/private/ikev2.key; do
			[ ! -f "$root/$path" ] || set -- "$@" "$path"
		done
		if ! tar -czf "$state/legacy-inbound-backup.tar.gz.new" -C "${root:-/}" "$@"; then
			rm -f "$state/legacy-inbound-backup.tar.gz.new"
			exit 1
		fi
		mv "$state/legacy-inbound-backup.tar.gz.new" "$state/legacy-inbound-backup.tar.gz"
	fi
	chmod 600 "$state/legacy-inbound-backup.tar.gz"
	gzip -t "$state/legacy-inbound-backup.tar.gz" || exit 1
	services="$(ubus call service list '{"name":"ikev2-user-policy"}')"
	if printf '%s' "$services" | grep -q '"ikev2-user-policy"'; then
		ubus call service delete '{"name":"ikev2-user-policy"}' >/dev/null
	fi
	rm -f "$root"/etc/rc.d/*ikev2-user-policy
	charon_live=0
	if command -v swanctl >/dev/null 2>&1 && swanctl --list-conns >/dev/null 2>&1; then
		charon_live=1
		swanctl --terminate --ike ikev2-in --timeout 5 >/dev/null 2>&1 || true
	fi
	rm -f "$root/etc/swanctl/conf.d/30-inbound.conf" "$root/etc/swanctl/conf.d/91-inbound-secrets.conf"
	rm -f "$state/users.db" "$state/inbound.custom.conf"
	# Site Link may still consume the shared certificate after Manager retires its server.
	if [ "$(uci -q get ikev2-site-link.applied 2>/dev/null || true)" != state ] ||
	   [ "$(uci -q get ikev2-site-link.applied.enabled 2>/dev/null || true)" != 1 ] ||
	   [ "$(uci -q get ikev2-site-link.applied.role 2>/dev/null || true)" != exit ]; then
		rm -f "$root/etc/swanctl/x509/ikev2.pem" "$root/etc/swanctl/private/ikev2.key"
		rm -f "$root"/etc/swanctl/x509ca/ikev2-server-chain-*.pem
	fi
	if [ "$charon_live" = 1 ]; then
		swanctl --load-conns >/dev/null
		swanctl --list-conns >"$state/retired-connections.check"
		if grep -q 'ikev2-in:' "$state/retired-connections.check"; then
			rm -f "$state/retired-connections.check"
			echo 'Unable to retire the old inbound connection' >&2
			exit 1
		fi
		rm -f "$state/retired-connections.check"
	fi
	for section in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=.*/\1/p'); do
		case "$section" in
			ikev2pbr_in | ikev2pbr_in_* | ikev2pbr_server | ikev2pbr_server_* | ikev2access_*)
				uci -q delete "firewall.$section" ;;
		esac
	done
	uci commit firewall
	fw4 check >/dev/null
	fw4 -q reload
	# Remove only the retired guard, after the inbound forwarding was removed.
	if nft list table inet ikev2_user_policy >/dev/null 2>&1; then
		nft delete table inet ikev2_user_policy
	fi
	ip link set ipsec-in down 2>/dev/null || true
	# Drop only the retired source from Manager-owned policies; preserve personal rules.
	pbr_changed=0
	for section in ikev2pbr_domains ikev2pbr_service_cidrs; do
		sources="$(uci -q get "pbr.$section.src_addr" 2>/dev/null || true)"
		[ -n "$sources" ] || continue
		kept=''
		for source in $sources; do
			[ "$source" = @ipsec-in ] || kept="${kept:+$kept }$source"
		done
		uci set "pbr.$section.src_addr=$kept"
		pbr_changed=1
	done
	[ "$pbr_changed" = 0 ] || uci commit pbr
	old_zone="$(uci -q get "$config.server.outbound_zone" 2>/dev/null || true)"
	[ -z "$old_zone" ] || uci set "$config.globals.outbound_zone=$old_zone"
	uci -q delete "$config.server" || true
	for section in $(uci -q show "$config" | sed -n "s/^$config\.\([^.=]*\)=user_policy$/\1/p"); do
		uci -q delete "$config.$section"
	done
fi
# Existing lists stay available until the routing helper replaces them transactionally.
[ -f "$state/iran-domains.txt" ] || cp "$bundle" "$state/iran-domains.txt"
[ -f "$state/iran-cidrs.txt" ] || : >"$state/iran-cidrs.txt"
uci set "$config.domains.iran_direct=1"
uci set "$config.client.tunnel_dns_provider=cloudflare"
uci set "$config.client.tunnel_dns_upstream=https://cloudflare-dns.com/dns-query"
uci set "$config.client.tunnel_dns_bootstrap=1.1.1.1:53 1.0.0.1:53"
uci set "$config.globals.schema_version=3"
uci set "$config.globals.client_only_schema=1"
uci commit "$config"
