# IkevWrt audit and fixes — 1.13.3

What this repo does: IkevWrt adds a LuCI interface and shell services for an
outbound IKEv2 tunnel, an optional inbound VPN server, DNS and policy routing.
The expected load is one OpenWrt router with a few administrators, background
health checks and several open browser tabs. Overlapping requests matter even
at this scale.

The audit started at commit `978d6096a024d5e1420af2a14d1ded41db2f1d80`.
All eight reported findings are addressed in the working tree, alongside the
requested English-only interface and UI performance fixes.

## Must fix

1. **Failed strongSwan commands appeared successful.**
   - What this is: `swanctl_quiet()` loads VPN configuration and credentials.
   - Problem: it captured the status after an `if` statement, losing the failed
     command's exit status. Callers could accept a failed credential reload.
   - Fix: capture the failure in the `else` branch. A forced reload failure now
     reaches rollback, preserving the old user database and secrets.
   - If left unfixed: the UI could report credentials saved while strongSwan
     continued using a different password.

2. **Concurrent user changes could overwrite each other.**
   - What this is: user creation, password changes, policy changes and deletion
     update shared files and reload the VPN service.
   - Problem: overlapping requests used the same temporary names and independent
     rollback snapshots. One failed request could undo another successful one.
   - Fix: reuse the router action lock and configuration lock for user changes.
     Run the transaction in a subshell so its cleanup traps cannot replace lock
     cleanup. A concurrent-request test checks rejection, retry and preservation
     of all accounts.
   - If left unfixed: a saved account or policy could disappear after another
     administrator's request failed.

3. **Failed client saves could leave new certificate files behind.**
   - What this is: certificate authentication installs a client certificate and
     private key before rendering the final VPN configuration.
   - Problem: rollback restored configuration and password files, but omitted
     the installed certificate and key.
   - Fix: include both files in the existing transaction snapshot and restore
     them on failure. A real certificate-pair regression checks restoration
     after a later configuration failure.
   - If left unfixed: the saved settings and installed authentication material
     could belong to different client identities.

4. **A background Iranian-list update could leave a permanent lock.**
   - What this is: the routing page starts background destination-list updates.
   - Problem: the update function replaced the worker's cleanup trap. Later
     updates then appeared permanently busy.
   - Fix: run the update in a subshell, reuse PID-backed locking and hold the
     shared router action lock. Tests run update, failure and disable workers
     and check that locks are released.
   - If left unfixed: list updates could stop working until manual cleanup or a
     reboot.

5. **Routing restart errors were hidden.**
   - What this is: applying Iranian destination lists rebuilds PBR and, when
     active, refreshes the FakeIP routing configuration.
   - Problem: a later successful shell statement hid a failed restart. The page
     reported success even though routing had not applied.
   - Fix: explicitly propagate restart errors and refresh through the existing
     domain-router helper. Enable/update and disable restore their prior setting
     after failure. Tests inject PBR failure in both directions.
   - If left unfixed: displayed routing state could disagree with running rules.

6. **Resume could report success before DNS used FakeIP again.**
   - What this is: resuming reliable routing restores the tunnel policy after a
     deliberate pause.
   - Problem: the resume path restored interception rules without reconnecting
     dnsmasq to FakeIP. It depended on a later health check to finish the job.
   - Fix: restore the DNS connection and verify real DNS queries before marking
     resume active. Restore dnsmasq on a failed cutover. DNS validation returns
     failure to its caller so retry and rollback code can run.
   - If left unfixed: selected destinations could continue following ordinary
     DNS results while the page already said routing had resumed.

## Should fix

7. **CI skipped existing risky-input tests.**
   - What this is: certificate upload and the Windows helper parse user files.
   - Problem: their existing executable tests were absent from the main CI path.
   - Fix: include certificate-upload tests and the C# profile-document tests in
     `ci-check.sh`; install jq and Mono in CI and release validation. Add focused
     regression checks for the failures above and the UI refresh changes.
   - If left unfixed: broken authentication-file handling could pass normal CI.

8. **Two unused Windows drawing classes remained.**
   - What this is: `BackdropPanel` and `RoundedPanel` were unused UI components.
   - Problem: they added code without affecting the shipped interface.
   - Fix: delete both classes, translate the remaining Windows UI into English
     and rebuild the bundled executable.
   - If left unfixed: future maintainers would keep reviewing and carrying dead
     drawing code.

## English-only interface

- Remove Russian and Persian dictionaries, language selection, locale storage
  handling, right-to-left overrides and the bundled Persian font.
- Keep app text and date/duration formatting in English, including when an old
  language preference remains in browser storage. Preserve LuCI's own translator.
- Use English menu titles, documentation entry point and Windows helper text.
- Bump resource names so browsers load the new scripts after an upgrade.
- The shared JavaScript source falls from 373,370 to 81,443 bytes, about 78%.
  The removed font was another 50,684 bytes before compression.

## UI performance

Status requests used to run configuration initialization and commit on every
poll. Initialization now runs once under the configuration lock, with a stored
schema marker. An existing empty user database is a valid initialized database.

Overview renders while its dependency diagnostic runs in the background. The
readiness controls retain an unknown state until the check completes. Users
refresh traffic and duration in place, rebuilding cards only when accounts or
session structure change. Hidden Users and Outbound Tunnel pages skip polling.

On the inspected Redmi AX6S, the old and fixed manager scripts were run against
private copies of the same configuration in temporary RAM storage. Five runs
per command were measured after initialization; this is a backend benchmark,
not a measurement of complete browser page load time.

| Read command | Old median | Fixed median | Configuration writes in five reads |
| --- | ---: | ---: | ---: |
| `client-get` | 0.24 s | 0.10 s | 20 → 0 |
| `users-show` | 0.19 s | 0.05 s | 20 → 0 |

## AX6S package

The router was inspected directly and reported:

- Xiaomi Redmi Router AX6S, board `xiaomi,redmi-router-ax6s`;
- OpenWrt `25.12.5`, revision `r33051-f5dae5ece4`;
- target `mediatek/mt7622`, package architecture `aarch64_cortex-a53`;
- kernel `6.12.94`.

The APK uses the matching official SDK:
`openwrt-sdk-25.12.5-mediatek-mt7622_gcc-14.3.0_musl.Linux-x86_64.tar.zst`.
Its SHA-256 is
`0bd25a391256dbe9ad1f9c6f313364b1f9eddcc0e280c829d644034981ad8306`.

The SDK produced `dist/apk/luci-app-ikev2-manager-1.13.3.apk`. Metadata confirms
version `1.13.3` and architecture `aarch64_cortex-a53`. Extracted runtime and UI
files were compared with the fixed source. The router accepted an offline
`apk add --simulate --allow-untrusted` upgrade from `1.13.2` to `1.13.3` without
requiring changes to other installed packages.

The APK is unsigned, following this repository's existing release policy.
Verify it against `dist/apk/SHA256SUMS.apk`. After copying the APK to `/tmp` on
the matching router, the installation command is:

```sh
apk add --allow-untrusted /tmp/luci-app-ikev2-manager-1.13.3.apk
```

## Validation and limits

The regression suite covers failed reloads, concurrent credential changes,
certificate rollback, background worker cleanup, routing restart failures,
resume DNS validation, English-only text, deferred Overview loading and stable
user-card refreshes. The C# profile-document tests pass under Mono.
The complete `scripts/ci-check.sh` run passes, including two identical IPK
builds. ShellCheck at error severity and `git diff --check` pass. The matching
SDK APK build and the AX6S installation simulation also pass.

After the owner authorized installation, the AX6S was upgraded from 1.13.2 to
1.13.3. A private settings backup was created on the router first. Existing
account and client-secret checksums matched after installation. LuCI displayed
1.13.3; the full router diagnostic returned `doctor_ok=1`. FakeIP routing,
firewall protection and the health watcher remained active. The existing VPN
session stayed established, ordinary DNS resolved, and an HTTPS request bound
to the VPN interface succeeded. The selected-domain DNS probe was skipped
because the configured domain list was empty.

The diagnostic still reports its pre-existing strongSwan warning for inbound
server use. The inbound server is disabled; the upgrade did not change that.

Verdict: the eight reported defects are fixed. The package matches the
inspected AX6S and passes its package-manager simulation.

Not checked: reboot recovery on the router, a deliberate VPN reconnection,
pause/resume under live traffic, or the Windows helper running on native
Windows. Existing router settings were preserved. Other boards and
OpenWrt releases were not validated. There was no sustained traffic load test
or independent audit of third-party VPN, DNS or downloaded-list dependencies.
