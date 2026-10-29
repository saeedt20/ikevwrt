# Publication privacy review

The v1.13.3 publication was checked before pushing source or uploading assets.
Only the application APK and its SHA-256 checksum are release assets.

## Checks performed

- Gitleaks 8.24.3 scanned existing Git history, the proposed public source tree
  and the extracted APK payload. No secrets were detected.
- The proposed source and APK payload were checked for private details from the
  development and router-validation session, including local workstation paths,
  network identifiers and temporary credentials. No matches were found.
- The APK payload was compared with the tested source. It contains packaged
  defaults, application resources and the Windows helper, without a router
  settings backup or live credentials.
- The new commit uses the maintainer's GitHub noreply address. Existing upstream
  credits, licenses and public commit history are preserved.

## Material kept out of publication

Build directories, local logs, router backups, private keys, authentication
state and private runbooks are excluded from the public tree. The router's
pre-upgrade backup stays on the router; it is not a release asset. No live-router
screenshot or network capture is published with this release.

Files under `keys/` are public verification keys, not signing secrets. Test
credentials are synthetic fixtures; certificate tests generate temporary keys
during execution.

## Sharing diagnostics

Review issue attachments yourself. Connection profiles can contain passwords;
backups and diagnostic output can reveal endpoints, device names, addresses,
MAC addresses and keys. Remove those details before sharing. Scanner results
reduce accidental exposure but cannot guarantee that every sensitive value
will be detected.
