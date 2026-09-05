# TikTok Morphe AutoBuild

[![TikTok Morphe AutoBuild](https://github.com/icysymmetra/tiktok-morphe-autobuild/actions/workflows/autobuild.yml/badge.svg)](https://github.com/icysymmetra/tiktok-morphe-autobuild/actions/workflows/autobuild.yml)

This repository is the binary-build companion to
[`icysymmetra/tiktok-patches-for-morphe`](https://github.com/icysymmetra/tiktok-patches-for-morphe).
Patch source and APK automation intentionally live in separate repositories.

The builder polls every three hours, resolves the latest stable patch release
and latest stable Morphe Desktop release, and publishes a patched APK only for a
combination that does not already have a release.

## Current build contract

- TikTok: `com.zhiliaoapp.musically` `46.2.3` (`2024602030`)
- Base APK: immutable prerelease `base-tiktok-46.2.3-r1`
- Patch source: `icysymmetra/tiktok-patches-for-morphe`, stable releases only
- Morphe: latest stable `MorpheApp/morphe-desktop`
- Bytecode mode: explicitly `STRIP_FAST`
- Patch selection: upstream defaults
- Signing: persistent Morphe BKS key, certificate SHA-256
  `43635fbdc8eb708ed8c484e3f1a4ec7234f0bd1b68de9408cbb6f0b0ee99cbf8`

## Build flow

1. Resolve the latest non-draft, non-prerelease patch release.
2. Stop immediately if the exact base-revision/patch combination already has a release.
3. Resolve the latest stable Morphe Desktop release.
4. Download the exact `.mpp` and `-all.jar` assets and verify their GitHub SHA-256 digests when available.
5. Ask Morphe `list-versions` whether the manifest's package/version is supported.
6. On mismatch, create or update one rolling GitHub issue and stop successfully.
7. On a match, download the stock APK from its immutable prerelease and verify the manifest SHA-256.
8. Patch with explicit `STRIP_FAST`, compatibility enforcement, upstream defaults, and the persistent signing key.
9. Require a successful Morphe result with zero failed patches and a valid APK archive.
10. Publish the APK, checksums, Morphe result, and provenance as a new immutable release.

There is deliberately no `--force`, `--continue-on-error`, automatic
`STRIP_SAFE`/`FULL` fallback, ABI stripping, APK scraper, or committed signing
material.

## Updating TikTok

When the rolling mismatch issue reports a newer compatible TikTok version:

1. Obtain and locally validate the clean APK.
2. Increment `base_apk.revision` if reusing a version, or start at revision `1` for a new version.
3. Create a new prerelease named `base-tiktok-<version>-r<revision>` with one APK asset.
4. Update [`original-apk/manifest.json`](original-apk/manifest.json) with the package, version code, source URL, release tag, asset name, and SHA-256.
5. Commit the manifest change. The push triggers an immediate compatibility check and build.

Never replace the bytes attached to an existing base release. A changed base
input gets a new revision and therefore a new output release tag.

## Signing secrets

The workflow expects two GitHub Actions secrets:

- `SIGNING_KEYSTORE_BASE64`
- `SIGNING_KEY_PASSWORD`

The keystore is reconstructed only inside the ephemeral runner and is never
uploaded as an artifact. Keep an offline backup: losing the private key breaks
Android update compatibility for every APK previously signed with it.

The current Morphe BKS file has no store-integrity password, so the workflow
intentionally omits `--keystore-password`. Its `Morphe` private-key entry still
uses `SIGNING_KEY_PASSWORD`. Passing an empty store password is not equivalent
to omitting the option for this BKS file.

## Manual checks

Use **Actions -> TikTok Morphe AutoBuild -> Run workflow**. Enable `check_only`
to verify current releases and compatibility without downloading the large base
APK or using the signing key.

Scheduled workflows in inactive public repositories can eventually be disabled
by GitHub. If that happens, re-enable the workflow from the Actions tab or run it
manually.
