# Bundled Iranian domains

Source: https://github.com/Chocolate4U/Iran-v2ray-rules

Pinned release revision: `df5e48a54ba2eada63ba85f45da40e5f7e1b3877`

Input: `ir.txt`, SHA-256 `d9f398d6cc9dc7888daaf08280060074d62d0665204b5d407e211d9c1dffbf5e`.

The `domain:` prefixes are removed and the `.ir` suffix rule is represented by
`ir`. The sorted snapshot contains 57,559 domain suffixes. No GeoIP,
advertising, security or other categories are included.

The upstream project licenses its own material under GPL-3.0; its Iranian
domain source (bootmortis/iran-hosted-domains) is MIT-licensed. Preserve this
source attribution and the accompanying GPL license when redistributing.
The application code retains its existing MIT license.

The router uses this packaged snapshot offline. It changes only with a new
application release; there is no runtime download or automatic Iran-list update.
