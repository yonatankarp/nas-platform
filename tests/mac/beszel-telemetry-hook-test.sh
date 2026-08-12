#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/beszel-telemetry-hook.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

mkdir -p "$fixture/tests/mac/hooks/verify" "$fixture/tests/mac/hooks/drift" \
  "$fixture/tests/contracts/support" "$fixture/reports"
cp "$repo_dir/tests/mac/hooks/verify/10-beszel.sh" "$fixture/tests/mac/hooks/verify/"
cp "$repo_dir/tests/mac/hooks/drift/10-beszel.sh" "$fixture/tests/mac/hooks/drift/"
cp "$repo_dir/tests/beszel_telemetry_probe_test.rb" "$fixture/tests/"
cp "$repo_dir/tests/contracts/beszel.sh" "$fixture/tests/contracts/"
cp "$repo_dir/tests/contracts/support/beszel_telemetry.rb" "$fixture/tests/contracts/support/"

hook_log=$fixture/hook.log
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$1" >>"$PLATFORM_HOOK_LOG"' > \
  "$fixture/tests/mac/run-beszel-contract.sh"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" verify-failed >&2' 'exit 1' > \
  "$fixture/tests/mac/verify.sh"
chmod +x "$fixture/tests/mac/run-beszel-contract.sh" "$fixture/tests/mac/verify.sh"

PLATFORM_HOOK_LOG=$hook_log "$fixture/tests/mac/hooks/verify/10-beszel.sh"
[ "$(sed -n '1p' "$hook_log")" = verify ] || {
  printf '%s\n' 'Beszel verify hook omitted persisted telemetry verification' >&2
  exit 1
}
[ "$(sed -n '2p' "$hook_log")" = notify ] || {
  printf '%s\n' 'Beszel verify hook omitted notification verification' >&2
  exit 1
}

: >"$hook_log"
PLATFORM_HOOK_LOG=$hook_log PLATFORM_REPORT_ROOT=$fixture/reports \
  "$fixture/tests/mac/hooks/drift/10-beszel.sh"
[ "$(sed -n '1p' "$hook_log")" = drift ] || {
  printf '%s\n' 'Beszel drift hook omitted supported live configuration drift' >&2
  exit 1
}

printf '%s\n' 'Beszel telemetry Mac hooks passed'
