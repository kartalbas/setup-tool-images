#!/usr/bin/env bash
set -u

image=${1:?usage: test.sh <image> [versions-table [containerfile]]}
table=${2:-$(dirname "$0")/versions.table}
containerfile=${3:-$(dirname "$0")/Containerfile}

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# A first run of an image that is not local prints docker's pull notice into the output it reads.
docker image inspect "$image" >/dev/null 2>&1 || docker pull --quiet "$image" >/dev/null || fail "cannot pull $image"

run() { docker run --rm "$image" "$@" 2>&1 </dev/null; }

version_output() {
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
    kubectl) run kubectl version --client ;;
    kubeconform) run kubeconform -v ;;
    rclone) run rclone version ;;
    skopeo) run skopeo --version ;;
    mongodump) run mongodump --version ;;
    mongosh) run mongosh --version ;;
    pg_dumpall) run pg_dumpall --version ;;
    redis-cli) run redis-cli --version ;;
    redis-server) run redis-server --version ;;
    mariadb) run mariadb --version ;;
    *) echo "this test has no version command for the row"; return 127 ;;
  esac
}

holds() {
  local printed=$1 wanted=${2#v}
  case "$wanted" in
    *.*.*) [ "$printed" = "$wanted" ] ;;
    *) [[ "$printed" == "$wanted".* ]] ;;
  esac
}

[ -r "$containerfile" ] || fail "cannot read $containerfile"
redis_arguments=$(grep -c -E '^ARG REDIS_VERSION=' "$containerfile")
[ "$redis_arguments" = 1 ] || fail "$containerfile holds $redis_arguments lines 'ARG REDIS_VERSION=', not one"
redis_series=$(sed -n 's/^ARG REDIS_VERSION=//p' "$containerfile")
[[ "$redis_series" =~ ^[0-9]+\.[0-9]+$ ]] || fail "$containerfile: ARG REDIS_VERSION is '$redis_series', not <major>.<minor>"
for tool in redis-cli redis-server; do
  redis_rows=$(awk -v tool="$tool" '$1 == tool' "$table" | wc -l)
  [ "$redis_rows" = 1 ] || fail "$table holds $redis_rows rows for $tool, not one"
done

rows=0
while read -r name version sha256 _; do
  case "$name" in '' | '#'*) continue ;; esac
  rows=$((rows + 1))
  case "$name" in
    redis-cli | redis-server)
      [ "$version" = REDIS_VERSION ] || fail "row '$name $version': a Redis row holds the marker REDIS_VERSION"
      version=$redis_series ;;
  esac
  output=$(version_output "$name") || fail "row '$name $version': $output"
  printed=$(printf '%s\n' "$output" | grep -o -E '[0-9]+(\.[0-9]+)+' | head -n 1)
  if [ -z "$sha256" ]; then
    held=$(run dpkg-query --show "--showformat=\${db:Status-Status} \${Version}" "$name") || fail "row '$name $version': $held"
    [ "$held" = "installed $version" ] || fail "row '$name $version': the image holds '$held'"
  else
    holds "$printed" "$version" || fail "row '$name $version': the image prints '$printed': $output"
  fi
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

run sh -c 'test -f /etc/containers/policy.json && test -s /etc/containers/policy.json' >/dev/null || fail "/etc/containers/policy.json is not a non-empty file of the image, and skopeo refuses every copy without a trust policy"
printf 'ok /etc/containers/policy.json is a non-empty file\n'

output=$(run sh -c 'ls /versions.table') && fail "the image carries /versions.table"
printf 'ok the image carries no version table\n'

printf 'PASS %s rows in %s, image %s\n' "$rows" "$table" "$image"
