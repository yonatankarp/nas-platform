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

# Copies named files, not the repo, so the contract's sibling Ruby programs are
# derived from non-comment lines of beszel.sh; the extensionless -r preload above
# cannot be derived, so its copy stays explicit.
programs=$(grep -v '^[[:space:]]*#' "$repo_dir/tests/contracts/beszel.sh" |
  grep -o 'tests/contracts/[A-Za-z0-9_./-]*\.rb' | sort -u || true)
# A floor, not non-emptiness: the wrapper's three modes need three programs.
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
# The contract runner, stubbed and logging every phase. PLATFORM_HOOK_DRIFT_LANDED=0
# makes drift-verify refuse, which is what an unapplied fixture looks like.
cat > "$fixture/tests/mac/run-beszel-contract.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$1" >>"$PLATFORM_HOOK_LOG"
[ "$1" != drift-verify ] || [ "${PLATFORM_HOOK_DRIFT_LANDED:-1}" = 1 ] || {
  printf '%s\n' 'managed universal token drift changed' >&2
  exit 1
}
STUB
# The vault-secret sweep, stubbed; it reports its inherited umask, the only
# non-vacuous way to observe the hook's mask (mktemp is 0600 regardless).
cat > "$fixture/tests/assert-no-vault-secrets.rb" <<'STUB'
#!/bin/sh
set -eu
printf 'SECRET_SCAN %s\n' "$(umask)" >>"${PLATFORM_HOOK_LOG:?}"
exit 0
STUB
chmod 0755 "$fixture/tests/assert-no-vault-secrets.rb"
# The all-service verification, stubbed with ansible-core's real banner and
# "[ERROR]: Task failed: Action failed: <fail_msg>" lines, one scenario per case.
# It logs its own event so the log orders the read-back before it.
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

# The drift hook must read back its own guard's diagnostic, not accept any failing
# service in the all-service playbook (#440).
drift_report_root=$fixture/reports
run_drift_hook() {
  : >"$hook_log"
  find "$drift_report_root" -mindepth 1 -maxdepth 1 -delete
  # A permissive mask on the way in, so the reported mask is the hook's own.
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
# Positions, not presence: read-back before the verification (a reconverge undoes
# the sentinels), the sweep after it (the capture does not exist until then).
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
# run_drift_hook enters with 022, so 0077 proves the hook set the mask itself.
[ "$(sed -n 's/^SECRET_SCAN //p' "$hook_log")" = 0077 ] || {
  printf 'Beszel drift hook ran its capture handling under mask %s, wanted 0077\n' \
    "$(sed -n 's/^SECRET_SCAN //p' "$hook_log")" >&2
  exit 1
}
find "$drift_report_root" -mindepth 1 -maxdepth 1 -print -quit | grep -q . && {
  printf '%s\n' 'Beszel drift hook retained its raw verification output' >&2
  exit 1
}

# The fixture that never landed: only the read-back distinguishes it from a pass.
drift_status=0
run_drift_hook beszel 0 >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted a drift fixture that never landed' >&2
  exit 1
}

# #440: an unrelated service failed while Beszel's guard accepted the drift.
drift_status=0
run_drift_hook unrelated >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted an unrelated service as its refusal' >&2
  exit 1
}

# #428: the anchored guard ran and passed, and a later Beszel guard failed the run.
drift_status=0
run_drift_hook guard-passed >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted a run in which its guard ran and passed' >&2
  exit 1
}

# A verification run that accepts the drift outright is a failure.
drift_status=0
run_drift_hook accepted >/dev/null 2>&1 || drift_status=$?
[ "$drift_status" -ne 0 ] || {
  printf '%s\n' 'Beszel drift hook accepted a verification run that passed on drift' >&2
  exit 1
}

# `set +x` in the hook keeps a caller's -x trace from echoing the capture handling.
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
