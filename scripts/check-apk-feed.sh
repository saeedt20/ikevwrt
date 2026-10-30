#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Nikitid

set -eu

fail() {
	printf 'check-apk-feed: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
release_workflow="$root/.github/workflows/release.yml"

# Release assets are signed directly; no external package feed is involved.
. "$root/apk-feed.env"
openssl pkey -pubin -in "$root/$OPENWRT_APK_KEY_FILE" -noout >/dev/null 2>&1 ||
	fail 'invalid public signing key'
actual_hash="$(sha256sum "$root/$OPENWRT_APK_KEY_FILE" | awk '{ print $1 }')"
[ "$actual_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail 'public signing key checksum mismatch'
grep -Fq './scripts/build-apk.sh' "$release_workflow" ||
	fail 'release workflow does not build the APK'
grep -Fq 'dist/apk/*' "$release_workflow" ||
	fail 'release workflow does not publish the APK asset'
grep -Fq 'secrets.IKEVWRT_APK_SIGNING_KEY' "$release_workflow" ||
	fail 'release workflow must use the dedicated signing secret'
grep -Fq 'test -n "$SIGNING_KEY_PEM"' "$release_workflow" ||
	fail 'release workflow must reject a missing signing secret'
grep -Fq 'OPENWRT_APK_SIGNING_KEY="$RUNNER_TEMP/ikevwrt-signing.pem"' "$release_workflow" ||
	fail 'release workflow must pass the signing key to the builder'
grep -Fq 'cp keys/ikevwrt-release.pem dist/apk/' "$release_workflow" ||
	fail 'release workflow must publish the public verification key'
if grep -Fq 'openwrt-feed' "$release_workflow"; then
	fail 'release workflow must not publish through an external APK feed'
fi

printf 'check-apk-feed OK\n'
