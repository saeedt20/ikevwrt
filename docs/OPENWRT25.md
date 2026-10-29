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

- OpenWrt `25.12.5`;
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
./scripts/build-apk-target.sh 25.12.5 mediatek/mt7622

# ARMv8 Cortex-A53 preset (MediaTek Filogic)
sh ./scripts/build-apk-aarch64-cortex-a53.sh 25.12.5
```

Use `ubus call system board` and `/etc/openwrt_release` on the target router;
do not choose an SDK solely by CPU family. A successful build is only the first
step: complete the release-validation checklist below before publishing it.

## Unsigned Release APKs

Release APKs are intentionally unsigned. Download the exact target-matched
APK and its SHA-256 checksum from the GitHub Release, copy it to the router,
and install it explicitly:

```sh
apk add --allow-untrusted /tmp/luci-app-ikev2-manager-1.13.3.apk
```

No signing key, package feed or system-wide `apk upgrade` is required. To
update, verify the next release checksum and repeat the same command with its
APK. `--allow-untrusted` means the checksum verification is the operator's
responsibility.

## Release validation

For every OpenWrt release update or additional target:

1. obtain the exact official SDK and verify its SHA-256 checksum;
2. build the APK and confirm target architecture and package metadata;
3. on the router, simulate the dependency plan and install only the package;
4. run `preflight`, dependency installation and `doctor`;
5. test outbound connection, DNS apply/rollback, managed enable/disable and
   PBR rebuild;
6. reboot once, run `doctor`, and repeat the outbound smoke test.
