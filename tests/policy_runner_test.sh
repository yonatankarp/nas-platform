#!/bin/sh
# The policy runner executes its checks concurrently, so "all checks passed" is
# only trustworthy if a check that never reported is louder than a check that
# passed. A runner that silently skipped work would still print success and would
# disable every policy guard at once, so that path is proved here rather than
# assumed.
#
# Each case runs the real tests/validate-policy.sh with only its manifest swapped
# for a three-line stub, so this exercises the shipped dispatch and accounting
# code instead of a copy of it.
#
# The manifest is partitioned into one heredoc per CI shard (#469), and the two
# ways that partition can go quiet are proved here rather than reasoned about: a
# shard identifier the runner does not declare must be refused, and a shard whose
# list is empty must fail. Either would otherwise be a job reporting success
# having executed no check at all -- the one outcome a sharded gate must be
# incapable of, because it is also the *fastest* outcome and nothing in a green
# run would say so. tests/gate_manifest_coverage_test.rb guards the lists; this
# guards the run.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
runner=$root/tests/validate-policy.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
failures=0

# Replaces the embedded check lists with $2, and drops the ansible interpreter
# discovery so these cases do not need a working Ansible install.
#
# The stub goes into the FIRST shard and the others are left empty, which is what
# makes the shard cases below expressible: an unsharded run of the built script
# sees exactly the stub, `1` sees the stub, and `2` sees a shard with no checks.
build() {
  stub=$1
  dest=$2
  awk -v stub="$stub" '
    /^# Resolved before the checks run/ { skip = 1 }
    skip {
      if ($0 == "export ansible_python") {
        print "ansible_python=/nonexistent"
        print "export ansible_python"
        skip = 0
      }
      next
    }
    inside {
      if ($0 ~ /^POLICY_CHECKS_[0-9]+$/) { inside = 0; print }
      next
    }
    { print }
    /cat <<.POLICY_CHECKS_[0-9]+.$/ {
      inside = 1
      if (!injected) {
        while ((getline line < stub) > 0) { print line }
        close(stub)
        injected = 1
      }
    }
  ' "$runner" >"$dest"
}

# The shard argument the next expect() passes to the built runner. Empty means
# the unsharded run, which is what every case but the shard cases exercises.
shard_argument=''

# $1 label, $2 expected exit, $3 required substring, $4.. stub check lines
expect() {
  label=$1
  want=$2
  needle=$3
  shift 3
  printf '%s\n' "$@" >"$work/stub"
  build "$work/stub" "$work/case.sh"
  set +e
  output=$(cd "$root" && sh "$work/case.sh" ${shard_argument:+"$shard_argument"} 2>&1)
  got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    printf 'FAIL %s: exited %s, expected %s\n%s\n' "$label" "$got" "$want" "$output" >&2
    failures=$((failures + 1))
    return
  fi
  case $output in
    *"$needle"*) ;;
    *)
      printf 'FAIL %s: output lacks %s\n%s\n' "$label" "$needle" "$output" >&2
      failures=$((failures + 1))
      ;;
  esac
}

expect 'passing checks report the total' 0 'all 3 checks passed' \
  'true' 'true' 'true'

# A non-zero check must be named with its status, not folded into a generic exit.
expect 'a failing check is named' 1 'FAILED (exit 3)' \
  'true' "sh -c 'exit 3'" 'true'

expect 'a failing check is counted' 1 '1 failed' \
  'true' "sh -c 'exit 3'" 'true'

# Killing the shell that would have recorded the status is the only way a check
# goes unrecorded. The run must fail and say so, never report success.
expect 'an unrecorded check fails the run' 1 'POLICY CHECK NEVER RAN' \
  'true' 'kill -9 "$PPID"' 'true'

# Every check still runs when an earlier one fails: the sequential runner stopped
# at the first failure, which hid the state of everything after it.
expect 'checks after a failure still run' 1 'later-check-ran' \
  "sh -c 'exit 1'" 'echo later-check-ran' 'true'

# A named shard runs its own list and says which shard it is, so a CI leg's log
# names the third of the gate it covered rather than looking like the whole of it.
shard_argument=1
expect 'a named shard runs its own list' 0 'policy gate shard 1' \
  'true' 'true' 'true'

# The stub went into shard 1, so shard 2 is a shard with nothing in it. Left
# alone the accounting would find 0 of 0 checks run, print "all 0 checks passed"
# and exit 0 -- success, faster than a real run, having proved nothing.
shard_argument=2
expect 'an empty shard fails the run' 1 'policy validation found no checks to run' \
  'true' 'true' 'true'

# A shard identifier the manifest does not declare is a typo in the CI matrix.
# Running nothing for it would be the same silent green; it must be a red leg.
shard_argument=9
expect 'an undeclared shard is refused' 2 'unknown policy shard: 9' \
  'true' 'true' 'true'

# ...and the refusal has to name what the manifest does declare, or the operator
# reading a red leg cannot tell a typo from a shard that was removed.
shard_argument=9
expect 'the refusal names the declared shards' 2 'the manifest declares shards: 1 2 3' \
  'true' 'true' 'true'

# More than one argument is a caller that thinks this takes options it does not.
shard_argument=''
printf 'true\ntrue\ntrue\n' >"$work/stub"
build "$work/stub" "$work/case.sh"
set +e
usage_output=$(cd "$root" && sh "$work/case.sh" 1 2 2>&1)
usage_status=$?
set -e
if [ "$usage_status" -ne 2 ]; then
  printf 'FAIL a second argument is refused: exited %s, expected 2\n%s\n' \
    "$usage_status" "$usage_output" >&2
  failures=$((failures + 1))
fi
case $usage_output in
  *'usage:'*) ;;
  *)
    printf 'FAIL a second argument is refused: output lacks a usage line\n%s\n' \
      "$usage_output" >&2
    failures=$((failures + 1))
    ;;
esac

if [ "$failures" -ne 0 ]; then
  printf 'policy runner: %s falsification cases failed\n' "$failures" >&2
  exit 1
fi

printf 'policy runner: fails closed on skipped, failing and out-of-order checks, '
printf 'and on empty or undeclared shards\n'
