#!/bin/sh
# tests/mac/run.sh refuses three classes of preset environment (the Ruby/Bundler
# chain matters: run.sh decrypts a vault, #643/#677). Each variable is tested on its
# own because dropping one `&&` term keeps a whole-guard case green; the table is
# held to the names parsed out of run.sh in both directions.
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

# Reserved variable and its guard's refusal. A file, not a variable: a `printf | while`
# loop is a subshell and could not fail the run.
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

# A collapse floor for the parse, below the eighteen so a deliberate removal is
# reported by the both-ways comparison rather than as a broken parse.
RESERVED_FLOOR=12

failures=0
note_failure() {
  printf '%s\n' "$1" >&2
  failures=$((failures + 1))
}

# Every invocation clears all eighteen first so the inherited environment cannot matter.
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
  # stdin from /dev/null: the loops read the case table on stdin, and a run.sh
  # that read stdin would silently eat the remaining rows.
  "$@" </dev/null 2>&1 || true
}

# Every invocation exits nonzero, so the message, not the status, is the assertion.
case_refuses() {
  [ "$(invoke_runner "$1" "$2" reserved-environment-test)" = "$3" ]
}

# The cleared run must reach past all three guards; it later dies at the vault file.
baseline_passes() {
  baseline_output=$(invoke_runner "$1" '' '')
  case $baseline_output in
    *'reserved proof platform environment must be unset'*) return 1 ;;
    *'reserved language startup environment must be unset'*) return 1 ;;
    *'reserved proof environment must be unset'*) return 1 ;;
  esac
  return 0
}

# Names the failing cases, so the self-test can tell a plant breaking its own case
# from one breaking another.
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

cases_run=0
while read -r case_name case_message; do
  cases_run=$((cases_run + 1))
  case_refuses "$runner_path" "$case_name" "$case_message" ||
    note_failure "tests/mac/run.sh did not refuse $case_name with '$case_message': got '$(invoke_runner "$runner_path" "$case_name" reserved-environment-test)'"
done < "$scratch/table"
# A loop that ended early would report every case it never ran as passing.
[ "$cases_run" -eq "$reserved_count" ] ||
  note_failure "ran $cases_run of $reserved_count declared cases: the case table was not read to the end"

# The guards test SET, not non-empty; an empty RUBYOPT tells the two apart.
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
# Each plant replaces one `[ -z "${NAME+x}" ]` with `true`, in a copy of run.sh
# inside a symlinked mirror of the repository (run.sh resolves the repo from itself).
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

# The control: an unplanted mirror must pass every case, or the plants prove nothing.
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
  # Literal replacement, not a regex: the term is nearly all metacharacters. The
  # count is asserted so a term that stopped matching fails here.
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
