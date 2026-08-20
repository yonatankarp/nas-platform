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
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
runner=$root/tests/validate-policy.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
failures=0

# Replaces the embedded check list with $2, and drops the ansible interpreter
# discovery so these cases do not need a working Ansible install.
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
      if ($0 == "POLICY_CHECKS") { inside = 0; print }
      next
    }
    { print }
    /cat <<.POLICY_CHECKS.$/ {
      inside = 1
      while ((getline line < stub) > 0) { print line }
      close(stub)
    }
  ' "$runner" >"$dest"
}

# $1 label, $2 expected exit, $3 required substring, $4.. stub check lines
expect() {
  label=$1
  want=$2
  needle=$3
  shift 3
  printf '%s\n' "$@" >"$work/stub"
  build "$work/stub" "$work/case.sh"
  set +e
  output=$(cd "$root" && sh "$work/case.sh" 2>&1)
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

if [ "$failures" -ne 0 ]; then
  printf 'policy runner: %s falsification cases failed\n' "$failures" >&2
  exit 1
fi

printf 'policy runner: fails closed on skipped, failing, and out-of-order checks\n'
