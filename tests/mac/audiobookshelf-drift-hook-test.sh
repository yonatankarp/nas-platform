#!/bin/sh
set -eu
set +x

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-audiobookshelf-drift-hook.XXXXXX")
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

mkdir -p "$temporary_input/contract-self-test/media" "$temporary_input/contract-self-test/reports"
chmod 0700 "$temporary_input/contract-self-test/reports"
PLATFORM_MEDIA_ROOT="$temporary_input/contract-self-test/media" \
  PLATFORM_REPORT_ROOT="$temporary_input/contract-self-test/reports" \
  "$repo_dir/tests/contracts/audiobookshelf.sh" drift-recovery-self-test

mkdir -p "$fixture_root/tests/mac/hooks/drift" "$fixture_root/tests/mac" \
  "$fixture_root/tests" "$fixture_root/inventory" "$fake_bin"
cp "$repo_dir/tests/mac/hooks/drift/30-audiobookshelf.sh" \
  "$fixture_root/tests/mac/hooks/drift/30-audiobookshelf.sh"
cp "$repo_dir/tests/mac/lib.sh" "$fixture_root/tests/mac/lib.sh"
chmod 0755 "$fixture_root/tests/mac/hooks/drift/30-audiobookshelf.sh"
: > "$fixture_root/verify.yml"
: > "$fixture_root/inventory/mac.yml"

cat > "$fixture_root/tests/mac/run-audiobookshelf-contract.sh" <<'STUB'
#!/bin/sh
set -eu
mode=${1-}
printf '%s\n' "$mode" >> "${PLATFORM_HOOK_EVENTS:?}"
case $mode in
  drift)
    cp "${PLATFORM_HOOK_STATE:?}" "${PLATFORM_HOOK_SNAPSHOT:?}"
    chmod 0600 "${PLATFORM_HOOK_SNAPSHOT:?}"
    cat > "${PLATFORM_HOOK_STATE:?}" <<'STATE'
provider=audible
icon=podcast
settings={"disableWatcher":true,"metadataPrecedence":["audioMetatags"]}
serverSettings={"scannerParseSubtitle":false,"backupSchedule":"0 4 * * *","backupsToKeep":2,"loggerDailyLogsToKeep":5}
STATE
    : > "${PLATFORM_HOOK_FIXTURE:?}"
    ;;
  drift-recover)
    [ -f "${PLATFORM_HOOK_SNAPSHOT:?}" ] && [ ! -L "${PLATFORM_HOOK_SNAPSHOT:?}" ]
    if [ "$(uname -s)" = Darwin ]; then
      snapshot_mode=$(stat -f '%Lp' "${PLATFORM_HOOK_SNAPSHOT:?}")
    else
      snapshot_mode=$(stat -c '%a' "${PLATFORM_HOOK_SNAPSHOT:?}")
    fi
    [ "$snapshot_mode" = 600 ]
    cp "${PLATFORM_HOOK_SNAPSHOT:?}" "${PLATFORM_HOOK_STATE:?}"
    cmp -s "${PLATFORM_HOOK_STATE:?}" "${PLATFORM_HOOK_EXPECTED_STATE:?}"
    unlink "${PLATFORM_HOOK_SNAPSHOT:?}"
    unlink "${PLATFORM_HOOK_FIXTURE:?}" 2>/dev/null || true
    : > "${PLATFORM_HOOK_RECOVERED:?}"
    ;;
  drift-commit)
    grep -qxF 'provider=audible' "${PLATFORM_HOOK_STATE:?}"
    grep -qxF 'icon=podcast' "${PLATFORM_HOOK_STATE:?}"
    grep -qxF 'settings={"disableWatcher":true,"metadataPrecedence":["audioMetatags"]}' \
      "${PLATFORM_HOOK_STATE:?}"
    grep -qxF 'serverSettings={"scannerParseSubtitle":false,"backupSchedule":"0 4 * * *","backupsToKeep":2,"loggerDailyLogsToKeep":5}' \
      "${PLATFORM_HOOK_STATE:?}"
    [ -f "${PLATFORM_HOOK_SNAPSHOT:?}" ]
    ;;
  run)
    cmp -s "${PLATFORM_HOOK_STATE:?}" "${PLATFORM_HOOK_EXPECTED_STATE:?}"
    grep -qxF 'serverSettings={"scannerParseSubtitle":true,"backupSchedule":"0 3 * * *","backupsToKeep":7,"loggerDailyLogsToKeep":5}' \
      "${PLATFORM_HOOK_STATE:?}"
    grep -qxF 'serverSettings={"scannerParseSubtitle":true,"backupSchedule":"0 3 * * *","backupsToKeep":7,"loggerDailyLogsToKeep":5}' \
      "${PLATFORM_HOOK_SNAPSHOT:?}"
    unlink "${PLATFORM_HOOK_SNAPSHOT:?}"
    ;;
esac
STUB
chmod 0755 "$fixture_root/tests/mac/run-audiobookshelf-contract.sh"

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
  *"/verify.yml "*" --tags platform_verify_audiobookshelf "*) ;;
  *) printf '%s\n' 'Audiobookshelf hook did not select isolated verification' >&2; exit 4 ;;
esac
printf '%s\n' VERIFY_AUDIOBOOKSHELF >> "${PLATFORM_HOOK_EVENTS:?}"
case ${PLATFORM_HOOK_SCENARIO:?} in
  audiobookshelf-accept) exit 0 ;;
  missing-diagnostic) printf '%s\n' 'unrelated verification failure' >&2; exit 2 ;;
  signal)
    : > "${PLATFORM_HOOK_READY:?}"
    sleep 1
    ;;
esac
printf '%s\n' 'The managed Audiobookshelf server settings or library are absent, duplicated, surplus, or drifted.' >&2
exit 2
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
  cat > "$case_root/expected-state" <<'STATE'
provider=google
icon=database
settings={"disableWatcher":false,"metadataPrecedence":["folderStructure","audioMetatags"]}
serverSettings={"scannerParseSubtitle":true,"backupSchedule":"0 3 * * *","backupsToKeep":7,"loggerDailyLogsToKeep":5}
STATE
  cp "$case_root/expected-state" "$case_root/state"
  PLATFORM_REPORT_ROOT="$report_root" \
    PLATFORM_MAC_VAULT_FILE="$case_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$case_root/password" \
    PLATFORM_HOOK_EVENTS="$case_root/events" \
    PLATFORM_HOOK_FIXTURE="$case_root/fixture" \
    PLATFORM_HOOK_SNAPSHOT="$report_root/audiobookshelf-drift-snapshot.json" \
    PLATFORM_HOOK_STATE="$case_root/state" \
    PLATFORM_HOOK_EXPECTED_STATE="$case_root/expected-state" \
    PLATFORM_HOOK_RECOVERED="$case_root/recovered" \
    PLATFORM_HOOK_READY="$case_root/ready" \
    PLATFORM_HOOK_SCENARIO="$scenario" \
    PATH="$fake_bin:$PATH" \
    "$fixture_root/tests/mac/hooks/drift/30-audiobookshelf.sh"
}

false_status=0
run_hook audiobookshelf-accept >/dev/null 2>&1 || false_status=$?
[ "$false_status" -ne 0 ] &&
  [ -f "$temporary_input/audiobookshelf-accept/recovered" ] &&
  [ ! -e "$temporary_input/audiobookshelf-accept/fixture" ] &&
  [ ! -e "$temporary_input/audiobookshelf-accept/reports/audiobookshelf-drift-snapshot.json" ] &&
  cmp -s "$temporary_input/audiobookshelf-accept/state" \
    "$temporary_input/audiobookshelf-accept/expected-state" || {
  printf '%s\n' 'Audiobookshelf drift hook accepted unrelated all-service failure or did not recover' >&2
  exit 1
}

run_hook success
success_root=$temporary_input/success
[ -f "$success_root/fixture" ] && [ ! -e "$success_root/recovered" ] &&
  [ -f "$success_root/reports/audiobookshelf-drift-snapshot.json" ] || {
  printf '%s\n' 'successful Audiobookshelf drift hook did not leave only its fixture for reconcile' >&2
  exit 1
}
grep -q '^drift-commit$' "$success_root/events" || {
  printf '%s\n' 'successful Audiobookshelf drift hook did not finalize its snapshot' >&2
  exit 1
}
! grep -q '^VERIFY_ALL$' "$success_root/events" || {
  printf '%s\n' 'Audiobookshelf drift hook used all-service verification' >&2
  exit 1
}
grep -q '^VERIFY_AUDIOBOOKSHELF$' "$success_root/events"
find "$success_root/reports" -mindepth 1 -maxdepth 1 ! -name audiobookshelf-drift-snapshot.json \
  -print -quit | grep -q . && {
  printf '%s\n' 'successful Audiobookshelf drift hook retained unexpected raw verification output' >&2
  exit 1
}
cp "$success_root/expected-state" "$success_root/state"
PLATFORM_HOOK_EVENTS="$success_root/events" \
  PLATFORM_HOOK_SNAPSHOT="$success_root/reports/audiobookshelf-drift-snapshot.json" \
  PLATFORM_HOOK_STATE="$success_root/state" \
  PLATFORM_HOOK_EXPECTED_STATE="$success_root/expected-state" \
  PLATFORM_HOOK_FIXTURE="$success_root/fixture" \
  "$fixture_root/tests/mac/run-audiobookshelf-contract.sh" run
[ ! -e "$success_root/reports/audiobookshelf-drift-snapshot.json" ] || {
  printf '%s\n' 'reconciliation verification did not consume the drift snapshot' >&2
  exit 1
}

diagnostic_status=0
run_hook missing-diagnostic >/dev/null 2>&1 || diagnostic_status=$?
[ "$diagnostic_status" -ne 0 ] &&
  [ -f "$temporary_input/missing-diagnostic/recovered" ] &&
  [ ! -e "$temporary_input/missing-diagnostic/fixture" ] &&
  [ ! -e "$temporary_input/missing-diagnostic/reports/audiobookshelf-drift-snapshot.json" ] &&
  cmp -s "$temporary_input/missing-diagnostic/state" \
    "$temporary_input/missing-diagnostic/expected-state" || {
  printf '%s\n' 'Audiobookshelf fixed-diagnostic failure did not recover its fixture' >&2
  exit 1
}

for signal in HUP INT TERM; do
  case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
  signal_root=$temporary_input/signal-$signal
  mkdir -p "$signal_root/reports"
  : > "$signal_root/vault.yml"
  : > "$signal_root/password"
  : > "$signal_root/events"
  cat > "$signal_root/expected-state" <<'STATE'
provider=google
icon=database
settings={"disableWatcher":false,"metadataPrecedence":["folderStructure","audioMetatags"]}
serverSettings={"scannerParseSubtitle":true,"backupSchedule":"0 3 * * *","backupsToKeep":7,"loggerDailyLogsToKeep":5}
STATE
  cp "$signal_root/expected-state" "$signal_root/state"
  signal_status_file=$signal_root/status
  PLATFORM_REPORT_ROOT="$signal_root/reports" \
    PLATFORM_MAC_VAULT_FILE="$signal_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$signal_root/password" \
    PLATFORM_HOOK_EVENTS="$signal_root/events" \
    PLATFORM_HOOK_FIXTURE="$signal_root/fixture" \
    PLATFORM_HOOK_SNAPSHOT="$signal_root/reports/audiobookshelf-drift-snapshot.json" \
    PLATFORM_HOOK_STATE="$signal_root/state" \
    PLATFORM_HOOK_EXPECTED_STATE="$signal_root/expected-state" \
    PLATFORM_HOOK_RECOVERED="$signal_root/recovered" \
    PLATFORM_HOOK_READY="$signal_root/ready" \
    PLATFORM_HOOK_SCENARIO=signal \
    PATH="$fake_bin:$PATH" \
    ruby - "$signal" "$fixture_root/tests/mac/hooks/drift/30-audiobookshelf.sh" \
      "$signal_root/ready" "$signal_status_file" <<'RUBY'
signal, hook, ready, status_file = ARGV
pid = Process.spawn(hook, out: File::NULL, err: File::NULL)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
until File.file?(ready)
  if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    Process.kill("KILL", pid)
    Process.wait(pid)
    abort "Audiobookshelf drift hook did not reach signal fixture for #{signal}"
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
    [ ! -e "$signal_root/reports/audiobookshelf-drift-snapshot.json" ] &&
    cmp -s "$signal_root/state" "$signal_root/expected-state" &&
    [ -z "$(find "$signal_root/reports" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
    printf 'Audiobookshelf drift hook mishandled %s (status %s)\n' "$signal" "$signal_status" >&2
    exit 1
  }
done

printf '%s\n' 'Mac Audiobookshelf drift hook: isolated proof, cleanup, recovery, and signals hold'
