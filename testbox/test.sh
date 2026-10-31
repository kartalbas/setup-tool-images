#!/usr/bin/env bash
# Usage: bash testbox/test.sh <image> [versions-table]
# Holds every package of the table to its row in the image, then holds the user, the work folder and the two settings
# the browser rows read, then runs the browser as the image's own user. Exit 1 on the first difference.
set -u

image=${1:?usage: test.sh <image> [versions-table]}
table=${2:-$(dirname "$0")/versions.table}

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

run() { docker run --rm "$image" "$@" 2>&1 </dev/null; }

rows=0
while read -r name version _; do
  case "$name" in '' | '#'*) continue ;; esac
  rows=$((rows + 1))
  held=$(run dpkg-query --show "--showformat=\${db:Status-Status} \${Version}" "$name") || fail "row '$name $version': $held"
  [ "$held" = "installed $version" ] || fail "row '$name $version': the image holds '$held'"
  printf 'ok %s %s\n' "$name" "$version"
  if [ "$name" = chromium ]; then
    output=$(run chromium --version) || fail "row '$name $version': $output"
    printed=$(printf '%s\n' "$output" | grep -o -E '[0-9]+(\.[0-9]+){3}' | head -n 1)
    [ "$printed" = "${version%%-*}" ] || fail "row '$name $version': the image prints '$printed': $output"
    printf 'ok chromium prints %s\n' "$printed"
  fi
done <"$table"
[ "$rows" -gt 0 ] || fail "no row in $table"

uid=$(run id -u) || fail "id -u: $uid"
[ "$uid" = 1000 ] || fail "the image runs as uid '$uid', not 1000"
printf 'ok id -u %s\n' "$uid"

output=$(run pwd) || fail "pwd: $output"
[ "$output" = /work ] || fail "the image starts in '$output', not in /work"
output=$(run printenv HOME) || fail "HOME is not set in the image"
[ "$output" = /work ] || fail "HOME is '$output', not /work"
output=$(run sh -c 'touch /work/.write-probe && rm /work/.write-probe') || fail "/work is not writable by uid $uid: $output"
printf 'ok /work is the home and is writable\n'

for setting in REPORT_CHROMIUM_PATH=/usr/bin/chromium REPORT_CHROMIUM_ARGS=--no-sandbox,--disable-dev-shm-usage; do
  output=$(run printenv "${setting%%=*}") || fail "${setting%%=*} is not set in the image"
  [ "$output" = "${setting#*=}" ] || fail "${setting%%=*} is '$output', not '${setting#*=}'"
  printf 'ok %s\n' "$setting"
done
output=$(run sh -c '[ -x "$REPORT_CHROMIUM_PATH" ]') || fail "REPORT_CHROMIUM_PATH names no executable: $output"
printf 'ok REPORT_CHROMIUM_PATH names an executable\n'

for drawing in 'Arial=Liberation Sans' 'sans-serif=DejaVu Sans'; do
  output=$(run fc-match --format '%{family}' "${drawing%%=*}") || fail "fc-match: $output"
  [ "$output" = "${drawing#*=}" ] || fail "a page that asks for ${drawing%%=*} gets '$output', not '${drawing#*=}'"
  printf 'ok %s is drawn with %s\n' "${drawing%%=*}" "$output"
done

errors=$(mktemp) || fail "mktemp"
trap 'rm -f "$errors"' EXIT
dom=$(docker run --rm "$image" chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom 'data:text/html,<p>testbox-ok</p>' 2>"$errors" </dev/null) ||
  fail "chromium --dump-dom ended with an error: $(cat "$errors")"
case "$dom" in
  *'<body><p>testbox-ok</p></body>'*) ;;
  *) fail "chromium --dump-dom prints '$dom', not the page: $(cat "$errors")" ;;
esac
printf 'ok chromium prints testbox-ok\n'

output=$(run sh -c 'ls /versions.table') && fail "the image carries /versions.table"
printf 'ok the image carries no version table\n'

printf 'PASS %s rows in %s, image %s\n' "$rows" "$table" "$image"
