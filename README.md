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
- Base APK: immutable prerelease `base-tiktok-46.2.3-r2`
- Patch source: `icysymmetra/tiktok-patches-for-morphe`, stable releases only
- Morphe: latest stable `MorpheApp/morphe-desktop`
- Bytecode mode: explicitly `STRIP_FAST`
- Patch selection: upstream defaults
- VirusTotal: `lookup_only` by default; public upload requires an explicit policy change or manual-run override
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
10. Apply the configured VirusTotal policy after patching and before publishing.
11. Publish the APK and one combined `build-info.json` as a new immutable release.

## Release layout

Release notes put the direct APK download and SHA-256 first. The patch source's
release notes are carried forward as a collapsed changelog, while build inputs,
signing identity, policy, and workflow link live in a second collapsed section.

Only two project assets are uploaded:

- the patched APK;
- `build-info.json`, which combines provenance, the complete Morphe result, and
  the VirusTotal outcome.

GitHub adds its own source `.zip` and `.tar.gz` links to every tag; workflows
cannot hide those entries. Older immutable releases keep their original notes
and asset layout.

GitHub release immutability is enforced for the repository. Published tags and
assets cannot be moved, replaced, or deleted; the workflow performs all checks
before asking GitHub to publish the release.

There is deliberately no `--force`, `--continue-on-error`, automatic
`STRIP_SAFE`/`FULL` fallback, ABI stripping, APK scraper, or committed signing
material.

## VirusTotal policy

Configure `security_scan` in `original-apk/manifest.json` or override it for a
manual workflow run:

- `disabled`: make no VirusTotal requests.
- `lookup_only` (default): look up the patched SHA-256 and reuse an existing
  report, but never upload the APK.
- `upload_public`: reuse an existing report when possible; otherwise upload the
  APK through VirusTotal's large-file endpoint and poll the analysis.

The integration spaces API requests by at least 16 seconds, honors HTTP `429`
`Retry-After`, uses bounded retries, and stops polling after the configured
`max_wait_seconds`. It is informational by default. `required` can make a
missing result fail the build, and `block_on_detections` can enforce the
configured malicious/suspicious thresholds.

`upload_public` requires a repository secret named `VT_API_KEY`. Public
VirusTotal submissions are shared with its community and analysis partners, and
the free public API is for non-commercial use. VirusTotal accepts large uploads
up to 650 MB but warns that files over 200 MB may receive incomplete engine
coverage; this APK is in that warning range. Keep `lookup_only` unless public
submission is deliberate.

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
APK or using the signing key. The `virustotal_mode` input can temporarily choose
`disabled`, `lookup_only`, or `upload_public` without changing the scheduled
policy.

Scheduled workflows in inactive public repositories can eventually be disabled
by GitHub. If that happens, re-enable the workflow from the Actions tab or run it
manually.
