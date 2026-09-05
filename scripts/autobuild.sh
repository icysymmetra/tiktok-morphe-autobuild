#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT
readonly MANIFEST_PATH="${MANIFEST_PATH:-$REPO_ROOT/original-apk/manifest.json}"
readonly WORK_ROOT="${RUNNER_TEMP:-$REPO_ROOT/.work}/tiktok-morphe-autobuild-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

notice() {
  printf '::notice::%s\n' "$*"
}

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is missing: $1"
}

json_string() {
  jq -er "$1 | strings | select(length > 0)" "$MANIFEST_PATH"
}

asset_from_release() {
  local release_json="$1"
  local suffix="$2"
  jq -cer --arg suffix "$suffix" '
    [.assets[] | select(.name | endswith($suffix))]
    | if length == 1 then .[0]
      else error("expected exactly one release asset ending in " + $suffix)
      end
  ' <<<"$release_json"
}

download_release_asset() {
  local repository="$1"
  local tag="$2"
  local asset_name="$3"
  local destination_dir="$4"
  mkdir -p "$destination_dir"
  gh release download "$tag" \
    --repo "$repository" \
    --pattern "$asset_name" \
    --dir "$destination_dir"
}

verify_github_digest() {
  local file="$1"
  local digest="$2"
  local label="$3"

  if [[ -z "$digest" || "$digest" == "null" ]]; then
    notice "$label has no GitHub asset digest; continuing with the exact resolved release asset."
    return
  fi

  [[ "$digest" == sha256:* ]] || fail "$label uses an unsupported GitHub digest: $digest"
  local expected="${digest#sha256:}"
  local actual
  actual="$(sha256sum "$file" | awk '{gsub(/[^0-9A-Fa-f]/, "", $1); print tolower($1)}')"
  [[ "$actual" == "${expected,,}" ]] || fail "$label digest mismatch. Expected $expected, got $actual."
}

validate_manifest() {
  [[ -f "$MANIFEST_PATH" ]] || fail "Manifest not found: $MANIFEST_PATH"
  jq -e '
    .schema_version == 2 and
    (.app.name | type == "string" and length > 0) and
    (.app.package_name | type == "string" and length > 0) and
    (.app.version_name | type == "string" and length > 0) and
    (.app.version_code | type == "number") and
    (.base_apk.revision | type == "number" and . >= 1 and floor == .) and
    (.base_apk.source.provider | type == "string" and length > 0) and
    (.base_apk.source.url | type == "string" and startswith("https://")) and
    (.base_apk.release_tag | type == "string" and length > 0) and
    (.base_apk.asset_name | type == "string" and endswith(".apk")) and
    (.base_apk.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$")) and
    (.patch_source.repository | type == "string" and test("^[^/]+/[^/]+$")) and
    .patch_source.channel == "stable" and
    (.morphe.repository | type == "string" and test("^[^/]+/[^/]+$")) and
    .morphe.channel == "stable" and
    .morphe.bytecode_mode == "STRIP_FAST" and
    .security_scan.provider == "virustotal" and
    (.security_scan.mode == "disabled" or .security_scan.mode == "lookup_only" or .security_scan.mode == "upload_public") and
    (.security_scan.required | type == "boolean") and
    (.security_scan.request_interval_seconds | type == "number" and . >= 15 and floor == .) and
    (.security_scan.max_wait_seconds | type == "number" and . >= 0 and floor == .) and
    (.security_scan.block_on_detections | type == "boolean") and
    (.security_scan.maximum_malicious | type == "number" and . >= 0 and floor == .) and
    (.security_scan.maximum_suspicious | type == "number" and . >= 0 and floor == .) and
    (.signing.alias | type == "string" and length > 0) and
    (.signing.signer | type == "string" and length > 0) and
    .signing.store_password_mode == "none" and
    (.signing.certificate_sha256 | type == "string" and test("^[0-9a-fA-F]{64}$"))
  ' "$MANIFEST_PATH" >/dev/null || fail "Manifest validation failed: $MANIFEST_PATH"
}

open_or_update_mismatch_issue() {
  local body_file="$1"
  local issue_number

  gh label create "autobuild-version-mismatch" \
    --repo "$build_repository" \
    --color "D73A4A" \
    --description "The stored base APK is not compatible with the latest stable patches" \
    --force >/dev/null

  issue_number="$(gh issue list \
    --repo "$build_repository" \
    --state open \
    --label "autobuild-version-mismatch" \
    --json number \
    --jq '.[0].number // empty')"

  if [[ -n "$issue_number" ]]; then
    gh issue edit "$issue_number" \
      --repo "$build_repository" \
      --title "AutoBuild blocked: base APK / patch version mismatch" \
      --body-file "$body_file" >/dev/null
    notice "Updated version-mismatch issue #$issue_number."
  else
    gh issue create \
      --repo "$build_repository" \
      --title "AutoBuild blocked: base APK / patch version mismatch" \
      --label "autobuild-version-mismatch" \
      --body-file "$body_file" >/dev/null
    notice "Opened the rolling version-mismatch issue."
  fi
}

close_mismatch_issues() {
  local issue_numbers
  issue_numbers="$(gh issue list \
    --repo "$build_repository" \
    --state open \
    --label "autobuild-version-mismatch" \
    --json number \
    --jq '.[].number')"

  while IFS= read -r issue_number; do
    [[ -n "$issue_number" ]] || continue
    gh issue close "$issue_number" \
      --repo "$build_repository" \
      --comment "Compatibility restored: TikTok $version_name is supported by $patch_repository $patch_tag. AutoBuild resumed." \
      >/dev/null
    notice "Closed resolved version-mismatch issue #$issue_number."
  done <<<"$issue_numbers"
}

require_command jq
validate_manifest

if [[ "${AUTOBUILD_VALIDATE_ONLY:-false}" == "true" ]]; then
  notice "Manifest is valid."
  exit 0
fi

for command in gh java sha256sum awk unzip base64; do
  require_command "$command"
done

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

readonly build_repository="$GITHUB_REPOSITORY"
app_name="$(json_string '.app.name')"
package_name="$(json_string '.app.package_name')"
version_name="$(json_string '.app.version_name')"
version_code="$(jq -er '.app.version_code | numbers' "$MANIFEST_PATH")"
base_revision="$(jq -er '.base_apk.revision | numbers' "$MANIFEST_PATH")"
base_source_provider="$(json_string '.base_apk.source.provider')"
base_source_url="$(json_string '.base_apk.source.url')"
base_release_tag="$(json_string '.base_apk.release_tag')"
base_asset_name="$(json_string '.base_apk.asset_name')"
base_sha256="$(json_string '.base_apk.sha256' | tr '[:upper:]' '[:lower:]')"
patch_repository="$(json_string '.patch_source.repository')"
morphe_repository="$(json_string '.morphe.repository')"
bytecode_mode="$(json_string '.morphe.bytecode_mode')"
signing_alias="$(json_string '.signing.alias')"
signer_name="$(json_string '.signing.signer')"
signing_certificate_sha256="$(json_string '.signing.certificate_sha256' | tr '[:upper:]' '[:lower:]')"
vt_manifest_mode="$(json_string '.security_scan.mode')"
vt_required="$(jq -r '.security_scan.required' "$MANIFEST_PATH")"
vt_request_interval="$(jq -er '.security_scan.request_interval_seconds | numbers' "$MANIFEST_PATH")"
vt_max_wait="$(jq -er '.security_scan.max_wait_seconds | numbers' "$MANIFEST_PATH")"
vt_block_on_detections="$(jq -r '.security_scan.block_on_detections' "$MANIFEST_PATH")"
vt_maximum_malicious="$(jq -er '.security_scan.maximum_malicious | numbers' "$MANIFEST_PATH")"
vt_maximum_suspicious="$(jq -er '.security_scan.maximum_suspicious | numbers' "$MANIFEST_PATH")"
vt_mode_override="${VT_MODE_OVERRIDE:-manifest}"
case "$vt_mode_override" in
  manifest) vt_mode="$vt_manifest_mode" ;;
  disabled | lookup_only | upload_public) vt_mode="$vt_mode_override" ;;
  *) fail "VT_MODE_OVERRIDE must be manifest, disabled, lookup_only, or upload_public." ;;
esac
readonly app_name package_name version_name version_code base_revision
readonly base_source_provider base_source_url base_release_tag base_asset_name base_sha256
readonly patch_repository morphe_repository bytecode_mode
readonly signing_alias signer_name signing_certificate_sha256
readonly vt_manifest_mode vt_required vt_request_interval vt_max_wait
readonly vt_block_on_detections vt_maximum_malicious vt_maximum_suspicious vt_mode_override vt_mode
readonly check_only="${CHECK_ONLY:-false}"
readonly workflow_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-unknown}"

[[ "$check_only" == "true" || "$check_only" == "false" ]] || fail "CHECK_ONLY must be true or false."

[[ ! -e "$WORK_ROOT" ]] || fail "Refusing to reuse an existing work directory: $WORK_ROOT"
mkdir -p "$WORK_ROOT"/{downloads/patches,downloads/morphe,input,output,temp}

notice "Resolving the latest stable patch release from $patch_repository."
patch_release_json="$(gh api "repos/$patch_repository/releases/latest")"
[[ "$(jq -r '.draft' <<<"$patch_release_json")" == "false" ]] || fail "Latest patch release is a draft."
[[ "$(jq -r '.prerelease' <<<"$patch_release_json")" == "false" ]] || fail "Latest patch release is a prerelease."
patch_tag="$(jq -er '.tag_name' <<<"$patch_release_json")"
patch_release_url="$(jq -er '.html_url' <<<"$patch_release_json")"
patch_asset_json="$(asset_from_release "$patch_release_json" '.mpp')"
patch_asset_name="$(jq -er '.name' <<<"$patch_asset_json")"
patch_asset_digest="$(jq -r '.digest // empty' <<<"$patch_asset_json")"
readonly patch_tag patch_release_url patch_asset_name patch_asset_digest

safe_patch_tag="$(tr -cs 'A-Za-z0-9._-' '-' <<<"$patch_tag" | sed 's/^-//;s/-$//')"
readonly safe_patch_tag
readonly build_tag="tiktok-${version_name}-base-r${base_revision}-patches-${safe_patch_tag}"
readonly output_apk_name="TikTok-${version_name}-Morphe-${safe_patch_tag}-r${base_revision}.apk"

if [[ "$check_only" != "true" ]] && gh release view "$build_tag" --repo "$build_repository" >/dev/null 2>&1; then
  notice "Release $build_tag already exists. No download or build is needed."
  exit 0
fi

notice "Resolving the latest stable Morphe Desktop release."
morphe_release_json="$(gh api "repos/$morphe_repository/releases/latest")"
[[ "$(jq -r '.draft' <<<"$morphe_release_json")" == "false" ]] || fail "Latest Morphe release is a draft."
[[ "$(jq -r '.prerelease' <<<"$morphe_release_json")" == "false" ]] || fail "Latest Morphe release is a prerelease."
morphe_tag="$(jq -er '.tag_name' <<<"$morphe_release_json")"
morphe_asset_json="$(asset_from_release "$morphe_release_json" '-all.jar')"
morphe_asset_name="$(jq -er '.name' <<<"$morphe_asset_json")"
morphe_asset_digest="$(jq -r '.digest // empty' <<<"$morphe_asset_json")"
readonly morphe_tag morphe_asset_name morphe_asset_digest

download_release_asset "$patch_repository" "$patch_tag" "$patch_asset_name" "$WORK_ROOT/downloads/patches"
download_release_asset "$morphe_repository" "$morphe_tag" "$morphe_asset_name" "$WORK_ROOT/downloads/morphe"
readonly patch_file="$WORK_ROOT/downloads/patches/$patch_asset_name"
readonly morphe_jar="$WORK_ROOT/downloads/morphe/$morphe_asset_name"
verify_github_digest "$patch_file" "$patch_asset_digest" "Patch bundle"
verify_github_digest "$morphe_jar" "$morphe_asset_digest" "Morphe Desktop"

readonly compatibility_output="$WORK_ROOT/output/compatible-versions.txt"
readonly patch_list_output="$WORK_ROOT/output/default-patches.txt"
java -jar "$morphe_jar" list-patches \
  --patches="$patch_file" \
  --filter-package-name="$package_name" \
  --with-packages \
  --with-versions \
  --out="$patch_list_output"

enabled_patch_count="$(awk '$1 == "Enabled:" && $2 == "true" { count++ } END { print count + 0 }' "$patch_list_output")"
readonly enabled_patch_count
(( enabled_patch_count > 0 )) || fail "Morphe reported no default-enabled patches for $package_name."

java -jar "$morphe_jar" list-versions \
  --patches="$patch_file" \
  --filter-package-names="$package_name" 2>&1 | tee "$compatibility_output"

target_patch_count="$(awk -v version="$version_name" '
  $1 == version && $2 ~ /^\(/ {
    line = $0
    sub(/^.*\(/, "", line)
    sub(/ patches?\).*$/, "", line)
    print line
    exit
  }
' "$compatibility_output")"

if [[ -z "$target_patch_count" || "$target_patch_count" != "$enabled_patch_count" ]]; then
  supported_versions="$(awk '$2 ~ /^\(/ { print "- `" $1 "`" }' "$compatibility_output")"
  [[ -n "$supported_versions" ]] || supported_versions="- Morphe did not report a compatible version. See the captured output below."
  incompatible_default_patches="$(awk -v version="$version_name" '
    BEGIN { RS = ""; FS = "\n" }
    /Enabled:[[:space:]]+true/ {
      name = ""
      supports = 0
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^Name:/) {
          sub(/^Name:[[:space:]]*/, "", line)
          name = line
        }
        trimmed = $i
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
        if (trimmed == version) supports = 1
      }
      if (!supports && name != "") print "- `" name "`"
    }
  ' "$patch_list_output")"
  [[ -n "$incompatible_default_patches" ]] || incompatible_default_patches="- The aggregate count did not match; inspect the raw patch list from this workflow run."

  mismatch_issue_body="$WORK_ROOT/output/version-mismatch.md"
  cat >"$mismatch_issue_body" <<EOF
AutoBuild is waiting for a compatible TikTok base APK.

## Stored base APK

- Package: \`$package_name\`
- Version: \`$version_name\`
- Version code: \`$version_code\`
- Base revision: \`r$base_revision\`
- SHA-256: \`$base_sha256\`

## Latest stable patch bundle

- Repository: [$patch_repository]($patch_release_url)
- Release: \`$patch_tag\`
- Asset: \`$patch_asset_name\`

## Morphe compatibility result

$supported_versions

Default-enabled patches: \`$enabled_patch_count\`  
Default-enabled patches declaring TikTok \`$version_name\`: \`${target_patch_count:-0}\`

### Default patches not declaring this version

$incompatible_default_patches

## Required action

Supply a clean compatible TikTok APK in a new immutable base prerelease, then update
\`original-apk/manifest.json\`. Do not replace the asset behind an existing base tag.

Morphe Desktop: \`$morphe_tag\`  
Workflow run: $workflow_url

<details><summary>Raw Morphe output</summary>

\`\`\`text
$(cat "$compatibility_output")
\`\`\`
</details>
EOF

  open_or_update_mismatch_issue "$mismatch_issue_body"
  notice "Compatibility mismatch: stored TikTok $version_name is not supported by $patch_repository $patch_tag."
  exit 0
fi

close_mismatch_issues
notice "Compatibility confirmed for $package_name $version_name."

if [[ "$check_only" == "true" ]]; then
  notice "Check-only run completed before downloading the base APK or signing key."
  exit 0
fi

: "${SIGNING_KEYSTORE_BASE64:?SIGNING_KEYSTORE_BASE64 is required for a build}"
: "${SIGNING_KEY_PASSWORD:?SIGNING_KEY_PASSWORD is required for a build}"

base_release_json="$(gh release view "$base_release_tag" \
  --repo "$build_repository" \
  --json tagName,url,isPrerelease,assets)"
[[ "$(jq -r '.isPrerelease' <<<"$base_release_json")" == "true" ]] || fail "Base release $base_release_tag must be marked as a prerelease."
base_asset_count="$(jq --arg name "$base_asset_name" '[.assets[] | select(.name == $name)] | length' <<<"$base_release_json")"
[[ "$base_asset_count" == "1" ]] || fail "Base release $base_release_tag must contain exactly one asset named $base_asset_name."

download_release_asset "$build_repository" "$base_release_tag" "$base_asset_name" "$WORK_ROOT/input"
readonly base_apk="$WORK_ROOT/input/$base_asset_name"
actual_base_sha256="$(sha256sum "$base_apk" | awk '{gsub(/[^0-9A-Fa-f]/, "", $1); print tolower($1)}')"
readonly actual_base_sha256
[[ "$actual_base_sha256" == "$base_sha256" ]] || fail "Base APK SHA-256 mismatch. Expected $base_sha256, got $actual_base_sha256."

readonly signing_keystore="$WORK_ROOT/input/signing.keystore"
printf '%s' "$SIGNING_KEYSTORE_BASE64" | base64 --decode >"$signing_keystore"
chmod 600 "$signing_keystore"
[[ -s "$signing_keystore" ]] || fail "Decoded signing keystore is empty."

readonly output_apk="$WORK_ROOT/output/$output_apk_name"
readonly patch_result="$WORK_ROOT/output/patch-result.json"
java -jar "$morphe_jar" patch \
  --patches="$patch_file" \
  --bytecode-mode="$bytecode_mode" \
  --keystore="$signing_keystore" \
  --keystore-entry-alias="$signing_alias" \
  --keystore-entry-password="$SIGNING_KEY_PASSWORD" \
  --signer="$signer_name" \
  --result-file="$patch_result" \
  --temporary-files-path="$WORK_ROOT/temp" \
  --out="$output_apk" \
  "$base_apk"

[[ -s "$output_apk" ]] || fail "Morphe did not produce the expected APK: $output_apk_name"
[[ -s "$patch_result" ]] || fail "Morphe did not produce patch-result.json."
jq -e --arg package "$package_name" --arg version "$version_name" '
  # Morphe omits the success field when it retains its default true value.
  (.success // true) == true and
  .packageName == $package and
  .packageVersion == $version and
  (.patchingSteps | length >= 3) and
  all(.patchingSteps[]; .success == true) and
  (.failedPatches | length == 0)
' "$patch_result" >/dev/null || fail "Morphe result JSON did not prove a complete successful patch run."
actual_applied_count="$(jq -er '.appliedPatches | length' "$patch_result")"
[[ "$actual_applied_count" == "$enabled_patch_count" ]] || fail "Morphe applied $actual_applied_count patches, but $enabled_patch_count were enabled by default."
unzip -t "$output_apk" >/dev/null || fail "The produced APK is not a valid ZIP/APK archive."

patched_sha256="$(sha256sum "$output_apk" | awk '{gsub(/[^0-9A-Fa-f]/, "", $1); print tolower($1)}')"
readonly patched_sha256

readonly virustotal_result="$WORK_ROOT/output/virustotal-result.json"
VT_REQUEST_INTERVAL_SECONDS="$vt_request_interval" \
VT_MAX_WAIT_SECONDS="$vt_max_wait" \
  bash "$SCRIPT_DIR/virustotal.sh" "$output_apk" "$patched_sha256" "$vt_mode" "$virustotal_result"

vt_status="$(jq -er '.status | strings' "$virustotal_result")"
vt_reason="$(jq -r '.reason // empty' "$virustotal_result")"
readonly vt_status vt_reason

if [[ "$vt_required" == "true" && "$vt_status" != "found" && "$vt_status" != "uploaded" ]]; then
  fail "VirusTotal is required, but its status is $vt_status${vt_reason:+: $vt_reason}."
fi

if [[ "$vt_block_on_detections" == "true" && ( "$vt_status" == "found" || "$vt_status" == "uploaded" ) ]]; then
  vt_malicious="$(jq -er '.statistics.malicious // 0' "$virustotal_result")"
  vt_suspicious="$(jq -er '.statistics.suspicious // 0' "$virustotal_result")"
  if (( vt_malicious > vt_maximum_malicious || vt_suspicious > vt_maximum_suspicious )); then
    fail "VirusTotal detection policy blocked the release: malicious=$vt_malicious, suspicious=$vt_suspicious."
  fi
fi

readonly provenance="$WORK_ROOT/output/build-provenance.json"
jq -n \
  --arg app "$app_name" \
  --arg package "$package_name" \
  --arg version "$version_name" \
  --argjson version_code "$version_code" \
  --argjson base_revision "$base_revision" \
  --arg base_release_tag "$base_release_tag" \
  --arg base_asset_name "$base_asset_name" \
  --arg base_sha256 "$base_sha256" \
  --arg base_source_provider "$base_source_provider" \
  --arg base_source_url "$base_source_url" \
  --arg patch_repository "$patch_repository" \
  --arg patch_tag "$patch_tag" \
  --arg patch_asset_name "$patch_asset_name" \
  --arg patch_asset_digest "$patch_asset_digest" \
  --arg morphe_repository "$morphe_repository" \
  --arg morphe_tag "$morphe_tag" \
  --arg morphe_asset_name "$morphe_asset_name" \
  --arg morphe_asset_digest "$morphe_asset_digest" \
  --arg bytecode_mode "$bytecode_mode" \
  --arg signer "$signer_name" \
  --arg signing_certificate_sha256 "$signing_certificate_sha256" \
  --arg output_apk "$output_apk_name" \
  --arg output_sha256 "$patched_sha256" \
  --arg workflow_url "$workflow_url" \
  --arg source_commit "${GITHUB_SHA:-unknown}" \
  --arg built_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    schema_version: 1,
    app: {name: $app, package_name: $package, version_name: $version, version_code: $version_code},
    base_apk: {
      revision: $base_revision,
      release_tag: $base_release_tag,
      asset_name: $base_asset_name,
      sha256: $base_sha256,
      source: {provider: $base_source_provider, url: $base_source_url}
    },
    patches: {
      repository: $patch_repository,
      release: $patch_tag,
      asset_name: $patch_asset_name,
      github_digest: $patch_asset_digest
    },
    morphe: {
      repository: $morphe_repository,
      release: $morphe_tag,
      asset_name: $morphe_asset_name,
      github_digest: $morphe_asset_digest,
      bytecode_mode: $bytecode_mode
    },
    signing: {signer: $signer, certificate_sha256: $signing_certificate_sha256},
    output: {asset_name: $output_apk, sha256: $output_sha256},
    workflow: {url: $workflow_url, source_commit: $source_commit, built_at: $built_at}
  }' >"$provenance"

readonly build_info="$WORK_ROOT/output/build-info.json"
jq -s '.[0] + {morphe_result: .[1], security_scan: .[2]}' \
  "$provenance" "$patch_result" "$virustotal_result" >"$build_info"

patch_changelog="$(jq -r '.body // ""' <<<"$patch_release_json" | awk '
  /^# \[/ { next }
  /^## [0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$/ { next }
  /^\* Merge branch / { next }
  /^\* merge dev into main/ { next }
  NF { blank = 0; print; next }
  !blank { print ""; blank = 1 }
')"
[[ -n "$patch_changelog" ]] || patch_changelog="No patch changelog was supplied for [$patch_tag]($patch_release_url)."
readonly patch_changelog

security_scan_summary=""
if [[ "$vt_status" == "found" || "$vt_status" == "uploaded" ]]; then
  vt_report_url="$(jq -er '.report_url | strings' "$virustotal_result")"
  vt_malicious_display="$(jq -er '.statistics.malicious // 0' "$virustotal_result")"
  vt_suspicious_display="$(jq -er '.statistics.suspicious // 0' "$virustotal_result")"
  vt_engine_total="$(jq -er '[.statistics[] | numbers] | add // 0' "$virustotal_result")"
  security_scan_summary="$(cat <<EOF
## Security scan

[VirusTotal report]($vt_report_url): **$vt_malicious_display malicious**, **$vt_suspicious_display suspicious** across $vt_engine_total engine results. Treat automated detections as signals, not a guarantee.
EOF
)"
elif [[ "$vt_status" == "pending" ]]; then
  vt_report_url="$(jq -er '.report_url | strings' "$virustotal_result")"
  security_scan_summary="$(cat <<EOF
## Security scan

[VirusTotal analysis]($vt_report_url) was submitted and was still processing when this immutable release was published.
EOF
)"
fi
readonly security_scan_summary

readonly release_notes="$WORK_ROOT/output/release-notes.md"
cat >"$release_notes" <<EOF
## Download

[**Download $output_apk_name**](https://github.com/$build_repository/releases/download/$build_tag/$output_apk_name)

TikTok **$version_name** with Morphe patches **$patch_tag**. Built automatically from the pinned stock APK and signed with the project's persistent update key.

SHA-256: \`$patched_sha256\`

$security_scan_summary

<details>
<summary><strong>What's changed in patches $patch_tag</strong></summary>

$patch_changelog

</details>

<details>
<summary><strong>Build details and provenance</strong></summary>

| Input | Value |
|---|---|
| Package | \`$package_name\` |
| Version | \`$version_name\` (\`$version_code\`) |
| Base | \`r$base_revision\` from \`$base_release_tag\` |
| Base SHA-256 | \`$base_sha256\` |
| Patch source | [$patch_repository]($patch_release_url) \`$patch_tag\` |
| Morphe Desktop | \`$morphe_tag\` |
| Bytecode mode | \`$bytecode_mode\` |
| Signer | \`$signer_name\` |
| Signing certificate SHA-256 | \`$signing_certificate_sha256\` |
| VirusTotal policy | \`$vt_mode\` (status: \`$vt_status\`) |

Policy: exact stable patch and Morphe assets, verified GitHub digests, upstream default patches, compatibility enforcement, no \`--force\`, no \`--continue-on-error\`, no ABI stripping, and one persistent signing identity.

[Workflow run]($workflow_url) · [Machine-readable build info](https://github.com/$build_repository/releases/download/$build_tag/build-info.json)

</details>
EOF

if gh release view "$build_tag" --repo "$build_repository" >/dev/null 2>&1; then
  notice "Release $build_tag appeared while this run was building; leaving the existing immutable release unchanged."
  exit 0
fi

gh release create "$build_tag" \
  --repo "$build_repository" \
  --title "TikTok $version_name - Patches $patch_tag" \
  --notes-file "$release_notes" \
  --latest \
  "$output_apk" \
  "$build_info"

notice "Published immutable build release $build_tag."
