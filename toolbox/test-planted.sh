#!/usr/bin/env bash
# shellcheck disable=SC2016
set -u

here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT

cat >"$scratch/fake-test.sh" <<'EOF'
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
[ "${1:-}" != a ] || fail "alpha is wrong"
[ "${1:-}" != b ] || fail "beta is wrong"
EOF

cat >"$scratch/prelude.sh" <<EOF
set -u
scratch=\$1
script=\$scratch/fake-test.sh
mode=\${2:-run}
fail() { printf 'FAIL %s\n' "\$*" >&2; exit 1; }
. "$here/planted.sh"
fake() { bash "\$script" "\$@"; }
EOF

cases=0

# case <label> <wanted exit status> <wanted text in the output> <body>
case_runs() {
  local label=$1 wanted=$2 text=$3 body=$4 status=0
  cases=$((cases + 1))
  { cat "$scratch/prelude.sh"; printf '%s\n' "$body"; } >"$scratch/case.sh"
  bash "$scratch/case.sh" "$scratch" ${5:+"$5"} >"$scratch/output" 2>&1 || status=$?
  if [ "$status" -ne "$wanted" ]; then
    cat "$scratch/output"
    printf 'FAIL case "%s" ended with %s, not %s\n' "$label" "$status" "$wanted" >&2
    exit 1
  fi
  grep -q -F -e "$text" "$scratch/output" || { cat "$scratch/output"; printf 'FAIL case "%s" did not print "%s"\n' "$label" "$text" >&2; exit 1; }
}

case_runs "every planted defect red, the innocent run green" 0 "PASS" '
refuses alpha "alpha is wrong" "alpha is wrong" fake a
refuses beta "beta is wrong" "beta is wrong" fake b
accepts innocent fake
planted_report yes'

case_runs "a planted defect that ends green" 1 "NOT RED alpha" '
refuses alpha "alpha is wrong" "alpha is wrong" fake c
refuses beta "beta is wrong" "beta is wrong" fake b
planted_report yes'

case_runs "a planted defect that names another check" 1 "NOT RED alpha" '
refuses alpha "alpha is wrong" "alpha is wrong" fake b
refuses beta "beta is wrong" "beta is wrong" fake b
planted_report yes'

case_runs "a planted defect that ends with 2" 1 "NOT RED alpha" '
refuses alpha "alpha is wrong" "alpha is wrong" bash -c "echo alpha is wrong; exit 2"
refuses beta "beta is wrong" "beta is wrong" fake b
planted_report yes'

case_runs "a check without a planted defect" 1 "covered 1 of 2 checks" '
refuses alpha "alpha is wrong" "alpha is wrong" fake a
planted_report yes'

case_runs "one group of the planted defects" 0 "covered 1 checks of one group, 2 checks in all" '
refuses alpha "alpha is wrong" "alpha is wrong" fake a
planted_report no'

case_runs "an innocent run that is refused" 1 "REFUSED innocent" '
refuses alpha "alpha is wrong" "alpha is wrong" fake a
refuses beta "beta is wrong" "beta is wrong" fake b
accepts innocent fake a
planted_report yes'

case_runs "a phrase that stands in no check" 1 'the phrase "gamma is wrong" stands on 0 lines' '
refuses alpha "alpha is wrong" "alpha is wrong" fake a
refuses beta "beta is wrong" "beta is wrong" fake b
refuses gamma "gamma is wrong" "gamma is wrong" fake a
planted_report yes'

case_runs "a phrase that stands in two checks" 1 'the phrase "is wrong" stands on 2 lines' '
refuses alpha "alpha is wrong" "alpha is wrong" fake a
refuses beta "beta is wrong" "beta is wrong" fake b
refuses both "is wrong" "alpha is wrong" fake a
planted_report yes'

case_runs "two phrases for one check" 1 "two phrases name one check" '
refuses alpha "alpha is wrong" "alpha is wrong" fake a
refuses alpha-again "alpha is" "alpha is wrong" fake a
refuses beta "beta is wrong" "beta is wrong" fake b
planted_report yes'

case_runs "an expected refusal that lacks its phrase" 1 "does not hold the phrase" '
refuses alpha "alpha is wrong" "beta is wrong" fake a'

case_runs "a planted file that equals the original" 1 "equals" '
differs "$script" "$script"'

case_runs "a pass that runs nothing" 0 "shown red 0 of 2 (nothing ran)" '
refuses alpha "alpha is wrong" "alpha is wrong" false
refuses beta "beta is wrong" "beta is wrong" false
planted_report yes' sites

printf 'PASS %s cases of the planted-defect library\n' "$cases"
