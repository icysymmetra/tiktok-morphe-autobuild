#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly WORK_ROOT="${RUNNER_TEMP:-$SCRIPT_DIR/../.work}/virustotal-backfill-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

for command in gh jq sha256sum awk; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command is missing: $command"
done

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${VT_API_KEY:?VT_API_KEY is required}"

[[ ! -e "$WORK_ROOT" ]] || fail "Refusing to reuse an existing work directory: $WORK_ROOT"
mkdir -p "$WORK_ROOT/release"

release_json="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG")"
[[ "$(jq -r '.draft' <<<"$release_json")" == "false" ]] || fail "Draft releases cannot be backfilled."
[[ "$(jq -r '.prerelease' <<<"$release_json")" == "false" ]] || fail "Refusing to scan a base/prerelease; provide a published build release tag."

apk_asset_json="$(jq -cer '
  [.assets[] | select(.name | endswith(".apk"))]
  | if length == 1 then .[0] else error("expected exactly one APK asset") end
' <<<"$release_json")"
apk_name="$(jq -er '.name' <<<"$apk_asset_json")"
apk_digest="$(jq -r '.digest // empty' <<<"$apk_asset_json")"
readonly apk_name apk_digest

gh release download "$RELEASE_TAG" \
  --repo "$GITHUB_REPOSITORY" \
  --pattern "$apk_name" \
  --dir "$WORK_ROOT/release"

readonly apk_path="$WORK_ROOT/release/$apk_name"
apk_sha256="$(sha256sum "$apk_path" | awk '{gsub(/[^0-9A-Fa-f]/, "", $1); print tolower($1)}')"
readonly apk_sha256
if [[ -n "$apk_digest" ]]; then
  [[ "$apk_digest" == "sha256:$apk_sha256" ]] || fail "Downloaded APK does not match its GitHub asset digest."
fi

readonly vt_result="$WORK_ROOT/virustotal-result.json"
bash "$SCRIPT_DIR/virustotal.sh" "$apk_path" "$apk_sha256" upload_public "$vt_result"

vt_status="$(jq -er '.status | strings' "$vt_result")"
vt_reason="$(jq -r '.reason // empty' "$vt_result")"
[[ "$vt_status" == "analyzed" ]] \
  || fail "VirusTotal did not complete the required fresh analysis; status is $vt_status${vt_reason:+: $vt_reason}."

vt_report_url="$(jq -er '.report_url | strings' "$vt_result")"
vt_malicious="$(jq -er '.statistics.malicious // 0' "$vt_result")"
vt_suspicious="$(jq -er '.statistics.suspicious // 0' "$vt_result")"
vt_engine_total="$(jq -er '[.statistics[] | numbers] | add // 0' "$vt_result")"
vt_analysis_date="$(jq -er '.last_analysis_date | numbers' "$vt_result")"
vt_analysis_iso="$(date -u -d "@$vt_analysis_date" +'%Y-%m-%d %H:%M:%S UTC')"
readonly vt_report_url vt_malicious vt_suspicious vt_engine_total vt_analysis_iso

scan_section="$(cat <<EOF
<!-- VIRUSTOTAL_SCAN_START -->
**VirusTotal:** [$vt_malicious malicious · $vt_suspicious suspicious · $vt_engine_total engines — view report]($vt_report_url) · Fresh scan: $vt_analysis_iso
<!-- VIRUSTOTAL_SCAN_END -->
EOF
)"
readonly scan_section

current_body="$(jq -r '.body // ""' <<<"$release_json")"
updated_body="$(jq -nr \
  --arg body "$current_body" \
  --arg section "$scan_section" '
    $body
    | gsub("(?s)\n*<!-- VIRUSTOTAL_SCAN_START -->.*?<!-- VIRUSTOTAL_SCAN_END -->\n*"; "\n")
    | if contains("<details>")
      then sub("<details>"; ($section + "\n\n<details>"))
      else . + "\n\n" + $section
      end
  ')"
readonly updated_body

gh api \
  --method PATCH \
  "repos/$GITHUB_REPOSITORY/releases/$(jq -er '.id' <<<"$release_json")" \
  --field body="$updated_body" \
  >/dev/null

printf '::notice::Added a fresh VirusTotal report to release %s.\n' "$RELEASE_TAG"
