# testbox

The [toolbox](../toolbox/README.md) image plus a headless Chromium, for the test jobs that need a
browser. It carries no project source and no project script: the job that runs it brings the code.

## What is in it

The base is the published toolbox image, the `BASE` argument at the top of the
[`Containerfile`](Containerfile), held by its digest. Everything the toolbox holds is in it, at the
toolbox's versions.

The rows of [`versions.table`](versions.table) are the Debian packages added to it: name and exact
version. The `Containerfile` installs each row as `<name>=<version>` without recommended packages,
and apt verifies the archive signatures. The table says where each version was read. `test.sh` holds
every package to its row and holds the version that `chromium --version` prints to the `chromium` row.

- `chromium` is Debian's own package from the suite of the base, trixie with its security updates.
- `fonts-dejavu-core` and `fonts-liberation` are the only fonts added. DejaVu is the font that
  fontconfig prefers for `sans-serif`, `serif` and `monospace`; with Liberation alone, a page that asks
  for `system-ui` gets the letter widths of a monospace font. Liberation draws the pages that name Arial, Helvetica,
  Times New Roman or Courier New with the same letter widths. `test.sh` holds that `fc-match` names
  DejaVu Sans for `sans-serif` and Liberation Sans for `Arial`.

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

`test.sh` does not run the tools of the toolbox: the toolbox's own `test.sh` holds those.

## Use it

```
docker run --rm ghcr.io/kartalbas/testbox:<tag> chromium --headless --dump-dom 'data:text/html,<p>ok</p>'
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

Test it on your machine before the push:

```
docker build --file testbox/Containerfile --tag testbox:local testbox/
bash testbox/test.sh testbox:local
```
