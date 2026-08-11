#!/bin/sh
set -eu
set +x

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-dozzle-drift-hook.XXXXXX")
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

mkdir -p "$fixture_root/tests/mac/hooks/drift" "$fixture_root/tests/mac" \
  "$fixture_root/tests" "$fixture_root/inventory" "$fake_bin"
cp "$repo_dir/tests/mac/hooks/drift/20-dozzle.sh" \
  "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh"
cp "$repo_dir/tests/mac/lib.sh" "$fixture_root/tests/mac/lib.sh"
chmod 0755 "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh"
: > "$fixture_root/site.yml"
: > "$fixture_root/verify.yml"
: > "$fixture_root/inventory/mac.yml"

cat > "$fixture_root/tests/mac/run-dozzle-contract.sh" <<'STUB'
#!/bin/sh
mode=${1-}
printf '%s\n' "$mode" >> "${PLATFORM_HOOK_EVENTS:?}"
case $mode in
  check-mixed-create)
    : > "${PLATFORM_HOOK_FIXTURE:?}"
    ;;
  check-mixed-recover)
    unlink "${PLATFORM_HOOK_FIXTURE:?}" 2>/dev/null || true
    : > "${PLATFORM_HOOK_RECOVERED:?}"
    ;;
  assert-check-mixed-output)
    [ "${PLATFORM_HOOK_SCENARIO:?}" != assertion-failure ]
    ;;
esac
STUB
chmod 0755 "$fixture_root/tests/mac/run-dozzle-contract.sh"

cat > "$fixture_root/tests/mac/verify.sh" <<'STUB'
#!/bin/sh
printf '%s\n' VERIFY_ALL >> "${PLATFORM_HOOK_EVENTS:?}"
printf '%s\n' 'Beszel verification failed because fixture drift remains.' >&2
exit 1
STUB
chmod 0755 "$fixture_root/tests/mac/verify.sh"

cat > "$fixture_root/tests/assert-no-vault-secrets.rb" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 0755 "$fixture_root/tests/assert-no-vault-secrets.rb"

cat > "$fake_bin/ansible-playbook" <<'STUB'
#!/bin/sh
case " $* " in
  *" --check "*)
    if [ "${PLATFORM_HOOK_SCENARIO:?}" = signal ]; then
      : > "${PLATFORM_HOOK_READY:?}"
      sleep 1
    fi
    cat <<'OUTPUT'
TASK [dozzle : Report planned managed Dozzle dispatcher creation]
TASK [dozzle : Report planned managed Dozzle dispatcher repair]
TASK [dozzle : Report planned managed Dozzle alert rule creation]
TASK [dozzle : Report planned managed Dozzle alert rule repair]
TASK [dozzle : Report planned managed Dozzle alert rule enabled-state repair]
TASK [dozzle : Report planned unmanaged Dozzle alert rule removal]
TASK [dozzle : Report planned unmanaged Dozzle dispatcher removal]
DOZZLE_PLAN_DISPATCHER_REPAIR
DOZZLE_PLAN_RULE_CREATE
DOZZLE_PLAN_RULE_REPAIR
DOZZLE_PLAN_RULE_ENABLE_REPAIR
DOZZLE_PLAN_RULE_REMOVE
DOZZLE_PLAN_DISPATCHER_REMOVE
mac : ok=1 changed=6 unreachable=0 failed=0 skipped=6 rescued=0 ignored=0
OUTPUT
    ;;
  *)
    printf '%s\n' VERIFY_DOZZLE >> "${PLATFORM_HOOK_EVENTS:?}"
    if [ "${PLATFORM_HOOK_SCENARIO:?}" = dozzle-accept ]; then
      exit 0
    fi
    printf '%s\n' 'Dozzle ntfy dispatcher is absent or drifted.' >&2
    exit 2
    ;;
esac
STUB
chmod 0755 "$fake_bin/ansible-playbook"

run_hook() {
  scenario=$1
  case_root=$temporary_input/$scenario
  report_root=$case_root/reports
  mkdir -p "$report_root"
  : > "$case_root/vault.yml"
  : > "$case_root/password"
  : > "$case_root/events"
  PLATFORM_REPORT_ROOT="$report_root" \
    PLATFORM_MAC_VAULT_FILE="$case_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$case_root/password" \
    PLATFORM_HOOK_EVENTS="$case_root/events" \
    PLATFORM_HOOK_FIXTURE="$case_root/fixture" \
    PLATFORM_HOOK_RECOVERED="$case_root/recovered" \
    PLATFORM_HOOK_READY="$case_root/ready" \
    PLATFORM_HOOK_SCENARIO="$scenario" \
    PATH="$fake_bin:$PATH" \
    "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh"
}

false_status=0
run_hook dozzle-accept >/dev/null 2>&1 || false_status=$?
[ "$false_status" -ne 0 ] &&
  [ -f "$temporary_input/dozzle-accept/recovered" ] &&
  [ ! -e "$temporary_input/dozzle-accept/fixture" ] || {
  printf '%s\n' 'Dozzle drift hook accepted a Beszel-only failure or did not recover' >&2
  exit 1
}

run_hook success
success_root=$temporary_input/success
[ -f "$success_root/fixture" ] && [ ! -e "$success_root/recovered" ] || {
  printf '%s\n' 'successful Dozzle drift hook did not leave only its fixture for reconcile' >&2
  exit 1
}
! grep -q '^VERIFY_ALL$' "$success_root/events" || {
  printf '%s\n' 'Dozzle drift hook used all-service verification' >&2
  exit 1
}
[ -z "$(find "$success_root/reports" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
  printf '%s\n' 'successful Dozzle drift hook retained raw report output' >&2
  exit 1
}

assertion_status=0
run_hook assertion-failure >/dev/null 2>&1 || assertion_status=$?
[ "$assertion_status" -ne 0 ] &&
  [ -f "$temporary_input/assertion-failure/recovered" ] &&
  [ ! -e "$temporary_input/assertion-failure/fixture" ] || {
  printf '%s\n' 'Dozzle drift assertion failure did not recover its fixture' >&2
  exit 1
}

for signal in HUP INT TERM; do
  case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
  signal_root=$temporary_input/signal-$signal
  mkdir -p "$signal_root/reports"
  : > "$signal_root/vault.yml"
  : > "$signal_root/password"
  : > "$signal_root/events"
  signal_status_file=$signal_root/status
  PLATFORM_REPORT_ROOT="$signal_root/reports" \
    PLATFORM_MAC_VAULT_FILE="$signal_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$signal_root/password" \
    PLATFORM_HOOK_EVENTS="$signal_root/events" \
    PLATFORM_HOOK_FIXTURE="$signal_root/fixture" \
    PLATFORM_HOOK_RECOVERED="$signal_root/recovered" \
    PLATFORM_HOOK_READY="$signal_root/ready" \
    PLATFORM_HOOK_SCENARIO=signal \
    PATH="$fake_bin:$PATH" \
    ruby - "$signal" "$fixture_root/tests/mac/hooks/drift/20-dozzle.sh" \
      "$signal_root/ready" "$signal_status_file" <<'RUBY'
signal, hook, ready, status_file = ARGV
pid = Process.spawn(hook, out: File::NULL, err: File::NULL)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
until File.file?(ready)
  if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    Process.kill("KILL", pid)
    Process.wait(pid)
    abort "Dozzle drift hook did not reach signal fixture for #{signal}"
  end
  sleep 0.02
end
Process.kill(signal, pid)
_waited, status = Process.wait2(pid)
File.write(status_file, status.exitstatus.to_s)
RUBY
  signal_status=$(cat "$signal_status_file")
  [ "$signal_status" -eq "$expected" ] &&
    [ -f "$signal_root/recovered" ] &&
    [ ! -e "$signal_root/fixture" ] &&
    [ -z "$(find "$signal_root/reports" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
    printf 'Dozzle drift hook mishandled %s (status %s)\n' "$signal" "$signal_status" >&2
    exit 1
  }
done

printf '%s\n' 'Mac Dozzle drift hook: isolated proof, cleanup, recovery, and signals hold'
