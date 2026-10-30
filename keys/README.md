# APK verification keys

`ikevwrt-release.pem` is the dedicated public P-256 key for IkevWrt release
APKs. Its file SHA-256 is:

```text
67d9a98b2527c24269ed688183af18ae2fb8f560292a237822d0cd69e53d24c3
```

See [one-time router setup](../docs/OPENWRT25.md#signed-release-apks).
The matching private key is excluded from Git and held in the repository's
`IKEVWRT_APK_SIGNING_KEY` Actions secret. Keep an independent protected backup;
GitHub cannot return secret values. Losing it requires key rotation on routers.
A compromised signing key can authorize arbitrary packages on trusting routers.

`ikev2-manager-release.pem` and `nikitid-openwrt-release.pem` are identical
inherited upstream public keys. They remain for upstream compatibility and do
not verify IkevWrt's dedicated signatures. Their file SHA-256 is:

```text
f27474d9261f1084350cf4ba34ecdff29e533769c36483d8dd85566e30a6a703
```

Every key in this directory is public. No private key belongs here.
