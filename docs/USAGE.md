# User guide

[![CI](https://github.com/saeedt20/ikevwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/saeedt20/ikevwrt/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)

A LuCI application that connects your OpenWrt router to an IKEv2 server,
and decides which traffic goes through the tunnel. Version 1.13.5 is client-only.
Development builds of this release were smoke-tested on AX6S.

Every setting is stored in UCI, and fresh installations wait for you to enable managed mode.
Upgrading an already managed installation also migrates the active policy.

**Hardware testing: Xiaomi Redmi Router AX6S only**, on OpenWrt 25.12.6 (`mediatek/mt7622`, `aarch64_cortex-a53`). Other targets and IPK builds are unverified.

## Contents

1. [Installation](#1-installation)
2. [Option reference](#2-option-reference)
3. [Uninstalling](#3-uninstalling)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Credits](#credits)

---

## 1. Installation

### Before you start

- Take a **backup** of the router configuration (`System → Backup / Flash Firmware`).
- Make sure you have enough free space: the dependencies (strongSwan, PBR,
  sing-box, `dnsmasq-full`, `dnsproxy`) are sizeable.
- Stay on a stable network while installing, because DNS/DHCP may restart
  briefly during dependency installation.

### Step 1: find out which package your router needs

On the router, over SSH:

```sh
cat /etc/openwrt_release
apk --print-arch 2>/dev/null || opkg print-architecture
```

- If `apk` answers, your router needs an **APK** (OpenWrt 25.12.x).
- If only `opkg` exists, your router needs an **IPK** (OpenWrt 24.10).

The two are not interchangeable. The `version`, `target` and `DISTRIB_ARCH`
fields must match the file you download exactly.

### Step 2a: install on OpenWrt 24.10 (IPK)

IPK builds are unverified and are not included in the AX6S release. Maintainers
can build `luci-app-ikev2-manager_*_all.ipk` locally with
`./scripts/build-ipk.sh` for testing on OpenWrt 24.10.

**From LuCI:**

1. Open `System → Software → Upload Package`.
2. Select and install the IPK.
3. Go to `Services → IKEv2 Manager`.

**Or over SSH:**

```sh
scp -O luci-app-ikev2-manager_*_all.ipk root@ROUTER:/tmp/
scp -O scripts/install.sh root@ROUTER:/tmp/
ssh root@ROUTER
chmod +x /tmp/install.sh
/tmp/install.sh /tmp/luci-app-ikev2-manager_*_all.ipk
```

### Step 2b: install on OpenWrt 25.12 (APK)

Download only the APK built for your router's exact release, target and
architecture. Verify the SHA-256 published beside the release before
installing. Release APKs are deliberately unsigned, so installation needs
`--allow-untrusted`:

```sh
apk add --allow-untrusted /tmp/luci-app-ikev2-manager-*.apk
```

> Do not run `apk upgrade` without a package name; it can change unrelated
> kernel modules on the router.

### Step 3: install the dependencies

Go to `Services → IKEv2 Manager → Overview` and press **Install
dependencies**. The application first checks the release, the feeds, available
storage and package compatibility, then installs.

Do not continue until every check under **Runtime dependencies** is **green**.

### Step 4: enable the application

On the same Overview page:

1. Choose the **WAN network** (the router's real uplink).
2. Choose the **protected networks** (usually `lan`).
3. Turn on **Let the app manage the router** and apply.

### Step 5: enter your account

Open the **Outbound Tunnel** tab and fill in the Connection section:

| Field | Value |
| --- | --- |
| Remote address | IPv4 address or hostname of the IKEv2 server |
| Remote identity | usually the FQDN in the server certificate |
| EAP username | your account username |
| Authentication method | `EAP-MSCHAPv2` for username/password accounts |
| New EAP password | your account password |

Then press **Save & Apply** and **Connect**. The result appears in the status
card on the page and in `Status → Overview`.

> Do not add any domain or device to the VPN policy until the outbound tunnel
> is healthy. Verify one test destination first.

---

## 2. Option reference

### Overview tab

The starting point of every installation. Do not enable the application until
the checks are green.

| Option | What it does | Practical note |
| --- | --- | --- |
| **Install dependencies** | Installs the missing VPN, DNS and PBR packages. | Replacing `dnsmasq-full` may restart DNS/DHCP briefly. |
| **Tunnel routing: Pause/Resume** | Temporarily sends selected destinations out through WAN instead of the VPN, without deleting anything. | While paused there is no fail-closed guarantee. Use it for troubleshooting only. |
| **WAN network** | The router's main internet interface. | Must be the real uplink. It must reach your VPN provider. |
| **Protected networks** | The LAN/VLAN networks the VPN policy applies to. | Never select WAN or an external management network. |
| **Let the app manage the router** | Hands ownership of route, PBR, DNS and firewall to the application. | Turn it off before removing the package or reworking the network. |
| **Device rules** | Lists LAN devices and their exceptions. | Each exception can bypass PBR, DNS interception and DPI separately. |
| **Redirect plain DNS** | Sends port 53 from protected devices to the router's resolver. | Needed for reliable domain routing. |
| **Block DNS-over-TLS** | Blocks outbound port 853 to WAN. | Stops clients bypassing domain classification, but affects some of them. |
| **Reset application** | Prepares the package for removal and reverts the managed state. | Settings and secrets are erased. Back up first. |

**Runtime dependencies** is status only. If strongSwan versions are installed
inconsistently, the application deliberately refuses to mix them; fix the
firmware and official feeds first.

### Outbound Tunnel tab

Connects **your router to a VPN provider**, such as Windscribe. Use the provider’s IKEv2 connection details.

| Option | Behaviour | Recommendation |
| --- | --- | --- |
| **Enable client** | Lets the health watcher restore the tunnel after boot or a WAN drop. | Turn on after one successful manual connection. |
| **Remote address** | IPv4 or hostname of the server. | The hostname must resolve from the router itself. |
| **Remote identity** | The identity expected in the server certificate. | Usually the certificate FQDN, not the IP. |
| **EAP username** / **New EAP password** | Credentials for EAP-MSCHAPv2. | The password is write-only; leaving it blank keeps the stored secret. |
| **Authentication method** | `EAP-MSCHAPv2`, `Certificate (X.509)` or `EAP-TLS`. | Only pick what the server actually offers. |
| **Client certificate / private key path** | For the two certificate-based methods. Enter a path on the router or upload the file from your computer. | Up to 64 KB, PEM format, unencrypted private key. |
| **CA certificate** | Trust root used to verify the server. | Do not disable certificate checking; fix the server chain instead. |
| **DPD, MTU, rekey, reauth** | Liveness timer, packet size and SA renewal. | Keep the recommended values unless there is a clear reason. A smaller MTU helps on constrained links. |
| **Custom strongSwan config** | Replaces the generated profile with raw configuration. | Expert only. The normal form has no runtime effect until you reset to generated. |
| **Connect / Disconnect** | Brings the outbound SA up or down. | Connect validates first and reports the actual cause of a failure. |

**Tunnel DNS** uses only Cloudflare DoH: `https://cloudflare-dns.com/dns-query`,
with bootstrap resolvers `1.1.1.1:53` and `1.0.0.1:53`. These fields are read-only.
Queries and bootstrap traffic bind to the outbound tunnel. An outage never
selects a different provider. Router DNS and destination DNS segments keep their own controls.

**Destination DNS segments** give specific suffixes their own resolver group.
Overlapping suffixes between segments are rejected.

### Policy Routing tab

This tab **does not change the VPN server**. It only decides which
destinations the protected networks reach through the tunnel.

| Section | Description |
| --- | --- |
| **Iranian destinations via WAN** | Enabled by default. Uses 57,559 bundled domain suffixes from Iran-v2ray-rules, without downloading lists. WAN rules precede VPN rules. No IP ranges are bundled; personal additions remain available. |
| **Domain routing engine** | Standard mode classifies a domain by its resolved public IP. Reliable mode uses FakeIP/TProxy and survives address changes. Prefer Reliable for CDN-backed services. |
| **Route router services by domain policy** | In Reliable mode, the router's own requests to selected domains also use the tunnel. Local management addresses stay direct. |
| **Logging** | Errors and Warnings suit day-to-day use. Higher levels fill the router log quickly. Timed capture lasts 60 seconds. |
| **Custom domains** | One suffix per line, such as `example.com`; subdomains are included and service updates never overwrite this list. |
| **Custom IP addresses and networks** | One IPv4 or CIDR per line, such as `203.0.113.0/24`; works without DNS. Avoid very broad networks. |

The Services selector and List sources panel are hidden in this build.
Existing service selections, definitions and background updates remain active;
saving custom destinations preserves those selections.

After saving, check the policy card. If the tunnel is down, selected
destinations are blocked — that is the fail-closed behaviour, not a fault.

The [Iran-v2ray-rules snapshot](../luci-ikev2-domains/iran/SOURCE.md) is included
in the APK and changes with application releases. There is no Update lists
button. Other optional service lists keep their existing refresh schedule.
Domain routing depends on clients using the router’s DNS; direct-IP traffic
cannot always be classified by its domain. Iran-direct classifies by the
resolved IP in both engines, so shared hosting can cause broader bypasses.
Its WAN rules take priority over device full-route rules.

Upgrading from v1.13.3 retires the inbound server and VPN Users. A private
recovery archive stays on the router at
`/etc/ikev2-manager/legacy-inbound-backup.tar.gz` (mode 600). It contains secrets;
do not upload it. Outbound credentials and personal VPN policies are preserved.

## 3. Uninstalling

Follow this order so route, PBR, DNS and firewall are handed back to the
router:

1. On the **Overview** tab, turn **off** "Let the app manage the router" and apply.
2. If you also want settings and secrets erased, press **Reset
   application** (back up first).
3. Remove the package:

```sh
# OpenWrt 25.12
apk del luci-app-ikev2-manager

# OpenWrt 24.10
opkg remove luci-app-ikev2-manager
```

> Skipping step 1 can leave routing and firewall rules behind. If removal
> reports an error, run `doctor` from the Overview page first.

**Upgrading** keeps outbound credentials and personal lists. Version 1.13.5
removes inbound functionality and enables the bundled Iran-direct policy.

---

## Troubleshooting

A healthy outbound tunnel shows a CHILD_SA named `proxy4`, a virtual address on
`ipsec-out`, and PBR and the health service running.

If the tunnel will not come up, check in order: the hostname and remote
identity, the CA certificate, the router's clock, the authentication method,
and the strongSwan log. Then repair the dependencies without changing the
installed versions.

More detail: [Operations and diagnostics](OPERATIONS.md)

## Building from source

The checks require Node.js, Python 3, jq and OpenSSL.

```sh
./scripts/ci-check.sh
```

The IPK is written to `dist/`. Building an APK needs the official SDK for the
exact target; see [OpenWrt 25.12 and APK](OPENWRT25.md).
The default APK profile targets Redmi AX6S on OpenWrt 25.12.6 (`mediatek/mt7622`).

## Documentation

- [Repository map](MAP.md)
- [Operations and diagnostics](OPERATIONS.md)
- [OpenWrt 25.12 and APK compatibility](OPENWRT25.md)
- [Architecture](ARCHITECTURE.md)
- [NOTICE for external lists](../NOTICE)

## Starting IkevWrt

IkevWrt is an independent continuation of [dreamboxone/ikev2-openwrt](https://github.com/dreamboxone/ikev2-openwrt), maintained by [saeedt20](https://github.com/saeedt20). The starting point is commit `048eb13`, version `1.13.2`. Direct routing for Iranian destinations is inherited from that repository. The interface is English-only.

Package names and internal paths retain `luci-app-ikev2-manager` for compatibility. APK feed settings and public keys still belong to upstream. Independent signed distribution requires a project-owned feed and signing key.

## Credits

This project is built on the work of
**[Nikitid](https://github.com/Nikitid)** and the upstream repository
[Nikitid/ikev2-openwrt](https://github.com/Nikitid/ikev2-openwrt). The core
architecture, the strongSwan and PBR integration and the LuCI interface are
their work, and we are sincerely grateful to the original Russian author for
building it and releasing it as open source.

Thanks also to dreamboxone for the additional features inherited by this continuation.

## License

Released under the [MIT License](../LICENSE). The bundled Iranian domains have a GPL-3.0 license; optional lists retain
their own terms. See [NOTICE](../NOTICE).
