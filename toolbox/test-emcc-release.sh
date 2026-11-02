#!/usr/bin/env bash
set -u

here=$(dirname "$0")
table=$here/versions.table

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT

cp "$here/Containerfile" "$scratch/Containerfile"
awk '$1 == "emcc" { $2 = "0.0.1"; print }' "$table" >"$scratch/versions.table"
[ "$(grep -c '^emcc ' "$scratch/versions.table")" = 1 ] || fail "$table holds no single emcc row"

status=0
docker build --progress plain --target install --file "$scratch/Containerfile" "$scratch" >"$scratch/log" 2>&1 || status=$?
cat "$scratch/log"
[ "$status" -ne 0 ] || fail "the build of an emcc row that names another release than the archive's ended with 0"
grep -q -F "versions.table: the emcc archive holds Emscripten '" "$scratch/log" || fail "the refusal does not say that the emcc archive holds another release"
grep -q -F ", not 0.0.1" "$scratch/log" || fail "the refusal does not name the planted release 0.0.1"

printf 'PASS the build refuses an emcc row whose release is not the archive'"'"'s, 1 of 1 check of toolbox/Containerfile\n'
