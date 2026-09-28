#!/bin/sh
# The integration lifecycle transition table, exercised directly (#773). The
# producer is a stub, so a row fails only when the table changed.
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
. "$script_dir/integration_lifecycle.sh"

failures=0

# A stub producer prints the plan on stdout.
# shellcheck disable=SC2329  # invoked indirectly, as the producer command
emit() {
  printf '%s\n' "$1"
}

expect_accepted() {
  description=$1
  plan=$2
  if output=$(consume_integration_lifecycle_plan emit "$plan" 2>/dev/null); then
    if [ "$output" = "$plan" ]; then
      return 0
    fi
    printf 'FAIL %s: plan accepted but echoed back changed\n' "$description" >&2
    printf '  expected: %s\n  actual:   %s\n' "$plan" "$output" >&2
  else
    printf 'FAIL %s: valid plan was rejected\n' "$description" >&2
  fi
  failures=$((failures + 1))
}

expect_rejected() {
  description=$1
  plan=$2
  if consume_integration_lifecycle_plan emit "$plan" >/dev/null 2>&1; then
    printf 'FAIL %s: invalid plan was accepted\n' "$description" >&2
    failures=$((failures + 1))
  fi
}

# --- what the table must accept ---

expect_accepted 'ordinary lane' 'converge
success'

expect_accepted 'upgrade lane' 'converge
seed
repin
converge
verify
stop
success'

# --- what it must refuse ---
# A repin before a seed would migrate an empty store and still pass.

expect_rejected 'repin before seed migrates an empty store' 'converge
repin
converge
verify
success'

expect_rejected 'verify before the upgrade converge reads back the writer' 'converge
seed
repin
verify
success'

expect_rejected 'seed without a converge to seed against' 'seed
repin
converge
verify
success'

expect_rejected 'upgrade lane ending before verify' 'converge
seed
repin
converge
stop
success'

# #781: stopping the head container is the only place its exit code is read.
expect_rejected 'upgrade lane ending before the stop' 'converge
seed
repin
converge
verify
success'

# A stop before verify leaves no running container to read rows from.
expect_rejected 'stop before verify leaves nothing to read the rows back from' 'converge
seed
repin
converge
stop
verify
success'

# The ordinary lane's converge is a fresh install; there is no upgrade to stop.
expect_rejected 'stop on a lane that never upgraded anything' 'converge
stop
success'

expect_rejected 'second converge without a repin is the same image twice' 'converge
seed
converge
verify
success'

expect_rejected 'plan that never reaches success' 'converge
seed
repin
converge
verify'

expect_rejected 'unknown event' 'converge
migrate
success'

expect_rejected 'empty plan' ''

# A failing producer must not read as an empty-but-valid plan.
if consume_integration_lifecycle_plan false >/dev/null 2>&1; then
  printf 'FAIL failing producer was accepted\n' >&2
  failures=$((failures + 1))
fi

# The acceptance rows are the tripwire against a consumer that refuses everything.
if [ $failures -eq 0 ]; then
  printf 'integration lifecycle: all transition checks passed\n'
  exit 0
fi

printf '%s integration lifecycle transition failure(s)\n' "$failures" >&2
exit 1
