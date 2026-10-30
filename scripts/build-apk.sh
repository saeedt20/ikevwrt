#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid

set -eu

fail() {
	printf 'build-apk: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/release.env"
. "$root/apk-feed.env"

# A normal release uses the checked-in Redmi AX6S profile. The target builder
# deliberately overrides these values after sourcing that profile so a second
# target never needs a source fork or a hand-edited Makefile.
OPENWRT_APK_VERSION="${OPENWRT_APK_VERSION_OVERRIDE:-$OPENWRT_APK_VERSION}"
OPENWRT_APK_TARGET="${OPENWRT_APK_TARGET_OVERRIDE:-$OPENWRT_APK_TARGET}"
OPENWRT_APK_ARCH="${OPENWRT_APK_ARCH_OVERRIDE:-$OPENWRT_APK_ARCH}"
OPENWRT_APK_SDK_ARCHIVE="${OPENWRT_APK_SDK_ARCHIVE_OVERRIDE:-$OPENWRT_APK_SDK_ARCHIVE}"
OPENWRT_APK_SDK_SHA256="${OPENWRT_APK_SDK_SHA256_OVERRIDE:-$OPENWRT_APK_SDK_SHA256}"

sdk="${OPENWRT_SDK_DIR:-}"
signing_key="${OPENWRT_APK_SIGNING_KEY:-}"
public_key="$root/$OPENWRT_APK_KEY_FILE"

[ -n "$sdk" ] || fail 'OPENWRT_SDK_DIR is required'
[ -d "$sdk" ] || fail "SDK directory not found: $sdk"
if [ -n "$signing_key" ]; then
	[ -r "$signing_key" ] || fail "signing key not readable: $signing_key"
	[ -r "$public_key" ] || fail "public key not found: $public_key"
fi

case "$(basename "$sdk")" in
	"${OPENWRT_APK_SDK_ARCHIVE%.tar.zst}") ;;
	*) fail "unexpected SDK directory: $(basename "$sdk")" ;;
esac

for command in make openssl python3 rsync sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

if [ -n "$signing_key" ]; then
	actual_key_hash="$(sha256sum "$public_key" | awk '{ print $1 }')"
	[ "$actual_key_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
		fail "public key checksum mismatch: $actual_key_hash"
fi

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

if [ -n "$signing_key" ]; then
	openssl ec -in "$signing_key" -pubout -out "$tmp/derived-public.pem" >/dev/null 2>&1 ||
		fail 'invalid EC signing key'
	cmp -s "$tmp/derived-public.pem" "$public_key" ||
		fail 'signing key does not match the tracked public release key'
fi

sdk_package="$sdk/package/luci-app-ikev2-manager"
rm -rf "$sdk_package"
mkdir -p "$sdk_package"
rsync -a --delete \
	--exclude .git \
	--exclude docs/private \
	--exclude signing \
	--exclude build \
	--exclude dist \
	--exclude .DS_Store \
	"$root/" "$sdk_package/"

"$root/scripts/check-version-sync.sh"
if [ "${OPENWRT_SDK_PREPARED:-0}" = 1 ]; then
	[ -r "$sdk/.config" ] || fail 'prepared SDK is missing .config'
	set -- "$sdk"/staging_dir/target-*/stamp/.package_prereq
	[ "$#" -eq 1 ] || fail 'prepared SDK must have exactly one target prerequisite stamp'
	package_prereq="$1"
	[ -e "$package_prereq" ] || fail 'prepared SDK is missing the package prerequisite stamp'
	# Feed registration may legitimately touch .config after the SDK target was
	# prepared. Verify the immutable target identity instead of rejecting that
	# cache solely because of timestamps.
	target_family="${OPENWRT_APK_TARGET%%/*}"
	target_subtarget="${OPENWRT_APK_TARGET#*/}"
	grep -Fxq "CONFIG_TARGET_${target_family}=y" "$sdk/.config" &&
		grep -Fxq "CONFIG_TARGET_${target_family}_${target_subtarget}=y" "$sdk/.config" &&
		grep -Fxq "CONFIG_TARGET_ARCH_PACKAGES=\"${OPENWRT_APK_ARCH}\"" "$sdk/.config" ||
		fail "prepared SDK target configuration does not match ${OPENWRT_APK_TARGET}"
	run_make() {
		target="${1##*/}"
		shift
		PATH="$sdk/staging_dir/host/bin:$PATH" make -C "$sdk_package" \
			TOPDIR="$sdk" SDK=1 \
			BUILD_SUBDIR=package/luci-app-ikev2-manager \
			BUILD_VARIANT= ALL_VARIANTS= "$target" "$@"
	}
else
	make -C "$sdk" defconfig
	run_make() {
		make -C "$sdk" "$@"
	}
fi
run_make package/luci-app-ikev2-manager/clean V=s
run_make package/luci-app-ikev2-manager/compile \
	BUILD_KEY_APK_SEC="$signing_key" \
	BUILD_KEY_APK_PUB="$public_key" \
	V=s

apk_tool="$sdk/staging_dir/host/bin/apk"
[ -x "$apk_tool" ] || fail "SDK apk tool not found: $apk_tool"

package_path="$(find "$sdk/bin/packages" -type f \
	-name "${PKG_NAME}-${PKG_VERSION}.apk" -print -quit)"
[ -n "$package_path" ] || fail 'built APK was not found'

if [ -n "$signing_key" ]; then
	"$apk_tool" --allow-untrusted adbsign \
		--sign-key "$signing_key" "$package_path"
	"$apk_tool" --keys-dir "$root/keys" verify "$package_path"
else
	printf '%s\n' 'build-apk: producing an unsigned APK; install it with apk add --allow-untrusted'
fi
"$apk_tool" --keys-dir "$root/keys" adbdump --format json \
	"$package_path" >"$tmp/package.json"
python3 - "$tmp/package.json" >"$tmp/pre-deinstall" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    package = json.load(package_file)
print(package.get("scripts", {}).get("pre-deinstall", ""), end="")
PY
grep -Fq 'PKG_UPGRADE:-0' "$tmp/pre-deinstall" &&
grep -Fq 'upgrade) exit 0' "$tmp/pre-deinstall" &&
grep -Fq 'cleanup helper is missing; package removal stopped before changing files' \
	"$tmp/pre-deinstall" &&
grep -Fq 'unable to restore managed router state; package removal stopped before changing files' \
	"$tmp/pre-deinstall" ||
	fail 'built APK does not contain the guarded removal cleanup'
if grep -Fq '*) exit 0' "$tmp/pre-deinstall"; then
	fail 'built APK pre-deinstall rejects the apk old-version argument'
fi
if grep -Fq '/etc/init.d/rpcd restart' "$tmp/pre-deinstall"; then
	fail 'built APK restarts rpcd during its package transaction'
fi

output="${OPENWRT_APK_OUTPUT_DIR:-$root/dist/apk}"
mkdir -p "$output"
rm -f "$output"/*.apk
cp "$package_path" "$output/$(basename "$package_path")"
(
	cd "$output"
	sha256sum "$(basename "$package_path")" >SHA256SUMS.apk
)

printf 'APK built in %s\n' "$output"
