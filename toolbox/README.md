# toolbox

One image with the command-line tools that build, test and check jobs call. It carries no project
source and no project script: the job that runs it brings the code.

## What is in it

The tools fetched from their upstream are the rows of [`versions.table`](versions.table): name,
version, sha256 and address. Every tool is held to its row: the build checks the sha256 of each file
before it unpacks it, and `test.sh` runs every tool and holds the printed version to the row.

The packages it adds from its Debian base are the `apt-get install` line of the last stage of the
[`Containerfile`](Containerfile), at the base's versions. The base is the `BASE` argument at the top of the
`Containerfile`, held by the digest of its `linux/amd64` manifest.

It runs as uid 1000 and starts in `/work`, which that user owns. `test.sh` holds both. It sets no
entrypoint: the job that runs it sets the command.

Two rows are not installed the way their package's name suggests:

- `npm` is installed from its registry tarball, offline and without install scripts, so nothing but
  the file with the checked sha256 goes in.
- `pnpm` is the standalone release file, not the npm tarball: that tarball fetches its native binary
  from the registry when it first runs, and a job without registry access would fail at that moment.

## Use it

```
docker run --rm ghcr.io/kartalbas/toolbox:<tag> <tool> --version
```

Verify it before you use it. The digest of each tag stands in the job summary of its workflow run:

```
cosign verify \
  --certificate-identity https://github.com/kartalbas/setup-tool-images/.github/workflows/toolbox.yml@refs/tags/toolbox/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/kartalbas/toolbox@sha256:<digest>
```

## Change a tool

1. Read the new release at its source and edit its row in `versions.table`: the version, the sha256
   from the upstream's own checksum file and the address of the upstream release file. A row that
   stays behind the newest release says why in the comment above it.
2. Commit to `master`. The workflow builds the image, runs `test.sh` and pushes nothing.
3. Cut the tag and push it. The workflow builds, tests, pushes, signs and verifies:

```
git tag toolbox/v<major>.<minor>.<patch>
git push origin toolbox/v<major>.<minor>.<patch>
```

Test it on your machine before the push:

```
docker build --file toolbox/Containerfile --tag toolbox:local toolbox/
bash toolbox/test.sh toolbox:local
```
