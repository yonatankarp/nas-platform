#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/beszel-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# Beszel 0.18.7 exposes system_stats and container_stats as authenticated,
# read-only collections (no supported create/update/delete rule). Editing the
# PocketBase database is explicitly unsupported, and stopping real metrics
# would destructively weaken the live proof. Exercise telemetry-fixtures through
# the same category evaluator instead of faking a live telemetry repair.
ruby "$mac_script_dir/../beszel_telemetry_probe_test.rb"

"$mac_script_dir/run-beszel-contract.sh" drift
if "$mac_script_dir/verify.sh" >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Beszel drift' >&2
  exit 1
fi
