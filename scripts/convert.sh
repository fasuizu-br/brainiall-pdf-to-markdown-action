#!/usr/bin/env bash

# Never inherit shell tracing: action inputs can contain a secret.
set +x
set -Eeuo pipefail

readonly API_URL='https://api.brainiall.com/v1/document/pdf-to-markdown/file'

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

reject_line_breaks() {
  local label=$1
  local value=$2

  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must not contain line breaks." ;;
  esac
}

for required_command in curl cp dd mktemp mv; do
  command -v "$required_command" >/dev/null 2>&1 \
    || fail "Required command not found: $required_command"
done

workspace_input=${GITHUB_WORKSPACE:-}
[[ -n "$workspace_input" ]] || fail 'GITHUB_WORKSPACE is not set.'
[[ -d "$workspace_input" ]] || fail 'GITHUB_WORKSPACE is not a directory.'
workspace=$(cd -P -- "$workspace_input" && pwd)
[[ "$workspace" != '/' ]] || fail 'Refusing to use the filesystem root as GITHUB_WORKSPACE.'

pdf_path=${BRAINIALL_PDF_PATH:-}
api_key=${BRAINIALL_API_KEY:-}
output_path=${BRAINIALL_OUTPUT_PATH:-}
page_range=${BRAINIALL_PAGE_RANGE:-}
output_format=${BRAINIALL_OUTPUT_FORMAT:-markdown}

[[ -n "$pdf_path" ]] || fail 'The pdf_path input is required.'
[[ -n "$api_key" ]] || fail 'The api_key input is required. Pass it from GitHub Actions secrets.'

reject_line_breaks 'pdf_path' "$pdf_path"
reject_line_breaks 'api_key' "$api_key"
reject_line_breaks 'output_path' "$output_path"
reject_line_breaks 'page_range' "$page_range"
reject_line_breaks 'output_format' "$output_format"

case "$output_format" in
  markdown|json) ;;
  *) fail 'output_format must be either markdown or json.' ;;
esac

if [[ -n "$page_range" ]]; then
  [[ "$page_range" =~ ^[1-9][0-9]*(-[1-9][0-9]*)?$ ]] \
    || fail 'page_range must be a positive page number or inclusive range such as 1-10.'

  if [[ "$page_range" == *-* ]]; then
    page_start=${page_range%%-*}
    page_end=${page_range##*-}
    (( 10#$page_start <= 10#$page_end )) \
      || fail 'page_range start must not be greater than its end.'
  fi
fi

if [[ "$pdf_path" == /* ]]; then
  pdf_candidate=$pdf_path
else
  pdf_candidate=$workspace/$pdf_path
fi

[[ -e "$pdf_candidate" ]] || fail "PDF not found: $pdf_path"
[[ ! -L "$pdf_candidate" ]] || fail 'pdf_path must not be a symbolic link.'
[[ -f "$pdf_candidate" ]] || fail 'pdf_path must point to a regular file.'
[[ -r "$pdf_candidate" ]] || fail 'The PDF is not readable.'
[[ -s "$pdf_candidate" ]] || fail 'The PDF is empty.'

pdf_dir=$(cd -P -- "$(dirname -- "$pdf_candidate")" && pwd)
pdf_abs=$pdf_dir/$(basename -- "$pdf_candidate")
case "$pdf_abs" in
  "$workspace"/*) ;;
  *) fail 'pdf_path must resolve inside GITHUB_WORKSPACE.' ;;
esac

pdf_signature=$(dd if="$pdf_abs" bs=5 count=1 2>/dev/null || true)
[[ "$pdf_signature" == '%PDF-' ]] || fail 'The input does not have a valid PDF signature.'

if [[ -z "$output_path" ]]; then
  pdf_name=$(basename -- "$pdf_abs")
  if [[ "$pdf_name" == *.[Pp][Dd][Ff] ]]; then
    output_stem=${pdf_name:0:${#pdf_name}-4}
  else
    output_stem=$pdf_name
  fi

  if [[ "$output_format" == 'markdown' ]]; then
    output_candidate=$pdf_dir/$output_stem.md
  else
    output_candidate=$pdf_dir/$output_stem.json
  fi
elif [[ "$output_path" == /* ]]; then
  output_candidate=$output_path
else
  output_candidate=$workspace/$output_path
fi

output_parent_candidate=$(dirname -- "$output_candidate")
[[ -d "$output_parent_candidate" ]] \
  || fail 'The output_path parent directory must already exist.'
output_dir=$(cd -P -- "$output_parent_candidate" && pwd)
output_abs=$output_dir/$(basename -- "$output_candidate")

case "$output_abs" in
  "$workspace"/*) ;;
  *) fail 'output_path must resolve inside GITHUB_WORKSPACE.' ;;
esac

[[ "$output_abs" != "$pdf_abs" ]] || fail 'output_path must not overwrite the input PDF.'
[[ ! -L "$output_abs" ]] || fail 'output_path must not be a symbolic link.'
if [[ -e "$output_abs" && ! -f "$output_abs" ]]; then
  fail 'output_path exists and is not a regular file.'
fi

umask 077
tmp_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
[[ -d "$tmp_root" && -w "$tmp_root" ]] || fail 'No writable runner temporary directory is available.'

request_dir=$(mktemp -d "$tmp_root/brainiall-pdf-action.XXXXXX") \
  || fail 'Could not create a private request directory.'
response_tmp=''

cleanup() {
  if [[ -n "${response_tmp:-}" && -e "$response_tmp" ]]; then
    rm -f -- "$response_tmp"
  fi
  if [[ -n "${request_dir:-}" && -d "$request_dir" ]]; then
    rm -f -- "$request_dir/headers" "$request_dir/input.pdf"
    rmdir -- "$request_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

headers_file=$request_dir/headers
upload_file=$request_dir/input.pdf
printf 'Authorization: Bearer %s\n' "$api_key" >"$headers_file"
printf 'Ocp-Apim-Subscription-Key: %s\n' "$api_key" >>"$headers_file"
unset api_key BRAINIALL_API_KEY

# A private, fixed-name copy prevents curl multipart filename parsing from
# treating punctuation in a user-supplied path as form syntax.
cp -- "$pdf_abs" "$upload_file"
response_tmp=$(mktemp "$output_dir/.brainiall-pdf-output.XXXXXX") \
  || fail 'Could not create a private output file.'

curl_args=(
  --silent
  --show-error
  --fail
  --proto '=https'
  --tlsv1.2
  --connect-timeout 20
  --max-time 600
  --request POST
  --header "@$headers_file"
  --form "pdf=@$upload_file;type=application/pdf"
  --form-string "output_format=$output_format"
  --output "$response_tmp"
  --write-out '%{http_code}'
)

if [[ -n "$page_range" ]]; then
  curl_args+=(--form-string "page_range=$page_range")
fi

if ! http_code=$(curl "${curl_args[@]}" "$API_URL"); then
  fail 'The Brainiall API request failed. No output file was replaced.'
fi

[[ "$http_code" =~ ^2[0-9][0-9]$ ]] \
  || fail "The Brainiall API returned HTTP $http_code. No output file was replaced."
[[ -s "$response_tmp" ]] || fail 'The Brainiall API returned an empty response.'

mv -f -- "$response_tmp" "$output_abs"
response_tmp=''

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'output_path=%s\n' "$output_abs" >>"$GITHUB_OUTPUT"
fi

printf 'Converted PDF to %s: %s\n' "$output_format" "$output_abs"
