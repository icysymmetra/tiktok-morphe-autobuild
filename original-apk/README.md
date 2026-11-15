# Base APK contract

The repository tracks metadata only. The stock APK is stored as the single
asset of the prerelease named by `manifest.json`.

For the current input:

- tag: `base-tiktok-47.4.3-r1`
- asset: `TikTok-47.4.3-stock.apk`
- SHA-256: `af7cbe2b00d33ff1339730f6abb8ed7e387a83b27ff2b16748b8f41e6fc87e0b`

GitHub release immutability is enabled. Older base releases stay unchanged. If
the bytes ever need to change, increment `base_apk.revision`, create a new
`-rN` prerelease, and update the manifest. Never replace the asset behind an
existing tag.
