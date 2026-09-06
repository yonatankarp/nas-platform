#!/bin/sh
# Regression proof for tests/mac/hooks/drift/70-immich.sh.
#
# The hook exists to prove that a verification-only run refuses installed Immich
# drift. What it can get wrong -- and did, until #428 -- is *which* text it reads
# back to decide that. Ansible prints "TASK [<name>]" whenever a task merely
# runs, before anything is known about the outcome, so an anchor on the task name
# is satisfied by the guard executing and passing while the run failed somewhere
# else. That is exactly reachable here: tests/contracts/immich-runtime.rb's drift
# mode installs a system-configuration drift alongside the managed-user
# preference drift, and "Require the managed Immich settings" runs strictly after
# "Verify exact Immich managed user preferences" in roles/immich/tasks/main.yml.
# A preferences guard that stopped refusing would still fail the run at the
# settings guard, one task later, with the task-name anchor none the wiser.
#
# The guard-passed case below is that plant, as a capture. It is the discriminator:
# the hook must refuse it. The other two cases pin the properties the hook already
# had, so a future rewrite of the anchor cannot trade them away.
#
# The captures are ansible-core 2.21.3's own output, reproduced rather than
# invented: the role-qualified TASK banner, the "[ERROR]: Task failed: Action
# failed: <fail_msg>" line, and -- for the preferences guard, which carries
# no_log: true -- the censored item line that accompanies it. That last pair is
# the reason this hook can anchor on a diagnostic at all, and is why it is
# written out here rather than summarized.
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

# The contract runner is stubbed: this test is about what the hook reads back
# from the verification run, not about what the Immich contract then does. Both
# drift phases are logged so a hook that stopped installing the fixture, or
# stopped confirming it landed, is still caught here.
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
    printf '%s\n' 'TASK [immich : Verify exact Immich managed user preferences] ********************'
    exit 0
    ;;
  guard-passed)
    # The plant. The preferences guard ran and passed -- its banner is printed
    # either way -- and the run failed one task later on the settings drift the
    # same fixture installs.
    printf '%s\n' 'TASK [immich : Verify exact Immich managed user preferences] ********************'
    printf '%s\n' 'TASK [immich : Require the managed Immich settings] *****************************'
    printf '%s\n' '[ERROR]: Task failed: Action failed: The managed Immich settings are absent or drifted.'
    exit 2
    ;;
  refusal)
    printf '%s\n' 'TASK [immich : Verify exact Immich managed user preferences] ********************'
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

# The discriminator (#428). The preferences guard ran and passed; the run failed
# at the settings guard one task later. Every task name the hook could anchor on
# is present, and the guard the hook exists to prove refused nothing.
guard_status=0
run_hook guard-passed >/dev/null 2>&1 || guard_status=$?
[ "$guard_status" -ne 0 ] ||
  fail 'Immich drift hook accepted a run in which its guard ran and passed'

# The property the hook already had: a verification run that accepts the drift
# outright is a failure, not a pass.
accepted_status=0
run_hook accepted >/dev/null 2>&1 || accepted_status=$?
[ "$accepted_status" -ne 0 ] ||
  fail 'Immich drift hook accepted a verification run that passed on drift'

printf '%s\n' 'Immich drift hook regression passed'
