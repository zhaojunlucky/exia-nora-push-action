#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 || $# == 3 ]] || {
  echo 'Usage: push-image.sh ARCHIVE REGISTRY/REPOSITORY:TAG [REGISTRY/REPOSITORY:MOVING-TAG]' >&2
  exit 1
}
: "${NORA_TOKEN:?NORA_TOKEN is required}"
archive=$1
images=("${@:2}")
# Optional: path to a JSON file recording what this (and any prior, same-job)
# push actually landed - see append_record below. Unset/empty means skip.
record_file=${NORA_PUSH_RECORD:-}
registry=${images[0]%%/*}
for image in "${images[@]}"; do
  [[ "$image" == */* && "$image" != *://* && -n "${image#*/}" ]] || {
    echo 'Expected fully qualified image references' >&2
    exit 1
  }
  [[ "${image%%/*}" == "$registry" ]] || {
    echo 'All image references must use the same registry' >&2
    exit 1
  }
done
scheme=https
# Plain HTTP is only used by the localhost regression fixture.
case "$registry" in localhost:*|127.0.0.1:*) scheme=http ;; esac

umask 077
auth_dir=$(mktemp -d)
trap 'rm -rf "$auth_dir"' EXIT
# Keep the token out of command arguments and the runner's Docker config.
printf 'Authorization: Bearer %s\n' "$NORA_TOKEN" > "$auth_dir/header"
# Log non-secret claims to make a rejected OIDC token diagnosable. The
# signature and token value are never printed.
token_payload=${NORA_TOKEN#*.}
token_payload=${token_payload%%.*}
token_payload=$(printf '%s' "$token_payload" | tr '_-' '/+' | awk '{ l=length($0)%4; if (l==2) print $0"=="; else if (l==3) print $0"="; else print $0 }' | base64 --decode 2>/dev/null || true)
if [[ -n "$token_payload" ]] && claims=$(jq -ec 'select(type == "object") | {iss, aud, sub, iat, exp}' <<<"$token_payload" 2>/dev/null); then
  echo "OIDC claims: $claims"
fi
status=$(curl --silent --show-error --max-time 30 \
  --user-agent 'exia-nora-push-action/1.0' \
  --header "@$auth_dir/header" \
  --dump-header "$auth_dir/response-headers" --output "$auth_dir/response-body" \
  --write-out '%{http_code}' "$scheme://$registry/v2/")
# Do not follow redirects or start uploading after an authentication failure.
if [[ "$status" != 200 ]]; then
  echo "Registry preflight failed: HTTP $status" >&2
  awk 'tolower($0) ~ /^(server|content-type|cf-ray|retry-after):/' "$auth_dir/response-headers" >&2
  # Nora returns a short, non-secret reason for OIDC failures. Print it so
  # issuer/audience/subject/JWKS problems are distinguishable in CI logs.
  head -c 512 "$auth_dir/response-body" >&2 || true
  printf '\n' >&2
  exit 1
fi
echo 'Registry Bearer authentication preflight passed'

# Crane honors registrytoken even when nora advertises Basic authentication.
jq -n --arg registry "$registry" \
  '{auths: {($registry): {registrytoken: env.NORA_TOKEN}}}' > "$auth_dir/config.json"
unset NORA_TOKEN

# append_record adds one JSON entry to record_file's top-level "pushes"
# array (creating the file if needed), so a job that pushes both a Docker
# image and a raw artifact ends up with one manifest of what actually landed
# - see push-raw.sh for the raw-side entries appended into the same file.
append_record() {
  local entry=$1
  local tmp
  tmp=$(mktemp)
  if [[ -f "$record_file" ]]; then
    jq -c --argjson entry "$entry" '.pushes += [$entry]' "$record_file" > "$tmp"
  else
    jq -nc --argjson entry "$entry" '{pushes: [$entry]}' > "$tmp"
  fi
  mv "$tmp" "$record_file"
}

pushed_json='[]'
for image in "${images[@]}"; do
  # `crane push` prints REGISTRY/REPO@sha256:DIGEST of the pushed manifest.
  pushed_ref=$(DOCKER_CONFIG="$auth_dir" crane push "$archive" "$image")
  digest=${pushed_ref##*@}
  echo "Pushed $archive -> $image ($digest)"
  entry=$(jq -nc --arg kind docker --arg image "$image" --arg digest "$digest" \
    '{kind: $kind, image: $image, digest: $digest}')
  pushed_json=$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$pushed_json")
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "- docker: \`$image\` @ \`$digest\`" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [[ -n "$record_file" ]]; then
    append_record "$entry"
  fi
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "digest=$(jq -r '.[0].digest' <<<"$pushed_json")"
    echo "pushed-json=$pushed_json"
  } >> "$GITHUB_OUTPUT"
fi
