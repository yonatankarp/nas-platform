#!/bin/sh
# The integration lifecycle transition table, exercised directly.
#
# It had no test of its own until #773 extended it. That mattered more than it
# sounds: the table is the only thing standing between a lane that proves a
# migration and a lane that reports one. Every ordering it accepts is a claim,
# and the orderings it must refuse are claims too -- a repin before a seed
# migrates an empty store, which is the fresh-install path every existing lane
# already takes and would pass exactly as loudly.
#
# The producer is a stub rather than tests/integration.sh, so a row here fails
# for one reason: the table changed. Wiring the real producer in would make this
# file fail whenever a suite's plan changed, which is what the suite's own tests
# are for.
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
. "$script_dir/integration_lifecycle.sh"

failures=0

# The producer contract is a command whose stdout is the plan, so a stub is a
# command that prints one. `printf '%s\n'` with the plan already newline-joined
# keeps each case a single readable string.
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

# --- what the table must accept -------------------------------------------

expect_accepted 'ordinary lane' 'converge
success'

expect_accepted 'upgrade lane' 'converge
seed
repin
converge
verify
success'

# --- what it must refuse --------------------------------------------------
#
# The first two are the whole reason the table was extended rather than the
# events merely being emitted in the right order by the producer. A producer
# that emitted them wrongly would otherwise run a green lane that asserted
# nothing, which is the shape this repository has had to close repeatedly.

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

# A producer that fails must not be read as an empty-but-valid plan. Without
# this the table would be asked to validate nothing and would refuse for the
# wrong reason, which reads the same in a log and is not the same defect.
if consume_integration_lifecycle_plan false >/dev/null 2>&1; then
  printf 'FAIL failing producer was accepted\n' >&2
  failures=$((failures + 1))
fi

# The tripwire. Every rejection row above is satisfied by a consumer that
# refuses everything -- a broken `case`, an inverted return, a read that never
# loops -- and such a consumer would report a pass while the upgrade lane could
# never run at all. The two acceptance rows at the top are that tripwire, so
# this restates why they must stay rather than adding a third.
if [ $failures -eq 0 ]; then
  printf 'integration lifecycle: all transition checks passed\n'
  exit 0
fi

printf '%s integration lifecycle transition failure(s)\n' "$failures" >&2
exit 1
