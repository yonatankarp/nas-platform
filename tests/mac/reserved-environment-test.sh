#!/bin/sh
# tests/mac/run.sh refuses to start on three classes of preset environment, and
# until #677 nothing asserted any of it: one `grep -rl` for the three refusal
# messages found the file that raises them and nothing else. So the whole block
# could have been deleted, or one variable dropped from the middle chain, and
# every check in the repository stayed green.
#
# The middle guard is the one that matters. It covers eleven Ruby and Bundler
# variables, and run.sh decrypts a vault: every one of them loads code into Ruby
# before the script's first line. It is not theoretical either -- in #643 an
# exported RUBYOPT=-EUTF-8 from tests/validate-policy.sh reached this guard, and
# the guard is what turned it into a red `static (3)` rather than a Mac proof
# running with an injected Ruby startup flag. That is also why the gate still
# sets RUBYOPT per check instead of exporting it once.
#
# WHY A PER-VARIABLE CASE AND NOT ONE CASE PER GUARD. Each guard is a long `&&`
# chain ending in a single `||`, and that shape fails quietly in one direction:
# drop a `[ -z ... ] &&` term and the chain still evaluates, still refuses every
# variable it still names, and its one refusal message is unchanged. A case per
# guard would keep passing across exactly that hole. So each of the eighteen
# variables is set on its own and required to produce its guard's message.
#
# THE SET IS CLOSED IN BOTH DIRECTIONS, which the per-variable cases alone do
# not do: they prove these eighteen are refused, not that these eighteen are all
# of them. Guard 3 has already churned -- 02d60e23 took it from about thirty
# names to six -- so a nineteenth name added to a chain with no row here would be
# the same silent hole arriving from the other side. The table below is compared
# against the names parsed out of run.sh in both directions, under a floor,
# because a parse that matches nothing must be loud rather than green.
#
# This test is portable despite driving run.sh, which the comment in
# tests/mac/run-phase-status-test.sh says requires Darwin. That requirement is
# at run.sh:592, inside the preflight phase; these guards are at 37-51, before
# argument parsing. Every invocation here dies far above it, which is also what
# makes the check cheap: each one ends in a refusal and waits for nothing.
# Measured in a Linux container rather than asserted -- 36ms for the plain run's
# twenty invocations and 753ms for the self-test's three hundred and sixty-one.
# The #319 lesson about READY_TIMEOUT_SECONDS applies in reverse: there is no
# wait here to spread across a shard, so neither line competes for a worker slot
# it is not using.
set -eu
set +x

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
runner_path=$mac_test_dir/run.sh

self_test=false
case ${1-} in
  --self-test) self_test=true ;;
  '') ;;
  *) printf 'usage: reserved-environment-test.sh [--self-test]\n' >&2; exit 2 ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-reserved-env.XXXXXX")
scratch=$(CDPATH= cd -- "$scratch" && pwd -P)
cleanup_scratch() {
  scratch_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$scratch" ] && [ ! -L "$scratch" ]; then
    find "$scratch" -depth -mindepth 1 -delete
    rmdir -- "$scratch"
  fi
  exit "$scratch_status"
}
trap cleanup_scratch EXIT HUP INT TERM

# Each row is a reserved variable and the refusal its guard raises. The three
# messages are what partitions the eighteen into their guards, so a variable
# that moves between chains fails here until this table moves with it.
#
# Written to a file rather than held in a variable because every loop over it
# below reads it by redirection: a `printf | while` loop is a subshell, and a
# case that needed to fail the run from inside one would be reporting its
# failure to a shell that has already exited.
cat > "$scratch/table" <<'TABLE'
PLATFORM_PROOF_PLATFORM reserved proof platform environment must be unset
RUBYOPT reserved language startup environment must be unset
RUBYLIB reserved language startup environment must be unset
RUBYGEMS_GEMDEPS reserved language startup environment must be unset
GEM_HOME reserved language startup environment must be unset
GEM_PATH reserved language startup environment must be unset
BUNDLE_GEMFILE reserved language startup environment must be unset
BUNDLE_BIN_PATH reserved language startup environment must be unset
BUNDLE_PATH reserved language startup environment must be unset
BUNDLE_APP_CONFIG reserved language startup environment must be unset
BUNDLE_WITH reserved language startup environment must be unset
BUNDLE_WITHOUT reserved language startup environment must be unset
PLATFORM_PROOF_CALLBACK_HOST reserved proof environment must be unset
PLATFORM_CALLBACK_HOST reserved proof environment must be unset
PLATFORM_MAC_FIXTURE_VARS_FILE reserved proof environment must be unset
PLATFORM_CONTRACT_REPO_DIR reserved proof environment must be unset
PLATFORM_KOMGA_CONFIG_PATH reserved proof environment must be unset
PLATFORM_SNAPSHOT_ESCAPE reserved proof environment must be unset
TABLE
awk '{print $1}' "$scratch/table" | sort -u > "$scratch/declared"
reserved_names=$(awk '{print $1}' "$scratch/table" | tr '\n' ' ')
reserved_count=$(grep -c . "$scratch/declared")

# A collapse floor, and deliberately well below the eighteen rather than equal to
# them. Membership is owned by the both-directions comparison below, which names
# the variable that moved; this floor answers the different question of whether
# the parse still works at all. Set at eighteen it fires on any legitimate
# removal as well, and says "the parse has broken" about a guard that shrank on
# purpose -- a true statement replaced by a false one. Twelve is above the
# eleven-name language chain, so it takes more than one whole guard going
# unparsed to satisfy it.
RESERVED_FLOOR=12

failures=0
note_failure() {
  printf '%s\n' "$1" >&2
  failures=$((failures + 1))
}

# Every invocation clears all eighteen first, so a case does not depend on the
# environment it inherits -- which is the same environment the gate is careful
# about, and would otherwise make a result depend on which runner it landed on.
invoke_runner() {
  invoke_program=$1
  invoke_var=$2
  invoke_value=$3
  set -- env
  for invoke_name in $reserved_names; do
    set -- "$@" -u "$invoke_name"
  done
  [ -z "$invoke_var" ] || set -- "$@" "$invoke_var=$invoke_value"
  set -- "$@" sh "$invoke_program" --lane fresh \
    --vault-file /dev/null --vault-password-file /dev/null
  "$@" 2>&1 || true
}

# The exit status is not the assertion. Every invocation here exits nonzero --
# the cleared one dies later, at the vault file -- so a case that read the status
# would pass against a guard that had stopped refusing anything at all.
case_refuses() {
  [ "$(invoke_runner "$1" "$2" reserved-environment-test)" = "$3" ]
}

# The cleared run must reach past all three guards. It is asserted as "none of
# the three refusals" rather than as the message run.sh actually prints there,
# because that message comes from the vault-file validation well below the block
# under test: pinning it would anchor this check to argument parsing and break it
# for a reason that has nothing to do with the guards.
baseline_passes() {
  baseline_output=$(invoke_runner "$1" '' '')
  case $baseline_output in
    *'reserved proof platform environment must be unset'*) return 1 ;;
    *'reserved language startup environment must be unset'*) return 1 ;;
    *'reserved proof environment must be unset'*) return 1 ;;
  esac
  return 0
}

# Runs every case against one runner and names the ones that failed. The
# self-test needs the names and not a count: a plant that breaks a case other
# than its own is a different defect from a plant that breaks none, and only the
# names tell those apart.
failing_cases() {
  suite_program=$1
  : > "$scratch/failing"
  baseline_passes "$suite_program" || printf '%s\n' '<cleared>' >> "$scratch/failing"
  while read -r suite_name suite_message; do
    case_refuses "$suite_program" "$suite_name" "$suite_message" ||
      printf '%s\n' "$suite_name" >> "$scratch/failing"
  done < "$scratch/table"
  tr '\n' ' ' < "$scratch/failing" | sed 's/ *$//'
}

# ---------------------------------------------------------------------------
# The table against the guards themselves, in both directions.
# ---------------------------------------------------------------------------
grep -o '\[ -z "\${[A-Z_][A-Z_0-9]*+x}" \]' "$runner_path" |
  sed 's/.*{//; s/+x.*//' | sort -u > "$scratch/observed"
observed_count=$(grep -c . "$scratch/observed" || true)

[ "$observed_count" -ge "$RESERVED_FLOOR" ] ||
  note_failure "tests/mac/run.sh's reserved-environment guards parse to $observed_count names, below the collapse floor of $RESERVED_FLOOR: this test no longer reads the guards it polices"

undeclared=$(comm -23 "$scratch/observed" "$scratch/declared" | tr '\n' ' ' | sed 's/ *$//')
missing=$(comm -13 "$scratch/observed" "$scratch/declared" | tr '\n' ' ' | sed 's/ *$//')
[ -z "$undeclared" ] ||
  note_failure "tests/mac/run.sh guards variables this test does not exercise: $undeclared"
[ -z "$missing" ] ||
  note_failure "this test declares variables tests/mac/run.sh no longer guards: $missing"

# ---------------------------------------------------------------------------
# The refusals themselves.
# ---------------------------------------------------------------------------
baseline_passes "$runner_path" ||
  note_failure "tests/mac/run.sh refused a cleared environment: $(invoke_runner "$runner_path" '' '')"

while read -r case_name case_message; do
  case_refuses "$runner_path" "$case_name" "$case_message" ||
    note_failure "tests/mac/run.sh did not refuse $case_name with '$case_message': got '$(invoke_runner "$runner_path" "$case_name" reserved-environment-test)'"
done < "$scratch/table"

# The guards test whether a variable is SET, not whether it is non-empty, and an
# empty value is the case that tells those two apart. RUBYOPT= loads nothing by
# itself, but a guard rewritten to `[ -n "$RUBYOPT" ]` would admit it and admit
# every future non-empty value through the same door on the next edit.
empty_output=$(invoke_runner "$runner_path" RUBYOPT '')
[ "$empty_output" = 'reserved language startup environment must be unset' ] ||
  note_failure "tests/mac/run.sh admitted an empty RUBYOPT: the guard tests emptiness rather than whether the variable is set, got '${empty_output}'"

if [ "$self_test" != true ]; then
  [ "$failures" -eq 0 ] || exit 1
  printf 'Mac reserved environment: %s guarded variables refused, cleared environment admitted\n' \
    "$reserved_count"
  exit 0
fi

[ "$failures" -eq 0 ] || exit 1

# ---------------------------------------------------------------------------
# --self-test: one plant per variable.
# ---------------------------------------------------------------------------
# The plant replaces that variable's `[ -z "${NAME+x}" ]` with `true`, which is
# the hole the issue describes: the term stops testing anything while the chain
# around it still evaluates and still raises its own message for every sibling.
# It is uniform across all three guards, which deleting the term is not --
# guard 1 is a single term, and `[ -z ... ] || mac_die` does not survive having
# its test cut out.
#
# The planted runner is a copy in a mirrored root rather than an edit in place.
# run.sh resolves its repository from its own physical location and sources three
# files before the guards, so the copy has to sit at tests/mac/run.sh of
# something shaped like this repository; editing the real file would also mean
# writing into a tree the rest of the gate is reading concurrently.
mirror=$scratch/repo
mkdir -p "$mirror/tests/mac"
for entry in "$repo_dir"/* "$repo_dir"/.[!.]*; do
  [ -e "$entry" ] || continue
  entry_name=$(basename -- "$entry")
  [ "$entry_name" = tests ] || ln -s "$entry" "$mirror/$entry_name"
done
for entry in "$repo_dir"/tests/*; do
  entry_name=$(basename -- "$entry")
  [ "$entry_name" = mac ] || ln -s "$entry" "$mirror/tests/$entry_name"
done
for entry in "$repo_dir"/tests/mac/*; do
  entry_name=$(basename -- "$entry")
  [ "$entry_name" = run.sh ] || ln -s "$entry" "$mirror/tests/mac/$entry_name"
done
mirror_runner=$mirror/tests/mac/run.sh

# THE CONTROL, and it is the half that keeps the plants from being vacuous. A
# mirror that broke run.sh for some unrelated reason would make every plant look
# detected while proving nothing -- the same vacuous pass as a plant that lands
# on a row the checker never reads.
cp "$runner_path" "$mirror_runner"
chmod 0755 "$mirror_runner"
control_failing=$(failing_cases "$mirror_runner")
if [ -n "$control_failing" ]; then
  printf 'unplanted mirror does not reproduce tests/mac/run.sh; failing cases: %s\n' \
    "$control_failing" >&2
  exit 1
fi

: > "$scratch/detected"
while read -r plant_name plant_message; do
  : "$plant_message"
  plant_term="[ -z \"\${$plant_name+x}\" ]"
  # Literal string replacement rather than a regex: the term is almost nothing
  # but metacharacters, and a bare-substring plant that lands on a row the
  # checker does not read is how a self-test comes to report defects it never
  # planted. The count is asserted in the same pass, so a term that stopped
  # matching fails here instead of being reported as an undetected hole.
  awk -v term="$plant_term" '
    { while ((at = index($0, term)) > 0) {
        $0 = substr($0, 1, at - 1) "true" substr($0, at + length(term))
        total++
      }
      print }
    END { if (total != 1) exit 1 }
  ' "$runner_path" > "$scratch/candidate" || {
    printf 'plant for %s did not match exactly one guard term\n' "$plant_name" >&2
    exit 1
  }
  cp "$scratch/candidate" "$mirror_runner"
  chmod 0755 "$mirror_runner"
  sh -n "$mirror_runner" || {
    printf 'plant for %s left tests/mac/run.sh unparseable\n' "$plant_name" >&2
    exit 1
  }

  plant_failing=$(failing_cases "$mirror_runner")
  if [ "$plant_failing" != "$plant_name" ]; then
    printf 'plant for %s should have failed exactly its own case; failing cases were: %s\n' \
      "$plant_name" "${plant_failing:-none}" >&2
    exit 1
  fi
  printf '%s\n' "$plant_name" >> "$scratch/detected"
done < "$scratch/table"

detected=$(grep -c . "$scratch/detected" || true)
if [ "$detected" -ne "$reserved_count" ]; then
  printf 'reserved-environment self-test detected %s of %s planted holes\n' \
    "$detected" "$reserved_count" >&2
  exit 1
fi

printf 'Mac reserved environment self-test: %s/%s unguarded variables detected, each failing only its own case\n' \
  "$detected" "$reserved_count"
printf '  %s\n' "$(tr '\n' ' ' < "$scratch/detected" | sed 's/ *$//')"
