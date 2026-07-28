#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
convert_script=$repo_root/scripts/convert.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/brainiall-pdf-action-test.XXXXXX")

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

workspace=$test_root/workspace
runner_temp=$test_root/runner-temp
mock_bin=$test_root/mock-bin
mkdir -p "$workspace/results" "$runner_temp" "$mock_bin"
workspace=$(cd -P -- "$workspace" && pwd)

mock_curl=$mock_bin/curl
cat >"$mock_curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail

output_file=''
headers_arg=''
url=''
forms=()

while (($#)); do
  case "$1" in
    --silent|--show-error|--fail|--tlsv1.2)
      shift
      ;;
    --proto|--connect-timeout|--max-time|--request|--write-out|--output|--header|--form|--form-string)
      option=$1
      value=${2:-}
      [[ -n "$value" ]] || exit 90
      case "$option" in
        --output) output_file=$value ;;
        --header) headers_arg=$value ;;
        --form|--form-string) forms+=("$value") ;;
      esac
      shift 2
      ;;
    https://*)
      url=$1
      shift
      ;;
    *)
      printf 'Unexpected curl argument: %s\n' "$1" >&2
      exit 91
      ;;
  esac
done

[[ "$url" == 'https://api.brainiall.com/v1/document/pdf-to-markdown/file' ]] || exit 92
[[ "$headers_arg" == @* ]] || exit 93
headers_file=${headers_arg#@}
grep -Fqx "Authorization: Bearer $MOCK_EXPECTED_KEY" "$headers_file" || exit 94
grep -Fqx "Ocp-Apim-Subscription-Key: $MOCK_EXPECTED_KEY" "$headers_file" || exit 95
[[ -n "$output_file" ]] || exit 96

form_dump=$(printf '%s\n' "${forms[@]}")
grep -Fq 'pdf=@' <<<"$form_dump" || exit 97
grep -Fqx "output_format=$MOCK_EXPECTED_FORMAT" <<<"$form_dump" || exit 98
if [[ -n "${MOCK_EXPECTED_PAGE_RANGE:-}" ]]; then
  grep -Fqx "page_range=$MOCK_EXPECTED_PAGE_RANGE" <<<"$form_dump" || exit 99
fi

case "${MOCK_CURL_MODE:-success_markdown}" in
  success_markdown)
    printf '# Converted document\n\nSafe mock response.\n' >"$output_file"
    printf '200'
    ;;
  success_json)
    printf '{"markdown":"# Converted document","pages":[{"page":1}]}' >"$output_file"
    printf '200'
    ;;
  http_error)
    printf '{"error":"unauthorized"}' >"$output_file"
    printf '401'
    exit 22
    ;;
  *)
    exit 100
    ;;
esac
MOCK_CURL
chmod +x "$mock_curl"

test_key='test-key-not-a-secret'
pdf_file=$workspace/input\ sample.pdf
printf '%%PDF-1.4\nmock test document\n%%%%EOF\n' >"$pdf_file"

assert_not_contains_key() {
  local logs=$1
  [[ "$logs" != *"$test_key"* ]] || {
    printf 'FAIL: the API key appeared in logs\n' >&2
    exit 1
  }
}

run_action() {
  local mode=$1
  local format=$2
  local output=$3
  local range=$4
  local key=${5-$test_key}

  PATH="$mock_bin:$PATH" \
  GITHUB_WORKSPACE="$workspace" \
  GITHUB_OUTPUT="$test_root/github-output" \
  RUNNER_TEMP="$runner_temp" \
  BRAINIALL_PDF_PATH='input sample.pdf' \
  BRAINIALL_API_KEY="$key" \
  BRAINIALL_OUTPUT_PATH="$output" \
  BRAINIALL_PAGE_RANGE="$range" \
  BRAINIALL_OUTPUT_FORMAT="$format" \
  MOCK_CURL_MODE="$mode" \
  MOCK_EXPECTED_KEY="$test_key" \
  MOCK_EXPECTED_FORMAT="$format" \
  MOCK_EXPECTED_PAGE_RANGE="$range" \
  "$convert_script"
}

: >"$test_root/github-output"
logs=$(run_action success_markdown markdown 'results/converted report.md' '1-2' 2>&1)
assert_not_contains_key "$logs"
grep -Fqx '# Converted document' "$workspace/results/converted report.md"
grep -Fqx "output_path=$workspace/results/converted report.md" "$test_root/github-output"

rm -f "$test_root/github-output"
logs=$(run_action success_json json '' '' 2>&1)
assert_not_contains_key "$logs"
grep -Fq '"markdown":"# Converted document"' "$workspace/input sample.json"

if logs=$(run_action success_markdown markdown 'results/missing-key.md' '' '' 2>&1); then
  printf 'FAIL: missing api_key was accepted\n' >&2
  exit 1
fi
assert_not_contains_key "$logs"
[[ ! -e "$workspace/results/missing-key.md" ]]

if logs=$(run_action success_markdown markdown 'results/invalid-range.md' '4-2' 2>&1); then
  printf 'FAIL: descending page_range was accepted\n' >&2
  exit 1
fi
assert_not_contains_key "$logs"
[[ ! -e "$workspace/results/invalid-range.md" ]]

invalid_pdf=$workspace/not-a-pdf.txt
printf 'plain text\n' >"$invalid_pdf"
if logs=$(
  PATH="$mock_bin:$PATH" \
  GITHUB_WORKSPACE="$workspace" \
  RUNNER_TEMP="$runner_temp" \
  BRAINIALL_PDF_PATH='not-a-pdf.txt' \
  BRAINIALL_API_KEY="$test_key" \
  BRAINIALL_OUTPUT_PATH='results/not-a-pdf.md' \
  BRAINIALL_PAGE_RANGE='' \
  BRAINIALL_OUTPUT_FORMAT='markdown' \
  "$convert_script" 2>&1
); then
  printf 'FAIL: non-PDF input was accepted\n' >&2
  exit 1
fi
assert_not_contains_key "$logs"
[[ ! -e "$workspace/results/not-a-pdf.md" ]]

outside_pdf=$test_root/outside.pdf
printf '%%PDF-1.4\noutside\n%%%%EOF\n' >"$outside_pdf"
ln -s "$outside_pdf" "$workspace/symlink.pdf"
if logs=$(
  PATH="$mock_bin:$PATH" \
  GITHUB_WORKSPACE="$workspace" \
  RUNNER_TEMP="$runner_temp" \
  BRAINIALL_PDF_PATH='symlink.pdf' \
  BRAINIALL_API_KEY="$test_key" \
  BRAINIALL_OUTPUT_PATH='results/symlink.md' \
  BRAINIALL_PAGE_RANGE='' \
  BRAINIALL_OUTPUT_FORMAT='markdown' \
  "$convert_script" 2>&1
); then
  printf 'FAIL: symlink input was accepted\n' >&2
  exit 1
fi
assert_not_contains_key "$logs"

printf 'keep-existing-output\n' >"$workspace/results/preserved.md"
if logs=$(run_action http_error markdown 'results/preserved.md' '' 2>&1); then
  printf 'FAIL: HTTP error was accepted\n' >&2
  exit 1
fi
assert_not_contains_key "$logs"
grep -Fqx 'keep-existing-output' "$workspace/results/preserved.md"

if find "$runner_temp" -mindepth 1 -print -quit | grep -q .; then
  printf 'FAIL: private request files were not cleaned up\n' >&2
  exit 1
fi

printf 'PASS: 7 isolated tests completed without a real API key or network request.\n'
