#!/bin/sh
# Proves the concurrent policy runner fails loudly on a check that never reported, an
# undeclared shard and an empty shard (#469), using the real tests/validate-policy.sh
# with its manifest swapped for a stub.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
runner=$root/tests/validate-policy.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
failures=0

# Replaces the check lists with $2 (in shard 1; others empty) and drops the Ansible
# interpreter discovery.
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

# Empty means the unsharded run.
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

# Killing the recording shell is the only way a check goes unrecorded.
expect 'an unrecorded check fails the run' 1 'POLICY CHECK NEVER RAN' \
  'true' 'kill -9 "$PPID"' 'true'

expect 'checks after a failure still run' 1 'later-check-ran' \
  "sh -c 'exit 1'" 'echo later-check-ran' 'true'

# A named shard says which shard it is in the log.
shard_argument=1
expect 'a named shard runs its own list' 0 'policy gate shard 1' \
  'true' 'true' 'true'

# Shard 2 is empty: "all 0 checks passed" must not be success.
shard_argument=2
expect 'an empty shard fails the run' 1 'policy validation found no checks to run' \
  'true' 'true' 'true'

# An undeclared shard is a matrix typo and must be a red leg.
shard_argument=9
expect 'an undeclared shard is refused' 2 'unknown policy shard: 9' \
  'true' 'true' 'true'

shard_argument=9
expect 'the refusal names the declared shards' 2 'the manifest declares shards: 1 2 3' \
  'true' 'true' 'true'

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
