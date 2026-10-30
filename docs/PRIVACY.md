# Publication privacy review

The v1.13.5 publication was checked before pushing source or publishing assets.
The release contains only the application APK and its SHA-256 checksum.

## Checks performed

- Gitleaks 8.24.3 checked Git history, the proposed public source tree, extracted
  APK files and APK script metadata. No secrets were detected.
- Source and package checks found no private development-session identifiers,
  workstation paths, temporary router credentials or live network details.
- Packaged resources were compared with source. No router configuration backup,
  live credentials, legacy recovery archive or diagnostic capture is included.
- The maintainer commit uses a GitHub noreply address. Existing upstream credits,
  licenses and public history are preserved.

## Screenshots and excluded material

The README and UI previews were rendered locally with synthetic demo data.
They contain no live router credentials, endpoints, device identifiers or LAN
addresses. The published JPEGs have no EXIF, location or comment metadata.
Original router screenshots are not published.

Build directories, logs, private keys, authentication state, local runbooks and
router backups stay out of Git and release assets. The upgrade's private legacy
recovery archive stays on the router and must never be shared publicly.

Files under `keys/` are public verification keys. Test credentials are synthetic
fixtures; certificate tests generate temporary keys during execution.

## Sharing diagnostics

Review attachments before sharing. Connection profiles can contain passwords;
backups and diagnostics can reveal endpoints, addresses, device names, MAC
addresses and keys. Remove those details first. Automated scans reduce accidental
exposure but cannot guarantee detection of every sensitive value.
