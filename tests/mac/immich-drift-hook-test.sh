#!/bin/sh
# Regression proof for drift/70-immich.sh: the hook must anchor on the guard's
# fail_msg, not the task banner, which prints even when the guard passes (#428).
# Captures reproduce ansible-core's own output, including the no_log censored line.
set -eu
set +x
umask 077

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-immich-drift-hook.XXXXXX")
temporary_input=$(CDPATH= cd -- "$temporary_input" && pwd -P)
fixture_root=$temporary_input/repo
fake_bin=$temporary_input/bin

cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$temporary_input" ] && [ ! -L "$temporary_input" ]; then
    find "$temporary_input" -depth -mindepth 1 -delete
    rmdir -- "$temporary_input"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

fail() {
  printf 'immich-drift-hook-error: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$fixture_root/tests/mac/hooks/drift" "$fixture_root/tests" \
  "$fixture_root/inventory" "$fake_bin"
cp "$repo_dir/tests/mac/hooks/drift/70-immich.sh" \
  "$fixture_root/tests/mac/hooks/drift/70-immich.sh"
cp "$repo_dir/tests/mac/lib.sh" "$fixture_root/tests/mac/lib.sh"
chmod 0755 "$fixture_root/tests/mac/hooks/drift/70-immich.sh"
: > "$fixture_root/verify.yml"
: > "$fixture_root/inventory/mac.yml"

# The contract runner is stubbed; both drift phases are logged so a hook that stops
# installing or confirming the fixture is still caught.
cat > "$fixture_root/tests/mac/run-immich-contract.sh" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "${1-}" >> "${PLATFORM_HOOK_EVENTS:?}"
STUB
chmod 0755 "$fixture_root/tests/mac/run-immich-contract.sh"

cat > "$fixture_root/tests/assert-no-vault-secrets.rb" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' SECRET_SCAN >> "${PLATFORM_HOOK_EVENTS:?}"
exit 0
STUB
chmod 0755 "$fixture_root/tests/assert-no-vault-secrets.rb"

cat > "$fake_bin/ansible-playbook" <<'STUB'
#!/bin/sh
case " $* " in
  *"/verify.yml "*" --tags platform_verify_immich "*) ;;
  *) printf '%s\n' 'Immich hook did not select isolated verification' >&2; exit 4 ;;
esac
case " $* " in
  *" -e @${PLATFORM_MAC_FIXTURE_VARS_FILE:?} "*) ;;
  *) printf '%s\n' 'Immich hook did not pass its fixture variables' >&2; exit 4 ;;
esac
printf '%s\n' VERIFY_IMMICH >> "${PLATFORM_HOOK_EVENTS:?}"
printf '%s\n' 'PLAY [nas] *********************************************************************'
case ${PLATFORM_HOOK_SCENARIO:?} in
  accepted)
    printf '%s\n' 'TASK [managed_users : Verify exact Immich managed user preferences] *************'
    exit 0
    ;;
  guard-passed)
    # The plant: the preferences guard passed and the run failed one task later.
    printf '%s\n' 'TASK [managed_users : Verify exact Immich managed user preferences] *************'
    printf '%s\n' 'TASK [immich : Require the managed Immich settings] *****************************'
    printf '%s\n' '[ERROR]: Task failed: Action failed: The managed Immich settings are absent or drifted.'
    exit 2
    ;;
  refusal)
    printf '%s\n' 'TASK [managed_users : Verify exact Immich managed user preferences] *************'
    printf '%s\n' "[ERROR]: Task failed: Action failed: An Immich managed user's declared preference leaves differ from its effective profile."
    printf '%s\n' 'failed: [nas] (item=(censored due to no_log)) => {"censored": "the output has been hidden due to the fact that '"'"'no_log: true'"'"' was specified for this result", "changed": false}'
    exit 2
    ;;
esac
printf '%s\n' 'unknown Immich hook scenario' >&2
exit 4
STUB
chmod 0755 "$fake_bin/ansible-playbook"

run_hook() {
  scenario=$1
  case_root=$temporary_input/$scenario
  report_root=$case_root/reports
  mkdir -p "$report_root"
  chmod 0700 "$report_root"
  : > "$case_root/vault.yml"
  : > "$case_root/password"
  : > "$case_root/fixture-vars.yml"
  : > "$case_root/events"
  PLATFORM_REPORT_ROOT="$report_root" \
    PLATFORM_MAC_VAULT_FILE="$case_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$case_root/password" \
    PLATFORM_MAC_FIXTURE_VARS_FILE="$case_root/fixture-vars.yml" \
    PLATFORM_HOOK_EVENTS="$case_root/events" \
    PLATFORM_HOOK_SCENARIO="$scenario" \
    PATH="$fake_bin:$PATH" \
    "$fixture_root/tests/mac/hooks/drift/70-immich.sh"
}

# The hook accepts a run that refused with the preferences guard's own fail_msg.
run_hook refusal || fail 'Immich drift hook refused the guard'\''s own diagnostic'
refusal_root=$temporary_input/refusal
grep -qx drift "$refusal_root/events" ||
  fail 'Immich drift hook did not install its drift fixture'
grep -qx drift-verify "$refusal_root/events" ||
  fail 'Immich drift hook did not confirm its drift fixture landed'
grep -qx VERIFY_IMMICH "$refusal_root/events" ||
  fail 'Immich drift hook did not run the isolated verification'
grep -qx SECRET_SCAN "$refusal_root/events" ||
  fail 'Immich drift hook did not scan its capture for vault secrets'
find "$refusal_root/reports" -mindepth 1 -maxdepth 1 -print -quit | grep -q . &&
  fail 'Immich drift hook retained its raw verification output'

# The discriminator (#428).
guard_status=0
run_hook guard-passed >/dev/null 2>&1 || guard_status=$?
[ "$guard_status" -ne 0 ] ||
  fail 'Immich drift hook accepted a run in which its guard ran and passed'

accepted_status=0
run_hook accepted >/dev/null 2>&1 || accepted_status=$?
[ "$accepted_status" -ne 0 ] ||
  fail 'Immich drift hook accepted a verification run that passed on drift'

printf '%s\n' 'Immich drift hook regression passed'
