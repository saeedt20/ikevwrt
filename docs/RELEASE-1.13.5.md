# IkevWrt 1.13.5

This release packages the client-only runtime, Iran-direct correction and LuCI
redesign developed and smoke-tested in local v1.13.4 builds.

## Changes since 1.13.3

- Removed the inbound IKEv2 server, VPN Users, ACME integration and exported
  phone/Windows profiles. Outbound credentials and personal policies are kept.
- Bundled 57,559 Iranian domain suffixes from the attributed Iran-v2ray-rules
  snapshot. Iran-direct is enabled by default; no GeoIP ranges are bundled.
- Fixed Iran-direct priority for full-route devices, including persistence after
  PBR restarts. Ordinary full-route traffic continues through the VPN.
- Restricted Tunnel DNS to Cloudflare DoH and its two bootstrap resolvers.
- Reorganized Status and Outbound Tunnel, fixed authentication-field visibility,
  improved live status and added collapsible DNS groups.
- Hid Services and List sources panels while preserving their backend features,
  saved selections, metadata and background updates.

## Upgrade behavior

The upgrade retires the inbound server. Its old configuration and secrets are
archived privately on the router at
`/etc/ikev2-manager/legacy-inbound-backup.tar.gz`, mode 600. Never share it.
An applied Site Link exit retains its shared certificate.

The migration enables Iran-direct and selects Cloudflare for Tunnel DNS.
Routing/DNS may pause briefly while the active policy is reconciled. Keep a
configuration backup and install the named APK rather than running a general
package upgrade.

## Compatibility and checks

Only Redmi AX6S has been tested. The APK is built with the verified official
OpenWrt 25.12.6 SDK for `mediatek/mt7622`, `aarch64_cortex-a53`. It is unsigned.
Other targets, firmware builds and IPK installations are unverified.

Local CI covers migration failure/retry, credential preservation, rollback,
policy priority, UI behavior and deterministic IPK packaging. The full bundled
DNS configuration was checked with the official sing-box validator.

The same runtime/UI passed live AX6S/OpenWrt 25.12.6 checks in development
builds: VPN HTTPS, tunnel DoH, Iran/WAN routing, firewall validation, fail-closed
routes and service health. The new version/SDK packaging has not been installed
on hardware. Full reboot recovery and sustained load remain untested.

The proposed source, APK payload/metadata and screenshots are checked for
secrets and private session identifiers before publication. See
[privacy checks](PRIVACY.md) and the [UI previews](UI-REDESIGN.md).
