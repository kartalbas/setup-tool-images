#!/usr/bin/env bash
# Usage: bash toolbox/test.sh <image> [versions-table]
# Runs every tool of the table in the image as the image's own user and holds the printed version to
# its row, then holds the user, the work folder and the tools of the test pod. Exit 1 on the first difference.
set -u

image=${1:?usage: test.sh <image> [versions-table]}
table=${2:-$(dirname "$0")/versions.table}

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# A first run of an image that is not local prints docker's pull notice into the output it reads.
docker image inspect "$image" >/dev/null 2>&1 || docker pull --quiet "$image" >/dev/null || fail "cannot pull $image"

run() { docker run --rm "$image" "$@" 2>&1 </dev/null; }

version_output() { # <row name> -> what the tool prints for its version
  case "$1" in
    node) run node -v ;;
    npm) run npm -v ;;
    pnpm) run pnpm -v ;;
    dart) run dart --version ;;
    helm) run helm version --short ;;
    yq) run yq --version ;;
    promtool) run promtool --version ;;
    gitleaks) run gitleaks version ;;
    powershell) run pwsh -v ;;
    *) echo "this test has no version command for the row"; return 127 ;;
  esac
}

rows=0
while read -r name version _ _; do
  case "$name" in '' | '#'*) continue ;; esac
  rows=$((rows + 1))
  output=$(version_output "$name") || fail "row '$name $version': $output"
  printed=$(printf '%s\n' "$output" | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  [ "$printed" = "${version#v}" ] || fail "row '$name $version': the image prints '$printed': $output"
  printf 'ok %s %s (printed %s)\n' "$name" "$version" "$printed"
done <"$table"
[ "$rows" -gt 0 ] || fail "no row in $table"

uid=$(run id -u) || fail "id -u: $uid"
[ "$uid" = 1000 ] || fail "the image runs as uid '$uid', not 1000"
printf 'ok id -u %s\n' "$uid"

output=$(run pwd) || fail "pwd: $output"
[ "$output" = /work ] || fail "the image starts in '$output', not in /work"
output=$(run sh -c 'touch /work/.write-probe && rm /work/.write-probe') || fail "/work is not writable by uid $uid: $output"
printf 'ok /work is writable\n'

for tool in git jq curl openssl od tr ps python3 ssh; do
  output=$(run sh -c 'command -v "$1"' sh "$tool") || fail "$tool is not in the image"
  printf 'ok %s at %s\n' "$tool" "$output"
done

output=$(run sh -c 'ls /versions.table') && fail "the image carries /versions.table"
printf 'ok the image carries no version table\n'

printf 'PASS %s rows in %s, image %s\n' "$rows" "$table" "$image"
