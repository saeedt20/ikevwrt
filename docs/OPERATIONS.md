# Operations

## CLI installation and upgrade

The preferred installation path is LuCI package upload. For CLI installation
with dependency preparation:

```sh
scp -O dist/luci-app-ikev2-manager_*_all.ipk root@router:/tmp/
scp -O scripts/install.sh root@router:/tmp/
ssh root@router
chmod +x /tmp/install.sh
/tmp/install.sh /tmp/luci-app-ikev2-manager_*_all.ipk
```

Upgrade an existing public package with:

```sh
opkg install /tmp/luci-app-ikev2-manager_*_all.ipk
```

Outbound credentials, custom destinations and cached service lists are
preserved. Version 1.13.5 archives and removes the retired inbound settings;
see [the migration notes](V1.13.4-REVIEW.md).

### OpenWrt 25.12 unsigned APK

Download the APK matching the router's exact OpenWrt release, target and
architecture from the GitHub Release, verify its published SHA-256 checksum,
then install it explicitly:

```sh
apk add --allow-untrusted /tmp/luci-app-ikev2-manager-*.apk
```

The project deliberately does not publish an APK signing key or an APK feed.
`--allow-untrusted` is therefore required. The command changes only the named
package and its dependencies; do not run a bare `apk upgrade` on a production
router. Repeat the same file-install command with a newly downloaded release
APK to update it.

### Controlled runtime updates

Dependency installation fills missing packages; it deliberately does not
upgrade an already installed runtime. Review runtime updates separately and
test them on a non-office router before promotion. Do not use a bare
`apk upgrade` as part of application maintenance.

On apk firmware, dependency repair pins any missing strongSwan component to the
already installed strongSwan version and refuses a mixed cohort before changing
the package database. opkg cannot express that exact constraint reliably, so an
incomplete pre-existing strongSwan cohort on 24.10 is not repaired
automatically. A missing same-version component is therefore an explicit repair
failure, not permission to advance part of the runtime.

strongSwan is not one independently replaceable binary in OpenWrt. The base
package, `strongswan-charon`, `strongswan-swanctl` and every installed
`strongswan-mod-*` package share one build and must come from the same SDK,
target and version. The OpenWrt 25.12 packages branch currently carries 6.0.3,
while the development packages branch carries 6.0.7. A security backport must
therefore publish and simulate the complete installed strongSwan subset as one
transaction. Installing only `strongswan` can leave charon or its plugins on a
different ABI and is unsupported.

The promotion sequence is: build the matched package subset with the exact
release SDK, verify every package version and signature, simulate the named
transaction, snapshot configuration, install on the test router, restart only
strongSwan, and exercise outbound and any separately installed Site Link SAs. Promote the same
artifacts to other routers only after a soak period. Kernel packages are never
mixed across firmware builds.

### Fast repeat APK builds

For a persistent build machine, prepare the SDK once with its normal
`make defconfig` and prerequisite stages. Subsequent package-only builds can
reuse that state:

```sh
OPENWRT_SDK_DIR=/path/to/openwrt-sdk \
OPENWRT_SDK_PREPARED=1 \
./scripts/build-apk.sh
```

This mode validates the SDK configuration and target prerequisite stamp, then
cleans and compiles only `luci-app-ikev2-manager`. Omit
`OPENWRT_SDK_PREPARED` for clean release or CI builds that must run the full SDK
preparation path. Prepared mode checks the exact mediatek/filogic target values
rather than timestamps because registering a feed can touch `.config` without
changing the already-prepared target toolchain. The optional
`OPENWRT_APK_SIGNING_KEY` is accepted only for private builds that need a
signature; public releases are intentionally unsigned.

## Diagnostics

```sh
/usr/libexec/ikev2-manager-system doctor
/usr/libexec/ikev2-manager overview
/usr/libexec/ikev2-manager-system failclosed-check
/usr/libexec/ikev2-domain-router status
/etc/init.d/pbr status
swanctl --list-sas
```

Healthy outbound routing has:

- an installed `proxy4` CHILD_SA;
- the assigned virtual IPv4 on `ipsec-out`;
- a tunnel default and unreachable fallback in `pbr_ikev2out`;
- PBR, FakeIP and health services running.

The health watcher performs a small data-plane probe through `ipsec-out`.
Probe failures are telemetry only: public check endpoints can fail independently
and never tear down an installed CHILD_SA. Missing SAs are recovered through
the serialized, rate-limited `ensure-client` action; its reconnect cooldown is
configurable under the outbound tunnel settings.

Tunnel DNS uses only `https://cloudflare-dns.com/dns-query` with bootstrap
resolvers `1.1.1.1:53` and `1.0.0.1:53`. The health watcher probes actual DNS
queries through `ipsec-out`. It can switch between these two Cloudflare
bootstrap addresses after a successful probe; it never chooses another
provider or a WAN fallback for selected destinations.

If strongSwan starts before WAN source-address selection is ready, the watcher
discards only a `proxy-out` IKE_SA that is still `CONNECTING` from a loopback
address and retries after gateway DNS is available. A handshake already using
a real local address is left alone. During shutdown the watcher stops before
the DNS, domain-router, XFRM and network services, with a five-second procd
termination bound, so it cannot recreate dependencies while the router stops.

## Destination updates

```sh
/usr/libexec/ikev2-domains-community apply
/usr/libexec/ikev2-domain-router status
```

Selected services, custom domains and custom IPv4/CIDR entries are rebuilt
atomically. In Reliable mode, a domain-only change hot-reloads the local
sing-box rule-set without restarting DNS or rebuilding PBR. Changes to service
networks or shared interfaces still reload PBR. Per-device overrides use the
independent early nftables table and do not reload PBR. Existing
matching conntrack sessions are removed after a successful update so they
cannot retain an older WAN route.

Prepared services are edited from **Manage services**. This stores a complete
local override; **Restore prepared service** removes only that override after
confirmation. **Add service** creates a separately named domain/CIDR list, so
large definitions do not accumulate in the common custom-domain field. The
editor changes definitions only. Service chips stage policy selection and the
page-level **Save** applies that selection. Definitions live in
`/etc/ikev2-manager/services.d/` and are included in sysupgrade preservation.

Clients must use router DNS for domain routing. Custom IPv4/CIDR entries and
direct-service networks do not depend on DNS.

Managed DNS keeps one cache owner: dnsmasq in Standard mode or sing-box in
Reliable mode. The main and per-segment dnsproxy processes do not use
optimistic caches. In Reliable mode sing-box connects directly to each segment
worker; Standard mode lets dnsmasq select the same worker directly. Enabled
destination segments are probed once per minute at both the worker listener and
the complete client-facing path;

**Use WAN-provided DNS** adds the IPv4 resolvers currently published by netifd
for the configured WAN as dnsproxy fallbacks. It is deliberately off by
default because fallback queries are unencrypted. Lease changes update only
the resolver workers and retain the previous validated group while WAN DNS is
temporarily absent. This fallback is not available to tunnel-selected domains.

Applying a resolver now fails if the fallback group cannot answer. The check
runs the configured fallback endpoints by themselves and requires one
successful query, because the ordinary health query is served by the primary
group and therefore proves nothing about the recovery path. When an apply is
rejected for this reason, the previous configuration is untouched: correct the
fallback endpoints, or empty the group if no recovery path is wanted, and apply
again. `dns-get` reports `fallback_verified` with the time of the last
successful proof, and `timeout_effective` beside the stored `timeout`, which is
bounded by sing-box's own deadline and is commonly lower than the stored value.

Both resolver groups accept mixed transports. Filtering is applied per protocol
per provider, so a primary group combining, for example, DoH and DoQ to
different providers keeps resolving where a single-protocol group stops. A
bootstrap entry may also be a DoH, DoT or DoQ endpoint whose authority is a
literal IPv4 address, which removes the ladder's dependence on plaintext
UDP/53.

Ordinary names are resolved over WAN, where per-protocol DNS filtering is
applied. To send them through the tunnel-bound resolver instead:

```sh
/usr/libexec/ikev2-domain-router tunnel-resolve 1
```

The same switch is on the outbound tunnel page, under Tunnel DNS.

This is deliberately not a default. It removes the WAN exposure but couples
every lookup to tunnel health: while the tunnel is down, no name resolves at
all, for every client. The command refuses to engage without an enabled
outbound client, validates the refreshed runtime and restores the previous
setting when it cannot resolve. `dns-get` reports the current value as
`tunnel_resolve`.

The resolver timeout bounds each group separately, so the worst case is twice
its value. Measured on a working router, a DoH query costs about 0.12 s warm and
a cold end-to-end lookup about 1 s, so `2s` leaves ample headroom while halving
the worst-case failover from eight seconds to four. dnsproxy keeps no sticky
failure state: it tries the primary group on every query and uses the fallback
only for the query that failed, so no return timer is needed.

A destination segment with an empty fallback field inherits the global fallback
group and then the global primary group. The segment editor shows that
effective list, because an empty field is the widest inheritance rather than
none - with **Use WAN-provided DNS** enabled it includes the provider's
plaintext resolver. Set an explicit segment fallback to stop inheriting.

inspect their state without changing configuration with:

```sh
/usr/libexec/ikev2-manager-system dns-segments-check
/usr/libexec/ikev2-manager-system dns-get
/usr/libexec/ikev2-manager-system dns-buffer-status
```

`dns-buffer-status` is read-only. It reports the total malformed UDP/53
counter, one expiring counter per source IPv4 address and the number of current
`dns: buffer size too small` messages in the system-log ring. If both counts
grow together, a listed client is sending datagrams too short to contain a DNS
header. If only the sing-box count grows, inspect local/TCP/alternate DNS paths;
the client guard is not the source. The diagnostic stores neither payloads nor
queried domain names.

Ordinary DoH is the default because TCP/443 remains usable on more access
networks. DoQ is standardized by [RFC 9250](https://www.rfc-editor.org/rfc/rfc9250)
and forced HTTP/3 is available for providers that document it, but both depend
on outbound UDP and are advanced choices rather than automatic upgrades. The
provider presets use published Cloudflare, Google, AdGuard, Control D, Mullvad,
Quad9 and Yandex endpoints. DDR/DNR are client resolver-discovery mechanisms,
not another upstream transport, and ODoH is not exposed because the packaged
dnsproxy runtime does not implement it.

`segment_health=degraded` names failed segment identifiers in
`segment_failures`. The status file `/var/run/ikev2-dns-segments.status`
separates `direct_failure_ids` from `path_failure_ids`. A package upgrade
re-applies an already-managed resolver only when the packaged runtime schema
changes. LuCI-only releases therefore do not interrupt DNS. A schema migration
uses the same transactional path, so a failed cutover restores the previous
runtime.

OpenWrt 25.12 currently ships sing-box 1.13.18. Reliable mode should use
1.13.19 or later because 1.13.19 fixes the upstream asynchronous FakeIP
metadata-save race. Build the unmodified upstream update with the same exact
SDK and publisher key used for the application:

```sh
OPENWRT_SDK_DIR=/path/to/openwrt-sdk \
OPENWRT_APK_SIGNING_KEY=/path/to/release-private.pem \
./scripts/build-sing-box-update.sh
```

The builder verifies a pinned official OpenWrt 1.13.x recipe and the upstream
source archive hash, then produces `sing-box-1.13.19-r2.apk` under
`dist/compat`. Without `OPENWRT_APK_SIGNING_KEY` it deliberately produces an
unsigned developer artifact for local testing; feed artifacts must be signed.
When the SDK has no Go host compiler, the builder downloads
the pinned official Go 1.24.13 bootstrap archive and verifies its SHA-256 before
use; `OPENWRT_GO_BOOTSTRAP_DIR` may point to the same exact toolchain locally.

For the selected Discord service, literal UDP voice endpoints are learned from
Discord's IP-discovery packet and routed as exact IPv4-address/port pairs. The
runtime set is rebuilt automatically after a policy or firewall restart:

```sh
/usr/libexec/ikev2-discord-voice status
nft list set inet ikev2_discord_voice voice_endpoints
```

Full route and Exclude rules are applied atomically and can be checked without
restarting PBR:

```sh
/usr/libexec/ikev2-device-routing check
nft list table inet ikev2_device_policy
```

The LuCI picker lists active local IPv4 neighbours and enriches them with DHCP
names. Use Custom for a sleeping client, a static address or a subnet.

### Bundled Iran domains

The Iran-direct toggle is enabled by default. Its 57,559 suffixes are packaged
from [Iran-v2ray-rules](../luci-ikev2-domains/iran/SOURCE.md), with no GeoIP
ranges and no runtime Iran-list downloads. Personal additions remain separate.
Enabling the toggle merges them with the snapshot. This WAN policy has priority
over VPN destinations. Iran-direct uses DNS-populated WAN address sets in both engines; sites sharing
those IPs may also bypass the VPN. Its WAN destination rule takes priority
over device full-route marks.

### Scheduled list refresh

Selected service lists refresh from their sources after every boot and then
once a day, at a fixed per-router offset within the hour. The health watcher
checks every fifteen minutes whether a refresh is due and queues it detached.
Nothing is refreshed while routing is paused or when no service is selected, a
failed attempt is retried after an hour, and routing restarts only when a list
actually changed.

Each downloaded revision is recorded beside its cache in
`/etc/pbr-ikev2-community-cache` as `<service>.lst.meta` or
`<service>.cidrs.meta`: source URL, fetch time, entry count, SHA-256, and the
date and size of the last real change. A failed download writes `.error` beside
it and the last validated revision stays in use. The Services and List sources panels are hidden in the interface.
Their saved selections, metadata and background refresh remain available
through the helpers below.

```sh
/usr/libexec/ikev2-domains-community sources
/usr/libexec/ikev2-domains-community refresh-schedule force
cat /etc/pbr-ikev2-community-cache/refresh.state
```

`sources` is read-only. `refresh-schedule force` starts a detached refresh that
ignores cache freshness and prints its `action_id`.

## Status Overview widget

The package installs `06_ikev2-manager-v2.js` before the standard system widgets.
Its two summary cards cover the outbound tunnel and policy routing, including
fail-closed state, policy counts and excluded devices. Outbound RX/TX counters
come from `ipsec-out` and survive CHILD_SA rekeys; recreating the interface
resets them. There are no inbound-user rows in v1.13.4.

## Background actions

Long LuCI operations continue in serialized workers:

```sh
/usr/libexec/ikev2-manager action-status
/usr/libexec/ikev2-manager-system action-status
/usr/libexec/ikev2-manager-system deps-status
```

Logs:

```text
/tmp/ikev2-manager-action.log
/tmp/ikev2-system-action.log
/tmp/ikev2-domains-community.log
/tmp/ikev2-domains-pbr-restart.log
```

Each worker publishes an action ID, state, update time and current phase. The
terminal states are `ok` and `error`. LuCI polls the worker and refreshes the
affected counters, lists and runtime state without a page reload.

Router-changing actions share one lock. A competing action is rejected after a
short wait instead of remaining queued behind an unknown operation. A browser
timeout does not cancel an already running router-side worker. Periodic health
work yields to this lock; a domain-router operation already in flight is given
a bounded interval to finish before the foreground transaction reports a real
lock conflict.

Observed times on the validated `mediatek/filogic` router are approximately
1 second for an unchanged managed setup, 2 seconds for an unchanged policy,
5-7 seconds for Reliable-mode or managed-mode disable, 12 seconds for a policy
restart or full dependency reset, 17-27 seconds for a full managed enable and
31 seconds for dependency installation with current package indexes. Feed
refreshes, downloads and ACME issuance can take longer. Treat an unchanged
phase for more than two minutes as a fault and inspect the status, logs and
process state before retrying the action.

Policy-list rebuild phases are preparation, optional service-list download,
combined-list generation and PBR restart. The PBR restart is normally the
longest phase and can take tens of seconds. Saving an unchanged managed setup
or unchanged policy list returns after a live health check instead of restarting
PBR; a failed health check automatically falls back to the full apply path.

## UPnP

The dependency doctor checks for conflicting mappings on IKEv2 UDP ports 500
and 4500. Reserve ports required by the outbound VPN client and adjacent
services when configuring UPnP.

## Backup and recovery

```sh
sysupgrade -b /tmp/ikev2-manager-backup.tar.gz
gzip -t /tmp/ikev2-manager-backup.tar.gz
```

Backups contain reversible VPN credentials and private keys. Store them as
secrets and never attach them to public issues.

Recovery sequence:

1. disable managed mode in Overview;
2. confirm ordinary WAN access;
3. run the dependency doctor;
4. re-enable managed mode and the outbound client;
5. verify one selected and one ordinary destination.

## Dependency reset and package removal

The Overview action that removes runtime dependencies is a full application
reset. It first restores the DNS/DHCP state captured before dependency
installation, disables managed routing, then asks the package manager to remove
only packages recorded as application-owned. Packages that another installed
application still requires are retained and reported as shared.

After a successful package transaction, the reset restores the packaged
default configuration and removes submitted client secrets,
generated strongSwan profiles, copied certificate material, generated policy
lists and caches. If an applied Site Link exit role still consumes the inbound
certificate, its certificate, private key, chain and ACME renewal section are
retained. An applied Site Link source likewise retains the nftset-capable DNS
provider and global PBR contract. External certificate source files and
unrelated ACME accounts are never deleted because ownership cannot be proven
safely.

Original DNS restoration is validated before any package is removed. A legacy
snapshot containing the application FakeIP resolver `127.0.0.42` is repaired
only from the domain router's saved upstream or from the saved configuration of
a dnsproxy service that was already running before management began. If neither
source is available, the reset stops and keeps the working managed DNS state.

XFRM interfaces are brought down after live PBR, firewall and strongSwan
references are removed. They are not forcibly deleted during a live cleanup:
on affected OpenWrt 25 kernels, `ip link del` can block in kernel D-state. A
down interface has no forwarding path and disappears when its package/module
is unloaded or at the next reboot.

Removing the package disables managed mode first and removes generated runtime
state, including rendered strongSwan profiles and copied certificate material.
Package-owned files are removed by the active package manager. User
configuration, credentials, source certificates, custom destination lists,
cached service lists and sysupgrade backups are preserved. This is intentionally
different from the full dependency-reset action. If managed mode is still
enabled and cleanup cannot run, package removal stops before files are changed.

OpenWrt 24.10:

```sh
opkg remove luci-app-ikev2-manager
```

OpenWrt 25.12:

```sh
apk del luci-app-ikev2-manager
```
