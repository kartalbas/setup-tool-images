#!/usr/bin/env bash
set -u

image=${1:?usage: test-redis-series.sh <image>}
here=$(dirname "$0")
containerfile=$here/Containerfile
table=$here/versions.table

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

series=$(sed -n 's/^ARG REDIS_VERSION=//p' "$containerfile")

plant() {
  local original=$1 planted=$2
  ! cmp -s "$original" "$planted" || fail "the planted $planted equals $original"
}

refuses() {
  local label=$1 expected=$2 planted_containerfile=$3 planted_table=$4 status=0
  bash "$here/test.sh" "$image" "$planted_table" "$planted_containerfile" >"$scratch/log" 2>&1 || status=$?
  cat "$scratch/log"
  [ "$status" -eq 1 ] || fail "$label: the planted defect ended with $status, not 1"
  grep -q -F -e "$expected" "$scratch/log" || fail "$label: the refusal does not say '$expected'"
  printf 'refused %s\n' "$label"
}

for older in 8.8 8.1; do
  sed "s/^ARG REDIS_VERSION=.*/ARG REDIS_VERSION=$older/" "$containerfile" >"$scratch/Containerfile-$older"
  plant "$containerfile" "$scratch/Containerfile-$older"
  refuses "series $older" "row 'redis-cli $older': the image prints" "$scratch/Containerfile-$older" "$table"
done

awk '$1 == "redis-cli" { cli = $0; next } $1 == "redis-server" { print; print cli; next } { print }' "$table" >"$scratch/server-first.table"
plant "$table" "$scratch/server-first.table"
refuses "series 8.8, redis-server row first" "row 'redis-server 8.8': the image prints" "$scratch/Containerfile-8.8" "$scratch/server-first.table"

for tool in redis-cli redis-server; do
  awk -v tool="$tool" '$1 != tool' "$table" >"$scratch/without-$tool.table"
  plant "$table" "$scratch/without-$tool.table"
  refuses "no $tool row" "holds 0 rows for $tool, not one" "$containerfile" "$scratch/without-$tool.table"

  awk -v tool="$tool" -v series="$series" '$1 == tool { $2 = series } { print }' "$table" >"$scratch/series-$tool.table"
  plant "$table" "$scratch/series-$tool.table"
  refuses "$tool row without the marker" "row '$tool $series': a Redis row holds the marker REDIS_VERSION" "$containerfile" "$scratch/series-$tool.table"
done

grep -v '^ARG REDIS_VERSION=' "$containerfile" >"$scratch/Containerfile-none"
plant "$containerfile" "$scratch/Containerfile-none"
refuses "no ARG REDIS_VERSION" "holds 0 lines 'ARG REDIS_VERSION=', not one" "$scratch/Containerfile-none" "$table"

sed 's/^ARG REDIS_VERSION=.*/&\n&/' "$containerfile" >"$scratch/Containerfile-two"
plant "$containerfile" "$scratch/Containerfile-two"
refuses "two ARG REDIS_VERSION" "holds 2 lines 'ARG REDIS_VERSION=', not one" "$scratch/Containerfile-two" "$table"

for malformed in 8 latest 8.10.3; do
  sed "s/^ARG REDIS_VERSION=.*/ARG REDIS_VERSION=$malformed/" "$containerfile" >"$scratch/Containerfile-$malformed"
  plant "$containerfile" "$scratch/Containerfile-$malformed"
  refuses "ARG REDIS_VERSION $malformed" "ARG REDIS_VERSION is '$malformed', not <major>.<minor>" "$scratch/Containerfile-$malformed" "$table"
done

refuses "no Containerfile" "cannot read $scratch/absent" "$scratch/absent" "$table"

cp "$containerfile" "$scratch/Containerfile-copy"
cp "$table" "$scratch/copy.table"
bash "$here/test.sh" "$image" "$scratch/copy.table" "$scratch/Containerfile-copy" || fail "the unchanged copies are refused"

printf 'PASS every planted Redis defect was refused, the unchanged copies passed, image %s\n' "$image"
