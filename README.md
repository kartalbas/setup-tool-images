# setup-tool-images

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![toolbox](https://github.com/kartalbas/setup-tool-images/actions/workflows/toolbox.yml/badge.svg)](https://github.com/kartalbas/setup-tool-images/actions/workflows/toolbox.yml)

Container images for the jobs that build, test and check software. This README is the only
documentation of the series. It keeps what exists today apart from what is planned.

## What exists today

One folder per image. Each folder holds the image's `Containerfile`, its `versions.table` where the
image fetches tools, its `test.sh` and its own `README.md`.

| Image | Folder | Pulled as |
| :--- | :--- | :--- |
| toolbox | [`toolbox/`](toolbox/README.md) | `ghcr.io/kartalbas/toolbox:<major>.<minor>.<patch>` |

An image is pushed to `ghcr.io/kartalbas/<image>`. The workflow `.github/workflows/<image>.yml` builds
it, runs its `test.sh`, pushes it as one OCI image manifest and signs the pushed digest with keyless
cosign. Only a tag `<image>/v<major>.<minor>.<patch>` pushes. A push to `master` builds and tests and
pushes nothing, so an image is rebuilt only when somebody cuts a tag for it.

Verify an image before you use it. The identity names the workflow file and the tag it ran for:

```
cosign verify \
  --certificate-identity https://github.com/kartalbas/setup-tool-images/.github/workflows/<image>.yml@refs/tags/<image>/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/kartalbas/<image>@sha256:<digest>
```

The digest of each tag stands in the job summary of its workflow run.

## How a tool is bumped

1. Read the new release at its source. Edit its row in `<image>/versions.table`: the version, the
   sha256 that the upstream's own checksum file states for the file, and the address of the upstream
   release file. A row never points at a mirror.
2. Commit to `master`. The workflow builds and tests the image and pushes nothing.
3. Cut the tag `<image>/v<major>.<minor>.<patch>` on that commit and push it. The workflow builds,
   tests, pushes, signs and verifies.

## What is planned

- `testbox`: the toolbox plus the browsers that end-to-end tests drive. It is not built.
