# exia-nora-push-action

Two reusable GitHub composite actions for pushing build output to
[Nora](https://nora.exia.app) (`getnora-io/nora`) over GitHub Actions OIDC —
no long-lived registry credential stored in any consuming repo.

- `zhaojunlucky/exia-nora-push-action/docker@main` — push a `docker save`
  archive to a Nora `docker` repository.
- `zhaojunlucky/exia-nora-push-action/raw@main` — upload a file to a Nora
  `raw` (generic) repository.

Both mint a short-lived OIDC token via `core.getIDToken('nora')`; Nora's
`github-actions` OIDC provider already has `write` role rules for
`repo:zhaojunlucky/*` on pull requests and on `refs/heads/main` (see
`exia-gitops/workloads/nora/values.yaml`), so no new secret is needed for
repos already covered by that pattern.

## Prerequisites

The calling **job** must set:

```yaml
permissions:
  id-token: write
```

Composite actions cannot grant this themselves — it has to come from the
workflow or job that calls them.

## `docker` — push a Docker image

```yaml
permissions:
  id-token: write

steps:
  - run: docker save --output "$RUNNER_TEMP/app.tar" app:build
  - uses: zhaojunlucky/exia-nora-push-action/docker@main
    with:
      archive: ${{ runner.temp }}/app.tar
      image: nora.exia.app/my-repo-ci:pr-${{ github.event.pull_request.number }}-1.0.${{ github.run_number }}
      # optional second, same-registry tag pushed in the same run
      moving-tag: nora.exia.app/my-repo-ci:pr-${{ github.event.pull_request.number }}-latest
```

Inputs: `archive` (required), `image` (required), `moving-tag` (optional),
`crane-version` (optional, default `v0.20.6`), `record` (optional, see
below). Installs Go + `crane` itself; no other setup needed.

Outputs: `digest` (the primary image's digest) and `pushed-json` (a JSON
array of `{kind, image, digest}`, one entry per reference actually pushed).

## `raw` — push a raw/generic artifact

```yaml
permissions:
  id-token: write

steps:
  - uses: zhaojunlucky/exia-nora-push-action/raw@main
    with:
      file: dist/mcp-command-gateway_linux_amd64
      target: nora.exia.app/mcp-command-gateway/release/1.0.${{ github.run_number }}/mcp-command-gateway_linux_amd64
```

Inputs: `file` (required), `target` (required, `REGISTRY/PATH`),
`allow-overwrite` (optional, default `false`), `record` (optional, see
below).

Outputs: `sha256` (of the pushed file) and `pushed-json` (a JSON object
`{kind, target, sha256, bytes, status}`, `status` being `pushed` or
`overwritten`).

Nora raw objects are immutable by default — re-uploading the same path
returns `409`. Give every build its own path (a run number or PR number
segment) and this never comes up. The one legitimate exception is a small
mutable pointer file such as `release/latest.json`; for that specific case
only, pass `allow-overwrite: true`, which reads the current `ETag` and
retries the upload with `If-Match` so a concurrent writer is detected
instead of silently overwritten.

## Recording what actually got pushed

Every push (Docker or raw) is logged to the step's stdout and to
`$GITHUB_STEP_SUMMARY`, so it's always visible in the Actions UI. To also
get it as data - e.g. so a downstream promotion step can tell what this
run actually produced instead of guessing a tag/path and treating "not
found" as ambiguous - pass the same `record` path to every push step in a
job:

```yaml
permissions:
  id-token: write

steps:
  - run: docker save --output "$RUNNER_TEMP/app.tar" app:build
  - uses: zhaojunlucky/exia-nora-push-action/docker@main
    with:
      archive: ${{ runner.temp }}/app.tar
      image: nora.exia.app/my-repo-ci:pr-${{ github.event.pull_request.number }}-1.0.${{ github.run_number }}
      record: ${{ runner.temp }}/nora-push.json
  - uses: zhaojunlucky/exia-nora-push-action/raw@main
    with:
      file: dist/notes.txt
      target: nora.exia.app/my-repo-ci/pr-${{ github.event.pull_request.number }}-1.0.${{ github.run_number }}/notes.txt
      record: ${{ runner.temp }}/nora-push.json
  - uses: actions/upload-artifact@v4
    with:
      name: nora-push-manifest
      path: ${{ runner.temp }}/nora-push.json
```

Each push step appends one entry to the file's top-level `pushes` array
(creating it on the first push), so after both steps above
`nora-push.json` holds:

```json
{
  "pushes": [
    {"kind": "docker", "image": "nora.exia.app/my-repo-ci:pr-1-1.0.42", "digest": "sha256:..."},
    {"kind": "raw", "target": "nora.exia.app/my-repo-ci/pr-1-1.0.42/notes.txt", "sha256": "...", "bytes": 123, "status": "pushed"}
  ]
}
```

If a job doesn't produce a Docker image or doesn't produce a raw artifact,
that step simply never runs and `pushes` has no entry of that `kind` -
which is the authoritative answer to "did this build actually produce a
Docker image / a raw artifact", rather than inferring it from a registry
404 after the fact.

## Design notes

- Both actions only ever use the OIDC token they mint themselves in that
  step; nothing in either action accepts or forwards a caller-supplied
  credential.
- The token is written to a header file (`umask 077`, temp dir removed on
  exit) rather than passed as a command argument, and masked via
  `core.setSecret` before it ever reaches shell/log output.
- `scripts/push-image.sh` and `scripts/push-raw.sh` are plain, dependency-light
  bash and can be run locally (with a real `NORA_TOKEN`) for testing without
  going through GitHub Actions at all.
- The raw contract (`PUT/GET/HEAD /raw/<path>`, immutable-by-default,
  `If-Match` for conditional overwrite) is Nora's actual documented API —
  see https://getnora.dev/registries/raw/.
