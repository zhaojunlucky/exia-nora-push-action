#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 || $# == 3 ]] || {
  echo 'Usage: push-image.sh ARCHIVE REGISTRY/REPOSITORY:TAG [REGISTRY/REPOSITORY:MOVING-TAG]' >&2
  exit 1
}
: "${NORA_TOKEN:?NORA_TOKEN is required}"
archive=$1
images=("${@:2}")
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
for image in "${images[@]}"; do
  DOCKER_CONFIG="$auth_dir" crane push "$archive" "$image"
done
