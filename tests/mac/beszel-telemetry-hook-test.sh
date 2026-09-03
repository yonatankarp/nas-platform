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

# This fixture copies *named* files into a narrow tree, unlike every other
# contract harness, which copies the whole repository and so gets a contract's
# siblings for free. Until #147 tests/contracts/beszel.sh carried its Ruby inside
# itself and the two lines above were the whole contract; it now names three
# sibling programs, and a program that is not copied simply does not arrive --
# tests/beszel_telemetry_probe_test.rb below would then fail on a missing file
# rather than on the telemetry semantics it exists to check.
#
# Derived from the wrapper rather than stated, by the same rule
# tests/run_contracts.rb:203 and tests/policy_mutation_support.rb:250 use: a
# tests/contracts/*.rb path named on a line that is not a comment. A stated list
# would have to be extended by the next extraction, which is the defect being
# fixed here rather than repeated. The -r preload of
# tests/contracts/support/beszel_telemetry carries no extension and so is not
# derivable this way, which is why its copy above stays explicit -- the same hole
# run_contracts.rb closes with a glob.
programs=$(grep -v '^[[:space:]]*#' "$repo_dir/tests/contracts/beszel.sh" |
  grep -o 'tests/contracts/[A-Za-z0-9_./-]*\.rb' | sort -u || true)
# A floor, not non-emptiness. A derived list that shrank to one entry would still
# be "not empty" and would copy a working-looking subset; three is what the
# wrapper's three modes need, and merging two programs is a change that should
# have to say so here.
program_count=$(printf '%s\n' "$programs" | grep -c '[^[:space:]]' || true)
[ "$program_count" -ge 3 ] || {
  printf 'Beszel contract names %s sibling Ruby program(s), wanted at least 3\n' \
    "$program_count" >&2
  exit 1
}
for program in $programs; do
  [ -f "$repo_dir/$program" ] || {
    printf 'Beszel contract names a sibling Ruby program that is absent: %s\n' \
      "$program" >&2
    exit 1
  }
  mkdir -p "$fixture/$(dirname "$program")"
  cp "$repo_dir/$program" "$fixture/$program"
done

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
