#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid

set -eu
umask 077

root="${IKEV2_ROOT:-}"
uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-$root/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

uci_config='ikev2-manager'
outbound_conf="$root/etc/swanctl/conf.d/20-proxy-out.conf"
outbound_secret="$root/etc/swanctl/conf.d/90-proxy-out-secret.conf"
client_secret_db="$root/etc/ikev2-manager/client.secret"
client_input_file="${IKEV2_CLIENT_INPUT:-}"
material_input_dir="${IKEV2_MATERIAL_INPUT_DIR:-/var/run}"
outbound_custom="$root/etc/ikev2-manager/outbound.custom.conf"
system_helper="${IKEV2_SYSTEM_HELPER:-$root/usr/libexec/ikev2-manager-system}"
action_status_file="${IKEV2_ACTION_STATUS:-$root/var/run/ikev2-manager-action.status}"
action_status_dir="${IKEV2_ACTION_STATUS_DIR:-$root/var/run/ikev2-manager-actions}"
action_lock_dir="${IKEV2_ACTION_LOCK:-$root/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-$root/var/run/ikev2-action.lock.status}"
auto_connect_lock="${IKEV2_AUTO_CONNECT_LOCK:-/var/run/ikev2-auto-connect.lock}"
auto_connect_attempt="${IKEV2_AUTO_CONNECT_ATTEMPT:-/var/run/ikev2-auto-connect.attempt}"
config_lock_dir="${IKEV2_CONFIG_LOCK:-$root/var/run/ikev2-manager-config.lock}"
tunnel_dns_state="${IKEV2_TUNNEL_DNS_STATE:-$root/var/run/ikev2-tunnel-dns.state}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-$root/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/actions.sh"
devices_library=0
if [ -r "$runtime_lib_dir/devices.sh" ]; then
	. "$runtime_lib_dir/devices.sh"
	devices_library=1
fi

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

input_file_for() {
	local kind="$1" token="$2"
	case "$token" in
		'' | *[!A-Za-z0-9-]* ) die 'Invalid input token' ;;
	esac
	[ "${#token}" -ge 8 ] && [ "${#token}" -le 64 ] || die 'Invalid input token'
	case "$kind" in
		client) printf '/var/run/ikev2-manager-client-%s.in\n' "$token" ;;
		material) printf '%s/ikev2-manager-material-%s.in\n' "$material_input_dir" "$token" ;;
		profile) printf '/var/run/ikev2-manager-profile-%s.in\n' "$token" ;;
		*) die 'Invalid input kind' ;;
	esac
}

filter_swanctl_noise() {
	grep -viE "plugin '.*': failed to load|no plugin file available|_plugin_create" |
		sed '/^[[:space:]]*$/d'
}

swanctl_quiet() {
	err="$(mktemp)"
	if swanctl "$@" 2>"$err"; then
		rm -f "$err"
		return 0
	else
		code=$?
	fi
	filtered="$(filter_swanctl_noise <"$err" | tail -n 8 | tr '\n' ' ')"
	rm -f "$err"
	[ -n "$filtered" ] && printf '%s\n' "$filtered" >&2
	return "$code"
}

consume_client_input() {
	local extra
	[ -f "$client_input_file" ] || die 'Client input is missing'
	[ ! -L "$client_input_file" ] || die 'Client input must not be a symbolic link'
	input_bytes="$(wc -c <"$client_input_file" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid client input size' ;; esac
	[ "$input_bytes" -le 8192 ] || {
		rm -f "$client_input_file"
		die 'Client input is too large'
	}
	chmod 600 "$client_input_file" || die 'Unable to protect client input'
	mode="$(sed -n '1p' "$client_input_file")"
	enabled="$(sed -n '2p' "$client_input_file")"
	remote_address="$(sed -n '3p' "$client_input_file")"
	remote_id="$(sed -n '4p' "$client_input_file")"
	username="$(sed -n '5p' "$client_input_file")"
	dpd="$(sed -n '6p' "$client_input_file")"
	mtu="$(sed -n '7p' "$client_input_file")"
	password="$(sed -n '8p' "$client_input_file")"
	reconnect_cooldown="$(sed -n '9p' "$client_input_file")"
	tunnel_dns_provider="$(sed -n '10p' "$client_input_file")"
	tunnel_dns_upstream="$(sed -n '11p' "$client_input_file")"
	tunnel_dns_bootstrap="$(sed -n '12p' "$client_input_file")"
	auth_method="$(sed -n '13p' "$client_input_file")"
	client_cert="$(sed -n '14p' "$client_input_file")"
	client_key="$(sed -n '15p' "$client_input_file")"
	extra="$(sed -n '16,$p' "$client_input_file" | sed '/^[[:space:]]*$/d')"
	[ -n "$reconnect_cooldown" ] || reconnect_cooldown=15
	[ "$tunnel_dns_provider" = cloudflare ] &&
	[ "$tunnel_dns_upstream" = 'https://cloudflare-dns.com/dns-query' ] &&
	[ "$tunnel_dns_bootstrap" = '1.1.1.1:53 1.0.0.1:53' ] ||
		die 'Tunnel DNS must use the fixed Cloudflare DoH and bootstrap servers'
	[ -n "$auth_method" ] || auth_method=eap-mschapv2
	rm -f "$client_input_file"
	[ -z "$extra" ] || die 'Client input contains unexpected fields'

	[ "$mode" = set ] || [ "$mode" = save ] || die 'Invalid client action'
	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	[ -z "$remote_address" ] || valid_host_list "$remote_address" ||
		die 'Invalid remote address list'
	[ -z "$remote_id" ] || valid_host "$remote_id" || die 'Invalid remote identity'
	[ -z "$username" ] || valid_user "$username" || die 'Invalid username'
	[ -z "$password" ] || valid_password "$password" ||
		die 'Password must be at most 256 characters without control characters'
	case "$auth_method" in
		eap-mschapv2 | pubkey | eap-tls) ;;
		*) die 'Authentication method must be eap-mschapv2, pubkey, or eap-tls' ;;
	esac
	if [ "$enabled" = 1 ]; then
		if [ "$mode" = set ]; then
			[ "$(getv globals configured)" = 1 ] ||
				ip link show ipsec-out >/dev/null 2>&1 ||
				die 'Complete and enable Overview first'
		fi
		valid_host_list "$remote_address" || die 'Invalid remote address list'
		valid_host "$remote_id" || die 'Invalid remote identity'
		valid_user "$username" || die 'Invalid username'
		case "$auth_method" in
			eap-mschapv2)
				[ -s "$client_secret_db" ] || [ -n "$password" ] ||
					die 'EAP password is required when enabling the client'
				;;
			pubkey | eap-tls)
				[ -n "$client_cert" ] ||
					die 'Client certificate path is required for certificate-based authentication'
				[ -n "$client_key" ] ||
					die 'Client private key path is required for certificate-based authentication'
				;;
		esac
	fi
	in_range "$dpd" 10 300 || die 'DPD must be 10-300 seconds'
	in_range "$mtu" 1280 1500 || die 'MTU must be 1280-1500'
	in_range "$reconnect_cooldown" 15 300 ||
		die 'Reconnect cooldown must be 15-300 seconds'
	valid_name "$tunnel_dns_provider" || die 'Invalid tunnel DNS provider'
	valid_tunnel_dns_list "$tunnel_dns_upstream" ||
		die 'Tunnel DNS must contain one or more valid HTTPS endpoints'
	valid_bootstrap_list "$tunnel_dns_bootstrap" ||
		die 'Tunnel DNS bootstrap must contain IPv4:port entries'

	pid_lock_acquire "$config_lock_dir" ||
		die 'Another configuration change is already in progress'
	client_state="$(mktemp -d)" || {
		pid_lock_release "$config_lock_dir"
		die 'Unable to prepare client configuration rollback'
	}
	if ! snapshot_path "$uci_config_dir/$uci_config" "$client_state" uci ||
	   ! snapshot_path "$client_secret_db" "$client_state" secret ||
	   ! snapshot_path "$outbound_conf" "$client_state" profile ||
	   ! snapshot_path "$outbound_secret" "$client_state" rendered_secret ||
	   ! snapshot_path "$root/etc/swanctl/x509/ikev2-client.pem" "$client_state" certificate ||
	   ! snapshot_path "$root/etc/swanctl/private/ikev2-client.key" "$client_state" private_key; then
		rm -rf "$client_state"
		pid_lock_release "$config_lock_dir"
		die 'Unable to back up current client configuration'
	fi
	trap 'restore_client_state "$client_state"; rm -rf "$client_state"; pid_lock_release "$config_lock_dir"; exit 1' INT TERM HUP
	if ! commit_client_settings; then
		client_restored=0
		restore_client_state "$client_state" && client_restored=1
		rm -rf "$client_state"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$client_restored" = 1 ] &&
			die 'Unable to save client settings; previous configuration restored'
		die 'Unable to save client settings and automatic rollback was incomplete'
	fi
	rm -rf "$client_state"
	pid_lock_release "$config_lock_dir"
	trap - INT TERM HUP

	[ "$mode" = set ] || return 0
	if [ "$(getv globals configured)" = 1 ]; then
		if [ "$enabled" = 1 ]; then
			start_action client-connect
		else
			start_action client-disable
		fi
	elif [ "$enabled" = 1 ]; then
		start_action connect
	fi
}

valid_user() {
	[ -n "$1" ] && [ "${#1}" -le 64 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@-]+$'
}

valid_password() {
	[ -n "$1" ] && [ "${#1}" -le 256 ] &&
		! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++)
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
					exit 1
		}
	'
}

valid_ipv6() {
	awk -v value="$1" 'BEGIN {
		if (value == "" || length(value) > 45 || value !~ /^[0-9A-Fa-f:]+$/ || index(value, ":") == 0)
			exit 1
		if (index(value, ":::") != 0)
			exit 1

		compressed = index(value, "::")
		if (compressed != 0) {
			left = substr(value, 1, compressed - 1)
			right = substr(value, compressed + 2)
			if (index(right, "::") != 0)
				exit 1
			left_count = left == "" ? 0 : split(left, left_groups, ":")
			right_count = right == "" ? 0 : split(right, right_groups, ":")
			if (left_count + right_count >= 8)
				exit 1
			for (i = 1; i <= left_count; i++)
				if (left_groups[i] !~ /^[0-9A-Fa-f]+$/ || length(left_groups[i]) > 4)
					exit 1
			for (i = 1; i <= right_count; i++)
				if (right_groups[i] !~ /^[0-9A-Fa-f]+$/ || length(right_groups[i]) > 4)
					exit 1
			exit 0
		}

		count = split(value, groups, ":")
		if (count != 8)
			exit 1
		for (i = 1; i <= count; i++)
			if (groups[i] !~ /^[0-9A-Fa-f]+$/ || length(groups[i]) > 4)
				exit 1
	}'
}

valid_dns_name() {
	awk -v value="$1" 'BEGIN {
		if (value == "" || length(value) > 253 || value !~ /^[A-Za-z0-9.-]+$/)
			exit 1
		if (value ~ /^[0-9.]+$/)
			exit 1
		count = split(value, labels, ".")
		for (i = 1; i <= count; i++) {
			label = labels[i]
			if (label == "" || length(label) > 63 ||
			    label !~ /^[A-Za-z0-9]/ || label !~ /[A-Za-z0-9]$/ ||
			    label !~ /^[A-Za-z0-9-]+$/)
				exit 1
		}
	}'
}

valid_host() {
	valid_ipv4 "$1" || valid_ipv6 "$1" || valid_dns_name "$1"
}

valid_tunnel_doh() {
	value="$1"
	[ "${#value}" -le 2048 ] || return 1
	case "$value" in https://*/*) ;; *) return 1 ;; esac
	authority="${value#https://}"
	authority="${authority%%/*}"
	path="/${value#https://*/}"
	host="${authority%%:*}"
	port="${authority#*:}"
	[ "$port" != "$authority" ] || port=443
	valid_dns_name "$host" && valid_uint "$port" &&
		[ "$port" -ge 1 ] && [ "$port" -le 65535 ] &&
		printf '%s' "$path" | grep -Eq '^/[A-Za-z0-9._~:/?%+=,&;@-]+$'
}

valid_tunnel_dns_list() {
	[ -n "$1" ] || return 1
	count=0
	for endpoint in $1; do
		valid_tunnel_doh "$endpoint" || return 1
		count=$((count + 1))
		[ "$count" -le 4 ] || return 1
	done
}

valid_bootstrap_endpoint() {
	host="${1%:*}"
	port="${1##*:}"
	[ "$host" != "$1" ] && valid_ipv4 "$host" && valid_uint "$port" &&
		[ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

valid_bootstrap_list() {
	[ -n "$1" ] || return 1
	count=0
	for endpoint in $1; do
		valid_bootstrap_endpoint "$endpoint" || return 1
		count=$((count + 1))
		[ "$count" -le 4 ] || return 1
	done
}

normalize_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

valid_name() {
	[ -n "$1" ] && [ "${#1}" -le 32 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

valid_path_or_empty() {
	[ -z "$1" ] || {
		[ "${#1}" -le 255 ] &&
			printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9_./@+-]+$'
	}
}

normalize_host_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' |
		sed 's/^ //; s/ $//'
}

valid_host_list() {
	hosts="$(normalize_host_list "$1")"
	[ -n "$hosts" ] || return 1
	count=0
	for host in $hosts; do
		count=$((count + 1))
		[ "$count" -le 16 ] || return 1
		valid_host "$host" || return 1
	done
}

valid_uint() {
	[ -n "$1" ] && printf '%s' "$1" | grep -Eq '^[0-9]+$'
}

in_range() {
	valid_uint "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

atomic_install() {
	local src="$1" dst="$2" mode="$3"
	chmod "$mode" "$src"
	mv "$src" "$dst"
}

snapshot_path() {
	local source="$1" directory="$2" name="$3"
	if [ -e "$source" ]; then
		cp -p "$source" "$directory/$name" || return 1
		: >"$directory/$name.present"
	else
		: >"$directory/$name.absent"
	fi
}

restore_path() {
	local destination="$1" directory="$2" name="$3"
	if [ -f "$directory/$name.present" ]; then
		mkdir -p "${destination%/*}" || return 1
		cp -p "$directory/$name" "${destination}.restore.$$" || return 1
		mv "${destination}.restore.$$" "$destination" || {
			rm -f "${destination}.restore.$$"
			return 1
		}
	elif [ -f "$directory/$name.absent" ]; then
		rm -f "$destination" || return 1
	else
		return 1
	fi
}

restore_client_state() {
	local directory="$1"
	restored=1
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	restore_path "$uci_config_dir/$uci_config" "$directory" uci || restored=0
	restore_path "$client_secret_db" "$directory" secret || restored=0
	restore_path "$outbound_conf" "$directory" profile || restored=0
	restore_path "$outbound_secret" "$directory" rendered_secret || restored=0
	restore_path "$root/etc/swanctl/x509/ikev2-client.pem" "$directory" certificate || restored=0
	restore_path "$root/etc/swanctl/private/ikev2-client.key" "$directory" private_key || restored=0
	[ "$restored" -eq 1 ]
}

commit_client_settings() {
	uci set "$uci_config.client.enabled=$enabled" || return 1
	uci set "$uci_config.client.auth_method=$auth_method" || return 1
	uci set "$uci_config.client.remote_address=$(normalize_host_list "$remote_address")" || return 1
	uci set "$uci_config.client.remote_id=$remote_id" || return 1
	uci set "$uci_config.client.username=$username" || return 1
	uci set "$uci_config.client.client_cert=$client_cert" || return 1
	uci set "$uci_config.client.client_key=$client_key" || return 1
	uci set "$uci_config.client.dpd=$dpd" || return 1
	uci set "$uci_config.client.mtu=$mtu" || return 1
	uci set "$uci_config.client.reconnect_cooldown=$reconnect_cooldown" || return 1
	uci set "$uci_config.client.tunnel_dns_provider=$tunnel_dns_provider" || return 1
	uci set "$uci_config.client.tunnel_dns_upstream=$tunnel_dns_upstream" || return 1
	uci set "$uci_config.client.tunnel_dns_bootstrap=$tunnel_dns_bootstrap" || return 1
	uci commit "$uci_config" || return 1
	case "$auth_method" in
		eap-mschapv2)
			if [ -n "$password" ]; then
				set_client_secret "$username" "$password" || return 1
			else
				sync_client_secret_identity "$username" || return 1
			fi
			;;
		pubkey | eap-tls)
			# Certificate-based auth: install cert and key for strongSwan
			install_client_certificate "$client_cert" "$client_key" || return 1
			;;
	esac
	render_client || return 1
	render_client_secret
}

getv_default() {
	value="$(uci -q get "$uci_config.$1.$2" 2>/dev/null || true)"
	printf '%s\n' "${value:-$3}"
}

get_list() {
	uci -q get "$uci_config.$1.$2" 2>/dev/null || true
}

interface_counter() {
	local file="$root/sys/class/net/$1/statistics/$2" value=0
	if [ -r "$file" ]; then
		IFS= read -r value <"$file" || value=0
	fi
	case "$value" in '' | *[!0-9]*) value=0 ;; esac
	printf '%s\n' "$value"
}

set_list() {
	section="$1"
	option="$2"
	value="$(normalize_list "$3")"
	uci -q delete "$uci_config.$section.$option" || true
	for item in $value; do
		uci add_list "$uci_config.$section.$option=$item" || return 1
	done
}

init_uci() {
	mkdir -p "$uci_config_dir" "$root/etc/ikev2-manager" "$root/etc/swanctl/conf.d"
	chmod 700 "$root/etc/ikev2-manager"
	touch "$uci_config_dir/$uci_config"
	for section in globals client dns domains; do
		uci -q get "$uci_config.$section" >/dev/null 2>&1 || uci set "$uci_config.$section=$section"
	done
	for assignment in 'globals.configured=0' 'client.enabled=0' 'client.dpd=30' \
		'client.mtu=1400' 'client.reconnect_cooldown=15' 'client.custom_config=0' \
		'domains.iran_direct=1'; do
		uci -q get "$uci_config.${assignment%%=*}" >/dev/null 2>&1 || uci set "$uci_config.$assignment"
	done
	uci set "$uci_config.client.tunnel_dns_provider=cloudflare"
	uci set "$uci_config.client.tunnel_dns_upstream=https://cloudflare-dns.com/dns-query"
	uci set "$uci_config.client.tunnel_dns_bootstrap=1.1.1.1:53 1.0.0.1:53"
	uci set "$uci_config.globals.schema_version=3"
	uci commit "$uci_config"
}

init_client_secret() {
	[ -s "$client_secret_db" ] && return 0
	[ -s "$outbound_secret" ] || return 0
	username="$(sed -n 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$outbound_secret" | head -n1)"
	secret="$(sed -n 's/^[[:space:]]*secret[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$outbound_secret" | head -n1)"
	[ -n "$username" ] && [ -n "$secret" ] || return 0
	printf '%s\t%s\n' "$username" "$secret" >"${client_secret_db}.new"
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

getv() {
	# Tolerate empty/missing options like get_list/getv_default and the system
	# helper's getv. A bare `uci -q get` returns non-zero for a set-but-empty
	# option, which under `set -eu` can abort before rollback. Callers only read the value.
	uci -q get "$uci_config.$1.$2" 2>/dev/null || true
}

sync_client_ca() {
	src="$root/usr/share/ikev2-manager/ca"
	dir="$root/etc/swanctl/x509ca"
	mkdir -p "$dir" || return 1
	for pem in "$src"/isrg-root-*.pem; do
		[ -s "$pem" ] || continue
		cp "$pem" "$dir/ikev2-le-${pem##*/}.new" || return 1
		chmod 644 "$dir/ikev2-le-${pem##*/}.new" || return 1
		mv "$dir/ikev2-le-${pem##*/}.new" "$dir/ikev2-le-${pem##*/}" || return 1
	done
}

import_client_material() {
	local kind="$1" token="$2" source destination temporary bytes
	case "$kind" in
		cert) destination="$root/etc/ikev2-manager/client-imported-cert.pem" ;;
		key) destination="$root/etc/ikev2-manager/client-imported-key.pem" ;;
		*) die 'Invalid client material type' ;;
	esac
	source="$(input_file_for material "$token")"
	[ -f "$source" ] && [ ! -L "$source" ] || die 'Uploaded PEM file is missing'
	bytes="$(wc -c <"$source" | tr -d ' ')"
	case "$bytes" in '' | *[!0-9]*) die 'Invalid uploaded PEM size' ;; esac
	if [ "$bytes" -lt 1 ] || [ "$bytes" -gt 65536 ]; then
		rm -f "$source"
		die 'Uploaded PEM must be between 1 and 65536 bytes'
	fi
	if [ "$kind" = cert ]; then
		if ! openssl x509 -in "$source" -noout >/dev/null 2>&1; then
			rm -f "$source"
			die 'Uploaded file is not a valid PEM X.509 certificate'
		fi
	elif ! openssl pkey -in "$source" -noout -passin pass: >/dev/null 2>&1; then
		rm -f "$source"
		die 'Uploaded file is not an unencrypted PEM private key'
	fi
	if ! mkdir -p "${destination%/*}"; then
		rm -f "$source"
		die 'Unable to create client certificate directory'
	fi
	temporary="${destination}.new.$$"
	if ! cp "$source" "$temporary" ||
	   ! chmod 600 "$temporary" ||
	   ! mv "$temporary" "$destination"; then
		rm -f "$source" "$temporary"
		die 'Unable to store uploaded client material'
	fi
	rm -f "$source"
	printf 'path=%s\n' "$destination"
}

install_client_certificate() {
	local cert_src="$1" key_src="$2"
	local cert_dst="$root/etc/swanctl/x509/ikev2-client.pem"
	local key_dst="$root/etc/swanctl/private/ikev2-client.key"
	local cert_public key_public
	mkdir -p "$root/etc/swanctl/x509" "$root/etc/swanctl/private"
	[ -f "$cert_src" ] || {
		printf '%s\n' "Client certificate file not found: $cert_src" >&2
		return 1
	}
	[ -f "$key_src" ] || {
		printf '%s\n' "Client private key file not found: $key_src" >&2
		return 1
	}
	cert_public="$(openssl x509 -in "$cert_src" -pubkey -noout 2>/dev/null)" || return 1
	key_public="$(openssl pkey -in "$key_src" -pubout -passin pass: 2>/dev/null)" || return 1
	[ -n "$cert_public" ] && [ "$cert_public" = "$key_public" ] || {
		printf '%s\n' 'Client certificate and private key do not match' >&2
		return 1
	}
	cp "$cert_src" "${cert_dst}.new" || return 1
	atomic_install "${cert_dst}.new" "$cert_dst" 644
	cp "$key_src" "${key_dst}.new" || return 1
	atomic_install "${key_dst}.new" "$key_dst" 600
}

render_client() {
	enabled="$(getv client enabled)"
	tmp="${outbound_conf}.new"

	if [ "$enabled" != 1 ]; then
		echo '# Managed by IKEv2 Manager. Outbound client is disabled.' >"$tmp" || return 1
		atomic_install "$tmp" "$outbound_conf" 600
		return
	fi

	auth_method="$(getv_default client auth_method eap-mschapv2)"

	if [ "$auth_method" = eap-mschapv2 ]; then
		if ! "$system_helper" strongswan-security client >/dev/null 2>&1; then
			echo '# Managed by IKEv2 Manager. Outbound client is blocked: installed strongSwan is unsafe for EAP-MSCHAPv2.' >"$tmp"
			atomic_install "$tmp" "$outbound_conf" 600
			return
		fi
	fi

	if [ "$(getv_default client custom_config 0)" = 1 ]; then
		[ -s "$outbound_custom" ] || {
			printf '%s\n' 'Outbound custom configuration is missing' >&2
			return 1
		}
		cp "$outbound_custom" "$tmp" || return 1
		atomic_install "$tmp" "$outbound_conf" 600
		return
	fi

	sync_client_ca || return 1

	remote_address="$(getv client remote_address)"
	remote_id="$(getv client remote_id)"
	username="$(getv client username)"
	dpd="$(getv client dpd)"
	remote_addrs="$(normalize_host_list "$remote_address" | sed 's/ /, /g')"
	client_cert="$(getv_default client client_cert '')"
	client_key="$(getv_default client client_key '')"

	# Build local auth block based on auth_method
	local_auth=""
	case "$auth_method" in
		eap-mschapv2)
			local_auth="$(cat <<-LOCALAUTH
		local {
			auth = eap-mschapv2
			id = $username
			eap_id = $username
		}
			LOCALAUTH
			)"
			;;
		pubkey)
			[ -n "$client_cert" ] || {
				printf '%s\n' 'Client certificate path is required for pubkey authentication' >&2
				return 1
			}
			[ -n "$client_key" ] || {
				printf '%s\n' 'Client private key path is required for pubkey authentication' >&2
				return 1
			}
			local_auth="$(cat <<-LOCALAUTH
		local {
			auth = pubkey
			certs = $client_cert
			id = $username
		}
			LOCALAUTH
			)"
			;;
		eap-tls)
			[ -n "$client_cert" ] || {
				printf '%s\n' 'Client certificate path is required for EAP-TLS authentication' >&2
				return 1
			}
			[ -n "$client_key" ] || {
				printf '%s\n' 'Client private key path is required for EAP-TLS authentication' >&2
				return 1
			}
			local_auth="$(cat <<-LOCALAUTH
		local {
			auth = eap-tls
			id = $username
			eap_id = $username
		}
			LOCALAUTH
			)"
			;;
		*)
			printf '%s\n' "Unknown authentication method: $auth_method" >&2
			return 1
			;;
	esac

	cat >"$tmp" <<EOF
connections {
	proxy-out {
		version = 2
		remote_addrs = $remote_addrs
		proposals = aes256gcm16-prfsha384-ecp384,aes256gcm16-prfsha256-ecp256,aes256-sha256-modp2048
		vips = 0.0.0.0
		mobike = yes
		fragmentation = yes
		dpd_delay = ${dpd}s
		reauth_time = 0
		keyingtries = 0

$local_auth

		remote {
			auth = pubkey
			id = $remote_id
		}

		children {
			proxy4 {
				local_ts = 0.0.0.0/0
				remote_ts = 0.0.0.0/0
				esp_proposals = aes256gcm16-ecp384,aes256gcm16-ecp256,aes256gcm16-modp2048,aes256gcm16,aes256-sha256-modp2048,aes256-sha256
				if_id_in = 42
				if_id_out = 42
				start_action = start
				dpd_action = restart
				close_action = start
			}
		}
	}
}
EOF
	[ -s "$tmp" ] || return 1
	atomic_install "$tmp" "$outbound_conf" 600
}

set_client_secret() {
	username="$1"
	password="$2"
	encoded="$(printf '%s' "$password" | openssl base64 -A)" || return 1
	mkdir -p "${client_secret_db%/*}" || return 1
	printf '%s\t0s%s\n' "$username" "$encoded" >"${client_secret_db}.new" || return 1
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

render_client_secret() {
	tmp="${outbound_secret}.new"
	if [ ! -s "$client_secret_db" ]; then
		echo '# Managed by IKEv2 Manager. Client secret is not configured.' >"$tmp" || return 1
		atomic_install "$tmp" "$outbound_secret" 600
		return
	fi
	IFS="$(printf '\t')" read -r username encoded <"$client_secret_db" || return 1
	tmp="${outbound_secret}.new"
	cat >"$tmp" <<EOF
secrets {
	eap-proxy-out {
		id = "$username"
		secret = $encoded
	}
}
EOF
	[ -s "$tmp" ] || return 1
	atomic_install "$tmp" "$outbound_secret" 600
}

sync_client_secret_identity() {
	username="$1"
	[ -s "$client_secret_db" ] || return 0
	IFS="$(printf '\t')" read -r old_username encoded <"$client_secret_db" || return 1
	[ "$old_username" = "$username" ] && return 0
	printf '%s\t%s\n' "$username" "$encoded" >"${client_secret_db}.new" || return 1
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

load_profile() {
	profile="$1"
	[ -z "$root" ] || return 0
	case "$profile" in
		outbound)
			swanctl_quiet --load-all >/dev/null
			if [ "$(getv client enabled)" = 1 ]; then
				swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null || :
				initiate_outbound
				/usr/libexec/ikev2-sync-vips
				/usr/share/pbr/pbr.user.ikev2out
			fi
			;;
		*)
			die 'Unknown profile'
			;;
	esac
}

profile_values() {
	case "$1" in
		outbound)
			profile_section='client'
			profile_active="$outbound_conf"
			profile_custom="$outbound_custom"
			;;
		*)
			die 'Expected profile: outbound'
			;;
	esac
}

advanced_read() {
	profile_values "$1"
		render_client
	cat "$profile_active"
}

advanced_set() {
	profile="$1"
	input="$2"
	profile_values "$profile"
	case "$profile" in
		outbound) "$system_helper" strongswan-security client >/dev/null 2>&1 ||
			die 'Outbound custom configuration is blocked by the installed strongSwan version' ;;
	esac
	[ -f "$input" ] || die 'Custom configuration input is missing'
	[ ! -L "$input" ] || die 'Custom configuration input must not be a symbolic link'
	input_bytes="$(wc -c <"$input" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) rm -f "$input"; die 'Invalid custom configuration size' ;; esac
	[ "$input_bytes" -le 65536 ] || {
		rm -f "$input"
		die 'Custom configuration is larger than 64 KiB'
	}
	chmod 600 "$input" || { rm -f "$input"; die 'Unable to protect custom configuration'; }
	tmp="${profile_custom}.new"
	if ! cp "$input" "$tmp"; then
		rm -f "$input" "$tmp"
		die 'Unable to stage custom configuration'
	fi
	rm -f "$input"
	[ -s "$tmp" ] || {
		rm -f "$tmp"
		die 'Custom configuration cannot be empty'
	}
	[ "$(wc -c <"$tmp")" -le 65536 ] || {
		rm -f "$tmp"
		die 'Custom configuration is larger than 64 KiB'
	}
	grep -Eq '^[[:space:]]*connections[[:space:]]*\{' "$tmp" || {
		rm -f "$tmp"
		die 'Custom configuration must contain a connections block'
	}
	case "$profile" in
		outbound)
			grep -Eq '^[[:space:]]*proxy-out[[:space:]]*\{' "$tmp" || {
				rm -f "$tmp"
				die 'Outbound custom configuration must define proxy-out'
			}
			;;
	esac

	old_mode="$(getv_default "$profile_section" custom_config 0)"
	backup="${profile_custom}.backup"
	[ -s "$profile_custom" ] && cp "$profile_custom" "$backup" || rm -f "$backup"
	atomic_install "$tmp" "$profile_custom" 600
	uci set "$uci_config.$profile_section.custom_config=1"
	uci commit "$uci_config"

	if ! {
		cp "$profile_custom" "${profile_active}.new"
		atomic_install "${profile_active}.new" "$profile_active" 600
		load_profile "$profile"
	}; then
		[ -s "$backup" ] && mv "$backup" "$profile_custom" || rm -f "$profile_custom"
		uci set "$uci_config.$profile_section.custom_config=$old_mode"
		uci commit "$uci_config"
			render_client
		load_profile "$profile" >/dev/null 2>&1 || :
		die 'strongSwan rejected the custom configuration'
	fi
	rm -f "$backup"
}

advanced_reset() {
	profile="$1"
	profile_values "$profile"
	old_mode="$(getv_default "$profile_section" custom_config 0)"
	active_backup="${profile_active}.rollback.$$"
	[ ! -s "$profile_active" ] || cp "$profile_active" "$active_backup"
	uci set "$uci_config.$profile_section.custom_config=0"
	uci commit "$uci_config"
	if ! {
			render_client
		load_profile "$profile"
	}; then
		uci set "$uci_config.$profile_section.custom_config=$old_mode"
		uci commit "$uci_config"
		if [ -s "$active_backup" ]; then
			cp "$active_backup" "${profile_active}.new"
			atomic_install "${profile_active}.new" "$profile_active" 600
		fi
		load_profile "$profile" >/dev/null 2>&1 || true
		rm -f "$active_backup"
		die 'Unable to restore the generated profile; previous profile restored'
	fi
	rm -f "$active_backup"
}

apply_all() {
	[ "$(getv globals configured)" = 1 ] ||
		die 'Complete and enable Overview first'
	render_client
	render_client_secret
	"$system_helper" apply
	swanctl_quiet --load-all >/dev/null
	/usr/libexec/ikev2-sync-vips || :
	/usr/share/pbr/pbr.user.ikev2out || :
}

package_installed() {
	name="$1"
	if command -v opkg >/dev/null 2>&1; then
		opkg status "$name" 2>/dev/null | grep -q '^Status: .* installed'
	elif command -v apk >/dev/null 2>&1; then
		apk info -e "$name" >/dev/null 2>&1
	else
		return 1
	fi
}

widget_status_live() {
	count_lines() {
		[ -r "$1" ] &&
			awk 'NF && $1 !~ /^#/ { n++ } END { print n + 0 }' "$1" ||
			echo 0
	}
	domain_status=''
	if [ -x "$root/usr/libexec/ikev2-domain-router" ]; then
		domain_status="$("$root/usr/libexec/ikev2-domain-router" status 2>/dev/null || true)"
	fi
	configured="$(getv globals configured)"
	[ -n "$configured" ] || configured=0
	device_excluded=0
	device_fullroute=0
	device_dns_passthrough=0
	device_dpi_passthrough=0
	for section in $(uci show "$uci_config" 2>/dev/null |
		sed -n "s/^${uci_config}\.\([^.=]*\)=device_policy\$/\1/p"); do
		case "$(uci -q get "$uci_config.$section.route_mode" 2>/dev/null || true)" in
			exclude) device_excluded=$((device_excluded + 1)) ;;
			fullroute) device_fullroute=$((device_fullroute + 1)) ;;
		esac
		[ "$(uci -q get "$uci_config.$section.dns_passthrough" 2>/dev/null || true)" != 1 ] ||
			device_dns_passthrough=$((device_dns_passthrough + 1))
		[ "$(uci -q get "$uci_config.$section.dpi_passthrough" 2>/dev/null || true)" != 1 ] ||
			device_dpi_passthrough=$((device_dpi_passthrough + 1))
	done
	if [ "$devices_library" = 1 ]; then
		device_excluded_list="$(device_addresses exclude 2>/dev/null || true)"
		device_excluded="$(printf '%s\n' "$device_excluded_list" |
			awk 'NF { n++ } END { print n + 0 }')"
	fi
	device_stats=''
	if [ -x "$root/usr/libexec/ikev2-device-routing" ]; then
		device_stats="$("$root/usr/libexec/ikev2-device-routing" stats 2>/dev/null || true)"
	fi
	device_excluded_packets="$(printf '%s\n' "$device_stats" |
		awk '$2 == "kind=exclude" { split($3, a, "="); n += a[2] } END { print n + 0 }')"
	device_excluded_bytes="$(printf '%s\n' "$device_stats" |
		awk '$2 == "kind=exclude" { split($4, a, "="); n += a[2] } END { print n + 0 }')"

	printf 'health=%s\n' \
		"$(sed -n 's/^state=\([^ ]*\).*/\1/p' "$root/var/run/ikev2-health.status" 2>/dev/null || echo unknown)"
	printf 'configured=%s\n' "$configured"
	printf 'pbr=%s\n' \
		"$([ -x "$root/etc/init.d/pbr" ] &&
			"$root/etc/init.d/pbr" running && echo running || echo stopped)"
	printf 'client_enabled=%s\n' "$(getv client enabled)"
	if [ -d "$root/sys/class/net/ipsec-out" ]; then
		printf 'interface_present=1\n'
	else
		printf 'interface_present=0\n'
	fi
	printf 'interface_bytes_in=%s\n' "$(interface_counter ipsec-out rx_bytes)"
	printf 'interface_bytes_out=%s\n' "$(interface_counter ipsec-out tx_bytes)"
	printf 'pbr_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.txt")"
	printf 'manual_addresses=%s\n' \
		"$(count_lines "$root/etc/pbr-ikev2-addresses.manual.txt")"
	printf 'community_services=%s\n' \
		"$(count_lines "$root/etc/pbr-ikev2-community-selected.txt")"
	printf 'device_excluded=%s\n' "$device_excluded"
	printf 'device_fullroute=%s\n' "$device_fullroute"
	printf 'device_dns_passthrough=%s\n' "$device_dns_passthrough"
	printf 'device_dpi_passthrough=%s\n' "$device_dpi_passthrough"
	printf 'device_excluded_packets=%s\n' "$device_excluded_packets"
	printf 'device_excluded_bytes=%s\n' "$device_excluded_bytes"
	printf 'killswitch=%s\n' "$(ip -4 route show table pbr_ikev2out 2>/dev/null |
		grep -Eq '^unreachable default( |$)' && echo active || echo missing)"
	for field in engine service healthy state; do
		if [ "$field" = engine ]; then
			value="$(getv domains engine)"
		else
			value="$(printf '%s\n' "$domain_status" |
				sed -n "s/^$field=//p" | tail -n1)"
		fi
		printf 'domain_%s=%s\n' "$field" "$value"
	done
}

widget_status() {
	# Status Overview polls every five seconds. Most fields change only after a
	# managed action, while active SAs and their traffic are fetched separately
	# by swanmon. Reuse the compact backend snapshot briefly instead of invoking
	# UCI, nft, PBR and strongSwan helpers on every browser poll.
	if [ -n "$root" ] && [ "${IKEV2_WIDGET_STATUS_CACHE_TEST:-0}" != 1 ]; then
		widget_status_live
		return
	fi
	cache="${IKEV2_WIDGET_STATUS_CACHE:-/var/run/ikev2-widget-status.cache}"
	ttl="${IKEV2_WIDGET_STATUS_TTL:-15}"
	case "$ttl" in '' | *[!0-9]*) ttl=15 ;; esac
	now="$(date +%s)"
	cached_at="$(sed -n 's/^cached_at=//p' "$cache" 2>/dev/null | head -n1)"
	case "$cached_at" in '' | *[!0-9]*) cached_at=0 ;; esac
	if [ "$cached_at" -gt 0 ] && [ "$now" -ge "$cached_at" ] &&
	   [ $((now - cached_at)) -lt "$ttl" ]; then
		sed '/^cached_at=/d' "$cache"
		return
	fi
	mkdir -p "${cache%/*}"
	{
		printf 'cached_at=%s\n' "$now"
		widget_status_live
	} >"${cache}.new.$$" || {
		rm -f "${cache}.new.$$"
		return 1
	}
	chmod 600 "${cache}.new.$$"
	mv "${cache}.new.$$" "$cache"
	sed '/^cached_at=/d' "$cache"
}

overview() {
	cert="$root/etc/swanctl/x509/ikev2.pem"
	count_lines() {
		[ -r "$1" ] && awk 'NF && $1 !~ /^#/ { n++ } END { print n + 0 }' "$1" || echo 0
	}
	configured="$(getv globals configured)"
	[ -n "$configured" ] || configured=0
	[ "$configured" = 1 ] && runtime_mode=managed || runtime_mode=unconfigured
	printf 'health=%s\n' "$(sed -n 's/^state=\([^ ]*\).*/\1/p' /var/run/ikev2-health.status 2>/dev/null || echo unknown)"
	printf 'pbr=%s\n' "$("$root/etc/init.d/pbr" running && echo running || echo stopped)"
	printf 'configured=%s\n' "$configured"
	printf 'runtime_mode=%s\n' "$runtime_mode"
	printf 'package_installed=%s\n' "$(package_installed luci-app-ikev2-manager && echo 1 || echo 0)"
	printf 'zapret=%s\n' "$([ -x "$root/etc/init.d/zapret" ] &&
		"$root/etc/init.d/zapret" running && echo running || echo not-installed)"
	printf 'client_enabled=%s\n' "$(getv client enabled)"
	printf 'client_remote=%s\n' "$(getv client remote_address)"
	printf 'client_mtu=%s\n' "$(getv client mtu)"
	printf 'pbr_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.txt")"
	printf 'manual_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.manual.txt")"
	printf 'manual_addresses=%s\n' "$(count_lines "$root/etc/pbr-ikev2-addresses.manual.txt")"
	printf 'community_services=%s\n' "$(count_lines "$root/etc/pbr-ikev2-community-selected.txt")"
	printf 'dns_hijack=%s\n' "$(
		if nft list chain inet ikev2_device_policy dns_prerouting 2>/dev/null |
			grep -Fq 'comment "ikev2-device:dns-enforce"'; then
			echo active
		elif [ "$(getv globals dns_enforce)" = 1 ]; then
			echo configured
		else
			echo missing
		fi
	)"
	printf 'dot_block=%s\n' "$(
		if nft list chain inet ikev2_device_policy dot_forward 2>/dev/null |
			grep -Fq 'comment "ikev2-device:dot-block"'; then
			echo active
		elif [ "$(getv globals block_dot)" = 1 ]; then
			echo configured
		else
			echo missing
		fi
	)"
	printf 'killswitch=%s\n' "$(ip -4 route show table pbr_ikev2out 2>/dev/null |
		grep -Eq '^unreachable default( |$)' && echo active || echo missing)"
	printf 'mtproto=%s\n' "$([ -x "$root/etc/init.d/tg-ws-proxy" ] &&
		"$root/etc/init.d/tg-ws-proxy" running &&
		echo running || echo not-installed)"
	printf 'mtproto_firewall=%s\n' "$(
		nft list ruleset 2>/dev/null |
			grep -Eq 'tcp dport 1443.*(accept|dnat)' &&
			echo active || echo missing
	)"
	printf 'flow_software=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading || echo 0)"
	printf 'flow_hardware=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 0)"
	printf 'safexcel=%s\n' "$(lsmod | grep -q '^crypto_safexcel ' && echo loaded || echo unloaded)"
}

manager_initialized() {
	[ "$(getv globals schema_version)" = 3 ] &&
		[ -d "$root/etc/swanctl/conf.d" ]
}

initialize_manager() {
	manager_initialized && return 0
	mkdir -p "${config_lock_dir%/*}"
	local tries=0
	while ! pid_lock_acquire "$config_lock_dir"; do
		tries=$((tries + 1))
		[ "$tries" -lt 5 ] || die 'Another configuration change is already in progress'
		sleep 1
	done
	trap 'pid_lock_release "$config_lock_dir"' EXIT
	if ! manager_initialized; then
		init_uci
		init_client_secret
	fi
	pid_lock_release "$config_lock_dir"
	trap - EXIT
}

initialize_manager

connect_failure_file="${IKEV2_CONNECT_FAILURE_FILE:-/var/run/ikev2-connect-failure}"

# charon reports the real reason for a failed handshake to syslog, not through
# VICI, so an operator otherwise gets "the CHILD_SA failed" and nothing else.
# Translate the recognised signatures into something that names what to fix.
classify_initiate_failure() {
	local recent
	recent="$(logread 2>/dev/null | grep -iE 'charon|ipsec' | tail -n 120)"
	[ -n "$recent" ] || return 0
	case "$recent" in
		*'no issuer certificate found'* | *'no trusted '*'public key found'*)
			printf '%s\n' \
				'the gateway certificate could not be validated: it was issued by an intermediate CA that the gateway did not send. Fix the certificate chain on the gateway.'
			;;
		*'EAP-Identity'*'failed'* | *'AUTHENTICATION_FAILED'* | *'AUTH_FAILED'*)
			printf '%s\n' 'the gateway rejected the credentials'
			;;
		*'no proposal chosen'* | *'NO_PROPOSAL_CHOSEN'*)
			printf '%s\n' 'no shared encryption proposal with the gateway'
			;;
		*'no acceptable traffic selectors'* | *'TS_UNACCEPTABLE'*)
			printf '%s\n' 'the gateway rejected the requested traffic selectors'
			;;
		*'retransmit'*'timed out'* | *'giving up after'*)
			printf '%s\n' 'the gateway did not answer; check its address, UDP 500/4500 and the WAN path'
			;;
		*'looking for peer configs matching'*'no matching peer config'*)
			printf '%s\n' 'the gateway has no configuration matching this identity'
			;;
	esac
}

# Run swanctl --initiate but swallow strongSwan's noisy plugin-load warnings,
# surfacing only the meaningful failure reason to the caller (and the LuCI UI).
initiate_outbound() {
	_err="$(swanctl --initiate --child proxy4 --timeout 20 2>&1 >/dev/null)" && return 0
	# A busy peer can complete IKE_AUTH immediately after the VICI timeout.
	# Check runtime truth briefly before reporting a failed reconnect.
	_wait=0
	while [ "$_wait" -lt 8 ]; do
		has_outbound_sa && return 0
		_wait=$((_wait + 1))
		sleep 1
	done
	_reason="$(printf '%s\n' "$_err" \
		| grep -viE 'failed to load|no plugin file|_plugin_create' \
		| grep -iE 'initiate|establish|auth|propos|timeout|retransmit|no ike|unable|notify|peer|certificate|fail' \
		| tail -n 4 | tr '\n' ' ' | sed 's/  */ /g')"
	[ -n "$_reason" ] || _reason='establishing CHILD_SA proxy4 failed'
	# VICI only reports that the CHILD_SA failed; charon logs why to syslog.
	# Without this the operator sees a dead end and has to read logread by hand,
	# so the actual cause is classified and appended here.
	_cause="$(classify_initiate_failure)"
	[ -z "$_cause" ] || _reason="$_reason - $_cause"
	printf 'Tunnel did not come up: %s\n' "$_reason" >&2
	# Carry the reason to the LuCI status message; pointing the operator at a
	# log file is not a diagnosis.
	mkdir -p "${connect_failure_file%/*}" 2>/dev/null || :
	printf '%s\n' "$_reason" >"$connect_failure_file" 2>/dev/null || :
	return 1
}

connect_action() {
	swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null 2>&1 || :
	rm -f /var/run/ikev2-vip4
	ip -4 addr flush dev ipsec-out scope global 2>/dev/null || :
	if initiate_outbound; then
		/usr/libexec/ikev2-sync-vips || return 1
		# The policy itself did not change. Refresh only the live PBR table route;
		# a full PBR restart would rebuild firewall4 and add ~20 seconds.
		/usr/share/pbr/pbr.user.ikev2out || return 1
		# Apply a changed tunnel-DNS list immediately after the XFRM path exists.
		# Resolver failure remains fail-closed and must not misreport the healthy
		# IKEv2 connection itself as failed.
		/usr/libexec/ikev2-domain-router tunnel-dns-check >/dev/null 2>&1 || :
		return 0
	else
		/usr/libexec/ikev2-sync-vips || :
		/usr/share/pbr/pbr.user.ikev2out || :
		return 1
	fi
}

has_outbound_sa() {
	swanctl --list-sas --raw 2>/dev/null |
		grep -q 'name=proxy4[^{}]* state=INSTALLED'
}

# A start_action fired before WAN is ready can leave an IKE_SA permanently
# bound to loopback. Further CHILD_SA initiations then reuse that IKE_SA and
# never perform source-address selection again. Match only this impossible
# outbound state; a CONNECTING SA with a real local address may simply be slow
# and must not be interrupted.
has_loopback_connecting_outbound() {
	printf '%s\n' "$1" |
		grep -Eq 'list-sa event \{proxy-out \{[^}]*state=CONNECTING[^}]*local-host=(127\.[0-9.]+|::1)([[:space:]}]|$)'
}

outbound_peer_resolves() {
	peers="$(normalize_host_list "$(getv client remote_address)")"
	for peer in $peers; do
		if valid_ipv4 "$peer" ||
		   printf '%s' "$peer" | grep -q ':' ||
		   resolveip -4 -t 3 "$peer" >/dev/null 2>&1; then
			return 0
		fi
	done
	return 1
}

# Bring up an enabled outbound client without tearing down an already healthy
# SA. This is used by WAN hotplug and the health watcher, so it has its own
# non-blocking lock and a short failure backoff to avoid duplicate initiations.
ensure_client_action() {
	[ -z "$root" ] || return 0
	[ "$(getv globals configured)" = 1 ] || return 0
	[ "$(getv client enabled)" = 1 ] || return 0
	"$system_helper" strongswan-security client >/dev/null 2>&1 || return 0
	has_outbound_sa && return 0
	[ ! -d "$action_lock_dir" ] || return 0

	now="$(date +%s)"
	cooldown="$(getv_default client reconnect_cooldown 15)"
	in_range "$cooldown" 15 300 || cooldown=15
	last="$(cat "$auto_connect_attempt" 2>/dev/null || echo 0)"
	case "$last" in
		'' | *[!0-9]*) last=0 ;;
	esac
	[ $((now - last)) -ge "$cooldown" ] || return 0

	if ! mkdir "$auto_connect_lock" 2>/dev/null; then
		lock_pid="$(cat "$auto_connect_lock/pid" 2>/dev/null || true)"
		if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$auto_connect_lock/pid"
		rmdir "$auto_connect_lock" 2>/dev/null || return 0
		mkdir "$auto_connect_lock" 2>/dev/null || return 0
	fi
	printf '%s\n' "$$" >"$auto_connect_lock/pid"
	trap 'rm -f "$auto_connect_lock/pid"; rmdir "$auto_connect_lock" 2>/dev/null || true' EXIT INT TERM

	# Recheck after taking the lock: WAN hotplug and the watcher may have raced.
	has_outbound_sa && return 0
	[ ! -d "$action_lock_dir" ] || return 0
	printf '%s\n' "$now" >"$auto_connect_attempt"
	# Do not spend swanctl's full initiation timeout while boot-time DNS is not
	# ready yet. The watcher will retry shortly, and hotplug calls us again only
	# after the WAN has had time to finish resolver/PBR setup.
	outbound_peer_resolves || return 1

	swanctl_quiet --load-conns >/dev/null || return 1
	swanctl_quiet --load-creds >/dev/null || return 1
	raw="$(swanctl --list-sas --raw 2>/dev/null || true)"
	if has_loopback_connecting_outbound "$raw"; then
		logger -t ikev2-health \
			'discarding boot-stalled proxy-out IKE_SA bound to loopback' || :
		swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null 2>&1 || :
		# Termination is synchronous, but start_action may already have created a
		# healthy replacement while the VICI request was completing.
		if has_outbound_sa; then
			/usr/libexec/ikev2-sync-vips || return 1
			/usr/share/pbr/pbr.user.ikev2out || return 1
			return 0
		fi
	fi
	initiate_outbound || return 1
	/usr/libexec/ikev2-sync-vips || return 1
	/usr/share/pbr/pbr.user.ikev2out || return 1
}

disable_client_action() {
	# The disabled profile contains no proxy-out connection. Reload it first so
	# charon unloads the previous start_action=start definition instead of
	# immediately re-initiating after termination.
	swanctl_quiet --load-conns >/dev/null || return 1
	swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null 2>&1 || :
	rm -f /var/run/ikev2-vip4
	ip -4 addr flush dev ipsec-out scope global 2>/dev/null || :
	/usr/share/pbr/pbr.user.ikev2out || return 1
	tries=0
	while [ "$tries" -lt 10 ]; do
		if ! swanctl --list-conns 2>/dev/null | grep -q 'proxy-out:' &&
		   ! swanctl --list-sas --raw 2>/dev/null | grep -q 'name=proxy-out'; then
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

apply_action() {
	"$system_helper" apply || return 1
	swanctl_quiet --load-all >/dev/null || return 1
	/usr/libexec/ikev2-sync-vips || :
	return 0
}

run_action() {
	id="$1"
	kind="$2"
	shift 2
	exec >>/tmp/ikev2-manager-action.log 2>&1
	printf '\n=== %s action=%s id=%s ===\n' "$(date)" "$kind" "$id"
	action_status "$id" running 'Waiting for other router actions...'
	if ! acquire_action_lock manager "$id"; then
		action_status "$id" error 'Timed out waiting for another router action.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM

	case "$kind" in
		apply)
			action_status "$id" running 'Applying firewall, PBR and strongSwan...'
			if apply_action; then
				action_status "$id" ok 'Configuration applied.'
			else
				action_status "$id" error 'Apply failed; see /tmp/ikev2-manager-action.log and logread.'
			fi
			;;
		connect)
			action_status "$id" running 'Reconnecting the outbound tunnel...'
			rm -f "$connect_failure_file"
			if connect_action; then
				action_status "$id" ok 'Outbound tunnel reconnected.'
			else
				connect_reason="$(sed -n '1p' "$connect_failure_file" 2>/dev/null || true)"
				rm -f "$connect_failure_file"
				if [ -n "$connect_reason" ]; then
					action_status "$id" error "Tunnel did not come up: $connect_reason"
				else
					action_status "$id" error 'Tunnel did not come up; see /tmp/ikev2-manager-action.log and logread.'
				fi
			fi
			;;
		client-connect)
			action_status "$id" running 'Loading settings and reconnecting the outbound tunnel...'
			rm -f "$connect_failure_file"
			if swanctl_quiet --load-conns >/dev/null &&
			   swanctl_quiet --load-creds >/dev/null &&
			   connect_action; then
				action_status "$id" ok 'Settings saved and tunnel connected.'
			else
				connect_reason="$(sed -n '1p' "$connect_failure_file" 2>/dev/null || true)"
				rm -f "$connect_failure_file"
				if [ -n "$connect_reason" ]; then
					action_status "$id" error "Settings were saved, but the tunnel did not come up: $connect_reason"
				else
					action_status "$id" error 'Settings were saved, but the tunnel did not come up; see logread.'
				fi
			fi
			;;
		client-disable)
			action_status "$id" running 'Stopping the outbound tunnel...'
			if disable_client_action; then
				action_status "$id" ok 'Settings saved and tunnel disabled.'
			else
				action_status "$id" error 'Settings were saved, but the tunnel could not be stopped cleanly.'
			fi
			;;
		advanced-set)
			action_status "$id" running 'Validating and loading the custom profile...'
			if ( advanced_set "$1" "$2" ); then
				action_status "$id" ok 'Custom profile loaded.'
			else
				action_status "$id" error 'Custom profile was rejected; previous profile restored.'
			fi
			;;
		advanced-reset)
			action_status "$id" running 'Restoring the generated profile...'
			if ( advanced_reset "$1" ); then
				action_status "$id" ok 'Generated profile restored.'
			else
				action_status "$id" error 'Unable to restore the generated profile.'
			fi
			;;
		*)
			action_status "$id" error 'Unknown background action.'
			;;
	esac
}

case "${1:-}" in
	overview)
		overview
		;;
	widget-status)
		widget_status
		;;
	client-get)
		for key in enabled remote_address remote_id username dpd mtu custom_config; do
			printf '%s=%s\n' "$key" "$(getv client "$key")"
		done
		printf 'reconnect_cooldown=%s\n' \
			"$(getv_default client reconnect_cooldown 15)"
		printf 'tunnel_dns_provider=%s\n' \
			"$(getv_default client tunnel_dns_provider cloudflare)"
		printf 'tunnel_dns_upstream=%s\n' \
			"$(getv_default client tunnel_dns_upstream 'https://cloudflare-dns.com/dns-query')"
		printf 'tunnel_dns_bootstrap=%s\n' \
			"$(getv_default client tunnel_dns_bootstrap '1.1.1.1:53 1.0.0.1:53')"
		state_configured="$(sed -n 's/^configured=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
		configured="$(getv_default client tunnel_dns_upstream 'https://cloudflare-dns.com/dns-query')"
		active=''
		[ "$state_configured" != "$configured" ] ||
			active="$(sed -n 's/^selected=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
		[ -n "$active" ] || { set -- $configured; active="${1:-}"; }
		printf 'tunnel_dns_active=%s\n' "$active"
		printf 'tunnel_dns_failures=%s\n' \
			"$(sed -n 's/^failures=//p' "$tunnel_dns_state" 2>/dev/null | tail -n1)"
		if [ -d "$root/sys/class/net/ipsec-out" ]; then
			printf 'interface_present=1\n'
		else
			printf 'interface_present=0\n'
		fi
		printf 'interface_bytes_in=%s\n' "$(interface_counter ipsec-out rx_bytes)"
		printf 'interface_bytes_out=%s\n' "$(interface_counter ipsec-out tx_bytes)"
		;;
	client-input)
		[ -n "$client_input_file" ] || client_input_file="$(input_file_for client "${2:-}")"
		consume_client_input
		;;
	client-material-import)
		[ "$#" -eq 3 ] || die 'Expected: cert|key input-token'
		import_client_material "$2" "$3"
		;;
	reconnect-client)
		[ "$(getv globals configured)" = 1 ] || die 'Complete and enable Overview first'
		[ "$(getv client enabled)" = 1 ] || die 'Outbound client is disabled'
		start_action connect
		;;
	ensure-client)
		ensure_client_action
		;;
	advanced-start)
		[ "$#" -eq 3 ] || die 'Expected: profile input-token'
		profile_values "$2"
		profile_input="$(input_file_for profile "$3")"
		[ -f "$profile_input" ] && [ ! -L "$profile_input" ] ||
			die 'Custom configuration input is missing'
		cleanup_profile_input=1
		trap '[ "$cleanup_profile_input" = 0 ] || rm -f "$profile_input"' EXIT INT TERM HUP
		start_action advanced-set "$2" "$profile_input"
		cleanup_profile_input=0
		trap - EXIT INT TERM HUP
		;;
	advanced-reset-start)
		[ "$#" -eq 2 ] || die 'Expected: profile'
		start_action advanced-reset "$2"
		;;
	_action-run)
		shift
		run_action "$@"
		;;
	action-status)
		if [ -n "${2:-}" ]; then
			cat "$action_status_dir/$2.status" 2>/dev/null || printf 'state=idle\n'
		else
			cat "$action_status_file" 2>/dev/null || printf 'state=idle\n'
		fi
		;;
	reload)
		apply_all
		;;
	advanced-mode)
		profile_values "${2:-}"
		getv_default "$profile_section" custom_config 0
		;;
	advanced-read)
		advanced_read "${2:-}"
		;;
	*)
		die 'Usage: ikev2-manager {overview|widget-status|client-get|client-input|client-material-import|reconnect-client|ensure-client|action-status|advanced-mode|advanced-read|advanced-start|advanced-reset-start|reload}'
		;;
esac
