# toolbox

One image with the command-line tools that build, test and check jobs call. It carries no project
source and no project script: the job that runs it brings the code.

## What is in it

The tools fetched from their upstream are the rows of [`versions.table`](versions.table): name,
version, sha256 and address. Every tool is held to its row: the build checks the sha256 of each file
before it unpacks it, and `test.sh` runs every tool and holds the printed version to the row.

The packages it adds from its Debian base are the first `apt-get install` line of the last stage of the
[`Containerfile`](Containerfile), at the base's versions, and the `skopeo` row, at the exact version it names.
The base is the `BASE` argument at the top of the `Containerfile`, held by the digest of its `linux/amd64` manifest.

The clients of the databases that jobs dump and restore are rows too, but their version is the series of the
database server they serve, not a release. Debian's archive carries one frozen series of each, so the build
installs them with apt from the vendor's own repository, which it configures in a directory of its own. The file
of such a row is the vendor's signing key: the build checks its sha256 like any other file, and apt then holds
every package to the signature of the repository. `test.sh` runs the client and holds the printed version to the
series.

| Row | Package | Serves | The row holds |
| :--- | :--- | :--- | :--- |
| `mongodump` | `mongodb-database-tools` | MongoDB 8.0 | the exact version |
| `mongosh` | `mongodb-mongosh` | MongoDB 8.0 | the exact version |
| `pg_dumpall` | `postgresql-client-18` | PostgreSQL 18 | the major, `18` |
| `redis-cli` | `redis-tools` | Redis, the series of `ARG REDIS_VERSION` | the marker `REDIS_VERSION` |
| `redis-server` | `redis-server` | Redis, the series of `ARG REDIS_VERSION` | the marker `REDIS_VERSION` |
| `mariadb` | `mariadb-client` | MariaDB 12.3 | the series, `12.3` |

MongoDB's database tools and mongosh are numbered apart from the server, and the repositories of the
series 7.0 and 8.0 carry the same builds. Their rows are therefore the exact versions, and the series is the
repository that the address of the signing key names. A database server that leaves its series needs a toolbox
cut: edit the row, and for MongoDB its key address too, then cut the tag.

The Redis series is not in the rows. It is the one `ARG REDIS_VERSION=<major>.<minor>` line of the
[`Containerfile`](Containerfile), and both Redis rows hold the marker `REDIS_VERSION` in its place. The build
pins `redis-tools` and `redis-server` to that series, and `test.sh` reads the same line to hold both
binaries to it. A project that serves Redis changes the line with its version stamp when its series
changes, so a series never has a second number to keep equal. `test.sh` stops when the line is missing,
appears twice or is not `<major>.<minor>`, and when either Redis row is missing or has no marker. The
script `test-redis-series.sh` plants each of those defects, a series older than the image, and the series
`8.1` against an image of the series `8.10`, and holds that `test.sh` refuses every one.

`emcc` is the Emscripten compiler for WebAssembly. Its row names the release archive of the SDK that
`emsdk` installs; the build unpacks it to `/usr/local/emcc`, writes its configuration there and puts the
launcher `/usr/local/bin/emcc` on the path. The archive's `emscripten-version.txt` names its release as
`<version>-git`. The build stops when that is not the row's version, and then writes the plain version
there, as `emsdk` does. A job that compiles with it finds `emcc --version` printing the row's version
between two spaces. Only `emcc` is on the path, not `em++`: a C++ source needs `-sDEFAULT_TO_CXX`.

The configuration sets `FROZEN_CACHE = True`. Without it, `emcc` writes into its cache in the image whenever
a build needs a file that the cache lacks. Only root can write there, and in a pod with a read-only root file
system not even root. With it, `emcc` never writes its cache and runs the same for every uid. It links only
the libraries that the cache holds: those the release carries, and the `-flto` variants that the build adds
with `embuilder` for a C program at `-O0`, `-O2` and `-Oz`. Their list is the `embuilder` line of the
`Containerfile`. A build that needs another library stops with "FROZEN_CACHE is set, but cache file is
missing" and the name of the file. A build that needs a port, for example `-sUSE_ZLIB=1`, stops with a
`PermissionError` in `cache/ports`, and as root with "Attempt to lock the cache but FROZEN_CACHE is set".
`test.sh` builds and runs a C program as uid 0, 1000 and 65532, without `-flto` and with it at `-O0`, `-O2`
and `-Oz`.

It runs as uid 1000 and starts in `/work`, which that user owns. `test.sh` holds both. It sets no
entrypoint: the job that runs it sets the command.

Three rows are not installed the way their package's name suggests:

- `npm` is installed from its registry tarball, offline and without install scripts, so nothing but
  the file with the checked sha256 goes in.
- `pnpm` is the standalone release file, not the npm tarball: that tarball fetches its native binary
  from the registry when it first runs, and a job without registry access would fail at that moment.
- `skopeo` is Debian's package from the base's archive, because upstream publishes no release file. Its row names the
  exact version of the package and no file: the last stage's apt call installs that version with its dependencies,
  apt holds it to the signature of the archive, and `test.sh` holds the installed package to the row. The trust policy,
  `/etc/containers/policy.json`, comes with the dependency `golang-github-containers-common`, and `test.sh` holds that
  file: skopeo refuses every copy without a policy, and its version print does not show it.

## Build and test it

```
docker build -f toolbox/Containerfile -t toolbox:local toolbox
bash toolbox/test.sh toolbox:local
bash toolbox/test-redis-series.sh toolbox:local
```

`test.sh` takes the image, then optionally a version table and a `Containerfile` in place of the two beside
it. The workflow runs the same three commands on the image it builds.

## Use it

```
docker run --rm ghcr.io/kartalbas/toolbox:<tag> <tool> --version
```

A few tools take another command: `helm version`, `kubectl version --client`, `kubeconform -v`, `rclone version`
and `gitleaks version`. `test.sh` names the command of every row.

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

The build prints messages that are no failure and that it cannot clear:

- `update-alternatives: warning: skip creation of /usr/share/man/man1/lzma.1.gz ...`, ten lines from the last stage.
  The base installs no man pages, and the `xz-utils` package links man pages that are therefore missing.
- `update-alternatives: error: no alternatives for my.cnf`, once. The postinst script of `mariadb-common` queries
  that alternative before any package has registered it, then installs it and goes on.

Clearing either would take a change to the base's dpkg configuration or to a vendor's package script.
