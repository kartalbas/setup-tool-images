#!/usr/bin/env bash
set -u

usage='usage: test-planted-defects.sh (--sites | <image> [redis])'
image=${1:?$usage}
group=${2:-all}
here=$(dirname "$0")
script=$here/test.sh
containerfile=$here/Containerfile
table=$here/versions.table
mode=run
[ "$image" != --sites ] || mode=sites

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT

# shellcheck source-path=SCRIPTDIR source=planted.sh
. "$here/planted.sh"

# The rows of the Redis tools, which test.sh requires, and of the named tools, in the order of the table.
table_of() {
  local out=$scratch/rows-${*// /_}.table
  awk -v names=" redis-cli redis-server ${*:+$* }" 'index(names, " " $1 " ")' "$table" >"$out"
  echo "$out"
}

row_version() { awk -v name="$1" '$1 == name { print $2 }' "$table"; }

redis_plants() {
  local series older malformed tool redis_rows
  redis_rows=$(table_of)
  series=$(sed -n 's/^ARG REDIS_VERSION=//p' "$containerfile")

  for older in 8.8 8.1; do
    sed "s/^ARG REDIS_VERSION=.*/ARG REDIS_VERSION=$older/" "$containerfile" >"$scratch/Containerfile-$older"
    differs "$containerfile" "$scratch/Containerfile-$older"
    refuses "series $older" "the image prints" "row 'redis-cli $older': the image prints" bash "$script" "$image" "$redis_rows" "$scratch/Containerfile-$older"
  done

  awk '$1 == "redis-cli" { cli = $0; next } $1 == "redis-server" { print; print cli; next } { print }' "$redis_rows" >"$scratch/server-first.table"
  differs "$redis_rows" "$scratch/server-first.table"
  refuses "series 8.8, redis-server row first" "the image prints" "row 'redis-server 8.8': the image prints" bash "$script" "$image" "$scratch/server-first.table" "$scratch/Containerfile-8.8"

  for tool in redis-cli redis-server; do
    awk -v tool="$tool" '$1 != tool' "$redis_rows" >"$scratch/without-$tool.table"
    differs "$redis_rows" "$scratch/without-$tool.table"
    refuses "no $tool row" "rows for" "holds 0 rows for $tool, not one" bash "$script" "$image" "$scratch/without-$tool.table" "$containerfile"

    awk -v tool="$tool" -v series="$series" '$1 == tool { $2 = series } { print }' "$redis_rows" >"$scratch/series-$tool.table"
    differs "$redis_rows" "$scratch/series-$tool.table"
    refuses "$tool row without the marker" "a Redis row holds the marker" "row '$tool $series': a Redis row holds the marker REDIS_VERSION" bash "$script" "$image" "$scratch/series-$tool.table" "$containerfile"
  done

  grep -v '^ARG REDIS_VERSION=' "$containerfile" >"$scratch/Containerfile-none"
  differs "$containerfile" "$scratch/Containerfile-none"
  refuses "no ARG REDIS_VERSION" "lines 'ARG REDIS_VERSION='" "holds 0 lines 'ARG REDIS_VERSION=', not one" bash "$script" "$image" "$redis_rows" "$scratch/Containerfile-none"

  sed 's/^ARG REDIS_VERSION=.*/&\n&/' "$containerfile" >"$scratch/Containerfile-two"
  differs "$containerfile" "$scratch/Containerfile-two"
  refuses "two ARG REDIS_VERSION" "lines 'ARG REDIS_VERSION='" "holds 2 lines 'ARG REDIS_VERSION=', not one" bash "$script" "$image" "$redis_rows" "$scratch/Containerfile-two"

  for malformed in 8 latest 8.10.3; do
    sed "s/^ARG REDIS_VERSION=.*/ARG REDIS_VERSION=$malformed/" "$containerfile" >"$scratch/Containerfile-$malformed"
    differs "$containerfile" "$scratch/Containerfile-$malformed"
    refuses "ARG REDIS_VERSION $malformed" "not <major>.<minor>" "ARG REDIS_VERSION is '$malformed', not <major>.<minor>" bash "$script" "$image" "$redis_rows" "$scratch/Containerfile-$malformed"
  done

  refuses "no Containerfile" "cannot read" "cannot read $scratch/absent" bash "$script" "$image" "$redis_rows" "$scratch/absent"

  cp "$containerfile" "$scratch/Containerfile-copy"
  accepts "the unchanged Containerfile and Redis rows" bash "$script" "$image" "$redis_rows" "$scratch/Containerfile-copy"
}

refuses_emcc_wrapper() {
  local name=$1 phrase=$2 expected=$3 fragment=$4
  refuses_in_planted_image "$name" "$phrase" "$expected" "$emcc_rows" <<EOF
mv /usr/local/bin/emcc /usr/local/bin/emcc.real
cat >/usr/local/bin/emcc <<'WRAPPER'
#!/bin/sh
case " \$* " in *" --version "*) exec /usr/local/bin/emcc.real "\$@" ;; esac
$fragment
exec /usr/local/bin/emcc.real "\$@"
WRAPPER
chmod 0755 /usr/local/bin/emcc
EOF
}

# The go link of the image is replaced by a wrapper that answers "go version" as the real tool and runs the fragment before any other command.
refuses_go_wrapper() {
  local name=$1 phrase=$2 expected=$3 fragment=$4
  refuses_in_planted_image "$name" "$phrase" "$expected" "$go_rows" <<EOF
rm -f /usr/local/bin/go
cat >/usr/local/bin/go <<'WRAPPER'
#!/bin/sh
case "\$1" in version) exec /usr/local/go/bin/go "\$@" ;; esac
$fragment
exec /usr/local/go/bin/go "\$@"
WRAPPER
chmod 0755 /usr/local/bin/go
EOF
}

image_plants() {
  local small three emcc_version planted_row name phrase uid
  small=$(table_of yq)
  three=$(table_of yq pg_dumpall skopeo mongod)
  emcc_rows=$(table_of emcc)
  emcc_version=$(row_version emcc)
  go_rows=$(table_of go)

  refuses "the image cannot be pulled" "cannot pull" "cannot pull registry.invalid/absent:0" bash "$script" registry.invalid/absent:0 "$small"

  for planted_row in "yq v0.0.0" "pg_dumpall 0.0" "skopeo 0.0.0-1" "mongod 0.0.0"; do
    name=${planted_row% *}
    case $name in
      skopeo) phrase="the image holds" ;;
      *) phrase="the image prints" ;;
    esac
    awk -v name="$name" -v version="${planted_row#* }" '$1 == name { $2 = version } { print }' "$three" >"$scratch/planted-$name.table"
    differs "$three" "$scratch/planted-$name.table"
    refuses "row $planted_row" "$phrase" "row '$planted_row': $phrase" bash "$script" "$image" "$scratch/planted-$name.table"
  done

  awk -v version=0.0.0 '$1 == "go" { $2 = version } { print }' "$go_rows" >"$scratch/planted-go.table"
  differs "$go_rows" "$scratch/planted-go.table"
  refuses "row go 0.0.0" "the image prints" "row 'go 0.0.0': the image prints" bash "$script" "$image" "$scratch/planted-go.table"

  { cat "$small"; echo "planted 1.0.0 00"; } >"$scratch/planted-unknown.table"
  refuses "a row without a version command" "the version command ends with an error" \
    "row 'planted 1.0.0': the version command ends with an error: this test has no version command for the row" bash "$script" "$image" "$scratch/planted-unknown.table"

  refuses_in_planted_image no-yq "the version command ends with an error" "row 'yq $(row_version yq)': the version command ends with an error" "$small" <<'EOF'
rm -f /usr/local/bin/yq
EOF

  refuses_in_planted_image no-mongod "the version command ends with an error" "row 'mongod $(row_version mongod)': the version command ends with an error" "$(table_of mongod)" <<'EOF'
rm -f /usr/bin/mongod
EOF

  refuses_in_planted_image no-mongod-row "is not in the image" "mongod is not in the image" "$small" <<'EOF'
rm -f /usr/bin/mongod
EOF

  refuses_in_planted_image mongoms-unset "does not name the image's mongod" "MONGOMS_SYSTEM_BINARY does not name the image's mongod" "$small" --change 'ENV MONGOMS_SYSTEM_BINARY=' <<'EOF'
true
EOF

  refuses_in_planted_image mongoms-version-unset "is not the version of the image's mongod" "MONGOMS_VERSION is not the version of the image's mongod" "$small" --change 'ENV MONGOMS_VERSION=' <<'EOF'
true
EOF

  refuses_in_planted_image mongoms-version-other "is not the version of the image's mongod" "MONGOMS_VERSION is not the version of the image's mongod" "$small" --change 'ENV MONGOMS_VERSION=0.0.0' <<'EOF'
true
EOF

  refuses_in_planted_image mongod-no-start "does not answer ping" "row 'mongod $(row_version mongod)': a mongod started as uid 1000 on 127.0.0.1 with no network does not answer ping" "$(table_of mongod)" <<'EOF'
mv /usr/bin/mongod /usr/bin/mongod.real
cat >/usr/bin/mongod <<'WRAPPER'
#!/bin/sh
case " $* " in *" --version "*) exec /usr/bin/mongod.real "$@" ;; esac
echo "planted: mongod does not start" >&2
exit 1
WRAPPER
chmod 0755 /usr/bin/mongod
EOF

  refuses_in_planted_image mongod-needs-network "does not answer ping" "row 'mongod $(row_version mongod)': a mongod started as uid 1000 on 127.0.0.1 with no network does not answer ping" "$(table_of mongod)" <<'EOF'
mv /usr/bin/mongod /usr/bin/mongod.real
cat >/usr/bin/mongod <<'WRAPPER'
#!/bin/sh
case " $* " in *" --version "*) exec /usr/bin/mongod.real "$@" ;; esac
[ "$(ls /sys/class/net)" != lo ] || { echo "planted: mongod needs a network" >&2; exit 1; }
exec /usr/bin/mongod.real "$@"
WRAPPER
chmod 0755 /usr/bin/mongod
EOF

  refuses_in_planted_image no-go "the version command ends with an error" "row 'go $(row_version go)': the version command ends with an error" "$go_rows" <<'EOF'
rm -f /usr/local/bin/go
EOF

  refuses_in_planted_image no-go-row "is not in the image" "go is not in the image" "$small" <<'EOF'
rm -f /usr/local/bin/go
EOF

  refuses_in_planted_image no-gofmt-row "is not in the image" "gofmt is not in the image" "$small" <<'EOF'
rm -f /usr/local/bin/gofmt
EOF

  refuses_go_wrapper go-no-build "does not build" "a one-file module as uid 1000 with no network does not build" \
    'echo "planted: go does not build" >&2; exit 1'
  # shellcheck disable=SC2016 # the fragment expands in the container's sh, not here
  refuses_go_wrapper go-uid-1000 "does not build" "a one-file module as uid 1000 with no network does not build" \
    '[ "$(id -u)" != 1000 ] || { echo "planted: uid 1000 is refused" >&2; exit 1; }'
  # shellcheck disable=SC2016 # the fragment expands in the container's sh, not here
  refuses_go_wrapper go-needs-network "does not build" "a one-file module as uid 1000 with no network does not build" \
    '[ "$(ls /sys/class/net)" != lo ] || { echo "planted: go needs a network" >&2; exit 1; }'
  # shellcheck disable=SC2016 # the fragment expands in the container's sh, not here
  refuses_go_wrapper go-wrong-output "the one-file module built" "the one-file module built as uid 1000 prints 'planted', not 'go-ok'" \
    '[ "$1" != build ] || { printf "#!/bin/sh\necho planted\n" >probe; chmod 0755 probe; exit 0; }'

  refuses_in_planted_image no-dpkg-query "dpkg-query ends with an error" "row 'skopeo $(row_version skopeo)': dpkg-query ends with an error" "$(table_of skopeo)" <<'EOF'
rm -f /usr/bin/dpkg-query
EOF

  refuses_in_planted_image emcc-git-release "emcc --version does not print" "row 'emcc $emcc_version': emcc --version does not print ' $emcc_version '" "$emcc_rows" <<EOF
printf '"%s-git"\n' '$emcc_version' >/usr/local/emcc/emscripten/emscripten-version.txt
EOF

  refuses_emcc_wrapper emcc-flto "a build with flags" "a build with flags '-O0 -flto' as uid 0 ends with an error" \
    'case " $* " in *" -flto "*) echo "planted: -flto is refused" >&2; exit 1 ;; esac'
  for uid in 0 1000 65532; do
    refuses_emcc_wrapper "emcc-uid-$uid" "a build with flags" "a build with flags '' as uid $uid ends with an error" \
      "[ \"\$(id -u)\" != $uid ] || { echo \"planted: uid $uid is refused\" >&2; exit 1; }"
  done
  refuses_emcc_wrapper emcc-wrong-output "the program built with flags" "the program built with flags '' as uid 0 prints 'planted', not 'emcc-ok'" \
    'printf "console.log(\"planted\");\n" >probe.js; exit 0'

  refuses_in_planted_image no-id "id -u:" "id -u: " "$small" <<'EOF'
rm -f /usr/bin/id
EOF
  refuses_in_planted_image user-65532 "the image runs as uid" "the image runs as uid '65532', not 1000" "$small" --change 'USER 65532' <<'EOF'
true
EOF
  refuses_in_planted_image no-pwd "pwd:" "pwd: " "$small" <<'EOF'
rm -f /usr/bin/pwd
EOF
  refuses_in_planted_image workdir-tmp "the image starts in" "the image starts in '/tmp', not in /work" "$small" --change 'WORKDIR /tmp' <<'EOF'
true
EOF
  refuses_in_planted_image work-owned-by-root "is not writable by uid" "/work is not writable by uid 1000" "$small" <<'EOF'
chown root:root /work
EOF
  refuses_in_planted_image no-jq "is not in the image" "jq is not in the image" "$small" <<'EOF'
rm -f /usr/bin/jq
EOF
  refuses_in_planted_image empty-policy "is not a non-empty file of the image" "/etc/containers/policy.json is not a non-empty file of the image" "$small" <<'EOF'
: >/etc/containers/policy.json
EOF
  refuses_in_planted_image versions-table-in-image "the image carries /versions.table" "the image carries /versions.table" "$small" <<'EOF'
touch /versions.table
EOF

  accepts_in_planted_image unchanged-copy "$table" <<'EOF'
true
EOF
}

case $group in
  all) redis_plants; image_plants; complete=yes ;;
  redis) redis_plants; complete=no ;;
  *) fail "$usage" ;;
esac
planted_report "$complete"
