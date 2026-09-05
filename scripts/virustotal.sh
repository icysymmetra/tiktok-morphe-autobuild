#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly apk_path="${1:?APK path is required}"
readonly apk_sha256="${2:?APK SHA-256 is required}"
readonly scan_mode="${3:?VirusTotal mode is required}"
readonly result_path="${4:?Result path is required}"
readonly api_base="${VT_API_BASE_URL:-https://www.virustotal.com/api/v3}"
readonly request_interval="${VT_REQUEST_INTERVAL_SECONDS:-16}"
readonly max_wait="${VT_MAX_WAIT_SECONDS:-1200}"
readonly report_url="https://www.virustotal.com/gui/file/$apk_sha256"

last_request_epoch=0
request_sequence=0
HTTP_STATUS=""

notice() {
  printf '::notice::VirusTotal: %s\n' "$*"
}

warning() {
  printf '::warning::VirusTotal: %s\n' "$*"
}

write_result() {
  local status="$1"
  local reason="${2:-}"
  local analysis_id="${3:-}"
  local statistics="${4:-}"
  local last_analysis_date="${5:-}"
  [[ -n "$statistics" ]] || statistics='{}'

  jq -n \
    --arg mode "$scan_mode" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg sha256 "$apk_sha256" \
    --arg report_url "$report_url" \
    --arg analysis_id "$analysis_id" \
    --arg last_analysis_date "$last_analysis_date" \
    --argjson statistics "$statistics" \
    '{
      schema_version: 1,
      provider: "virustotal",
      mode: $mode,
      status: $status,
      reason: (if $reason == "" then null else $reason end),
      sha256: $sha256,
      report_url: (if ($status == "found" or $status == "uploaded" or $status == "pending") then $report_url else null end),
      analysis_id: (if $analysis_id == "" then null else $analysis_id end),
      last_analysis_date: (if $last_analysis_date == "" then null else ($last_analysis_date | tonumber) end),
      statistics: $statistics
    }' >"$result_path"
}

wait_for_request_slot() {
  local now elapsed delay
  now="$(date +%s)"
  elapsed=$((now - last_request_epoch))
  delay=$((request_interval - elapsed))
  if (( last_request_epoch > 0 && delay > 0 )); then
    sleep "$delay"
  fi
}

api_request() {
  local method="$1"
  local url="$2"
  local response_file="$3"
  shift 3

  local attempt=1
  local headers_file curl_status retry_after
  while (( attempt <= 5 )); do
    wait_for_request_slot
    request_sequence=$((request_sequence + 1))
    headers_file="${result_path}.headers-${request_sequence}"

    set +e
    HTTP_STATUS="$(curl \
      --silent \
      --show-error \
      --location \
      --request "$method" \
      --header "x-apikey: $VT_API_KEY" \
      --dump-header "$headers_file" \
      --output "$response_file" \
      --write-out '%{http_code}' \
      "$@" \
      "$url")"
    curl_status=$?
    set -e
    last_request_epoch="$(date +%s)"

    if (( curl_status != 0 )); then
      if (( attempt == 5 )); then
        HTTP_STATUS="000"
        return 0
      fi
      warning "request failed at the transport layer; retrying (attempt $attempt of 5)."
      sleep "$request_interval"
      attempt=$((attempt + 1))
      continue
    fi

    if [[ "$HTTP_STATUS" != "429" ]]; then
      return 0
    fi

    retry_after="$(awk 'tolower($1) == "retry-after:" { gsub("\\r", "", $2); print $2; exit }' "$headers_file")"
    [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=60
    (( retry_after >= request_interval )) || retry_after="$request_interval"
    (( retry_after <= 300 )) || retry_after=300
    warning "rate limit reached; honoring Retry-After and waiting ${retry_after}s."
    sleep "$retry_after"
    attempt=$((attempt + 1))
  done
}

api_error_message() {
  local response_file="$1"
  jq -r '.error.message // .error.code // "unexpected VirusTotal API response"' "$response_file" 2>/dev/null \
    || printf '%s' 'unexpected VirusTotal API response'
}

write_file_report() {
  local status="$1"
  local response_file="$2"
  local analysis_id="${3:-}"
  local statistics last_analysis_date
  statistics="$(jq -c '.data.attributes.last_analysis_stats // {}' "$response_file")"
  last_analysis_date="$(jq -r '.data.attributes.last_analysis_date // empty' "$response_file")"
  write_result "$status" "" "$analysis_id" "$statistics" "$last_analysis_date"
}

mkdir -p "$(dirname -- "$result_path")"

case "$scan_mode" in
  disabled)
    write_result "skipped" "disabled by policy"
    exit 0
    ;;
  lookup_only | upload_public)
    ;;
  *)
    write_result "error" "unsupported mode: $scan_mode"
    exit 0
    ;;
esac

if [[ -z "${VT_API_KEY:-}" ]]; then
  write_result "skipped" "VT_API_KEY is not configured"
  exit 0
fi

command -v curl >/dev/null 2>&1 || {
  write_result "error" "curl is required"
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  printf '%s\n' 'jq is required for VirusTotal integration' >&2
  exit 1
}
[[ -f "$apk_path" ]] || {
  write_result "error" "APK file was not found"
  exit 0
}
[[ "$apk_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || {
  write_result "error" "invalid APK SHA-256"
  exit 0
}
if ! [[ "$request_interval" =~ ^[0-9]+$ ]] || (( request_interval < 15 )); then
  write_result "error" "request interval must be at least 15 seconds"
  exit 0
fi
if ! [[ "$max_wait" =~ ^[0-9]+$ ]]; then
  write_result "error" "maximum wait must be a non-negative integer"
  exit 0
fi

readonly lookup_response="${result_path}.lookup"
api_request GET "$api_base/files/$apk_sha256" "$lookup_response"
if [[ "$HTTP_STATUS" == "200" ]]; then
  write_file_report "found" "$lookup_response"
  notice "reused the existing report for $apk_sha256; no upload was performed."
  exit 0
fi

if [[ "$HTTP_STATUS" != "404" ]]; then
  write_result "error" "lookup failed with HTTP $HTTP_STATUS: $(api_error_message "$lookup_response")"
  exit 0
fi

if [[ "$scan_mode" == "lookup_only" ]]; then
  write_result "not_found" "no existing report; lookup-only policy forbids uploads"
  notice "no report exists and lookup-only policy kept the APK local."
  exit 0
fi

apk_size="$(stat -c '%s' "$apk_path")"
readonly apk_size
if (( apk_size > 650000000 )); then
  write_result "error" "APK exceeds VirusTotal's 650 MB public upload limit"
  exit 0
fi
if (( apk_size > 200000000 )); then
  warning "the APK is larger than 200 MB; VirusTotal warns that some engines may time out or skip large bundles."
fi

notice "upload_public is enabled; this APK will be shared with VirusTotal and its analysis partners."
readonly upload_url_response="${result_path}.upload-url"
api_request GET "$api_base/files/upload_url" "$upload_url_response"
if [[ "$HTTP_STATUS" != "200" ]]; then
  write_result "error" "upload URL request failed with HTTP $HTTP_STATUS: $(api_error_message "$upload_url_response")"
  exit 0
fi

upload_url="$(jq -er '.data | strings | select(length > 0)' "$upload_url_response")" || {
  write_result "error" "VirusTotal did not return a large-file upload URL"
  exit 0
}
readonly upload_url
readonly upload_response="${result_path}.upload"
api_request POST "$upload_url" "$upload_response" --form "file=@$apk_path"
if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" ]]; then
  write_result "error" "upload failed with HTTP $HTTP_STATUS: $(api_error_message "$upload_response")"
  exit 0
fi

analysis_id="$(jq -er '.data.id | strings | select(length > 0)' "$upload_response")" || {
  write_result "error" "VirusTotal accepted the upload without returning an analysis ID"
  exit 0
}
readonly analysis_id
readonly analysis_response="${result_path}.analysis"
readonly deadline=$(( $(date +%s) + max_wait ))

while (( $(date +%s) < deadline )); do
  sleep 30
  api_request GET "$api_base/analyses/$analysis_id" "$analysis_response"
  if [[ "$HTTP_STATUS" != "200" ]]; then
    warning "analysis poll returned HTTP $HTTP_STATUS; the bounded poll will continue."
    continue
  fi

  analysis_status="$(jq -r '.data.attributes.status // "unknown"' "$analysis_response")"
  if [[ "$analysis_status" == "completed" ]]; then
    api_request GET "$api_base/files/$apk_sha256" "$lookup_response"
    if [[ "$HTTP_STATUS" == "200" ]]; then
      write_file_report "uploaded" "$lookup_response" "$analysis_id"
    else
      write_result "pending" "analysis completed but the file report is not available yet" "$analysis_id"
    fi
    notice "public upload analysis completed."
    exit 0
  fi
done

write_result "pending" "analysis did not complete within ${max_wait}s" "$analysis_id"
warning "analysis is still pending; publishing the permanent report link without blocking the build."
