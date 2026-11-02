#!/usr/bin/env bash
# Sourced by the test-planted-defects.sh scripts. The caller sets scratch, script (the test.sh whose checks are planted),
# image and mode (run, or sites for a pass that runs nothing), and defines fail.
# shellcheck disable=SC2154

phrases=$scratch/phrases
shown=$scratch/shown
: >"$phrases"
: >"$shown"
planted_runs=0
innocent_runs=0
not_red=0
refused_innocent=0

differs() {
  ! cmp -s "$1" "$2" || fail "the planted $2 equals $1"
}

# A check is named by a phrase that stands in its fail line of $script and in the refusal it prints.
refuses() {
  local label=$1 phrase=$2 expected=$3 status=0
  shift 3
  case $expected in
    *"$phrase"*) ;;
    *) fail "$label: the expected refusal '$expected' does not hold the phrase '$phrase'" ;;
  esac
  printf '%s\n' "$phrase" >>"$phrases"
  planted_runs=$((planted_runs + 1))
  [ "$mode" = run ] || return 0
  "$@" >"$scratch/log" 2>&1 || status=$?
  cat "$scratch/log"
  if [ "$status" -eq 1 ] && grep -q -F -e "$expected" "$scratch/log"; then
    printf '%s\n' "$phrase" >>"$shown"
    printf 'refused %s\n' "$label"
  else
    printf 'NOT RED %s: the planted defect ended with %s and did not print "%s"\n' "$label" "$status" "$expected" >&2
    not_red=$((not_red + 1))
  fi
}

accepts() {
  local label=$1 status=0
  shift
  innocent_runs=$((innocent_runs + 1))
  [ "$mode" = run ] || return 0
  "$@" >"$scratch/log" 2>&1 || status=$?
  cat "$scratch/log"
  if [ "$status" -eq 0 ]; then
    printf 'accepted %s\n' "$label"
  else
    printf 'REFUSED %s: the innocent run ended with %s\n' "$label" "$status" >&2
    refused_innocent=$((refused_innocent + 1))
  fi
}

mutation() { cat >"$scratch/$1.mutation"; }

# Commits a copy of $image that the mutation script, read from stdin, changed as root; the tag is left in planted_tag.
planted_image() {
  local name=$1 container
  shift
  mutation "$name"
  planted_tag=planted-$name:test
  [ "$mode" = run ] || return 0
  container=planted-$name-$$
  docker create --user 0 --name "$container" "$image" sh -c 'sh /mutation.sh && rm -f /mutation.sh' >/dev/null || fail "cannot create a container of $image"
  docker cp "$scratch/$name.mutation" "$container:/mutation.sh" || fail "cannot copy the mutation $name into $container"
  docker start --attach "$container" >/dev/null || fail "the mutation $name ends with an error"
  docker commit --change 'USER 1000' --change 'CMD ["bash"]' "$@" "$container" "$planted_tag" >/dev/null || fail "cannot commit $container"
  docker rm "$container" >/dev/null
}

refuses_in_planted_image() {
  local name=$1 phrase=$2 expected=$3 rows=$4
  shift 4
  planted_image "$name" "$@"
  refuses "$name" "$phrase" "$expected" bash "$script" "$planted_tag" "$rows"
}

accepts_in_planted_image() {
  local name=$1 rows=$2
  shift 2
  planted_image "$name" "$@"
  accepts "$name" bash "$script" "$planted_tag" "$rows"
}

# complete is yes where the planted defects must cover every check of $script, and no for one group of them.
planted_report() {
  local complete=$1 sites occurrences phrase matching count covered shown_red=0 valid problems=0 verdict
  sites=$(grep -c 'fail "' "$script")
  occurrences=$(grep -o 'fail "' "$script" | wc -l)
  [ "$sites" -eq "$occurrences" ] || fail "a line of $script calls fail twice"
  sort -u "$phrases" >"$scratch/phrases.sorted"
  : >"$scratch/lines"
  while IFS= read -r phrase; do
    matching=$(grep -n -F -e "$phrase" "$script")
    count=$(printf '%s\n' "$matching" | grep -c .)
    if [ "$count" -ne 1 ]; then
      printf 'PROBLEM the phrase "%s" stands on %s lines of %s, not one\n' "$phrase" "$count" "$script" >&2
      problems=$((problems + 1))
      continue
    fi
    case $matching in
      *'fail "'*) ;;
      *)
        printf 'PROBLEM the phrase "%s" does not stand in a fail line of %s\n' "$phrase" "$script" >&2
        problems=$((problems + 1))
        continue
        ;;
    esac
    printf '%s\n' "${matching%%:*}" >>"$scratch/lines"
    if grep -q -x -F -e "$phrase" "$shown"; then shown_red=$((shown_red + 1)); fi
  done <"$scratch/phrases.sorted"
  valid=$(wc -l <"$scratch/lines")
  covered=$(sort -u "$scratch/lines" | wc -l)
  if [ "$valid" -ne "$covered" ]; then
    printf 'PROBLEM two phrases name one check of %s\n' "$script" >&2
    problems=$((problems + 1))
  fi

  verdict=0
  [ "$problems" -eq 0 ] || verdict=1
  [ "$not_red" -eq 0 ] || verdict=1
  [ "$refused_innocent" -eq 0 ] || verdict=1
  if [ "$complete" = yes ] && [ "$covered" -ne "$sites" ]; then verdict=1; fi
  if [ "$mode" = run ] && [ "$shown_red" -ne "$covered" ]; then verdict=1; fi

  if [ "$complete" = yes ]; then
    printf '%s %s: covered %s of %s checks' "$([ "$verdict" -eq 0 ] && echo PASS || echo FAIL)" "$script" "$covered" "$sites"
  else
    printf '%s %s: covered %s checks of one group, %s checks in all' "$([ "$verdict" -eq 0 ] && echo PASS || echo FAIL)" "$script" "$covered" "$sites"
  fi
  if [ "$mode" = run ]; then
    printf ', shown red %s of %s; %s planted defects, %s innocent runs\n' "$shown_red" "$covered" "$planted_runs" "$innocent_runs"
  else
    printf ', shown red 0 of %s (nothing ran)\n' "$covered"
  fi
  return "$verdict"
}
