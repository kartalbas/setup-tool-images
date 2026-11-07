#!/usr/bin/env bash
# shellcheck disable=SC2016
set -u

usage='usage: test-planted-defects.sh (--sites | <image>)'
image=${1:?$usage}
here=$(dirname "$0")
script=$here/test.sh
table=$here/versions.table
mode=run
[ "$image" != --sites ] || mode=sites

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT

# shellcheck source-path=SCRIPTDIR source=../toolbox/planted.sh
. "$here/../toolbox/planted.sh"

row_version() { awk -v name="$1" '$1 == name { print $2 }' "$table"; }

refuses_in_wrapper() {
  local name=$1 phrase=$2 expected=$3 tool=$4 fragment=$5
  refuses_in_planted_image "$name" "$phrase" "$expected" "$table" <<EOF
cat >/usr/local/bin/$tool <<'WRAPPER'
#!/bin/sh
$fragment
exec /usr/bin/$tool "\$@"
WRAPPER
chmod 0755 /usr/local/bin/$tool
EOF
}

chromium_version=$(row_version chromium)
poppler_version=$(row_version poppler-utils)

refuses "the image cannot be pulled" "cannot pull" "cannot pull registry.invalid/absent:0" bash "$script" registry.invalid/absent:0 "$table"

for name in chromium poppler-utils; do
  awk -v name="$name" '$1 == name { $2 = "0.0.0-1" } { print }' "$table" >"$scratch/planted-$name.table"
  differs "$table" "$scratch/planted-$name.table"
  refuses "row $name 0.0.0-1" "the image holds" "row '$name 0.0.0-1': the image holds" bash "$script" "$image" "$scratch/planted-$name.table"
done

printf '# a table with no row\n' >"$scratch/no-row.table"
refuses "a table with no row" "no row in" "no row in $scratch/no-row.table" bash "$script" "$image" "$scratch/no-row.table"

refuses_in_planted_image no-dpkg-query "dpkg-query ends with an error" "row 'chromium $chromium_version': dpkg-query ends with an error" "$table" <<'EOF'
rm -f /usr/bin/dpkg-query
EOF

refuses_in_planted_image no-chromium "chromium --version ends with an error" "row 'chromium $chromium_version': chromium --version ends with an error" "$table" <<'EOF'
rm -f /usr/bin/chromium
EOF

refuses_in_wrapper chromium-prints-another-version "the image prints" "row 'chromium $chromium_version': the image prints '1.2.3.4'" chromium \
  'case " $* " in *" --version "*) echo "Chromium 1.2.3.4"; exit 0 ;; esac'

refuses_in_planted_image no-pdftotext "-v ends with an error" "row 'poppler-utils $poppler_version': pdftotext -v ends with an error" "$table" <<'EOF'
rm -f /usr/bin/pdftotext
EOF

refuses_in_wrapper pdftotext-prints-another-version "-v prints" "row 'poppler-utils $poppler_version': pdftotext -v prints '1.2.3'" pdftotext \
  'echo "pdftotext version 1.2.3" >&2; exit 0'

refuses_in_planted_image no-locale "locale -a ends with an error" "locale -a ends with an error: " "$table" <<'EOF'
rm -f /usr/bin/locale
EOF
refuses_in_planted_image no-en-us-locale "the image has no locale en_US.UTF-8" "the image has no locale en_US.UTF-8: " "$table" <<'EOF'
rm -f /usr/lib/locale/locale-archive
EOF

refuses_in_planted_image no-id "id -u:" "id -u: " "$table" <<'EOF'
rm -f /usr/bin/id
EOF
refuses_in_planted_image user-65532 "the image runs as uid" "the image runs as uid '65532', not 1000" "$table" --change 'USER 65532' <<'EOF'
true
EOF
refuses_in_planted_image no-pwd "pwd:" "pwd: " "$table" <<'EOF'
rm -f /usr/bin/pwd
EOF
refuses_in_planted_image workdir-tmp "the image starts in" "the image starts in '/tmp', not in /work" "$table" --change 'WORKDIR /tmp' <<'EOF'
true
EOF

# Docker never leaves HOME unset, so the planted printenv is the only way to reach the refusal.
refuses_in_wrapper printenv-without-home "HOME is not set" "HOME is not set in the image" printenv \
  '[ "$1" != HOME ] || exit 1'
refuses_in_planted_image home-in-tmp "HOME is '" "HOME is '/tmp', not /work" "$table" <<'EOF'
sed -i 's#:/work:#:/tmp:#' /etc/passwd
EOF
refuses_in_planted_image work-owned-by-root "is not writable by uid" "/work is not writable by uid 1000" "$table" <<'EOF'
chown root:root /work
EOF
refuses_in_wrapper printenv-without-chromium-path "the image does not set" "the image does not set REPORT_CHROMIUM_PATH" printenv \
  '[ "$1" != REPORT_CHROMIUM_PATH ] || exit 1'
refuses_in_planted_image chromium-arguments "the image sets" "the image sets REPORT_CHROMIUM_ARGS to '--planted', not '--no-sandbox,--disable-dev-shm-usage'" "$table" --change 'ENV REPORT_CHROMIUM_ARGS=--planted' <<'EOF'
true
EOF

# The copy at /usr/local/bin keeps chromium running for the rows, which come before this check.
refuses_in_planted_image chromium-not-executable "names no executable" "REPORT_CHROMIUM_PATH names no executable" "$table" <<'EOF'
cp -p /usr/bin/chromium /usr/local/bin/chromium
chmod 0644 /usr/bin/chromium
EOF

refuses_in_planted_image no-fc-match "fc-match:" "fc-match: " "$table" <<'EOF'
rm -f /usr/bin/fc-match
EOF
refuses_in_planted_image no-liberation-fonts "a page that asks for" "a page that asks for Arial gets" "$table" <<'EOF'
rm -rf /usr/share/fonts/truetype/liberation
fc-cache --force
EOF

refuses "no file for the errors of chromium" "mktemp" "FAIL mktemp" env TMPDIR="$scratch/absent" bash "$script" "$image" "$table"
refuses_in_wrapper chromium-dump-dom-fails "ended with an error" "chromium --dump-dom ended with an error" chromium \
  'case " $* " in *" --dump-dom "*) echo "planted: chromium does not start" >&2; exit 1 ;; esac'
refuses_in_wrapper chromium-dump-dom-prints-another-page "dump-dom prints" "chromium --dump-dom prints '<html><head></head><body><p>planted</p></body></html>', not the page" chromium \
  'case " $* " in *" --dump-dom "*) echo "<html><head></head><body><p>planted</p></body></html>"; exit 0 ;; esac'

refuses_in_planted_image versions-table-in-image "the image carries /versions.table" "the image carries /versions.table" "$table" <<'EOF'
touch /versions.table
EOF

accepts_in_planted_image unchanged-copy "$table" <<'EOF'
true
EOF

planted_report yes
