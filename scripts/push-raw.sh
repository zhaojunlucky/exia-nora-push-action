#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 || $# == 3 ]] || {
  echo 'Usage: push-raw.sh LOCAL_FILE REGISTRY/RAW_PATH [--allow-overwrite]' >&2
  echo 'Example: push-raw.sh dist/index.json nora.exia.app/mcp-command-parser-plugins/release/latest.json' >&2
  exit 1
}
: "${NORA_TOKEN:?NORA_TOKEN is required}"
local_file=$1
target=$2
allow_overwrite=0
if [[ "${3:-}" == "--allow-overwrite" ]]; then
  allow_overwrite=1
fi

[[ -f "$local_file" ]] || {
  echo "Local file not found: $local_file" >&2
  exit 1
}
registry=${target%%/*}
raw_path=${target#*/}
[[ -n "$raw_path" && "$raw_path" != "$target" ]] || {
  echo 'Expected REGISTRY/RAW_PATH with at least one path segment' >&2
  exit 1
}
case "$raw_path" in
  */../*|../*|*/..|..)
    echo "Refusing raw path with .. segments: $raw_path" >&2
    exit 1
    ;;
esac
scheme=https
# Plain HTTP is only used by a localhost regression fixture.
case "$registry" in localhost:*|127.0.0.1:*) scheme=http ;; esac
url="$scheme://$registry/raw/$raw_path"

umask 077
auth_dir=$(mktemp -d)
trap 'rm -rf "$auth_dir"' EXIT
# Keep the token out of command arguments.
printf 'Authorization: Bearer %s\n' "$NORA_TOKEN" > "$auth_dir/header"
unset NORA_TOKEN

put() {
  local extra_header=$1
  curl --silent --show-error --max-time 60 \
    --user-agent 'exia-nora-push-action/1.0' \
    --header "@$auth_dir/header" \
    ${extra_header:+--header "$extra_header"} \
    --upload-file "$local_file" \
    --dump-header "$auth_dir/response-headers" --output "$auth_dir/response-body" \
    --write-out '%{http_code}' \
    "$url"
}

fail() {
  echo "Raw push failed: HTTP $1" >&2
  awk 'tolower($0) ~ /^(server|content-type|cf-ray|retry-after):/' "$auth_dir/response-headers" >&2
  head -c 512 "$auth_dir/response-body" >&2 || true
  printf '\n' >&2
  exit 1
}

status=$(put "")
case "$status" in
  200|201|204)
    echo "Pushed $local_file -> $url (HTTP $status)"
    exit 0
    ;;
  409)
    if [[ "$allow_overwrite" != 1 ]]; then
      echo "Raw path already exists and is immutable: $raw_path (HTTP 409)" >&2
      echo 'Push to a new, unused path instead, or pass --allow-overwrite for an intentional pointer-file update (e.g. latest.json).' >&2
      exit 1
    fi
    ;;
  *)
    fail "$status"
    ;;
esac

# --allow-overwrite path: read the current ETag and retry conditionally, so
# a concurrent writer is detected instead of silently clobbered.
etag=$(curl --silent --show-error --max-time 30 --head \
  --user-agent 'exia-nora-push-action/1.0' \
  --header "@$auth_dir/header" \
  "$url" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2; exit}')
[[ -n "$etag" ]] || {
  echo "Could not read ETag for conditional overwrite of $raw_path" >&2
  exit 1
}
status=$(put "If-Match: $etag")
case "$status" in
  200|201|204)
    echo "Overwrote $url (HTTP $status, If-Match: $etag)"
    ;;
  *)
    fail "$status"
    ;;
esac
