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
: > "$fixture/vault.yml"
: > "$fixture/vault-password"
# The contract runner, stubbed. Every phase the hooks ask for is logged, so a
# hook that stopped installing its fixture -- or stopped confirming the fixture
# landed -- is caught by the log rather than by the hook's own exit status.
#
# PLATFORM_HOOK_DRIFT_LANDED=0 is the fixture that silently failed to apply:
# drift-verify is the only mode that reads the installed drift back, so a runner
# that refuses there is exactly what an unapplied fixture looks like to the hook.
cat > "$fixture/tests/mac/run-beszel-contract.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$1" >>"$PLATFORM_HOOK_LOG"
[ "$1" != drift-verify ] || [ "${PLATFORM_HOOK_DRIFT_LANDED:-1}" = 1 ] || {
  printf '%s\n' 'managed universal token drift changed' >&2
  exit 1
}
STUB
# The vault-secret sweep, stubbed for the same reason: this test is about which
# steps the hook takes over its capture, not about the scanner's own semantics,
# which tests/assert_no_vault_secrets_test.rb owns.
#
# It reports the mask it inherited, which is the only non-vacuous way to observe
# the hook's umask: mktemp creates the capture 0600 whatever the mask is, so the
# capture's own mode proves nothing. What the mask does change is every file the
# programs the hook invokes create -- tests/mac/verify.sh above all, which sets
# none of its own -- and that is what this reads back.
cat > "$fixture/tests/assert-no-vault-secrets.rb" <<'STUB'
#!/bin/sh
set -eu
printf 'SECRET_SCAN %s\n' "$(umask)" >>"${PLATFORM_HOOK_LOG:?}"
exit 0
STUB
chmod 0755 "$fixture/tests/assert-no-vault-secrets.rb"
# The all-service verification, stubbed, one scenario per case below. Only the
# drift hook reaches it -- the verify hook runs the contract twice and nothing
# else -- so scenario-driving it cannot disturb the verify assertions.
#
# The captures are ansible-core 2.21.3's own output rather than invented text:
# the role-qualified TASK banner, printed whenever a task merely runs, and the
# "[ERROR]: Task failed: Action failed: <fail_msg>" line, which is the anchor
# HttpFixtureSupport::TASK_REFUSAL_PREFIX pins. Every fail_msg below is the one
# its role actually carries. "Verify the exact managed universal token" carries
# no_log: true and still prints its message on that line (#428), which is why the
# guard-passed case is reachable at all.
#
# It logs its own event too, on the same stream the contract runner uses. Without
# that the log cannot separate a read-back that ran before the verification from
# one that ran after it, and "after" is wrong: the drift-verify mode asserts the
# sentinel values are still installed, which only holds while nothing has
# reconverged them.
cat > "$fixture/tests/mac/verify.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' VERIFY_BESZEL >>"${PLATFORM_HOOK_LOG:?}"
printf '%s\n' 'PLAY [nas] *********************************************************************'
case ${PLATFORM_HOOK_SCENARIO:?} in
  beszel)
    printf '%s\n' 'TASK [beszel : Verify the managed application user contract] ********************'
    printf '%s\n' '[ERROR]: Task failed: Action failed: Managed application user is absent or differs from the verified admin contract.'
    exit 2
    ;;
  unrelated)
    # The plant #440 names. Beszel's guard ran and accepted the installed drift;
    # Dozzle, six roles later in verify.yml, is what failed the run.
    printf '%s\n' 'TASK [beszel : Verify the managed application user contract] ********************'
    printf '%s\n' 'TASK [dozzle : Require exactly the managed Dozzle ntfy dispatcher] **************'
    printf '%s\n' '[ERROR]: Task failed: Action failed: Dozzle ntfy dispatcher is absent or drifted.'
    exit 2
    ;;
  guard-passed)
    # The #428 plant, in Beszel's shape: the anchored guard ran and passed, and a
    # later Beszel guard refused a different facet of the same installed drift.
    printf '%s\n' 'TASK [beszel : Verify the managed application user contract] ********************'
    printf '%s\n' 'TASK [beszel : Verify the exact managed universal token] ************************'
    printf '%s\n' '[ERROR]: Task failed: Action failed: Managed universal token is absent, duplicated, or differs from vault.'
    exit 2
    ;;
  accepted)
    printf '%s\n' 'TASK [beszel : Verify the managed application user contract] ********************'
    exit 0
    ;;
esac
printf '%s\n' 'unknown Beszel hook scenario' >&2
exit 4
STUB
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

# The drift hook's anchor (#440). tests/mac/verify.sh runs every service's
# verification in one playbook, and the hook used to assert only that the command
# exited non-zero, so a failure belonging to any other service satisfied it. The
# hook now reads back the diagnostic of the guard the installed drift is aimed at,
# and the four cases below are what tell the two apart: the first is the property
# the hook has to keep, the other three are the ones it used to accept.
drift_report_root=$fixture/reports
run_drift_hook() {
  : >"$hook_log"
  find "$drift_report_root" -mindepth 1 -maxdepth 1 -delete
  # A permissive mask on the way in, so what the hook reports back is the mask it
  # set rather than the one this file happens to run under.
  (
    umask 022
    PLATFORM_HOOK_LOG=$hook_log PLATFORM_REPORT_ROOT=$drift_report_root \
      PLATFORM_HOOK_SCENARIO=$1 \
      PLATFORM_HOOK_DRIFT_LANDED=${2:-1} \
      PLATFORM_MAC_VAULT_FILE=$fixture/vault.yml \
      PLATFORM_MAC_VAULT_PASSWORD_FILE=$fixture/vault-password \
      "$fixture/tests/mac/hooks/drift/10-beszel.sh"
  )
}

run_drift_hook beszel || {
  printf '%s\n' 'Beszel drift hook rejected its own guard diagnostic' >&2
  exit 1
}
[ "$(sed -n '1p' "$hook_log")" = drift ] || {
  printf '%s\n' 'Beszel drift hook omitted supported live configuration drift' >&2
  exit 1
}
# Positions, not mere presence. The read-back has to sit between the fixture and
# the verification -- it asserts the installed sentinels are still there, which a
# reconverge undoes -- and the sweep has to sit after the verification, because
# the capture it sweeps does not exist until then. Each of the three steps is
# therefore checked at its own line rather than anywhere in the log.
grep -qx drift-verify "$hook_log" || {
  printf '%s\n' 'Beszel drift hook did not confirm its drift fixture landed' >&2
  exit 1
}
[ "$(sed -n '2p' "$hook_log")" = drift-verify ] || {
  printf '%s\n' 'Beszel drift hook confirmed its drift fixture outside the window that proves anything' >&2
  exit 1
}
[ "$(sed -n '3p' "$hook_log")" = VERIFY_BESZEL ] || {
  printf '%s\n' 'Beszel drift hook did not run the verification after reading its fixture back' >&2
  exit 1
}
[ "$(sed -n '4p' "$hook_log" | cut -d' ' -f1)" = SECRET_SCAN ] || {
  printf '%s\n' 'Beszel drift hook did not scan its capture for vault secrets' >&2
  exit 1
}
# The mask the hook hands the programs it runs. run_drift_hook enters with 022
# on purpose, so this is 0077 only because the hook set it: an inherited mask
# would make the check pass without the hook doing anything, which is the vacuous
# form of it.
[ "$(sed -n 's/^SECRET_SCAN //p' "$hook_log")" = 0077 ] || {
  printf 'Beszel drift hook ran its capture handling under mask %s, wanted 0077\n' \
    "$(sed -n 's/^SECRET_SCAN //p' "$hook_log")" >&2
  exit 1
}
find "$drift_report_root" -mindepth 1 -maxdepth 1 -print -quit | grep -q . && {
  printf '%s\n' 'Beszel drift hook retained its raw verification output' >&2
  exit 1
}

# The fixture that never landed. Everything downstream is unchanged -- the
# verification still refuses with Beszel's own diagnostic -- so without the
# read-back this run is indistinguishable from the passing one above, which is
# the whole reason the read-back is there.
drift_status=0
run_drift_hook beszel 0 >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted a drift fixture that never landed' >&2
  exit 1
}

# The discriminator #440 exists for. An unrelated service failed the all-service
# run while Beszel's own guard accepted the drift this hook had just installed.
drift_status=0
run_drift_hook unrelated >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted an unrelated service as its refusal' >&2
  exit 1
}

# The #428 discriminator, which a task-name anchor would also have accepted: the
# anchored guard ran and passed, and a later Beszel guard failed the run.
drift_status=0
run_drift_hook guard-passed >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted a run in which its guard ran and passed' >&2
  exit 1
}

# The property the hook already had: a verification run that accepts the drift
# outright is a failure, not a pass.
drift_status=0
run_drift_hook accepted >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted a verification run that passed on drift' >&2
  exit 1
}

# The trace. A caller running the drift hook under -x echoes every command that
# handles the capture -- the capture's own path, the vault paths handed to the
# scanner, the sentence the grep pins -- to stderr, where tests/mac/run.sh
# collects it. `set +x` near the top of the hook is what stops that, and only
# running the hook that way can tell whether the line is still there.
trace_log=$fixture/trace.log
: >"$hook_log"
find "$drift_report_root" -mindepth 1 -maxdepth 1 -delete
(
  umask 022
  PLATFORM_HOOK_LOG=$hook_log PLATFORM_REPORT_ROOT=$drift_report_root \
    PLATFORM_HOOK_SCENARIO=beszel \
    PLATFORM_MAC_VAULT_FILE=$fixture/vault.yml \
    PLATFORM_MAC_VAULT_PASSWORD_FILE=$fixture/vault-password \
    sh -x "$fixture/tests/mac/hooks/drift/10-beszel.sh"
) >/dev/null 2>"$trace_log"
grep -qE 'run-beszel-contract\.sh|beszel-verify-drift|assert-no-vault-secrets' \
  "$trace_log" && {
  printf '%s\n' 'Beszel drift hook traced its capture handling to a caller running under -x' >&2
  exit 1
}

printf '%s\n' 'Beszel telemetry Mac hooks passed'
