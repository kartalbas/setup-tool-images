#!/usr/bin/env bash
set -u

image=${1:?usage: test.sh <image> [versions-table [containerfile]]}
table=${2:-$(dirname "$0")/versions.table}
containerfile=${3:-$(dirname "$0")/Containerfile}

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# A first run of an image that is not local prints docker's pull notice into the output it reads.
docker image inspect "$image" >/dev/null 2>&1 || docker pull --quiet "$image" >/dev/null || fail "cannot pull $image"

run() { docker run --rm "$image" "$@" 2>&1 </dev/null; }

run_as() { local user=$1; shift; docker run --rm --user "$user" "$image" "$@" 2>&1 </dev/null; }

version_output() {
  case "$1" in
    node) run node -v ;;
    npm) run npm -v ;;
    pnpm) run pnpm -v ;;
    dart) run dart --version ;;
    go) run go version ;;
    helm) run helm version --short ;;
    yq) run yq --version ;;
    promtool) run promtool --version ;;
    gitleaks) run gitleaks version ;;
    powershell) run pwsh -v ;;
    kubectl) run kubectl version --client ;;
    kubeconform) run kubeconform -v ;;
    rclone) run rclone version ;;
    emcc) run emcc --version ;;
    skopeo) run skopeo --version ;;
    mongodump) run mongodump --version ;;
    mongosh) run mongosh --version ;;
    mongod) run mongod --version ;;
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
  output=$(version_output "$name") || fail "row '$name $version': the version command ends with an error: $output"
  printed=$(printf '%s\n' "$output" | grep -o -E '[0-9]+(\.[0-9]+)+' | head -n 1)
  if [ -z "$sha256" ]; then
    held=$(run dpkg-query --show "--showformat=\${db:Status-Status} \${Version}" "$name") || fail "row '$name $version': dpkg-query ends with an error: $held"
    [ "$held" = "installed $version" ] || fail "row '$name $version': the image holds '$held'"
  else
    holds "$printed" "$version" || fail "row '$name $version': the image prints '$printed': $output"
  fi
  printf 'ok %s %s (printed %s)\n' "$name" "$version" "$printed"
  if [ "$name" = emcc ]; then
    # A job that checks the compiler matches the version between two spaces in the output of emcc --version.
    case "$output" in
      *" $version "*) ;;
      *) fail "row '$name $version': emcc --version does not print ' $version ': $output" ;;
    esac
    for emcc_user in 0 1000 65532; do
      for emcc_flags in "" "-O0 -flto" "-O2 -flto" "-Oz -flto"; do
        # shellcheck disable=SC2016 # the script expands in the container's sh
        built=$(run_as "$emcc_user" sh -c 'cd "$(mktemp -d)" && printf "#include <stdio.h>\nint main(void) { puts(\"emcc-ok\"); return 0; }\n" >probe.c && emcc $1 probe.c -o probe.js && node probe.js' sh "$emcc_flags") ||
          fail "row '$name $version': a build with flags '$emcc_flags' as uid $emcc_user ends with an error: $built"
        [ "$built" = emcc-ok ] || fail "row '$name $version': the program built with flags '$emcc_flags' as uid $emcc_user prints '$built', not 'emcc-ok'"
        printf "ok emcc builds and runs a program with flags '%s' as uid %s\n" "$emcc_flags" "$emcc_user"
      done
    done
  fi
  if [ "$name" = mongod ]; then
    # A test pod runs as uid 1000 and its fence admits only the hosts the Manager lists, so the server has to start with neither root nor a network.
    answer=$(docker run --rm --network none --user 1000 "$image" sh -c 'd=$(mktemp -d) && mongod --dbpath "$d" --bind_ip 127.0.0.1 --port 27017 --fork --logpath "$d/mongod.log" >/dev/null && mongosh --quiet --port 27017 --eval "db.runCommand({ping: 1}).ok"' 2>&1 </dev/null) && [ "$answer" = 1 ] ||
      fail "row '$name $version': a mongod started as uid 1000 on 127.0.0.1 with no network does not answer ping: $answer"
    printf 'ok mongod answers ping as uid 1000 with no network\n'
  fi
  if [ "$name" = go ]; then
    # A test pod runs as uid 1000. This module imports only the standard library, so it needs no network; a real build downloads its modules through the hosts of the Manager's fence.
    built=$(docker run --rm --network none --user 1000 "$image" sh -c 'd=$(mktemp -d) && cd "$d" && export HOME="$d" GOCACHE="$d/cache" && printf "module probe\n\ngo 1.24\n" >go.mod && printf "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"go-ok\") }\n" >main.go && go build -buildvcs=false -o probe . && ./probe' 2>&1 </dev/null) ||
      fail "row '$name $version': a one-file module as uid 1000 with no network does not build: $built"
    [ "$built" = go-ok ] || fail "row '$name $version': the one-file module built as uid 1000 prints '$built', not 'go-ok'"
    printf 'ok go builds and runs a one-file module as uid 1000 with no network\n'
  fi
done <"$table"

uid=$(run id -u) || fail "id -u: $uid"
[ "$uid" = 1000 ] || fail "the image runs as uid '$uid', not 1000"
printf 'ok id -u %s\n' "$uid"

output=$(run pwd) || fail "pwd: $output"
[ "$output" = /work ] || fail "the image starts in '$output', not in /work"
output=$(run sh -c 'touch /work/.write-probe && rm /work/.write-probe') || fail "/work is not writable by uid $uid: $output"
printf 'ok /work is writable\n'

for tool in git jq curl openssl od tr ps python3 ssh mongod go gofmt; do
  output=$(run sh -c 'command -v "$1"' sh "$tool") || fail "$tool is not in the image"
  printf 'ok %s at %s\n' "$tool" "$output"
done

run sh -c 'test -f /etc/containers/policy.json && test -s /etc/containers/policy.json' >/dev/null || fail "/etc/containers/policy.json is not a non-empty file of the image, and skopeo refuses every copy without a trust policy"
printf 'ok /etc/containers/policy.json is a non-empty file\n'

output=$(run sh -c 'ls /versions.table') && fail "the image carries /versions.table"
printf 'ok the image carries no version table\n'

printf 'PASS %s rows in %s, image %s\n' "$rows" "$table" "$image"
