# testbox

The [toolbox](../toolbox/README.md) image plus a headless Chromium, make and the locale en_US.UTF-8,
for the test jobs that need a browser and the build jobs that compile with the toolbox's emcc. It carries no project source and no project script: the job that runs it brings the code.

## What is in it

The base is the published toolbox image, the `BASE` argument at the top of the
[`Containerfile`](Containerfile), held by its digest. Everything the toolbox holds is in it, at the
toolbox's versions.

The rows of [`versions.table`](versions.table) are the Debian packages added to it: name and exact
version. The `Containerfile` installs each row as `<name>=<version>` without recommended packages,
and apt verifies the archive signatures. The table says where each version was read. `test.sh` holds
every package to its row, holds the version that `chromium --version` prints to the `chromium` row and
holds the versions that `pdftotext -v` and `pdftoppm -v` print to the `poppler-utils` row.

- `chromium` is Debian's own package from the suite of the base, trixie with its security updates.
- `fonts-dejavu-core` and `fonts-liberation` are the only fonts added. DejaVu is the font that
  fontconfig prefers for `sans-serif`, `serif` and `monospace`; with Liberation alone, a page that asks
  for `system-ui` gets the letter widths of a monospace font. Liberation draws the pages that name Arial, Helvetica,
  Times New Roman or Courier New with the same letter widths. `test.sh` holds that `fc-match` names
  DejaVu Sans for `sans-serif` and Liberation Sans for `Arial`.
- `locales` is Debian's own package from trixie, at the version of the base's `libc-bin`, which it
  depends on exactly. The `Containerfile` compiles the one locale `en_US.UTF-8` from it, and `test.sh`
  holds the image to it: a test of a push gate sorts a list in that locale to show that it is not in
  byte order.
- `make` is Debian's own package from trixie. A build that compiles C sources with the toolbox's
  `emcc` runs it.
- `poppler-utils` is Debian's own package from trixie. It carries `pdftotext` and `pdftoppm`, which a job
  that tests the text and the pages of a PDF runs.

The image sets two variables for the jobs that start the browser:

| Variable | Value |
| :--- | :--- |
| `REPORT_CHROMIUM_PATH` | `/usr/bin/chromium` |
| `REPORT_CHROMIUM_ARGS` | `--no-sandbox,--disable-dev-shm-usage` |

The arguments are separated by commas. In a default container the browser finds no usable sandbox and
stops without `--no-sandbox`, and Docker's default `/dev/shm` of 64 MB is too small for it, which is
why `--disable-dev-shm-usage` is there.

A job that drives the browser with Playwright installs Playwright itself and passes
`REPORT_CHROMIUM_PATH` as `executablePath`: the image holds no Playwright and no Playwright browser.

It runs as uid 1000, starts in `/work` and has `/work` as its home, which that user owns. `test.sh`
holds all three, and holds that the browser renders a page: `chromium --headless --dump-dom` on a
`data:` page prints that page's text. It sets no entrypoint: the job that runs it sets the command.
The `Containerfile` copies `versions.table` in for the install step and deletes it in that step, and
`test.sh` holds that no `/versions.table` is left in the filesystem. The copy stays in the layer of
its `COPY` instruction.

`test.sh` does not run the tools of the toolbox: the toolbox's own `test.sh` holds those, and the workflow
runs it against this image too.

## Use it

```
docker run --rm ghcr.io/kartalbas/testbox:<tag> chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom 'data:text/html,<p>ok</p>'
```

Verify it before you use it. The digest of each tag stands in the job summary of its workflow run:

```
cosign verify \
  --certificate-identity https://github.com/kartalbas/setup-tool-images/.github/workflows/testbox.yml@refs/tags/testbox/v<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/kartalbas/testbox@sha256:<digest>
```

## Change a package

1. Read the newest version at its source, the page `https://packages.debian.org/trixie/<name>` and
   the `Packages` index of the suite it names, and edit its row in `versions.table`. A security
   update replaces the version before it in the archive, so the build stops at the row of a package
   that has one until the row is edited.
2. Commit to `master`. The workflow builds the image, runs `test.sh` and pushes nothing.
3. Cut the tag and push it. The workflow builds, tests, pushes, signs and verifies:

```
git tag testbox/v<major>.<minor>.<patch>
git push origin testbox/v<major>.<minor>.<patch>
```

A new toolbox is taken in by editing the tag and the digest of `BASE` in the `Containerfile`.

The tests run on GitHub's runners, in the workflow, and never on a development machine: nothing here builds or
runs the image locally. After the build, the workflow runs `test.sh`, the toolbox's `test.sh` and
`test-planted-defects.sh`. That script plants one defect for every check of `test.sh` (a wrong row, or a copy of the
image changed as root) and holds that `test.sh` ends with exit 1 and a message that names the check. It prints how
many checks it covered and in how many of them it showed the refusal, and it fails when a check has no planted
defect. The argument `--sites` runs the coverage count alone, which needs no image. The workflow then runs the
Redis group of the toolbox's `test-planted-defects.sh` on this image.

The build prints one warning, from `update-alternatives`: it skips the man page link of `open`,
because the base installs no man pages. That link comes from `xdg-utils`, which `chromium-common`
depends on.
