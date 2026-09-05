# Base APK contract

The repository tracks metadata only. The stock APK is stored as the single
asset of the prerelease named by `manifest.json`.

For the current input:

- tag: `base-tiktok-46.2.3-r2`
- asset: `TikTok-46.2.3-stock.apk`
- SHA-256: `2fbe277a568e0e820cb51b09bcf0c0d788dc4fb070e66025f12d11cd3ec16936`

GitHub release immutability is enabled, and revision 2 is protected by it. If
the bytes ever need to change, increment `base_apk.revision`, create a new
`-rN` prerelease, and update the manifest. Never replace the asset behind an
existing tag.
