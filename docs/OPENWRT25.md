# OpenWrt 25.12 and APK

The same source tree produces the two supported package formats:

- OpenWrt `24.10.x`: architecture-independent IPK, installed with `opkg`;
- OpenWrt `25.12.x`: target-specific APK, installed with apk-tools 3.

## Compatibility boundary

The application accepts only official release builds with firewall4, IPv4 WAN
and matching official package feeds. Vendor firmware, snapshots, firewall3 and
a mismatched package manager fail before dependency installation.

The LuCI and shell source itself is portable, but the runtime installs kernel
modules and other target-specific dependencies. Every OpenWrt target needs its own exact SDK build and
real-router validation. Never install an APK built for one target on another.

The default build target is Xiaomi Redmi Router AX6S:

- OpenWrt `25.12.6`;
- `mediatek/mt7622`;
- `aarch64_cortex-a53` (ARMv8);
- Xiaomi Redmi Router AX6S running official OpenWrt.

This profile matches the inspected router's release, board and package
architecture. The APK is built with the checksum-verified official SDK.
Installation, VPN/DNS changes and reboot testing on the router remain required
before claiming full runtime validation. See [the audit report](AUDIT-FIXES.md).

An optional manual build preset exists for this ARMv8 candidate:

- `mediatek/filogic`;
- `aarch64_cortex-a53`;
- OpenWrt `25.12.x`.

It is a target-matched package for common Filogic routers, not a universal
package for every ARMv8 router. It remains unverified until it passes the
router validation checklist below.

## Building another target

To produce an APK for another official OpenWrt 25.12 target, run the manual **Build target APK**
workflow and supply the exact `release` and `target/subtarget` reported by the
router. The workflow downloads the official target checksum index, selects and
verifies the matching SDK, reads `CONFIG_TARGET_ARCH_PACKAGES` from that SDK,
then uploads a separate APK artifact. It does not publish that artifact as a
public release or claim compatibility.

The same operation is available to a maintainer on a Linux build host:

```sh
./scripts/build-apk-target.sh 25.12.6 mediatek/mt7622

# ARMv8 Cortex-A53 preset (MediaTek Filogic)
sh ./scripts/build-apk-aarch64-cortex-a53.sh 25.12.6
```

Use `ubus call system board` and `/etc/openwrt_release` on the target router;
do not choose an SDK solely by CPU family. A successful build is only the first
step: complete the release-validation checklist below before publishing it.

## Signed Release APKs

Release APKs use the dedicated IkevWrt P-256 signing key. Add its public key
once on each router before installing through LuCI. The private signing key
never belongs on the router or in a release asset.

Download `ikevwrt-release.pem` from the release and copy it to `/tmp` on the
router. Compare its fingerprint with this record before trusting it:

```sh
echo '67d9a98b2527c24269ed688183af18ae2fb8f560292a237822d0cd69e53d24c3  /tmp/ikevwrt-release.pem' | sha256sum -c -
```

Only if that reports `OK`, install the public key:

```sh
mkdir -p /etc/apk/keys
cp /tmp/ikevwrt-release.pem /etc/apk/keys/ikevwrt-release.pem
chmod 644 /etc/apk/keys/ikevwrt-release.pem
grep -qxF /etc/apk/keys/ikevwrt-release.pem /etc/sysupgrade.conf ||
  printf '\n/etc/apk/keys/ikevwrt-release.pem\n' >> /etc/sysupgrade.conf
```

For each update, download the target-matched APK and use **System → Software →
Upload Package… → Install**. LuCI still asks for confirmation for an uploaded
file; APK then verifies the trusted signature. Alternatively:

```sh
apk add /tmp/luci-app-ikev2-manager-1.13.5.apk
```

No package feed or system-wide `apk upgrade` is needed. Factory resets and
firmware installations without preserved settings require key setup again.
Trusting this key authorizes packages signed by its holder; APK does not scope
a trusted key to one package name. Keep the signing secret protected.

The v1.13.5 release asset was replaced with its signed equivalent. Package
files and scripts are unchanged; the APK checksum changed. Download it again
if you kept the earlier unsigned file. Older unsigned releases still require
`--allow-untrusted`. Manual target-build artifacts remain unsigned unless the
maintainer supplies `OPENWRT_APK_SIGNING_KEY`.

Maintainer release builds read the encrypted `IKEVWRT_APK_SIGNING_KEY` GitHub
Actions secret, write a temporary owner-only key file, and remove it afterward.
A missing secret or mismatched public key stops the release build. Local builds
can pass the private-key path as `OPENWRT_APK_SIGNING_KEY`; never commit it.

## Release validation

For every OpenWrt release update or additional target:

1. obtain the exact official SDK and verify its SHA-256 checksum;
2. build the APK and confirm target architecture and package metadata;
3. on the router, simulate the dependency plan and install only the package;
4. run `preflight`, dependency installation and `doctor`;
5. test outbound connection, DNS apply/rollback, managed enable/disable and
   PBR rebuild;
6. reboot once, run `doctor`, and repeat the outbound smoke test.
